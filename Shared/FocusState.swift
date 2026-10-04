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
    case deleteTodo(UUID)
    case setTodoCompleted(UUID, Bool)
    case undoTodoCompletion(FocusTodoCompletionUndo)
    case selectTarget(FocusTarget)
}

/// One in-memory undo receipt. Never retains history or rewinds the whole state.
public struct FocusTodoCompletionUndo: Equatable, Sendable {
    public let item: FocusTodo
    let previousTarget: FocusTarget
    let previousDurationOverride: TimeInterval?
    let completedList: FocusTodoList
    let mode: FocusMode
    let status: FocusStatus
    let sessionID: UUID?
    let duration: TimeInterval

    init?(id: UUID, previous: FocusState, updated: FocusState) {
        guard let item = previous.todos.first(where: { $0.id == id }), !item.isCompleted,
              let list = updated.todoList, list.items.contains(where: { $0.id == id && $0.isCompleted }) else { return nil }
        self.item = item
        previousTarget = previous.focusTarget
        previousDurationOverride = previous.todoList?.durationOverride
        completedList = list
        mode = updated.mode
        status = updated.status
        sessionID = updated.sessionID
        duration = updated.duration
    }
}

public struct FocusLog: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let task: String
    public let startedAt: Date
    public let endedAt: Date
    public let seconds: TimeInterval
    public let completed: Bool
}

public enum FocusStateError: Error, LocalizedError {
    case invalidData

    public var errorDescription: String? { "计时数据无效，原文件已保留。" }
}

public struct FocusState: Codable, Equatable, Sendable {
    public static let minimumDuration: TimeInterval = 60
    public static let maximumDuration: TimeInterval = 10_800
    /// A whole list may exceed the single-task / free-timer limit.
    public static let maximumPlanDuration = maximumDuration * Double(FocusTodo.maximumCount)
    public static let maximumLogCount = 1_000

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
    /// Version 2 adds lists; version 3 adds optional task due dates.
    public var todoList: FocusTodoList?
    /// Freeze membership at start; checklist edits never change a running session.
    public var sessionTodoIDs: [UUID]?

