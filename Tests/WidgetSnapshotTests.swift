import Foundation

/// Exercises the extension's read-only projection and wake-up boundaries without
/// loading WidgetKit, a real App Group, or the user's preferences and task store.
@main
struct WidgetSnapshotTests {
    private static var checks = 0

    private static func expect(_ assertion: Bool, _ message: String) {
        guard assertion else { fatalError("FAIL: \(message)") }
        checks += 1
    }

    private static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("FAIL: \(message)") }
        catch { checks += 1 }
    }

    private static func calendar(_ zone: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }

    private static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private static func state(_ tasks: [FocusTodo]) -> FocusState {
        var state = FocusState()
        var list = FocusTodoList(); list.items = tasks; state.todoList = list
        return state
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func main() throws {
        let shanghai = calendar("Asia/Shanghai")
        let now = date("2026-10-08T09:00:00+08:00")
        let day = shanghai.startOfDay(for: now)
        let yesterday = shanghai.date(byAdding: .day, value: -1, to: day)!
        let tomorrow = shanghai.date(byAdding: .day, value: 1, to: day)!
        let overdue = FocusTodo(title: "Overdue", dueDate: yesterday, sortOrder: 5)
        let dueToday = FocusTodo(title: "Due later today", dueDate: day.addingTimeInterval(20 * 3_600), hasDueTime: true)
        let scheduled = FocusTodo(title: "Planned", plannedDate: day, sortOrder: 4)
        let carried = FocusTodo(title: "Carried", plannedDate: yesterday, sortOrder: 3)
        let bothDates = FocusTodo(title: "Both dates", plannedDate: day, dueDate: day, sortOrder: 2)
        let future = FocusTodo(title: "Tomorrow", plannedDate: tomorrow)
        let undated = FocusTodo(title: "Inbox")
        let completed = FocusTodo(title: "PRIVATE_COMPLETED", plannedDate: day, isCompleted: true, completedAt: now)
        let deleted = FocusTodo(title: "PRIVATE_DELETED", plannedDate: day, deletedAt: now)
        var privateTask = FocusTodo(title: "Visible", notes: "PRIVATE_NOTES", plannedDate: day, sortOrder: 1,
                                    steps: [TodoStep(title: "PRIVATE_STEP")])
        privateTask.reminderDate = now.addingTimeInterval(100)
        let original = state([future, undated, completed, deleted, privateTask, scheduled, carried, bothDates, dueToday, overdue])
        try original.validate()
        let snapshot = TodoWidgetSnapshot(state: original)
        let today = snapshot.today(at: now, calendar: shanghai)
        expect(today.map(\.id) == [overdue.id, bothDates.id, dueToday.id, privateTask.id, carried.id, scheduled.id],
               "today combines overdue, planned and due tasks in deadline/manual order")
        expect(today.filter { $0.id == bothDates.id }.count == 1, "planned and due on the same day is one task")
        expect(!today.contains { $0.id == future.id || $0.id == undated.id }, "tomorrow and undated inbox tasks stay out of today")
        expect(snapshot.today(at: tomorrow, calendar: shanghai).contains { $0.id == future.id }, "tomorrow appears at local midnight")
        expect(snapshot.items.count == 8, "completed and deleted items are absent from the extension cache")
        expect(snapshot.timer.todoList == nil && snapshot.timer.logs.isEmpty && snapshot.timer.sessionTodoIDs == nil,
               "the timer projection does not retain the document or task ID list")
        let privateEncoded = String(decoding: try encoded(snapshot), as: UTF8.self)
        for marker in ["PRIVATE_NOTES", "PRIVATE_STEP", "PRIVATE_COMPLETED", "PRIVATE_DELETED", "reminderDate"] {
            expect(!privateEncoded.contains(marker), "cache omits \(marker)")
        }

        // Stable ties avoid visually shuffling equal-date tasks across refreshes.
        let firstID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let ties = TodoWidgetSnapshot(state: state([
            FocusTodo(id: secondID, title: "Second", plannedDate: day),
            FocusTodo(id: firstID, title: "First", plannedDate: day)
        ]))
        expect(ties.today(at: now, calendar: shanghai).map(\.id) == [firstID, secondID], "equal-date/order ties are stable")

        // Running timer settlement is local and must not persist a log or change
        // the task. A paused timer has no wall-clock deadline and cannot expire.
        var timer = original.applying(.selectTarget(.todo(privateTask.id)), at: now)
        timer = timer.applying(.start, at: now)
        let running = TodoWidgetSnapshot(state: timer)
        try running.timer.validate()
        expect(running.timer.task.isEmpty && running.timer.sessionTask == "" && running.timer.todoList == nil,
               "the timer carries no session title or complete task document")
        expect(running.timer.remaining(at: now.addingTimeInterval(60)) == 1_440, "active countdown is date based")
        let finished = running.settled(at: now.addingTimeInterval(1_500))
        try finished.timer.validate()
        expect(finished.timer.status == .done && finished.timer.remaining == 0, "deadline advances the cached timer to done")
        expect(finished.timer.logs.isEmpty && finished.items == running.items, "local settlement adds neither history nor task mutations")
        expect(running.timer.status == .running && running.timer.logs.isEmpty, "settlement leaves the input cache value unchanged")
        let paused = TodoWidgetSnapshot(state: timer.applying(.pause, at: now.addingTimeInterval(45)))
        try paused.timer.validate()
        let pausedLater = paused.settled(at: now.addingTimeInterval(100_000))
        expect(pausedLater.timer.status == .paused && pausedLater.timer.remaining == 1_455, "paused timers remain paused across days")
        try snapshot.timer.validate()
        expect(snapshot.timer.sessionTask == nil, "idle timer has no synthetic active session")
        var loggedState = timer
        loggedState.logs = [FocusLog(id: UUID(), task: "PRIVATE_HISTORY", startedAt: now.addingTimeInterval(-600),
                                    endedAt: now, seconds: 600, completed: true, todoIDs: [privateTask.id])]
        let loggedData = String(decoding: try encoded(TodoWidgetSnapshot(state: loggedState)), as: UTF8.self)
        expect(!loggedData.contains("PRIVATE_HISTORY"), "cache never includes retained focus logs")

        // Tests write only inside a uniquely named temporary directory. Reading
        // the cache must not acquire or rewrite the authoritative task document.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-widget-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("focus-state.json")
        let cacheURL = directory.appendingPathComponent(TodoWidgetCache.filename)
        let sourceData = try encoded(timer)
        try sourceData.write(to: sourceURL, options: .atomic)
        try TodoWidgetCache.write(state: timer, directory: directory)
        let goodCache = try Data(contentsOf: cacheURL)
        let read = try TodoWidgetCache.read(directory: directory, at: now)
        expect(read.timer == running.timer && read.items == running.items, "cache round-trip preserves the thin snapshot")
        expect(try TodoWidgetCache.read(directory: directory, at: now.addingTimeInterval(1_501)).timer.status == .done,
               "read settles elapsed timers without a store mutation")
        expect(try Data(contentsOf: sourceURL) == sourceData, "cache reads preserve the authoritative document byte for byte")
        expect(try Data(contentsOf: cacheURL) == goodCache, "cache reads do not rewrite the snapshot")

        // Source byte count gives a deterministic stale test without sleep or
        // relying on the filesystem's timestamp precision.
        try (sourceData + Data(" ".utf8)).write(to: sourceURL, options: .atomic)
        do {
            _ = try TodoWidgetCache.read(directory: directory, at: now)
            fatalError("FAIL: stale source accepted")
        } catch TodoWidgetCacheError.stale { checks += 1 }
        try TodoWidgetCache.write(state: timer, directory: directory)
        expect(try TodoWidgetCache.read(directory: directory, at: now).items == running.items, "cache rebuild recovers a stale projection")
        try FileManager.default.removeItem(at: sourceURL)
        rejects("a cache from a removed document is stale") { _ = try TodoWidgetCache.read(directory: directory, at: now) }
        try sourceData.write(to: sourceURL, options: .atomic)
        try TodoWidgetCache.write(state: timer, directory: directory)
        let currentCache = try Data(contentsOf: cacheURL)
        let currentJSON = try JSONSerialization.jsonObject(with: currentCache) as! [String: Any]

        func corrupt(_ change: (inout [String: Any]) -> Void) throws {
            var json = currentJSON; change(&json)
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: cacheURL, options: .atomic)
        }
        try corrupt { $0["version"] = TodoWidgetSnapshot.currentVersion + 1 }
        rejects("future cache versions cannot be interpreted silently") { _ = try TodoWidgetCache.read(directory: directory, at: now) }
        try corrupt { json in
            let items = json["items"] as! [[String: Any]]; json["items"] = items + [items[0]]
        }
        rejects("duplicate task identities are rejected") { _ = try TodoWidgetCache.read(directory: directory, at: now) }
        try corrupt { json in
            var items = json["items"] as! [[String: Any]]; items[0]["title"] = "  "; json["items"] = items
        }
        rejects("blank cached task titles are rejected") { _ = try TodoWidgetCache.read(directory: directory, at: now) }
        try corrupt { json in
            var items = json["items"] as! [[String: Any]]; items[0]["sortOrder"] = -1; json["items"] = items
        }
        rejects("invalid order is rejected") { _ = try TodoWidgetCache.read(directory: directory, at: now) }
        try corrupt { json in
            var items = json["items"] as! [[String: Any]]; items[0]["dueDate"] = 1e20; json["items"] = items
        }
        rejects("out-of-range task dates are rejected") { _ = try TodoWidgetCache.read(directory: directory, at: now) }
        try corrupt { json in
            var clock = json["timer"] as! [String: Any]; clock["remaining"] = -1; json["timer"] = clock
        }
        rejects("invalid timer state is rejected") { _ = try TodoWidgetCache.read(directory: directory, at: now) }
        try corrupt { json in
            var clock = json["timer"] as! [String: Any]
            clock["todoList"] = ["items": [], "collections": [], "target": ["free": [:]]] as [String: Any]
            json["timer"] = clock
        }
        rejects("a full document cannot be smuggled into the thin timer") { _ = try TodoWidgetCache.read(directory: directory, at: now) }
        try Data("{ broken".utf8).write(to: cacheURL, options: .atomic)
        rejects("truncated cache data fails closed") { _ = try TodoWidgetCache.read(directory: directory, at: now) }
        try TodoWidgetCache.write(state: timer, directory: directory)
        expect(try TodoWidgetCache.read(directory: directory, at: now).items == running.items, "corrupt cache is rebuilt from valid state")
        try Data(repeating: 32, count: TodoWidgetCache.maximumBytes + 1).write(to: cacheURL, options: .atomic)
        rejects("oversized cache is rejected before decoding") { _ = try TodoWidgetCache.read(directory: directory, at: now) }
        try FileManager.default.removeItem(at: cacheURL)
        rejects("missing cache does not load or invent task data") { _ = try TodoWidgetCache.read(directory: directory, at: now) }

        // One thousand richly annotated tasks still yield a small, bounded cache.
        let annotated = (0..<FocusTodo.maximumCount).map {
            FocusTodo(title: "Task \($0)", notes: String(repeating: "N", count: 2_000), plannedDate: day, sortOrder: $0,
                      steps: [TodoStep(title: "STEP_PRIVATE_\($0)")])
        }
        let bounded = TodoWidgetSnapshot(state: state(annotated))
        let boundedBytes = try encoded(bounded)
        expect(bounded.items.count == FocusTodo.maximumCount && boundedBytes.count < 300_000,
               "maximum active list produces a bounded metadata-only projection")
        expect(!String(decoding: boundedBytes, as: UTF8.self).contains("STEP_PRIVATE_"), "large task projections still omit steps")

        // Wake-ups are driven only by an active timer boundary and the next local
        // calendar day, including DST's 23/25-hour days, never a polling interval.
        expect(TodoWidgetSchedule.dates(after: now, snapshot: snapshot, calendar: shanghai) == [tomorrow], "static list wakes only at next local midnight")
        expect(TodoWidgetSchedule.dates(after: now, snapshot: running, calendar: shanghai) == [now.addingTimeInterval(1_500), tomorrow],
               "active list includes the timer deadline before local midnight")
        expect(TodoWidgetSchedule.dates(after: now, snapshot: paused, calendar: shanghai) == [tomorrow], "paused timer adds no polling wake-up")
        expect(TodoWidgetSchedule.dates(after: now, snapshot: finished, calendar: shanghai) == [tomorrow], "finished timer adds no polling wake-up")
        expect(TodoWidgetSchedule.dates(after: now.addingTimeInterval(1_600), snapshot: running, calendar: shanghai) == [tomorrow],
               "expired deadlines cannot schedule wake-ups in the past")
        let nearMidnight = tomorrow.addingTimeInterval(-60)
        let midnightTimer = TodoWidgetSnapshot(state: FocusState(duration: 60).applying(.start, at: nearMidnight))
        expect(TodoWidgetSchedule.dates(after: nearMidnight, snapshot: midnightTimer, calendar: shanghai) == [tomorrow], "matching timer/day boundaries are deduplicated")
        let midnightFirst = TodoWidgetSnapshot(state: FocusState(duration: 120).applying(.start, at: nearMidnight))
        expect(TodoWidgetSchedule.dates(after: nearMidnight, snapshot: midnightFirst, calendar: shanghai) == [tomorrow, tomorrow.addingTimeInterval(60)],
               "timeline remains chronological when midnight precedes the timer deadline")

        let losAngeles = calendar("America/Los_Angeles")
        for (start, next, hours) in [("2026-03-08T00:00:00-08:00", "2026-03-09T00:00:00-07:00", 23.0),
                                    ("2026-11-01T00:00:00-07:00", "2026-11-02T00:00:00-08:00", 25.0)] {
            let startDate = date(start), expected = date(next)
            let schedule = TodoWidgetSchedule.dates(after: startDate, snapshot: snapshot, calendar: losAngeles)
            expect(schedule == [expected], "DST transition wakes at actual local midnight")
            expect(schedule[0].timeIntervalSince(startDate) == hours * 3_600, "DST calendar day has \(hours) hours")
        }
        let utc = calendar("UTC")
        expect(TodoWidgetSchedule.dates(after: now, snapshot: snapshot, calendar: utc) == [date("2026-10-09T00:00:00Z")],
               "timezone controls the next calendar-day boundary")
        try testUnicodeTitlesAndLegacyTimer(at: now)
        print("PASS: \(checks) widget snapshot checks; read-only cache, date boundaries, corruption handling and no static polling.")
    }

    private static func testUnicodeTitlesAndLegacyTimer(at now: Date) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-widget-edge-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("focus-state.json")
        let cacheURL = directory.appendingPathComponent(TodoWidgetCache.filename)

        // CRLF counts as one Swift Character but contains two Unicode scalars.
        // A valid imported title can therefore have 240 leading blank scalars;
        // trimming after truncation would create an unreadable, perpetually
        // rewritten cache despite the authoritative document being unchanged.
        var imported = FocusTodo(title: "Task")
        imported.title = String(repeating: "\r\n", count: 120) + "Task"
        let importedState = state([imported])
        try importedState.validate()
        expect(imported.title.count == 124 && imported.title.unicodeScalars.count == 244,
               "imported title fixture fits the persisted Character limit")
        try encoded(importedState).write(to: sourceURL, options: .atomic)
        try TodoWidgetCache.write(state: importedState, directory: directory)
        let decoded = try TodoWidgetCache.read(directory: directory, at: now)
        expect(decoded.items.first?.title == "Task", "cache trims imported whitespace before limiting Unicode scalars")
        let before = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.systemFileNumber] as! NSNumber
        try TodoWidgetCache.write(state: importedState, directory: directory)
        let after = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.systemFileNumber] as! NSNumber
        expect(before == after, "valid unchanged cache is not atomically rewritten and cannot feed its own watcher")

        let combining = FocusTodo(title: String(repeating: "e\u{301}", count: FocusTodo.maximumTitleLength))
        let combiningState = state([combining])
        try combiningState.validate()
        try encoded(combiningState).write(to: sourceURL, options: .atomic)
        try TodoWidgetCache.write(state: combiningState, directory: directory)
        let limited = try TodoWidgetCache.read(directory: directory, at: now)
        expect(limited.items.first?.title.unicodeScalars.count == 240,
               "valid combining-character titles stay within the cache scalar bound")

        // Pre-todo-first whole-list sessions could exceed today's single-session
        // input limit. Upgrading and projecting them must retain the live clock.
        var legacy = FocusState().applying(.start, at: now)
        legacy.version = 3
        legacy.duration = 360 * 60; legacy.remaining = legacy.duration
        legacy.deadline = now.addingTimeInterval(legacy.duration)
        try legacy.validate()
        try encoded(legacy).write(to: sourceURL, options: .atomic)
        let migrated = try FocusStore(directory: directory).snapshot(at: now)
        let longTimer = try TodoWidgetCache.read(directory: directory, at: now)
        try longTimer.timer.validate()
        expect(migrated.version == FocusState.currentVersion && longTimer.timer.duration == 21_600
               && longTimer.timer.deadline == legacy.deadline && longTimer.timer.sessionID == legacy.sessionID,
               "migration and cache decoding preserve a running legacy 360-minute session")
        let settled = try TodoWidgetCache.read(directory: directory, at: now.addingTimeInterval(21_600))
        try settled.timer.validate()
        expect(settled.timer.status == .done && settled.timer.logs.isEmpty,
               "a long legacy cached timer settles without reintroducing history")
    }
}
