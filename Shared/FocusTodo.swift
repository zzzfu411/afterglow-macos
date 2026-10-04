import Foundation

public struct FocusTodo: Codable, Identifiable, Equatable, Sendable {
    public static let maximumCount = 100
    public static let maximumTitleLength = 180
    public static let minutesRange = 1...180

    public let id: UUID
    public var title: String
    public var minutes: Int
    public var isCompleted: Bool
    /// A planning date, independent of a running focus timer's deadline.
    public var dueDate: Date?

    public init(id: UUID = UUID(), title: String, minutes: Int, isCompleted: Bool = false, dueDate: Date? = nil) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minutes = minutes
        self.isCompleted = isCompleted
        self.dueDate = dueDate
    }

    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= Self.maximumTitleLength && Self.minutesRange.contains(minutes)
            && (dueDate.map { $0.timeIntervalSince1970.isFinite && (Date.distantPast...Date.distantFuture).contains($0) } ?? true)
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

    public var pending: [FocusTodo] {
        // Preserve insertion order for ties and undated items. Sorting is a
        // derived view and never rewrites the stored list just for display.
        items.enumerated().filter { !$0.element.isCompleted }.sorted { lhs, rhs in
            switch (lhs.element.dueDate, rhs.element.dueDate) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
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
