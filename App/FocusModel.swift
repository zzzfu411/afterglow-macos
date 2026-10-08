import SwiftUI
import WidgetKit
import UniformTypeIdentifiers

/// All file transactions run off the main actor and are serialized with reads.
private actor FocusStoreExecutor {
    let store: FocusStore
    init(_ store: FocusStore) { self.store = store }
    func snapshot() throws -> StoreChange { StoreChange(state: try store.snapshot()) }
    func actions(_ actions: [FocusAction]) throws -> StoreChange { StoreChange(state: try store.performActions(actions)) }
    func todos(_ actions: [FocusAction]) throws -> StoreChange {
        let result = try store.performTodoActions(actions)
        return StoreChange(state: result.state, undo: result.undo)
    }
    func undo(_ record: TodoUndoRecord) throws -> StoreChange {
        let result = try store.undoTodo(record)
        return StoreChange(state: result.state, undo: result.undo)
    }
    func previewImport(_ url: URL) throws -> StoreChange {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let archive = try TodoTransfer.read(from: url)
        let latest = try store.snapshot()
        let preview = try TodoTransfer.preview(archive, mergingInto: latest)
        return StoreChange(state: latest, importRequest: TodoImportRequest(archive: archive, preview: preview))
    }
    func merge(_ request: TodoImportRequest) throws -> StoreChange {
        let result = try TodoTransfer.mergeArchive(request.archive, into: store, preview: request.preview)
        return StoreChange(state: result.state, undo: result.undo)
    }
    func export(_ url: URL) throws -> StoreChange {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let latest = try store.snapshot()
        try TodoTransfer.export(TodoTransfer.archive(from: latest), to: url)
        return StoreChange(state: latest)
    }
    func intent(_ action: FocusModel.IntentAction) throws -> StoreChange {
        let state: FocusState
        switch action {
        case .toggle: state = try store.toggle()
        case .finish: state = try store.update(.finish)
        case .rest: state = try store.startRest()
        case .reset: state = try store.update(.reset)
        }
        return StoreChange(state: state)
    }
}
private struct StoreChange: Sendable {
    let state: FocusState
    var undo: TodoUndoRecord? = nil
    var importRequest: TodoImportRequest? = nil
}
struct TodoImportRequest: Sendable {
    let archive: TodoArchive
    let preview: TodoImportPreview
}

@MainActor
final class FocusModel: ObservableObject {
    static let shared = FocusModel(preferences: .standard)
    @Published private(set) var state = FocusState()
    @Published var error: String?
    @Published var notice: String?
    @Published var showHistory = false
    @Published var showFocus = false
    @Published var showSearch = false
    @Published var searchRequest = 0
    @Published var showSidebar: Bool { didSet { preferences?.set(showSidebar, forKey: "afterglow.sidebar-visible") } }
    @Published var section: TodoSection {
        didSet { preferences?.set(section.persistenceKey, forKey: "moro.section"); selectedTodoID = nil; pageSize = 100; rebuildTodos() }
    }
    @Published var sort: TodoSort {
        didSet { preferences?.set(sort.rawValue, forKey: "moro.sort"); rebuildTodos() }
    }
    @Published var searchText = "" { didSet { selectedTodoID = nil; pageSize = 100; rebuildTodos() } }
    @Published var selectedTodoID: UUID?
    @Published var quickEntryText = ""
    @Published var quickEntryRequest = 0
    @Published var todoDraft: TodoDraft?
    @Published var todoToDelete: FocusTodo?
    @Published var pendingFocusID: UUID?
    @Published var pendingPurgeIDs: [UUID] = []
    @Published var pendingImport: TodoImportRequest?
    @Published var isEditingDuration = false
    @Published private(set) var isBusy = false
    @Published private(set) var visibleTodos: [FocusTodo] = []
    @Published private(set) var visibleTodoCount = 0
    @Published private(set) var collections: [TodoCollection] = []
    @Published private(set) var canUndoTodo = false
    @Published private(set) var canRedoTodo = false
    let reminders: FocusReminders?
    let todoReminders: TodoReminders?
    private let store: FocusStore
    private let worker: FocusStoreExecutor
    private let preferences: UserDefaults?
    private var deadlineTimer: Timer?
    private var dayTimer: Timer?
    private var scheduledDeadline: Date?
    private var observation: FocusStoreObservation?
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var operation: Task<Void, Never>?
    private var pendingWrites = 0
    private var refreshPending = false
    private var pendingForceRefresh = false
    private var refreshAgain = false
    private var pageSize = 100
    private var counts: [TodoSection: Int] = [:]
    private var undoStack: [TodoUndoRecord] = []
    private var redoStack: [TodoUndoRecord] = []

