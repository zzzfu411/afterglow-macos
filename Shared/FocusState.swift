import Foundation

public enum FocusMode: String, Codable, CaseIterable, Sendable {
    case focus, rest
}

public enum FocusStatus: String, Codable, Sendable {
    case idle, running, paused, done
}

public enum FocusAction: Sendable {
    case start
    case pause
    case finish
    case startNext
    case reset
    case settle
    case selectMode(FocusMode)
    case selectDuration(TimeInterval)
    case setTask(String)
    case addTodo(FocusTodo)
    case editTodo(UUID, title: String, minutes: Int, dueDate: Date? = nil)
    case upsertTodo(FocusTodo)
    case replaceTodo(expected: FocusTodo, replacement: FocusTodo)
    case trashTodo(UUID)
    case restoreTodo(UUID)
    case purgeTodos([UUID])
    case upsertCollection(TodoCollection)
    case deleteCollection(UUID)
    case reorderTodos([UUID])
    case deleteTodo(UUID)
    case setTodoCompleted(UUID, Bool)
    case undoTodoCompletion(FocusTodoCompletionUndo)
    case selectTarget(FocusTarget)
}

/// Compatibility receipt for completion-only callers. It retains affected tasks
/// (including a generated occurrence), never the whole list, timer, or history.
public struct FocusTodoCompletionUndo: Equatable, Sendable {
    public let item: FocusTodo
    let record: TodoUndoRecord

    init?(id: UUID, previous: FocusState, updated: FocusState) {
        guard let item = previous.todos.first(where: { $0.id == id && !$0.isCompleted && !$0.isDeleted }),
              updated.todos.contains(where: { $0.id == id && $0.isCompleted && !$0.isDeleted }),
              let record = TodoUndoRecord(previous: previous, updated: updated) else { return nil }
        self.item = item
        self.record = record
    }
}

/// Per-object before/after values support conflict-safe undo and redo. Strings
/// use Swift's copy-on-write storage; no timer state or focus logs are retained.
public struct TodoUndoRecord: Equatable, Sendable {
    struct ItemChange: Equatable, Sendable {
        let id: UUID
        let before: FocusTodo?
        let after: FocusTodo?
        let beforeIndex: Int?
    }
    struct CollectionChange: Equatable, Sendable {
        let id: UUID
        let before: TodoCollection?
        let after: TodoCollection?
        let beforeIndex: Int?
    }
    let items: [ItemChange]
    let collections: [CollectionChange]
    public let title: String
    public var itemIDs: [UUID] { items.map(\.id) }
    public var collectionIDs: [UUID] { collections.map(\.id) }
    public var isEmpty: Bool { items.isEmpty && collections.isEmpty }
    /// Conservative text-payload estimate used to bound the UI's undo history.
    public var estimatedByteCount: Int {
        items.reduce(0) { total, change in
            total + [change.before, change.after].compactMap { $0 }.reduce(0) { $0 + $1.estimatedStorageBytes }
        } + collections.reduce(0) { total, change in
            total + [change.before, change.after].compactMap { $0 }.reduce(0) { $0 + $1.title.utf8.count + 128 }
        }
    }

    init?(previous: FocusState, updated: FocusState, title: String = "待办操作") {
        let oldItems = Dictionary(uniqueKeysWithValues: previous.todos.map { ($0.id, $0) })
        let newItems = Dictionary(uniqueKeysWithValues: updated.todos.map { ($0.id, $0) })
        let oldItemPositions = Dictionary(uniqueKeysWithValues: previous.todos.enumerated().map { ($0.element.id, $0.offset) })
        let itemIDs = previous.todos.map(\.id) + updated.todos.filter { oldItems[$0.id] == nil }.map(\.id)
        items = itemIDs.compactMap { id in
            oldItems[id] == newItems[id] ? nil : ItemChange(id: id, before: oldItems[id], after: newItems[id], beforeIndex: oldItemPositions[id])
        }
        let oldLists = Dictionary(uniqueKeysWithValues: (previous.todoList?.collections ?? []).map { ($0.id, $0) })
        let newLists = Dictionary(uniqueKeysWithValues: (updated.todoList?.collections ?? []).map { ($0.id, $0) })
        let oldListPositions = Dictionary(uniqueKeysWithValues: (previous.todoList?.collections ?? []).enumerated().map { ($0.element.id, $0.offset) })
        let listIDs = (previous.todoList?.collections ?? []).map(\.id)
            + (updated.todoList?.collections ?? []).filter { oldLists[$0.id] == nil }.map(\.id)
        collections = listIDs.compactMap { id in
            oldLists[id] == newLists[id] ? nil : CollectionChange(id: id, before: oldLists[id], after: newLists[id], beforeIndex: oldListPositions[id])
        }
        self.title = title
        if isEmpty { return nil }
    }
}

