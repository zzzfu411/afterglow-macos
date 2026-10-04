import SwiftUI
import WidgetKit

@MainActor
final class FocusModel: ObservableObject {
    static let shared = FocusModel(preferences: .standard)
    @Published private(set) var state = FocusState()
    @Published var error: String?
    @Published var showHistory = false
    @Published var showSidebar: Bool {
        didSet {
            if showSidebar != oldValue { preferences?.set(showSidebar, forKey: "afterglow.sidebar-visible") }
        }
    }
    @Published var todoDraft: TodoDraft?
    @Published var todoToDelete: FocusTodo?
    @Published private(set) var completionUndo: FocusTodoCompletionUndo?
    @Published var isEditingDuration = false
    let reminders: FocusReminders?
    private let store: FocusStore
    private let preferences: UserDefaults?
    private var deadlineTimer: Timer?
    private var scheduledDeadline: Date?
    private var observation: FocusStoreObservation?
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?

    var shared: Bool { store.isShared }

    init(store: FocusStore = .shared, remindersEnabled: Bool = true, preferences: UserDefaults? = nil) {
        self.store = store
        self.preferences = preferences
        showSidebar = preferences?.object(forKey: "afterglow.sidebar-visible") as? Bool ?? true
        reminders = remindersEnabled ? FocusReminders(delivery: SystemReminderDelivery()) : nil
        observeStore()
        refresh(force: true)
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
        deadlineTimer?.invalidate()
        for observer in applicationObservers { NotificationCenter.default.removeObserver(observer) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    private func observeStore() {
        do {
            observation = try FocusStoreObservation(directory: store.directoryURL) { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func resume() {
        // Reopen the directory after a wake/activation in case it was replaced.
        observeStore()
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        do { accept(try store.snapshot(), force: force) }
        catch { if self.error == nil { self.error = storageMessage(for: error) } }
    }

    func retryStorage() {
        error = nil
        refresh(force: true)
    }

    @discardableResult func send(_ action: FocusAction) -> Bool {
        do {
            let updated = try store.update(action)
            let starting = updated.status == .running && state.status != .running
            accept(updated)
            // Ask once, in context of a start click in the app. Widget intents
            // never show a permission sheet or foreground the app unexpectedly.
            if starting { reminders?.reconcile(updated, requestPermission: true) }
            return true
        } catch { self.error = storageMessage(for: error); return false }
    }

    func newTodo() {
        if todoDraft == nil { todoDraft = TodoDraft() }
        showHistory = false
        showSidebar = true
    }

    func completeTodo(_ id: UUID) {
        do {
            let change = try store.completeTodo(id)
            accept(change.state)
            if let undo = change.undo { completionUndo = undo }
        } catch { self.error = storageMessage(for: error) }
    }

    func undoTodoCompletion() {
        guard let undo = completionUndo else { return }
        if send(.undoTodoCompletion(undo)) { completionUndo = nil }
    }

    @discardableResult func selectFocusTarget(_ target: FocusTarget) -> Bool {
        guard !state.isActive, send(.selectTarget(target)),
              state.status == .idle, state.mode == .focus, state.focusTarget == target else { return false }
        return true
    }

    /// A persistent sidebar is not a modal. Only editing and confirmations
    /// suppress timer keys; hiding the sidebar keeps an unfinished draft.
    var allowsTimerKeyboard: Bool {
        !isEditingDuration && !showHistory && error == nil && todoToDelete == nil
            && !(showSidebar && todoDraft != nil)
    }

    func saveTodo() {
        guard let draft = todoDraft, let minutes = FocusTodo.parseMinutes(draft.minutes) else { return }
        let item = FocusTodo(id: draft.id, title: draft.title, minutes: minutes)
        guard item.isValid else { return }
        if draft.isNew && state.todos.count >= FocusTodo.maximumCount {
            error = "清单最多保留 \(FocusTodo.maximumCount) 项，请先删除不再需要的事项。"
            return
        }
        let action: FocusAction = draft.isNew ? .addTodo(item) : .editTodo(item.id, title: item.title, minutes: item.minutes)
        if send(action) {
            guard state.todos.contains(where: { $0.id == item.id && $0.title == item.title && $0.minutes == item.minutes }) else {
                error = "清单已变化，请关闭编辑后重试。"
                return
            }
            todoDraft = nil
        }
    }

    private func storageMessage(for error: Error) -> String {
        if error is DecodingError { return "记录文件格式异常，原文件已保留。" }
        return error.localizedDescription
    }

    func performIntent(_ action: IntentAction) async throws {
        let updated: FocusState
        switch action {
        case .toggle: updated = try store.toggle()
        case .finish: updated = try store.update(.finish)
        case .rest: updated = try store.startRest()
        case .reset: updated = try store.update(.reset)
        }
        accept(updated, force: true)
        await reminders?.flush()
    }

    enum IntentAction { case toggle, finish, rest, reset }

    private func accept(_ updated: FocusState, force: Bool = false) {
        let changed = updated != state
        if changed { state = updated }
        if let undo = completionUndo, !state.todos.contains(where: { $0.id == undo.item.id && $0.isCompleted }) {
            completionUndo = nil
        }
        let nextDeadline = state.status == .running ? state.deadline : nil
        if nextDeadline != scheduledDeadline || force {
            deadlineTimer?.invalidate()
            deadlineTimer = nil
            scheduledDeadline = nextDeadline
            if let deadline = nextDeadline {
                let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
                timer.tolerance = 0.1
                RunLoop.main.add(timer, forMode: .common)
                deadlineTimer = timer
            }
        }
        if changed || force { reminders?.reconcile(state) }
        if changed, shared { WidgetCenter.shared.reloadAllTimelines() }
    }
}

/// Keep an unfinished draft across sidebar toggles without persisting keystrokes.
struct TodoDraft {
    var id: UUID = UUID()
    var title = ""
    var minutes = "25"
    var isNew = true

    init(item: FocusTodo? = nil) {
        if let item {
            id = item.id; title = item.title; minutes = String(item.minutes); isNew = false
        }
    }

    var isValid: Bool {
        guard let value = FocusTodo.parseMinutes(minutes) else { return false }
        return FocusTodo(title: title, minutes: value).isValid
    }
}
