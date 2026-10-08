import Foundation

public struct FocusTodo: Codable, Identifiable, Equatable, Sendable {
    /// Completed and deleted items do not consume the active-task allowance.
    public static let maximumCount = 1_000
    public static let maximumStoredCount = 10_000
    public static let maximumTitleLength = 180
    public static let maximumNotesLength = 10_000
    public static let minutesRange = 1...10_080

    public let id: UUID
    public var title: String
    public var estimatedMinutes: Int?
    public var notes: String
    public var plannedDate: Date?
    /// A deadline is independent of both the planned day and notification time.
    public var dueDate: Date?
    public var hasDueTime: Bool
    public var reminderDate: Date?
    public var listID: UUID?
    public var isCompleted: Bool
    public var completedAt: Date?
    public var deletedAt: Date?
    /// Legacy files did not record creation/completion dates. Keep them unknown.
    public var createdAt: Date?
    public var sortOrder: Int

    /// Legacy callers can still access a numeric estimate; zero means no estimate.
    public var minutes: Int {
        get { estimatedMinutes ?? 0 }
        set { estimatedMinutes = newValue }
    }
    public var isDeleted: Bool { deletedAt != nil }
    public var isPending: Bool { !isCompleted && !isDeleted }

    public init(id: UUID = UUID(), title: String, estimatedMinutes: Int? = nil,
                notes: String = "", plannedDate: Date? = nil, dueDate: Date? = nil,
                hasDueTime: Bool = false, reminderDate: Date? = nil, listID: UUID? = nil,
                isCompleted: Bool = false, completedAt: Date? = nil, deletedAt: Date? = nil,
                createdAt: Date? = nil, sortOrder: Int = 0) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.estimatedMinutes = estimatedMinutes
        self.notes = notes
        self.plannedDate = plannedDate
        self.dueDate = dueDate
        self.hasDueTime = hasDueTime
        self.reminderDate = reminderDate
        self.listID = listID
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.sortOrder = sortOrder
    }

    public init(id: UUID = UUID(), title: String, minutes: Int, isCompleted: Bool = false, dueDate: Date? = nil) {
        self.init(id: id, title: title, estimatedMinutes: minutes, dueDate: dueDate,
                  hasDueTime: dueDate != nil, isCompleted: isCompleted)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, minutes, estimatedMinutes, notes, plannedDate, dueDate, hasDueTime,
             reminderDate, listID, isCompleted, completedAt, deletedAt, createdAt, sortOrder
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        estimatedMinutes = try values.contains(.estimatedMinutes)
            ? values.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
            : values.decodeIfPresent(Int.self, forKey: .minutes)
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        plannedDate = try values.decodeIfPresent(Date.self, forKey: .plannedDate)
        dueDate = try values.decodeIfPresent(Date.self, forKey: .dueDate)
        hasDueTime = try values.decodeIfPresent(Bool.self, forKey: .hasDueTime) ?? (dueDate != nil)
        reminderDate = try values.decodeIfPresent(Date.self, forKey: .reminderDate)
        listID = try values.decodeIfPresent(UUID.self, forKey: .listID)
        isCompleted = try values.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        deletedAt = try values.decodeIfPresent(Date.self, forKey: .deletedAt)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encodeIfPresent(estimatedMinutes, forKey: .estimatedMinutes)
        try values.encode(notes, forKey: .notes)
        try values.encodeIfPresent(plannedDate, forKey: .plannedDate)
        try values.encodeIfPresent(dueDate, forKey: .dueDate)
        try values.encode(hasDueTime, forKey: .hasDueTime)
        try values.encodeIfPresent(reminderDate, forKey: .reminderDate)
        try values.encodeIfPresent(listID, forKey: .listID)
        try values.encode(isCompleted, forKey: .isCompleted)
        try values.encodeIfPresent(completedAt, forKey: .completedAt)
        try values.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try values.encodeIfPresent(createdAt, forKey: .createdAt)
        try values.encode(sortOrder, forKey: .sortOrder)
    }

    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= Self.maximumTitleLength
            && (estimatedMinutes.map { Self.minutesRange.contains($0) } ?? true)
            && notes.count <= Self.maximumNotesLength
            && [plannedDate, dueDate, reminderDate, completedAt, deletedAt, createdAt]
                .allSatisfy { $0.map(Self.validDate) ?? true }
            && (isCompleted || completedAt == nil)
            && (0...1_000_000_000).contains(sortOrder)
    }

    public func isOverdue(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isPending, let dueDate else { return false }
        if hasDueTime { return dueDate <= now }
        // A date-only task is due throughout its whole local calendar day, even
        // on daylight-saving days that do not have exactly 86,400 seconds.
        return calendar.startOfDay(for: dueDate) < calendar.startOfDay(for: now)
    }

    public static func parseMinutes(_ text: String) -> Int? {
        guard let value = Int(text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)),
              minutesRange.contains(value) else { return nil }
        return value
    }

    public static func parseEstimatedMinutes(_ text: String) -> Int? { parseMinutes(text) }

    static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (Date.distantPast...Date.distantFuture).contains(date)
    }
}

public struct TodoCollection: Codable, Identifiable, Equatable, Sendable {
    public static let maximumCount = 100
    public let id: UUID
    public var title: String

    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 80
    }
}

public enum FocusTarget: Codable, Equatable, Sendable {
    case free
    case todo(UUID)
    case list
}

public struct FocusTodoList: Codable, Equatable, Sendable {
    public var items: [FocusTodo] = []
    public var collections: [TodoCollection] = []
    public var target: FocusTarget = .free
    /// A session-specific adjustment; never changes an item's estimate.
    public var durationOverride: TimeInterval?

    public init() {}

    private enum CodingKeys: String, CodingKey { case items, collections, target, durationOverride }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([FocusTodo].self, forKey: .items)
        collections = try values.decodeIfPresent([TodoCollection].self, forKey: .collections) ?? []
        target = try values.decodeIfPresent(FocusTarget.self, forKey: .target) ?? .free
        durationOverride = try values.decodeIfPresent(TimeInterval.self, forKey: .durationOverride)
    }

    public var pending: [FocusTodo] {
        items.enumerated().filter { $0.element.isPending }.sorted { lhs, rhs in
            switch (lhs.element.dueDate, rhs.element.dueDate) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if lhs.element.sortOrder != rhs.element.sortOrder { return lhs.element.sortOrder < rhs.element.sortOrder }
                return lhs.offset < rhs.offset
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

    public var estimatedDuration: TimeInterval { TimeInterval(selected.reduce(0) { $0 + ($1.estimatedMinutes ?? 0) } * 60) }

    public mutating func normalizeSelection() {
        if target != .free && selected.isEmpty {
            target = .free
            durationOverride = nil
        }
    }
}