public struct FocusLog: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let task: String
    public let startedAt: Date
    public let endedAt: Date
    public let seconds: TimeInterval
    public let completed: Bool
    /// Absent in old history. Never guess task links from a possibly reused title.
    public let todoIDs: [UUID]?

    public init(id: UUID, task: String, startedAt: Date, endedAt: Date, seconds: TimeInterval,
                completed: Bool, todoIDs: [UUID]? = nil) {
        self.id = id
        self.task = task
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.seconds = seconds
        self.completed = completed
        self.todoIDs = todoIDs
    }
}

public struct TodoFocusSummary: Equatable, Sendable {
    public var totalSeconds: TimeInterval = 0
    public var sessionCount: Int = 0
    public var completedSessionCount: Int = 0
    public var lastFocusedAt: Date?
    public init() {}
}

struct PreparedTodoChange {
    let item: FocusTodo
    let nextOccurrence: FocusTodo?
    let index: Int?
    let completesCurrentTask: Bool
}

public enum FocusStateError: Error, LocalizedError {
    case invalidData

    public var errorDescription: String? { "应用数据无效，原文件已保留。" }
}

public struct FocusState: Codable, Equatable, Sendable {
    public static let minimumDuration: TimeInterval = 60
    public static let maximumDuration: TimeInterval = 10_800
    /// A whole list may exceed the single-task / free-timer limit.
    public static let maximumPlanDuration = maximumDuration * 100
    public static let maximumLogCount = 1_000
    public static let currentVersion = 5

    public var version: Int
    public var mode: FocusMode
    public var status: FocusStatus
    public var duration: TimeInterval
    /// Remaining active time at the last start/resume or pause, in seconds.
    public var remaining: TimeInterval
    public var deadline: Date?
    public var startedAt: Date?
    public var sessionID: UUID?
    public var task: String
    /// The task at the beginning of this session; later edits cannot relabel history.
    public var sessionTask: String?
    public var logs: [FocusLog]
    public var focusDuration: TimeInterval
    public var restDuration: TimeInterval
    /// Optional for compatibility with version 1 files written before reminders.
    public var completedNaturally: Bool?
    /// Version 5 adds single-level steps and completion-driven recurring occurrences.
    public var todoList: FocusTodoList?
    /// Freeze membership at start; checklist edits never change a running session.
    public var sessionTodoIDs: [UUID]?

    public init(mode: FocusMode = .focus, duration: TimeInterval? = nil, task: String = "") {
        let defaultDuration: TimeInterval = mode == .focus ? 25 * 60 : 5 * 60
        let chosen = duration.flatMap { Self.validDuration($0) ? $0 : nil } ?? defaultDuration
        self.version = Self.currentVersion
        self.mode = mode
        self.status = .idle
        self.duration = chosen
        self.remaining = chosen
        self.deadline = nil
        self.startedAt = nil
        self.sessionID = nil
        self.task = String(task.prefix(180))
        self.sessionTask = nil
        self.logs = []
        self.focusDuration = mode == .focus ? chosen : 25 * 60
        self.restDuration = mode == .rest ? chosen : 5 * 60
        self.completedNaturally = nil
        self.todoList = nil
        self.sessionTodoIDs = nil
    }

    public var isActive: Bool { status == .running || status == .paused }