    var shared: Bool { store.isShared }
    var hasMoreTodos: Bool { visibleTodoCount > visibleTodos.count }
    var sectionTitle: String {
        if case .collection(let id) = section { return collections.first { $0.id == id }?.title ?? "清单" }
        return section.title
    }
    var allowsTimerKeyboard: Bool {
        !isEditingDuration && !showHistory && error == nil && todoToDelete == nil && todoDraft == nil && !isBusy
    }

    init(store: FocusStore = .shared, remindersEnabled: Bool = true, preferences: UserDefaults? = nil) {
        self.store = store; self.worker = FocusStoreExecutor(store); self.preferences = preferences
        showSidebar = preferences?.object(forKey: "afterglow.sidebar-visible") as? Bool ?? true
        section = TodoSection(key: preferences?.string(forKey: "moro.section"))
        sort = TodoSort(rawValue: preferences?.string(forKey: "moro.sort") ?? "deadline") ?? .deadline
        reminders = remindersEnabled ? FocusReminders(delivery: SystemReminderDelivery()) : nil
        todoReminders = remindersEnabled ? TodoReminders(delivery: SystemTodoReminderDelivery()) : nil
        observeStore(); refresh(force: true); scheduleDayBoundary()
        for name in [NSApplication.didBecomeActiveNotification, .NSSystemClockDidChange] {
            applicationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            })
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
    }
    deinit {
        deadlineTimer?.invalidate(); dayTimer?.invalidate()
        for observer in applicationObservers { NotificationCenter.default.removeObserver(observer) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    private func enqueue(write: Bool = true, force: Bool = false,
                         work: @escaping @Sendable (FocusStoreExecutor) async throws -> StoreChange,
                         success: @escaping (StoreChange) -> Void = { _ in },
                         failure: @escaping (Error) -> Void = { _ in }) {
        let previous = operation
        if write { pendingWrites += 1; isBusy = true }
        operation = Task { [weak self, worker] in
            await previous?.value
            do {
                let result = try await work(worker)
                guard let self else { return }
                self.accept(result.state, force: force)
                success(result)
            } catch {
                guard let self else { return }
                self.error = error is DecodingError ? "记录文件格式异常，原文件已保留。" : error.localizedDescription
                failure(error)
            }
            if let self, write { self.pendingWrites -= 1; self.isBusy = self.pendingWrites > 0 }
        }
    }
    /// Used by tests, intent handlers, and the final installation check.
    func flush() async {
        repeat { await operation?.value } while isBusy || refreshPending
        await reminders?.flush(); await todoReminders?.flush()
    }
    private func observeStore() {
        do {
            observation = try FocusStoreObservation(directory: store.directoryURL) { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func resume() {
        observeStore(); refresh(force: true); scheduleDayBoundary()
    }
    func refresh(force: Bool = false) {
        guard !refreshPending else { refreshAgain = true; pendingForceRefresh = pendingForceRefresh || force; return }
        refreshPending = true
        enqueue(write: false, force: force, work: { try await $0.snapshot() }, success: { [weak self] _ in
            guard let self else { return }
            self.refreshPending = false
            if self.refreshAgain {
                let force = self.pendingForceRefresh
                self.refreshAgain = false; self.pendingForceRefresh = false; self.refresh(force: force)
            }
        }, failure: { [weak self] _ in self?.refreshPending = false })
    }
    func retryStorage() { error = nil; refresh(force: true) }

    @discardableResult func send(_ action: FocusAction) -> Bool {
        guard !isBusy else { return false }
        enqueue(work: { try await $0.actions([action]) }, success: { [weak self] result in
            if result.state.status == .running { self?.reminders?.reconcile(result.state, requestPermission: true) }
        })
        return true
    }
    private func changeTodos(_ actions: [FocusAction], permission: Bool = false, success: @escaping () -> Void = {}) {
        guard !isBusy else { return }
        enqueue(work: { try await $0.todos(actions) }, success: { [weak self] change in
            guard let self else { return }
            if let undo = change.undo { self.pushUndo(undo); self.redoStack.removeAll(); self.updateUndoAvailability() }
            if permission { self.todoReminders?.reconcile(todos: change.state.todos, requestPermission: true) }
            success()
        })
    }
    func newTodo() {
        if section == .completed || section == .trash { section = .inbox }
        searchText = ""; showFocus = false; showHistory = false; quickEntryRequest += 1
    }
    func captureInbox(title: String) async throws -> UUID {
        let item = FocusTodo(title: title, createdAt: Date(), sortOrder: nextSortOrder)
        guard item.isValid else { throw FocusStoreError.invalidTodoAction }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(work: { try await $0.todos([.upsertTodo(item)]) }, success: { [weak self] change in
                if let undo = change.undo { self?.pushUndo(undo); self?.redoStack.removeAll(); self?.updateUndoAvailability() }
                continuation.resume()
            }, failure: { continuation.resume(throwing: $0) })
        }
        return item.id
    }
    func quickAddTodo() {
        let title = quickEntryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isBusy else { return }
        var item = FocusTodo(title: title, createdAt: Date(), sortOrder: nextSortOrder)
        if case .collection(let id) = section { item.listID = id }
        if section == .today { item.plannedDate = Calendar.current.startOfDay(for: Date()) }
        guard item.isValid else { notice = "标题最多 \(FocusTodo.maximumTitleLength) 字"; return }
        let typed = quickEntryText
        let routeToInbox = section == .upcoming
        let previousQuery = searchText
        changeTodos([.upsertTodo(item)]) { [weak self] in
            guard let self else { return }
            if self.quickEntryText == typed { self.quickEntryText = "" }
            if self.searchText == previousQuery { self.searchText = "" }
            if routeToInbox && self.section == .upcoming { self.section = .inbox }
            self.selectedTodoID = item.id; self.quickEntryRequest += 1
        }
    }
    private var nextSortOrder: Int { min(1_000_000_000, (state.todos.map(\.sortOrder).max() ?? -1) + 1) }
    func selectTodo(_ id: UUID) { selectedTodoID = id }
    func editTodo(_ id: UUID) {
        guard let item = state.todos.first(where: { $0.id == id }), !item.isDeleted else { return }
        if todoDraft?.id == id { return }
        if let draft = todoDraft, draft.id != id {
            let old = state.todos.first { $0.id == draft.id }
            if !draft.sameEditableFields(as: TodoDraft(item: old)) { notice = "先保存或取消当前编辑"; return }
        }
        todoDraft = TodoDraft(item: item); selectedTodoID = id
    }
    func saveTodo() {
        guard let draft = todoDraft, draft.isValid, !isBusy else { return }
        let old = state.todos.first { $0.id == draft.id }
        guard draft.isNew || old != nil else { notice = "事项已不存在，请保留内容后重新添加"; return }
        guard old?.isDeleted != true else { notice = "事项已移至最近删除，请恢复后再保存"; return }
        if let baseline = draft.baseItem, let old,
           !TodoDraft(item: baseline).sameEditableFields(as: TodoDraft(item: old)) {
            notice = "事项已在别处修改。请保留当前内容，取消后重新编辑。"; return
        }
        var item = draft.applying(to: old)
        if draft.isNew { item.sortOrder = nextSortOrder }
        let action: FocusAction = old.map { .replaceTodo(expected: $0, replacement: item) } ?? .upsertTodo(item)
        changeTodos([action], permission: item.reminderDate != nil && item.reminderDate != old?.reminderDate) { [weak self] in
            if self?.todoDraft == draft { self?.todoDraft = nil }
            else if self?.todoDraft?.id == draft.id {
                self?.todoDraft?.baseItem = self?.state.todos.first { $0.id == draft.id }
            }
        }
    }
    func cancelTodoDraft() { todoDraft = nil }
    func toggleTodo(_ id: UUID) {
        guard let item = state.todos.first(where: { $0.id == id }) else { return }
        setTodosCompleted([id], !item.isCompleted)
    }
    func completeTodo(_ id: UUID) { setTodosCompleted([id], true) }
    func setTodosCompleted(_ ids: [UUID], _ completed: Bool) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        changeTodos(ids.map { .setTodoCompleted($0, completed) }) { [weak self] in
            self?.notice = completed ? "已完成" : "已恢复待办"

        }
    }
    func trashTodo(_ id: UUID) { trashTodos([id]) }
    func trashTodos(_ ids: [UUID]) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let draft = todoDraft, ids.contains(draft.id), !draft.sameEditableFields(as: TodoDraft(item: state.todos.first { $0.id == draft.id })) {
            notice = "先保存或取消当前编辑，再删除事项"; return
        }
        changeTodos(ids.map { .trashTodo($0) }) { [weak self] in
            self?.notice = "已移至最近删除"
            if let id = self?.todoDraft?.id, ids.contains(id) { self?.todoDraft = nil }

        }
    }
    func exportTodos() {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Moro-todos-" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + ".json"
        panel.title = "导出待办归档"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.enqueue(work: { try await $0.export(url) }, success: { [weak self] _ in self?.notice = "待办已导出" })
            }
        }
    }
    func importTodos() {
        guard !isBusy, todoDraft == nil else { notice = "先保存或取消当前编辑"; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.title = "导入待办归档"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.enqueue(work: { try await $0.previewImport(url) }, success: { [weak self] change in self?.pendingImport = change.importRequest })
            }
        }
    }
    func confirmImport() {
        guard let request = pendingImport, !isBusy else { return }
        pendingImport = nil
        enqueue(work: { try await $0.merge(request) }, success: { [weak self] change in
            guard let self else { return }
            if let undo = change.undo { self.pushUndo(undo); self.redoStack.removeAll(); self.updateUndoAvailability() }
            self.searchText = ""; self.section = .all; self.notice = "待办已导入"
            self.todoReminders?.reconcile(todos: change.state.todos, requestPermission: true)
        })
    }
    func requestPurgeTodos(_ ids: [UUID]) { pendingPurgeIDs = ids }
    func confirmPurgeTodos() {
        let ids = pendingPurgeIDs; pendingPurgeIDs = []
        guard !ids.isEmpty else { return }
        changeTodos([.purgeTodos(ids)]) { [weak self] in self?.notice = "已永久删除，可在退出前撤销" }
    }
    func restoreTodo(_ id: UUID) { restoreTodos([id]) }
    func restoreTodos(_ ids: [UUID]) { changeTodos(ids.map { .restoreTodo($0) }) }
    func moveTodo(_ id: UUID, to listID: UUID?) { moveTodos([id], to: listID) }
    func moveTodos(_ ids: [UUID], to listID: UUID?) {
        let ids = Set(ids)
        changeTodos(state.todos.filter { ids.contains($0.id) }.map { item in
            var moved = item; moved.listID = listID; return .replaceTodo(expected: item, replacement: moved)
        }) { [weak self] in
            guard let self, let draft = self.todoDraft, ids.contains(draft.id) else { return }
            self.todoDraft?.listID = listID
            self.todoDraft?.baseItem?.listID = listID
        }
    }
    func scheduleTodos(_ ids: [UUID], on date: Date?) {
        let ids = Set(ids)
        changeTodos(state.todos.filter { ids.contains($0.id) && $0.isPending }.map { item in
            var planned = item; planned.plannedDate = date.map { Calendar.current.startOfDay(for: $0) }
            return .replaceTodo(expected: item, replacement: planned)
        }) { [weak self] in
            guard let self, let draft = self.todoDraft, ids.contains(draft.id) else { return }
            self.todoDraft?.plannedDate = date.map { Calendar.current.startOfDay(for: $0) }
            self.todoDraft?.baseItem?.plannedDate = self.todoDraft?.plannedDate
        }
    }
    func reorderVisibleTodos(from offsets: IndexSet, to destination: Int) {
        guard sort == .manual, searchText.isEmpty else { return }
        var ids = visibleTodos.map(\.id); ids.move(fromOffsets: offsets, toOffset: destination)
        changeTodos([.reorderTodos(ids)])
    }
    func addCollection(title: String) { changeTodos([.upsertCollection(TodoCollection(title: title))]) }
    func renameCollection(_ id: UUID, title: String) { changeTodos([.upsertCollection(TodoCollection(id: id, title: title))]) }
    func deleteCollection(_ id: UUID) {
        changeTodos([.deleteCollection(id)]) { [weak self] in
            if self?.section == .collection(id) { self?.section = .inbox }
            if self?.todoDraft?.listID == id { self?.todoDraft?.listID = nil; self?.todoDraft?.baseItem?.listID = nil }
        }
    }
    func undoTodoCompletion() { undoTodoChange() }
    func undoTodoChange() { applyUndo(redo: false) }
    func redoTodoChange() { applyUndo(redo: true) }
    private func applyUndo(redo: Bool) {
        guard !isBusy, let receipt = redo ? redoStack.last : undoStack.last else { return }
        enqueue(work: { try await $0.undo(receipt) }, success: { [weak self] result in
            guard let self else { return }
            if redo { self.redoStack.removeLast(); if let inverse = result.undo { self.pushUndo(inverse) } }
            else { self.undoStack.removeLast(); if let inverse = result.undo { self.redoStack.append(inverse) } }
            self.updateUndoAvailability(); self.notice = redo ? "已重做" : "已撤销"
        })
    }
    private func pushUndo(_ record: TodoUndoRecord) {
        undoStack.append(record)
        while undoStack.count > 20 || undoStack.reduce(0, { $0 + $1.estimatedByteCount }) > 4_000_000 { undoStack.removeFirst() }
        updateUndoAvailability()
    }
    private func updateUndoAvailability() { canUndoTodo = !undoStack.isEmpty; canRedoTodo = !redoStack.isEmpty }

    func startFocus(_ id: UUID) {
        guard state.todos.contains(where: { $0.id == id && $0.isPending }), !isBusy else { return }
        if state.isActive {
            if state.sessionTodoIDs == [id], state.mode == .focus { showFocus = true; return }
            pendingFocusID = id; return
        }
        beginFocus(target: .todo(id))
    }
    func confirmSwitchFocus() {
        guard let id = pendingFocusID else { return }
        pendingFocusID = nil; beginFocus(target: .todo(id), finishCurrent: true)
    }
    func setFocusDuration(_ minutes: Int) {
        guard !state.isActive, !isBusy, (1...180).contains(minutes) else { return }
        enqueue(work: { try await $0.actions([.selectMode(.focus), .selectTarget(.free), .selectDuration(TimeInterval(minutes * 60))]) })
    }
    func startRest() {
        guard !state.isActive, !isBusy else { return }
        enqueue(work: { try await $0.actions([.selectMode(.rest), .start]) }, success: { [weak self] result in
            self?.reminders?.reconcile(result.state, requestPermission: true)
        })
    }
    func startFreeFocus() { guard !state.isActive else { showFocus = true; return }; beginFocus(target: .free) }
    private func beginFocus(target: FocusTarget, finishCurrent: Bool = false) {
        guard !isBusy else { return }
        let actions: [FocusAction] = (finishCurrent ? [.finish] : []) + [.selectMode(.focus), .selectTarget(target), .start]
        enqueue(work: { try await $0.actions(actions) }, success: { [weak self] result in
            self?.reminders?.reconcile(result.state, requestPermission: true)
        })
    }
    @discardableResult func selectFocusTarget(_ target: FocusTarget) -> Bool {
        guard !state.isActive else { return false }; return send(.selectTarget(target))
    }
    func toggleFocus() {
        guard !isBusy else { return }
        if state.isActive { send(state.status == .running ? .pause : .start) }
        else if let selectedTodoID, state.todos.contains(where: { $0.id == selectedTodoID && $0.isPending }) { startFocus(selectedTodoID) }
        else { startFreeFocus() }
    }
    func showCurrentTodo() {
        guard let id = state.sessionTodoIDs?.first, let item = state.todos.first(where: { $0.id == id }) else { return }
        searchText = ""; section = item.isDeleted ? .trash : (item.isCompleted ? .completed : .all)
        pageSize = FocusTodo.maximumStoredCount; rebuildTodos(); selectedTodoID = id; showFocus = false
        if !item.isDeleted { editTodo(id) }
    }
    func openTodo(_ id: UUID) {
        guard let item = state.todos.first(where: { $0.id == id }) else { return }
        searchText = ""; section = item.isDeleted ? .trash : (item.isCompleted ? .completed : .all)
        pageSize = FocusTodo.maximumStoredCount; rebuildTodos(); selectedTodoID = id; showFocus = false
        if !item.isDeleted { editTodo(id) }
    }
    func loadMoreTodos() { pageSize += 100; rebuildTodos() }
    func count(in section: TodoSection) -> Int { counts[section] ?? 0 }
    private func rebuildTodos() {
        let now = Date(), items = state.todos
        let sections: [TodoSection] = [.inbox, .today, .upcoming, .all, .completed, .trash] + collections.map { .collection($0.id) }
        counts = Dictionary(uniqueKeysWithValues: sections.map { section in (section, items.filter { section.contains($0, at: now) }.count) })
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var matching = items.filter { item in
            if query.isEmpty { return section.contains(item, at: now) }
            let inScope = section == .trash ? item.isDeleted : !item.isDeleted
            return inScope && (item.title.localizedStandardContains(query) || item.notes.localizedStandardContains(query))
        }
        let positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        matching.sort { a, b in
            if section == .completed, a.completedAt != b.completedAt { return (a.completedAt ?? .distantPast) > (b.completedAt ?? .distantPast) }
            if section == .trash, a.deletedAt != b.deletedAt { return (a.deletedAt ?? .distantPast) > (b.deletedAt ?? .distantPast) }
            if section == .upcoming {
                let today = Calendar.current.startOfDay(for: now)
                let first = [a.plannedDate, a.dueDate].compactMap { $0 }.filter { Calendar.current.startOfDay(for: $0) > today }.min() ?? .distantFuture
                let second = [b.plannedDate, b.dueDate].compactMap { $0 }.filter { Calendar.current.startOfDay(for: $0) > today }.min() ?? .distantFuture
                if first != second { return first < second }
            }
            if sort == .deadline, a.dueDate != b.dueDate { return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture) }
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            let aIndex = positions[a.id] ?? 0
            let bIndex = positions[b.id] ?? 0
            return aIndex < bIndex
        }
        visibleTodoCount = matching.count; visibleTodos = Array(matching.prefix(pageSize))
    }
    private func scheduleDayBoundary() {
        dayTimer?.invalidate()
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rebuildTodos(); self?.scheduleDayBoundary() }
        }
        timer.tolerance = 1; RunLoop.main.add(timer, forMode: .common); dayTimer = timer
    }
    func performIntent(_ action: IntentAction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(force: true, work: { try await $0.intent(action) }, success: { _ in
                continuation.resume()
            }, failure: { error in continuation.resume(throwing: error) })
        }
        await reminders?.flush()
    }
    enum IntentAction: Sendable { case toggle, finish, rest, reset }

    private func accept(_ updated: FocusState, force: Bool = false) {
        let old = state, changed = old != updated
        let todosChanged = old.todoList?.items != updated.todoList?.items || old.todoList?.collections != updated.todoList?.collections
        if changed { state = updated }
        if todosChanged || force {
            collections = state.todoList?.collections ?? []
            if case .collection(let id) = section, !collections.contains(where: { $0.id == id }) { section = .inbox }
            rebuildTodos(); todoReminders?.reconcile(todos: state.todos)
        }
        let nextDeadline = state.status == .running ? state.deadline : nil
        if nextDeadline != scheduledDeadline || force {
            deadlineTimer?.invalidate(); deadlineTimer = nil; scheduledDeadline = nextDeadline
            if let deadline = nextDeadline {
                let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
                timer.tolerance = 0.1; RunLoop.main.add(timer, forMode: .common); deadlineTimer = timer
            }
        }
        if changed || force { reminders?.reconcile(state) }
        if shared && (old.status != updated.status || old.deadline != updated.deadline || old.duration != updated.duration || old.currentTask != updated.currentTask || old.remaining != updated.remaining) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