    public init(mode: FocusMode = .focus, duration: TimeInterval? = nil, task: String = "") {
        let defaultDuration: TimeInterval = mode == .focus ? 25 * 60 : 5 * 60
        let chosen = duration.flatMap { Self.validDuration($0) ? $0 : nil } ?? defaultDuration
        self.version = 1
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
    public var focusTarget: FocusTarget { todoList?.target ?? .free }
    public var plannedFocusDuration: TimeInterval {
        guard let list = todoList, !list.selected.isEmpty else { return focusDuration }
        return list.durationOverride ?? list.estimatedDuration
    }

    public var plannedTask: String {
        guard let list = todoList, !list.selected.isEmpty else { return task }
        if case .todo = list.target { return list.selected[0].title }
        let summary = "清单 · \(list.selected.count) 项：" + list.selected.map(\.title).joined(separator: "、")
        return String(summary.prefix(180))
    }

    public var durationLimit: TimeInterval {
        mode == .focus && focusTarget != .free
            ? max(Self.maximumDuration, todoList?.estimatedDuration ?? 0) : Self.maximumDuration
    }

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
            guard item.isValid, result.todos.count < FocusTodo.maximumCount,
                  !result.todos.contains(where: { $0.id == item.id }) else { return result }
            result.editList { $0.items.append(item) }
        case .editTodo(let id, let title, let minutes, let dueDate):
            guard let index = result.todos.firstIndex(where: { $0.id == id }) else { return result }
            let item = FocusTodo(id: id, title: title, minutes: minutes, isCompleted: result.todos[index].isCompleted, dueDate: dueDate)
            guard item.isValid else { return result }
            result.editList { $0.items[index] = item }
        case .deleteTodo(let id):
            guard result.todos.contains(where: { $0.id == id }) else { return result }
            result.editList { $0.items.removeAll { $0.id == id } }
        case .setTodoCompleted(let id, let completed):
            guard let index = result.todos.firstIndex(where: { $0.id == id }), result.todos[index].isCompleted != completed else { return result }
            result.editList { $0.items[index].isCompleted = completed }
        case .undoTodoCompletion(let undo):
            guard let index = result.todos.firstIndex(where: { $0.id == undo.item.id && $0.isCompleted }) else { return result }
            // Restore the old selection only if no subsequent plan/timer edit
            // superseded it. Always preserve later task edits and active time.
            let restorePlan = result.todoList == undo.completedList
                && result.mode == undo.mode && result.status == undo.status
                && result.sessionID == undo.sessionID && result.duration == undo.duration
            result.editList { $0.items[index].isCompleted = false }
            if restorePlan {
                result.todoList?.target = undo.previousTarget
                result.todoList?.durationOverride = undo.previousDurationOverride
                result.todoList?.normalizeSelection()
                if result.status == .idle && result.mode == .focus {
                    result.resetTimer(mode: .focus, duration: result.plannedFocusDuration)
                }
            }
        case .selectTarget(let target):
            guard !result.isActive else { return result }
            var list = result.todoList ?? FocusTodoList()
            if list.target != target { list.durationOverride = nil }
            list.target = target
            guard target == .free || !list.selected.isEmpty else { return result }
            result.todoList = list
            result.version = max(result.version, 2)
            result.resetTimer(mode: .focus, duration: result.plannedFocusDuration)
        }
        return result
    }

    /// Validation happens before disk data can replace the current state. Corruption is not reset silently.
    public func validate() throws {
        guard (1...3).contains(version),
              duration.isFinite, (Self.minimumDuration...Self.maximumPlanDuration).contains(duration),
              Self.validDuration(focusDuration), Self.validDuration(restDuration),
              remaining.isFinite, (0...duration).contains(remaining),
              task.count <= 180, (sessionTask?.count ?? 0) <= 180,
              logs.count <= Self.maximumLogCount,
              Set(logs.map(\.id)).count == logs.count else { throw FocusStateError.invalidData }

        if version == 1 && (todoList != nil || sessionTodoIDs != nil) { throw FocusStateError.invalidData }
        if let list = todoList {
            guard list.items.count <= FocusTodo.maximumCount,
                  list.items.allSatisfy(\.isValid), Set(list.items.map(\.id)).count == list.items.count,
                  list.target == .free || !list.selected.isEmpty else { throw FocusStateError.invalidData }
            if version < 3 && list.items.contains(where: { $0.dueDate != nil }) { throw FocusStateError.invalidData }
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
        }
    }

    private static func validDuration(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && (minimumDuration...maximumDuration).contains(seconds)
    }

    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && abs(seconds) <= 8_640_000_000_000
    }

    private mutating func editList(_ edit: (inout FocusTodoList) -> Void) {
        var list = todoList ?? FocusTodoList()
        let previousSelection = list.selected
        edit(&list)
        list.normalizeSelection()
        // An estimate override belongs to a particular selection. Editing an
        // unrelated item leaves it intact; changing its members/estimates resets it.
        let estimates = Dictionary(uniqueKeysWithValues: list.selected.map { ($0.id, $0.minutes) })
        let previousEstimates = Dictionary(uniqueKeysWithValues: previousSelection.map { ($0.id, $0.minutes) })
        if estimates != previousEstimates { list.durationOverride = nil }
        todoList = list
        // Never downgrade after clearing dates: older apps must not silently
        // erase deadline fields when they write this file.
        version = max(version, list.items.contains(where: { $0.dueDate != nil }) ? 3 : 2)
        if status == .idle && mode == .focus {
            resetTimer(mode: .focus, duration: plannedFocusDuration)
        }
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
            logs.append(FocusLog(id: id, task: sessionTask ?? task, startedAt: start, endedAt: endedAt, seconds: seconds, completed: completed))
            if logs.count > Self.maximumLogCount { logs.removeFirst(logs.count - Self.maximumLogCount) }
        }
        status = .done
        completedNaturally = completed
        remaining = 0
        deadline = nil
    }
}