    public var currentTask: String {
        mode == .focus && status != .idle ? sessionTask ?? plannedTask : plannedTask
    }

    public var todos: [FocusTodo] { todoList?.items ?? [] }
    /// Summaries cover retained logs with one explicit task association. A legacy
    /// multi-task session is not duplicated or speculatively divided between tasks.
    public var todoFocusSummaries: [UUID: TodoFocusSummary] {
        var summaries: [UUID: TodoFocusSummary] = [:]
        var seen = Set<UUID>()
        for log in logs {
            guard seen.insert(log.id).inserted, let ids = log.todoIDs, ids.count == 1,
                  log.seconds.isFinite, log.seconds >= 0 else { continue }
            let id = ids[0]
            var summary = summaries[id] ?? TodoFocusSummary()
            summary.totalSeconds += log.seconds
            summary.sessionCount += 1
            if log.completed { summary.completedSessionCount += 1 }
            summary.lastFocusedAt = max(summary.lastFocusedAt ?? log.endedAt, log.endedAt)
            summaries[id] = summary
        }
        return summaries
    }

    public var focusTarget: FocusTarget { todoList?.target ?? .free }
    public var plannedFocusDuration: TimeInterval {
        guard let list = todoList, !list.selected.isEmpty else { return focusDuration }
        return list.durationOverride.map { min(Self.maximumDuration, $0) } ?? focusDuration
    }

    public var plannedTask: String {
        guard let list = todoList, !list.selected.isEmpty else { return task }
        if case .todo = list.target { return list.selected[0].title }
        let summary = "清单 · \(list.selected.count) 项：" + list.selected.map(\.title).joined(separator: "、")
        return String(summary.prefix(180))
    }

    public var durationLimit: TimeInterval { Self.maximumDuration }

    public func remaining(at now: Date) -> TimeInterval {
        guard status == .running, let deadline else { return remaining }
        return max(0, min(remaining, deadline.timeIntervalSince(now)))
    }

    public func elapsed(at now: Date) -> TimeInterval {
        max(0, duration - remaining(at: now))
    }

