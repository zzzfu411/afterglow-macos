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
    case settle
    case selectMode(FocusMode)
    case selectDuration(TimeInterval)
    case setTask(String)
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
    }

    public var isActive: Bool { status == .running || status == .paused }

    public var currentTask: String {
        isActive && mode == .focus ? sessionTask ?? task : task
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
            if result.status == .done { result.resetTimer(mode: result.mode, duration: result.duration) }
            if result.remaining == 0 {
                result.end(at: now)
                return result
            }
            result.status = .running
            result.deadline = now.addingTimeInterval(result.remaining)
            if result.sessionID == nil {
                result.sessionID = newID
                result.startedAt = now
                let name = result.task.trimmingCharacters(in: .whitespacesAndNewlines)
                result.sessionTask = name.isEmpty ? "专注" : String(name.prefix(180))
            }
        case .pause:
            guard result.status == .running else { return result }
            result.remaining = result.remaining(at: now)
            result.deadline = nil
            result.status = .paused
        case .finish:
            result.end(at: now)
        case .selectMode(let mode):
            guard !result.isActive, result.mode != mode else { return result }
            result.resetTimer(mode: mode, duration: mode == .focus ? result.focusDuration : result.restDuration)
        case .selectDuration(let duration):
            // Presets are disabled during an active session. Ignore stale button actions too.
            guard !result.isActive, Self.validDuration(duration) else { return result }
            if result.mode == .focus { result.focusDuration = duration }
            else { result.restDuration = duration }
            result.resetTimer(mode: result.mode, duration: duration)
        case .setTask(let task):
            result.task = String(task.prefix(180))
        }
        return result
    }

    /// Validation happens before disk data can replace the current state. Corruption is not reset silently.
    public func validate() throws {
        guard version == 1,
              Self.validDuration(duration), Self.validDuration(focusDuration), Self.validDuration(restDuration),
              remaining.isFinite, (0...duration).contains(remaining),
              task.count <= 180, (sessionTask?.count ?? 0) <= 180,
              logs.count <= Self.maximumLogCount,
              Set(logs.map(\.id)).count == logs.count else { throw FocusStateError.invalidData }

        if isActive {
            guard sessionID != nil, startedAt != nil, sessionTask != nil else { throw FocusStateError.invalidData }
        }
        if status == .running {
            guard deadline != nil else { throw FocusStateError.invalidData }
        } else if deadline != nil { throw FocusStateError.invalidData }
        if status == .idle {
            guard remaining == duration, sessionID == nil, startedAt == nil, sessionTask == nil else { throw FocusStateError.invalidData }
        }
        if status == .done && remaining != 0 { throw FocusStateError.invalidData }
        if let startedAt, !Self.validDate(startedAt) { throw FocusStateError.invalidData }
        if let deadline, !Self.validDate(deadline) { throw FocusStateError.invalidData }
        for log in logs {
            guard log.task.count <= 180, log.seconds.isFinite, (0...Self.maximumDuration).contains(log.seconds),
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

    private mutating func resetTimer(mode: FocusMode, duration: TimeInterval) {
        self.mode = mode
        self.status = .idle
        self.duration = duration
        self.remaining = duration
        self.deadline = nil
        self.startedAt = nil
        self.sessionID = nil
        self.sessionTask = nil
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
        remaining = 0
        deadline = nil
    }
}
