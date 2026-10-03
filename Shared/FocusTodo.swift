import Foundation

public struct FocusTodo: Codable, Identifiable, Equatable, Sendable {
    public static let maximumCount = 100
    public static let maximumTitleLength = 180
    public static let minutesRange = 1...180

    public let id: UUID
    public var title: String
    public var minutes: Int
    public var isCompleted: Bool

    public init(id: UUID = UUID(), title: String, minutes: Int, isCompleted: Bool = false) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minutes = minutes
        self.isCompleted = isCompleted
    }

    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= Self.maximumTitleLength && Self.minutesRange.contains(minutes)
    }

    public static func parseMinutes(_ text: String) -> Int? {
        guard let value = Int(text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)),
              minutesRange.contains(value) else { return nil }
        return value
    }
}

public enum FocusTarget: Codable, Equatable, Sendable {
    case free
    case todo(UUID)
    case list
}

public struct FocusTodoList: Codable, Equatable, Sendable {
    public var items: [FocusTodo] = []
    public var target: FocusTarget = .free
    /// A session-specific adjustment; never changes an item's estimate.
    public var durationOverride: TimeInterval?

    public init() {}

    public var pending: [FocusTodo] { items.filter { !$0.isCompleted } }
    public var selected: [FocusTodo] {
        switch target {
        case .free: return []
        case .todo(let id): return pending.filter { $0.id == id }
        case .list: return pending
        }
    }

    public var estimatedDuration: TimeInterval { TimeInterval(selected.reduce(0) { $0 + $1.minutes } * 60) }

    public mutating func normalizeSelection() {
        if target != .free && selected.isEmpty {
            target = .free
            durationOverride = nil
        }
    }
}