    /// Pure transitions. The caller supplies a timestamp and can supply an ID for tests.
    public func applying(_ action: FocusAction, at now: Date = Date(), sessionID newID: UUID = UUID()) -> FocusState {
        var result = self
        let expiredWhileRunning = status == .running && remaining(at: now) == 0
        if expiredWhileRunning { result.end(at: now) }

        switch action {
        case .settle:
            break
        case .start:
            // A stale start action must not turn an expired session into a new one.
            guard !expiredWhileRunning, result.status != .running else { return result }
            if result.status == .done { result.resetTimer(mode: result.mode, duration: result.mode == .focus ? result.plannedFocusDuration : result.restDuration) }
            if result.remaining == 0 {
                result.end(at: now)
                return result
            }
            result.status = .running
            result.deadline = now.addingTimeInterval(result.remaining)
            if result.sessionID == nil {
                result.sessionID = newID
                result.startedAt = now
                let name = result.plannedTask.trimmingCharacters(in: .whitespacesAndNewlines)
                result.sessionTask = name.isEmpty ? "专注" : String(name.prefix(180))
                result.sessionTodoIDs = result.mode == .focus ? result.todoList?.selected.map(\.id) : nil
            }
        case .pause:
            guard result.status == .running else { return result }
            result.remaining = result.remaining(at: now)
            result.deadline = nil
            result.status = .paused
        case .finish:
            result.end(at: now)
        case .startNext:
            guard result.status == .done else { return result }
            let next: FocusMode = result.mode == .focus ? .rest : .focus
            result.resetTimer(mode: next, duration: next == .focus ? result.plannedFocusDuration : result.restDuration)
            return result.applying(.start, at: now, sessionID: newID)
        case .reset:
            guard !result.isActive else { return result }
            result.resetTimer(mode: .focus, duration: result.plannedFocusDuration)
        case .selectMode(let mode):
            guard !result.isActive, result.mode != mode else { return result }
            result.resetTimer(mode: mode, duration: mode == .focus ? result.plannedFocusDuration : result.restDuration)
        case .selectDuration(let duration):
            // Presets are disabled during an active session. Ignore stale button actions too.
            guard !result.isActive, duration.isFinite, (Self.minimumDuration...result.durationLimit).contains(duration) else { return result }
            if result.mode == .focus && result.focusTarget != .free { result.todoList?.durationOverride = duration }
            else if result.mode == .focus { result.focusDuration = duration }
            else { result.restDuration = duration }
            result.resetTimer(mode: result.mode, duration: duration)
        case .setTask(let task):
            result.task = String(task.prefix(180))
        case .addTodo(let item):
            guard !result.todos.contains(where: { $0.id == item.id }) else { return result }
            var created = item
            if created.createdAt == nil { created.createdAt = now }
            result.upsert(created, at: now)
        case .upsertTodo(let item):
            result.upsert(item, at: now)
        case .replaceTodo(let expected, let replacement):
            guard expected.id == replacement.id,
                  result.todos.first(where: { $0.id == expected.id }) == expected else { return result }
            result.upsert(replacement, at: now)
        case .editTodo(let id, let title, let minutes, let dueDate):
            guard var item = result.todos.first(where: { $0.id == id && !$0.isDeleted }) else { return result }
            item.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            item.estimatedMinutes = minutes
            item.dueDate = dueDate
            item.hasDueTime = dueDate != nil
            result.upsert(item, at: now)
        case .deleteTodo(let id), .trashTodo(let id):
            guard let index = result.todos.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { return result }
            result.editList { $0.items[index].deletedAt = now }
        case .restoreTodo(let id):
            guard var item = result.todos.first(where: { $0.id == id && $0.isDeleted }) else { return result }
            item.deletedAt = nil
            result.upsert(item, at: now)
        case .purgeTodos(let ids):
            let requested = Set(ids)
            guard requested.count == ids.count, requested.isSubset(of: Set(result.todos.filter(\.isDeleted).map(\.id))) else { return result }
            result.editList { $0.items.removeAll { requested.contains($0.id) } }
        case .setTodoCompleted(let id, let completed):
            guard var item = result.todos.first(where: { $0.id == id && !$0.isDeleted }), item.isCompleted != completed else { return result }
            item.isCompleted = completed
            item.completedAt = completed ? now : nil
            result.upsert(item, at: now)
        case .undoTodoCompletion(let undo):
            if let restored = try? result.applyingTodoUndo(undo.record) { result = restored }
        case .upsertCollection(let collection):
            guard collection.isValid else { return result }
            let collections = result.todoList?.collections ?? []
            if let index = collections.firstIndex(where: { $0.id == collection.id }) {
                result.editList { $0.collections[index] = collection }
            } else if collections.count < TodoCollection.maximumCount {
                result.editList { $0.collections.append(collection) }
            }
        case .deleteCollection(let id):
            guard result.todoList?.collections.contains(where: { $0.id == id }) == true else { return result }
            // Deleting a collection never deletes its tasks, including archived ones.
            result.editList { list in
                list.collections.removeAll { $0.id == id }
                for index in list.items.indices where list.items[index].listID == id { list.items[index].listID = nil }
            }
        case .reorderTodos(let ids):
            guard !ids.isEmpty, ids.count <= FocusTodo.maximumCount, Set(ids).count == ids.count else { return result }
            let requested = Set(ids)
            let pending = result.todos.enumerated().filter { $0.element.isPending }.sorted {
                $0.element.sortOrder == $1.element.sortOrder ? $0.offset < $1.offset : $0.element.sortOrder < $1.element.sortOrder
            }.map(\.element)
            guard requested.isSubset(of: Set(pending.map(\.id))) else { return result }
            // Reorder only the visible subset within its existing slots. Tasks
            // hidden by a filter keep their relative positions.
            var reorderedIDs = ids.makeIterator()
            let ordered = pending.map { requested.contains($0.id) ? reorderedIDs.next()! : $0.id }
            let positions = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
            result.editList { list in
                for index in list.items.indices {
                    if let order = positions[list.items[index].id] { list.items[index].sortOrder = order }
                }
            }
        case .selectTarget(let target):
            guard !result.isActive else { return result }
            var list = result.todoList ?? FocusTodoList()
            if list.target != target { list.durationOverride = nil }
            list.target = target
            guard target == .free || !list.selected.isEmpty else { return result }
            result.todoList = list
            result.version = Self.currentVersion
            result.resetTimer(mode: .focus, duration: result.plannedFocusDuration)
        }
        return result
    }

