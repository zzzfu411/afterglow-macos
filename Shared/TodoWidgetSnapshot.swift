import Foundation

/// The extension reads only the fields it displays, never notes, steps, archives,
/// undo receipts or the full log. At most 1,000 active task summaries are retained.
struct TodoWidgetItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let plannedDate: Date?
    let dueDate: Date?
    let hasDueTime: Bool
    let sortOrder: Int

    init(_ todo: FocusTodo) {
        id = todo.id
        title = String(String.UnicodeScalarView(todo.title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(240)))
        plannedDate = todo.plannedDate; dueDate = todo.dueDate
        hasDueTime = todo.hasDueTime; sortOrder = todo.sortOrder
    }
    func isToday(at now: Date, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        return plannedDate.map { calendar.startOfDay(for: $0) <= today } == true
            || dueDate.map { calendar.startOfDay(for: $0) <= today } == true
    }
}

struct TodoWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let sourceModifiedAt: Double?
    let sourceBytes: Int
    var timer: FocusState
    let items: [TodoWidgetItem]

    init(state: FocusState, sourceModifiedAt: Double? = nil, sourceBytes: Int = 0) {
        version = Self.currentVersion; self.sourceModifiedAt = sourceModifiedAt; self.sourceBytes = sourceBytes
        var clock = FocusState(mode: state.mode, duration: state.duration)
        clock.duration = state.duration; clock.status = state.status; clock.remaining = state.remaining
        clock.deadline = state.deadline; clock.startedAt = state.startedAt; clock.sessionID = state.sessionID
        clock.sessionTask = state.status == .idle ? nil : ""; clock.completedNaturally = state.completedNaturally
        clock.focusDuration = state.plannedFocusDuration; clock.restDuration = state.restDuration
        timer = clock
        items = state.todos.filter(\.isPending).map(TodoWidgetItem.init)
    }
    func today(at now: Date, calendar: Calendar = .current) -> [TodoWidgetItem] {
        items.filter { $0.isToday(at: now, calendar: calendar) }.sorted { a, b in
            if a.dueDate != b.dueDate { return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture) }
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.id.uuidString < b.id.uuidString
        }
    }
    func settled(at date: Date) -> TodoWidgetSnapshot {
        var copy = self
        copy.timer = timer.applying(.settle, at: date)
        copy.timer.logs = []
        return copy
    }
}

enum TodoWidgetCacheError: Error { case unavailable, stale, invalid }

enum TodoWidgetCache {
    static let filename = "widget-snapshot.json"
    static let maximumBytes = 2_000_000

    /// Called while the authoritative store transaction lock is held. A failed
    /// cache cannot invalidate a successful user-data write; freshness is checked
    /// against the source file before the extension uses a cached value.
    static func write(state: FocusState, directory: URL) throws {
        let source = directory.appendingPathComponent("focus-state.json")
        let metadata = try sourceMetadata(source)
        let url = directory.appendingPathComponent(filename)
        if let old = try? readFile(url),
           old.sourceModifiedAt == metadata.modified, old.sourceBytes == metadata.bytes { return }
        let snapshot = TodoWidgetSnapshot(state: state, sourceModifiedAt: metadata.modified, sourceBytes: metadata.bytes)
        try validate(snapshot)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumBytes else { throw TodoWidgetCacheError.invalid }
        try data.write(to: url, options: .atomic)
    }
    static func read(directory: URL, at date: Date = Date()) throws -> TodoWidgetSnapshot {
        let snapshot = try readFile(directory.appendingPathComponent(filename))
        let metadata = try sourceMetadata(directory.appendingPathComponent("focus-state.json"))
        guard snapshot.sourceModifiedAt == metadata.modified, snapshot.sourceBytes == metadata.bytes else { throw TodoWidgetCacheError.stale }
        return snapshot.settled(at: date)
    }
    private static func readFile(_ url: URL) throws -> TodoWidgetSnapshot {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes else { throw TodoWidgetCacheError.invalid }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw TodoWidgetCacheError.invalid }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(TodoWidgetSnapshot.self, from: data)
        try validate(snapshot)
        return snapshot
    }
    private static func validate(_ snapshot: TodoWidgetSnapshot) throws {
        guard snapshot.version == TodoWidgetSnapshot.currentVersion,
              snapshot.items.count <= FocusTodo.maximumCount,
              Set(snapshot.items.map(\.id)).count == snapshot.items.count,
              snapshot.timer.logs.isEmpty, snapshot.timer.todoList == nil, snapshot.timer.sessionTodoIDs == nil,
              snapshot.timer.task.isEmpty, snapshot.timer.sessionTask.map(\.isEmpty) ?? true,
              snapshot.items.allSatisfy({ item in
                  !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && item.title.unicodeScalars.count <= 240
                      && (0...1_000_000_000).contains(item.sortOrder)
                      && [item.plannedDate, item.dueDate].allSatisfy { $0.map(FocusTodo.validDate) ?? true }
              }) else { throw TodoWidgetCacheError.invalid }
        try snapshot.timer.validate()
    }
    private static func sourceMetadata(_ url: URL) throws -> (modified: Double?, bytes: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, 0) }
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values.contentModificationDate?.timeIntervalSince1970, values.fileSize ?? 0)
    }
}
