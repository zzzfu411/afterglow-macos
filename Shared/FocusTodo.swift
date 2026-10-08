import Foundation
import CryptoKit

public struct FocusTodo: Codable, Identifiable, Equatable, Sendable {
    /// Completed and deleted items do not consume the active-task allowance.
    public static let maximumCount = 1_000
    public static let maximumStoredCount = 10_000
    public static let maximumTitleLength = 180
    public static let maximumNotesLength = 10_000
    public static let maximumStepCount = 100
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
    public var steps: [TodoStep]
    public var repeatRule: TodoRepeatRule?
    /// The scheduled calendar day for this occurrence, independent of edits to a deadline.
    public var repeatScheduledDate: Date?
    /// Once generated, reopening/completing this occurrence cannot generate another child.
    public var nextOccurrenceID: UUID?

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
                createdAt: Date? = nil, sortOrder: Int = 0, steps: [TodoStep] = [],
                repeatRule: TodoRepeatRule? = nil, repeatScheduledDate: Date? = nil,
                nextOccurrenceID: UUID? = nil) {
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
        self.steps = steps
        self.repeatRule = repeatRule
        self.repeatScheduledDate = repeatScheduledDate
        self.nextOccurrenceID = nextOccurrenceID
    }

    public init(id: UUID = UUID(), title: String, minutes: Int, isCompleted: Bool = false, dueDate: Date? = nil) {
        self.init(id: id, title: title, estimatedMinutes: minutes, dueDate: dueDate,
                  hasDueTime: dueDate != nil, isCompleted: isCompleted)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, minutes, estimatedMinutes, notes, plannedDate, dueDate, hasDueTime,
             reminderDate, listID, isCompleted, completedAt, deletedAt, createdAt, sortOrder,
             steps, repeatRule, repeatScheduledDate, nextOccurrenceID
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
        steps = try values.decodeIfPresent([TodoStep].self, forKey: .steps) ?? []
        repeatRule = try values.decodeIfPresent(TodoRepeatRule.self, forKey: .repeatRule)
        repeatScheduledDate = try values.decodeIfPresent(Date.self, forKey: .repeatScheduledDate)
        nextOccurrenceID = try values.decodeIfPresent(UUID.self, forKey: .nextOccurrenceID)
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
        if !steps.isEmpty { try values.encode(steps, forKey: .steps) }
        try values.encodeIfPresent(repeatRule, forKey: .repeatRule)
        try values.encodeIfPresent(repeatScheduledDate, forKey: .repeatScheduledDate)
        try values.encodeIfPresent(nextOccurrenceID, forKey: .nextOccurrenceID)
    }

    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= Self.maximumTitleLength
            && (estimatedMinutes.map { Self.minutesRange.contains($0) } ?? true)
            && notes.count <= Self.maximumNotesLength
            && [plannedDate, dueDate, reminderDate, completedAt, deletedAt, createdAt, repeatScheduledDate]
                .allSatisfy { $0.map(Self.validDate) ?? true }
            && (isCompleted || completedAt == nil)
            && (0...1_000_000_000).contains(sortOrder)
            && steps.count <= Self.maximumStepCount && steps.allSatisfy(\.isValid)
            && Set(steps.map(\.id)).count == steps.count
            && (repeatRule?.isValid ?? true)
            && nextOccurrenceID != id
    }

    var hasVersion5Metadata: Bool {
        !steps.isEmpty || repeatRule != nil || repeatScheduledDate != nil || nextOccurrenceID != nil
    }

    var estimatedStorageBytes: Int {
        title.utf8.count + notes.utf8.count + 768
            + steps.reduce(0) { $0 + $1.title.utf8.count + 96 }
            + (repeatRule?.timeZoneIdentifier.utf8.count ?? 0)
    }

    /// A stable, namespaced ID avoids duplicate children after reopening or
    /// importing an old copy of the source task. This algorithm is a file-format contract.
    public var generatedNextOccurrenceID: UUID { Self.stableID("moro.todo.next.v1:" + id.uuidString.lowercased()) }

    func nextOccurrence(completedAt now: Date) -> FocusTodo? {
        guard let rule = repeatRule, let calendar = rule.calendar,
              let day = rule.nextDate(after: repeatScheduledDate ?? plannedDate ?? dueDate, completedAt: now) else { return nil }
        let sourceDay = calendar.startOfDay(for: repeatScheduledDate ?? plannedDate ?? dueDate ?? rule.anchorDate)
        var next = FocusTodo(id: generatedNextOccurrenceID, title: title, estimatedMinutes: estimatedMinutes,
                             notes: notes, plannedDate: day, hasDueTime: hasDueTime, listID: listID,
                             createdAt: now, sortOrder: sortOrder, repeatRule: rule, repeatScheduledDate: day)
        if let dueDate {
            guard let shifted = rule.shift(dueDate, from: sourceDay, to: day, includesTime: hasDueTime) else { return nil }
            next.dueDate = shifted
        }
        if let reminderDate {
            guard let shifted = rule.shift(reminderDate, from: sourceDay, to: day, includesTime: true) else { return nil }
            next.reminderDate = shifted
        }
        next.steps = steps.map {
            TodoStep(id: Self.stableID("moro.todo.step.v1:" + next.id.uuidString.lowercased() + ":" + $0.id.uuidString.lowercased()), title: $0.title)
        }
        return next.isValid ? next : nil
    }

    private static func stableID(_ name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // RFC 9562 version 8, application-defined SHA-256 namespacing.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
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

public struct TodoStep: Codable, Identifiable, Equatable, Sendable {
    public static let maximumTitleLength = 180
    public let id: UUID
    public var title: String
    public var isCompleted: Bool

    public init(id: UUID = UUID(), title: String, isCompleted: Bool = false) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isCompleted = isCompleted
    }
    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= Self.maximumTitleLength
    }
}