    /// Validation happens before disk data can replace the current state. Corruption is not reset silently.
    public func validate() throws {
        guard (1...Self.currentVersion).contains(version),
              duration.isFinite, (Self.minimumDuration...Self.maximumPlanDuration).contains(duration),
              Self.validDuration(focusDuration), Self.validDuration(restDuration),
              remaining.isFinite, (0...duration).contains(remaining),
              task.count <= 180, (sessionTask?.count ?? 0) <= 180,
              logs.count <= Self.maximumLogCount,
              Set(logs.map(\.id)).count == logs.count else { throw FocusStateError.invalidData }

        if version == 1 && (todoList != nil || sessionTodoIDs != nil) { throw FocusStateError.invalidData }
        if let list = todoList {
            guard list.items.count <= FocusTodo.maximumStoredCount,
                  list.items.filter(\.isPending).count <= FocusTodo.maximumCount,
                  list.items.allSatisfy(\.isValid), Set(list.items.map(\.id)).count == list.items.count,
                  list.collections.count <= TodoCollection.maximumCount,
                  list.collections.allSatisfy(\.isValid), Set(list.collections.map(\.id)).count == list.collections.count,
                  list.target == .free || !list.selected.isEmpty else { throw FocusStateError.invalidData }
            let collectionIDs = Set(list.collections.map(\.id))
            guard list.items.allSatisfy({ $0.listID.map { collectionIDs.contains($0) } ?? true }) else { throw FocusStateError.invalidData }
            if version < 4 && (!list.collections.isEmpty || list.items.contains(where: {
                $0.estimatedMinutes == nil || !$0.notes.isEmpty || $0.plannedDate != nil || $0.reminderDate != nil
                    || $0.listID != nil || $0.createdAt != nil || $0.completedAt != nil || $0.deletedAt != nil
                    || ($0.dueDate != nil && !$0.hasDueTime)
            })) { throw FocusStateError.invalidData }
            if version < 3 && list.items.contains(where: { $0.dueDate != nil }) { throw FocusStateError.invalidData }
            if version < 5 && list.items.contains(where: \.hasVersion5Metadata) { throw FocusStateError.invalidData }
            if let override = list.durationOverride {
                guard list.target != .free, override.isFinite, (Self.minimumDuration...Self.maximumPlanDuration).contains(override) else { throw FocusStateError.invalidData }
            }
        }
        if let ids = sessionTodoIDs {
            guard ids.count <= FocusTodo.maximumCount, Set(ids).count == ids.count else { throw FocusStateError.invalidData }
        }

        if isActive {
            guard sessionID != nil, startedAt != nil, sessionTask != nil else { throw FocusStateError.invalidData }
        }
        if status == .running {
            guard deadline != nil else { throw FocusStateError.invalidData }
        } else if deadline != nil { throw FocusStateError.invalidData }
        if status == .idle {
            guard remaining == duration, sessionID == nil, startedAt == nil, sessionTask == nil, sessionTodoIDs == nil else { throw FocusStateError.invalidData }
        }
        if status == .done && remaining != 0 { throw FocusStateError.invalidData }
        if let startedAt, !Self.validDate(startedAt) { throw FocusStateError.invalidData }
        if let deadline, !Self.validDate(deadline) { throw FocusStateError.invalidData }
        for log in logs {
            guard log.task.count <= 180, log.seconds.isFinite, (0...Self.maximumPlanDuration).contains(log.seconds),
                  Self.validDate(log.startedAt), Self.validDate(log.endedAt) else { throw FocusStateError.invalidData }
            if let ids = log.todoIDs {
                guard ids.count <= FocusTodo.maximumCount, Set(ids).count == ids.count else { throw FocusStateError.invalidData }
            }
        }
    }

