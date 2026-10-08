import Foundation

// Navigation and filtering stay independent from the active focus target.
enum TodoSection: Hashable {
    case inbox, today, upcoming, all, completed, trash, collection(UUID)
    var title: String {
        switch self {
        case .inbox: return "收件箱"
        case .today: return "今天"
        case .upcoming: return "接下来"
        case .all: return "全部"
        case .completed: return "已完成"
        case .trash: return "最近删除"
        case .collection: return "清单"
        }
    }
    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .today: return "sun.max"
        case .upcoming: return "calendar"
        case .all: return "square.stack"
        case .completed: return "checkmark.circle"
        case .trash: return "trash"
        case .collection: return "list.bullet"
        }
    }
    var persistenceKey: String {
        switch self {
        case .collection(let id): return "collection:\(id.uuidString)"
        default: return String(describing: self)
        }
    }
    init(key: String?) {
        if let key, key.hasPrefix("collection:"), let id = UUID(uuidString: String(key.dropFirst(11))) {
            self = .collection(id); return
        }
        switch key {
        case "inbox": self = .inbox
        case "upcoming": self = .upcoming
        case "all": self = .all
        case "completed": self = .completed
        case "trash": self = .trash
        default: self = .today
        }
    }
    func contains(_ item: FocusTodo, at now: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .completed: return item.isCompleted && !item.isDeleted
        case .trash: return item.isDeleted
        default: guard item.isPending else { return false }
        }
        switch self {
        case .inbox: return item.listID == nil
        case .today:
            return item.plannedDate.map { calendar.startOfDay(for: $0) <= calendar.startOfDay(for: now) } == true
                || item.dueDate.map { calendar.startOfDay(for: $0) <= calendar.startOfDay(for: now) } == true
        case .upcoming:
            return item.plannedDate.map { calendar.startOfDay(for: $0) > calendar.startOfDay(for: now) } == true
                || item.dueDate.map { calendar.startOfDay(for: $0) > calendar.startOfDay(for: now) } == true
        case .collection(let id): return item.listID == id
        case .all: return true
        default: return false
        }
    }
}

enum TodoSort: String, CaseIterable { case deadline, manual }

struct TodoDraft: Equatable {
    var baseItem: FocusTodo?
    var id = UUID()
    var title = ""
    var minutes = ""
    var notes = ""
    var steps: [TodoStep] = []
    var repeatRule: TodoRepeatRule?
    var repeatScheduledDate: Date?
    var plannedDate: Date?
    var dueDate: Date?
    var hasDueTime = false
    var reminderDate: Date?
    var listID: UUID?
    var isNew = true

    init(item: FocusTodo? = nil) {
        baseItem = item
        if let item {
            id = item.id; title = item.title; minutes = item.estimatedMinutes.map(String.init) ?? ""
            notes = item.notes; steps = item.steps; repeatRule = item.repeatRule; repeatScheduledDate = item.repeatScheduledDate
            plannedDate = item.plannedDate; dueDate = item.dueDate
            hasDueTime = item.hasDueTime; reminderDate = item.reminderDate; listID = item.listID; isNew = false
        }
    }
    func sameEditableFields(as other: TodoDraft) -> Bool {
        var left = self, right = other
        left.baseItem = nil; right.baseItem = nil; left.isNew = false; right.isNew = false
        return left == right
    }
    var hasUnsavedChanges: Bool {
        if let baseItem { return !sameEditableFields(as: TodoDraft(item: baseItem)) }
        return !title.isEmpty || !notes.isEmpty || !minutes.isEmpty || !steps.isEmpty || repeatRule != nil
            || plannedDate != nil || dueDate != nil || reminderDate != nil || listID != nil
    }
    var isValid: Bool {
        let text = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || FocusTodo.parseEstimatedMinutes(text) != nil else { return false }
        return applying(to: nil).isValid
    }
    func applying(to existing: FocusTodo?) -> FocusTodo {
        var item = existing ?? FocusTodo(id: id, title: title, createdAt: Date())
        item.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.estimatedMinutes = FocusTodo.parseEstimatedMinutes(minutes)
        item.steps = steps; item.repeatRule = repeatRule; item.repeatScheduledDate = repeatScheduledDate
        item.notes = notes; item.plannedDate = plannedDate; item.dueDate = dueDate
        item.hasDueTime = dueDate != nil && hasDueTime
        item.reminderDate = reminderDate; item.listID = listID
        return item
    }
    static func suggestedDueDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: 18, minute: 0, second: 0), matchingPolicy: .nextTime) ?? now
    }
}