public enum TodoRepeatFrequency: String, Codable, CaseIterable, Sendable {
    case daily, weekly, monthly
}

public struct TodoRepeatRule: Codable, Equatable, Sendable {
    public var frequency: TodoRepeatFrequency
    public var anchorDate: Date
    public var timeZoneIdentifier: String

    public init(frequency: TodoRepeatFrequency, anchorDate: Date,
                timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.frequency = frequency
        self.anchorDate = anchorDate
        self.timeZoneIdentifier = timeZoneIdentifier
    }
    public var isValid: Bool {
        FocusTodo.validDate(anchorDate) && timeZoneIdentifier.count <= 128 && TimeZone(identifier: timeZoneIdentifier) != nil
    }
    var calendar: Calendar? {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Produce one future occurrence, never a backlog. The fixed anchor retains
    /// the original weekday/day-of-month even after clamping February's end.
    public func nextDate(after scheduledDate: Date?, completedAt now: Date) -> Date? {
        guard isValid, FocusTodo.validDate(now), let calendar,
              scheduledDate.map(FocusTodo.validDate) ?? true else { return nil }
        let floor = max(calendar.startOfDay(for: scheduledDate ?? anchorDate), calendar.startOfDay(for: now))
        let next: Date?
        switch frequency {
        case .daily:
            next = calendar.date(byAdding: .day, value: 1, to: floor)
        case .weekly:
            let offset = (calendar.component(.weekday, from: anchorDate) - calendar.component(.weekday, from: floor) + 7) % 7
            next = calendar.date(byAdding: .day, value: offset == 0 ? 7 : offset, to: floor)
        case .monthly:
            guard let month = calendar.dateInterval(of: .month, for: floor)?.start else { return nil }
            let candidate = clampedMonthDate(month, calendar: calendar)
            if let candidate, candidate > floor { next = candidate }
            else if let following = calendar.date(byAdding: .month, value: 1, to: month) {
                next = clampedMonthDate(following, calendar: calendar)
            } else { next = nil }
        }
        guard let next, FocusTodo.validDate(next), next > floor else { return nil }
        return calendar.startOfDay(for: next)
    }

    private func clampedMonthDate(_ month: Date, calendar: Calendar) -> Date? {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return nil }
        var parts = calendar.dateComponents([.year, .month], from: month)
        parts.day = min(calendar.component(.day, from: anchorDate), range.count)
        parts.hour = 12 // Noon exists even in time zones with a midnight DST change.
        return calendar.date(from: parts).map { calendar.startOfDay(for: $0) }
    }

    func shift(_ date: Date, from oldDay: Date, to newDay: Date, includesTime: Bool) -> Date? {
        guard let calendar,
              let offset = calendar.dateComponents([.day], from: oldDay, to: calendar.startOfDay(for: date)).day,
              let target = calendar.date(byAdding: .day, value: offset, to: newDay) else { return nil }
        if !includesTime { return calendar.startOfDay(for: target) }
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        // Spring-forward gaps preserve smaller time components; fall-back uses
        // the first matching local time, yielding one reminder rather than two.
        let start = calendar.startOfDay(for: target)
        guard let shifted = calendar.nextDate(after: start.addingTimeInterval(-1),
                                              matching: DateComponents(hour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0),
                                              matchingPolicy: .nextTimePreservingSmallerComponents,
                                              repeatedTimePolicy: .first, direction: .forward),
              calendar.isDate(shifted, inSameDayAs: target) else { return nil }
        return shifted
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