    private static func validDuration(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && (minimumDuration...maximumDuration).contains(seconds)
    }

    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && abs(seconds) <= 8_640_000_000_000
    }

    /// Normalize legacy planning without changing active or finished sessions.
    /// Storage performs and backs up this migration while holding its file lock.
    func migratedToCurrent() -> FocusState {
        guard version < Self.currentVersion else { return self }
        var result = self
        // Only the timer-first v1-v3 formats need planning normalization. v4
        // already has explicit manual order and independent focus durations.
        if version < 4 {
            if var list = result.todoList {
                for index in list.items.indices { list.items[index].sortOrder = index }
                if let override = list.durationOverride, override > Self.maximumDuration { list.durationOverride = nil }
                result.todoList = list
            }
            if result.status == .idle && result.mode == .focus {
                result.resetTimer(mode: .focus, duration: result.plannedFocusDuration)
            }
        }
        result.version = Self.currentVersion
        return result
    }

    func applyingTodoUndo(_ record: TodoUndoRecord) throws -> FocusState {
        let currentItems = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let currentCollections = Dictionary(uniqueKeysWithValues: (todoList?.collections ?? []).map { ($0.id, $0) })
        guard record.items.allSatisfy({ currentItems[$0.id] == $0.after }),
              record.collections.allSatisfy({ currentCollections[$0.id] == $0.after }) else { throw FocusStoreError.undoConflict }
        var result = self
        result.editList { list in
            for change in record.collections {
                if let value = change.before {
                    if let index = list.collections.firstIndex(where: { $0.id == change.id }) { list.collections[index] = value }
                    else { list.collections.insert(value, at: min(change.beforeIndex ?? list.collections.count, list.collections.count)) }
                } else { list.collections.removeAll { $0.id == change.id } }
            }
            for change in record.items {
                if let value = change.before {
                    if let index = list.items.firstIndex(where: { $0.id == change.id }) { list.items[index] = value }
                    else { list.items.insert(value, at: min(change.beforeIndex ?? list.items.count, list.items.count)) }
                } else { list.items.removeAll { $0.id == change.id } }
            }
        }
        // A collection may have acquired an unrelated task after its creation.
        // Treat that referential/capacity conflict as a failed undo, not data loss.
        do { try result.validate() } catch { throw FocusStoreError.undoConflict }
        return result
    }

    /// Import tasks as recorded, including unknown legacy timestamps and order.
    /// This never imports, finishes, or replaces the current focus session.
    func mergingTodos(_ items: [FocusTodo], collections: [TodoCollection]) throws -> FocusState {
        guard items.count <= FocusTodo.maximumStoredCount, items.allSatisfy(\.isValid),
              Set(items.map(\.id)).count == items.count,
              collections.count <= TodoCollection.maximumCount, collections.allSatisfy(\.isValid),
              Set(collections.map(\.id)).count == collections.count else { throw FocusStoreError.invalidTodoAction }
        var result = self
        result.editList { list in
            let existingCollections = Dictionary(uniqueKeysWithValues: list.collections.enumerated().map { ($0.element.id, $0.offset) })
            for collection in collections {
                if let index = existingCollections[collection.id] { list.collections[index] = collection }
                else { list.collections.append(collection) }
            }
            let existingItems = Dictionary(uniqueKeysWithValues: list.items.enumerated().map { ($0.element.id, $0.offset) })
            for item in items {
                if let index = existingItems[item.id] { list.items[index] = item }
                else { list.items.append(item) }
            }
        }
        guard result.todos.count <= FocusTodo.maximumStoredCount,
              result.todos.filter(\.isPending).count <= FocusTodo.maximumCount,
              (result.todoList?.collections.count ?? 0) <= TodoCollection.maximumCount else { throw FocusStoreError.todoCapacityReached }
        try result.validate()
        return result
    }

    /// Shared by pure transitions and the store's throwing preflight. Generation
    /// and capacity checks happen before a completion can stop real focus time.
    func preparingTodoUpsert(_ supplied: FocusTodo, at now: Date) throws -> PreparedTodoChange {
        var item = supplied
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.isValid,
              item.listID.map({ id in todoList?.collections.contains(where: { $0.id == id }) == true }) ?? true else {
            throw FocusStoreError.invalidTodoAction
        }
        let index = todos.firstIndex(where: { $0.id == item.id })
        let previous = index.map { todos[$0] }
        let newlyCompleted = item.isCompleted && !item.isDeleted && previous?.isPending == true
        var nextOccurrence: FocusTodo?
        if newlyCompleted {
            item.completedAt = now
            if item.repeatRule != nil && item.nextOccurrenceID == nil {
                item.nextOccurrenceID = item.generatedNextOccurrenceID
                if !todos.contains(where: { $0.id == item.generatedNextOccurrenceID }) {
                    guard let generated = item.nextOccurrence(completedAt: now) else { throw FocusStoreError.repeatDateUnavailable }
                    nextOccurrence = generated
                }
            }
        } else if !item.isCompleted { item.completedAt = nil }
        let pendingCount = todos.filter(\.isPending).count - (previous?.isPending == true ? 1 : 0)
            + (item.isPending ? 1 : 0) + (nextOccurrence?.isPending == true ? 1 : 0)
        let totalCount = todos.count + (index == nil ? 1 : 0) + (nextOccurrence == nil ? 0 : 1)
        guard pendingCount <= FocusTodo.maximumCount, totalCount <= FocusTodo.maximumStoredCount else {
            throw FocusStoreError.todoCapacityReached
        }
        if index == nil { item.sortOrder = min(1_000_000_000, (todos.map(\.sortOrder).max() ?? -1) + 1) }
        if nextOccurrence != nil {
            nextOccurrence?.sortOrder = min(1_000_000_000, max(todos.map(\.sortOrder).max() ?? -1, item.sortOrder) + 1)
        }
        return PreparedTodoChange(item: item, nextOccurrence: nextOccurrence, index: index,
                                  completesCurrentTask: newlyCompleted && mode == .focus && isActive && sessionTodoIDs == [item.id])
    }

    private mutating func upsert(_ supplied: FocusTodo, at now: Date) {
        guard let change = try? preparingTodoUpsert(supplied, at: now) else { return }
        if change.completesCurrentTask { end(at: now) }
        editList { list in
            if let index = change.index { list.items[index] = change.item }
            else { list.items.append(change.item) }
            if let next = change.nextOccurrence { list.items.append(next) }
        }
    }

    private mutating func editList(_ edit: (inout FocusTodoList) -> Void) {
        var list = todoList ?? FocusTodoList()
        edit(&list)
        list.normalizeSelection()
        todoList = list
        version = Self.currentVersion
        if status == .idle && mode == .focus { resetTimer(mode: .focus, duration: plannedFocusDuration) }
    }

    private mutating func resetTimer(mode: FocusMode, duration: TimeInterval) {
        self.mode = mode
        self.status = .idle
        self.duration = duration
        self.remaining = duration
        self.deadline = nil
        self.startedAt = nil
        self.sessionID = nil
        self.sessionTask = nil
        self.completedNaturally = nil
        self.sessionTodoIDs = nil
    }

    private mutating func end(at now: Date) {
        guard isActive, let id = sessionID, let start = startedAt else { return }
        let completed = remaining(at: now) == 0
        // Attribute delayed completion to the deadline, never the next app/widget refresh.
        let endedAt = completed ? deadline ?? now : now
        let seconds = completed ? duration : elapsed(at: now)
        if mode == .focus && seconds > 0 && !logs.contains(where: { $0.id == id }) {
            logs.append(FocusLog(id: id, task: sessionTask ?? task, startedAt: start, endedAt: endedAt, seconds: seconds, completed: completed, todoIDs: sessionTodoIDs))
            if logs.count > Self.maximumLogCount { logs.removeFirst(logs.count - Self.maximumLogCount) }
        }
        status = .done
        completedNaturally = completed
        remaining = 0
        deadline = nil
    }
}
