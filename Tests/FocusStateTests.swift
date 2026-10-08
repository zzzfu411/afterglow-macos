import Foundation

@main
struct FocusStateTests {
    static var count = 0
    static func expect(_ assertion: Bool, _ message: String) {
        guard assertion else { fatalError("FAIL: \(message)") }
        count += 1
    }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--worker" {
            let store = FocusStore(directory: URL(fileURLWithPath: args[2]))
            for _ in 0..<41 { try store.toggle(at: Date(timeIntervalSince1970: 100_000)) }
            return
        }
        if args.count == 5, args[1] == "--complete-worker", let id = UUID(uuidString: args[3]), let timestamp = Double(args[4]) {
            let store = FocusStore(directory: URL(fileURLWithPath: args[2]))
            for _ in 0..<5 { try store.performTodoAction(.setTodoCompleted(id, true), at: Date(timeIntervalSince1970: timestamp)) }
            return
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = FocusState(duration: 1500, task: "写作")
        try original.validate()
        expect(original.status == .idle && original.remaining == 1500, "defaults")
        expect(FocusState(mode: .rest).duration == 300, "five-minute rest default")

        let running = original.applying(.start, at: start)
        expect(running.deadline == start.addingTimeInterval(1500), "deadline persisted")
        expect(running.remaining(at: start.addingTimeInterval(100)) == 1400, "elapsed wall time")
        expect(running.remaining(at: start.addingTimeInterval(-100)) == 1500, "backward clock does not inflate remaining")
        let paused = running.applying(.pause, at: start.addingTimeInterval(100))
        expect(paused.status == .paused && paused.remaining == 1400, "pause stores remaining")
        expect(paused.remaining(at: start.addingTimeInterval(10_000)) == 1400, "pause does not count time")
        let resumed = paused.applying(.start, at: start.addingTimeInterval(300))
        expect(resumed.deadline == start.addingTimeInterval(1700), "resume excludes pause")
        expect(resumed.sessionID == running.sessionID, "resume retains session")
        expect(running.applying(.selectMode(.rest), at: start.addingTimeInterval(50)) == running, "active mode switch ignored")
        expect(paused.applying(.selectDuration(60), at: start.addingTimeInterval(150)) == paused, "active preset change ignored")

        let done = resumed.applying(.settle, at: start.addingTimeInterval(86_400))
        expect(done.status == .done && done.logs.count == 1, "sleep settles once")
        expect(done.logs[0].endedAt == start.addingTimeInterval(1700), "completion attributed to deadline")
        expect(done.logs[0].seconds == 1500 && done.logs[0].completed, "only active seconds counted")
        expect(done.applying(.settle, at: start.addingTimeInterval(172_800)).logs.count == 1, "no duplicate completion")
        let interrupted = resumed.applying(.finish, at: start.addingTimeInterval(400))
        expect(interrupted.logs[0].seconds == 200 && !interrupted.logs[0].completed, "early finish counts work only")
        expect(running.applying(.setTask("改名"), at: start.addingTimeInterval(10)).applying(.finish, at: start.addingTimeInterval(20)).logs[0].task == "写作", "history task is immutable")
        let fresh = done.applying(.start, at: start.addingTimeInterval(90_000))
        expect(fresh.sessionID != done.sessionID && fresh.logs.count == 1, "new session retains history")
        expect(running.applying(.start, at: start.addingTimeInterval(2000)).status == .done, "stale start settles expired session")
        let rest = FocusState(mode: .rest).applying(.start, at: start).applying(.settle, at: start.addingTimeInterval(400))
        expect(rest.status == .done && rest.logs.isEmpty, "rest is not focus history")
        let nextRest = done.applying(.startNext, at: start.addingTimeInterval(90_000))
        expect(nextRest.mode == .rest && nextRest.status == .running && nextRest.duration == 300, "one click starts remembered rest")
        expect(nextRest.logs == done.logs && nextRest.sessionID != done.sessionID, "rest keeps history and has a fresh session")
        expect(rest.applying(.startNext, at: start.addingTimeInterval(500)).mode == .focus, "rest completion starts focus")
        expect(paused.applying(.startNext, at: start.addingTimeInterval(150)) == paused, "stale next cannot abandon paused work")
        expect(paused.applying(.reset, at: start.addingTimeInterval(150)) == paused, "stale wrap-up cannot discard paused work")
        let wrappedUp = nextRest.applying(.finish, at: start.addingTimeInterval(90_060)).applying(.reset)
        expect(wrappedUp.mode == .focus && wrappedUp.status == .idle && wrappedUp.logs == done.logs, "wrap-up preserves history and prepares next focus")
        expect(done.completedNaturally == true && interrupted.completedNaturally == false, "natural completion distinguished from cancellation")
        let custom = original.applying(.selectDuration(37 * 60)).applying(.selectMode(.rest)).applying(.selectDuration(7 * 60)).applying(.selectMode(.focus))
        expect(custom.duration == 37 * 60 && custom.restDuration == 7 * 60, "custom durations remembered independently")
        expect(original.applying(.selectDuration(59)) == original && original.applying(.selectDuration(10_801)) == original, "custom duration boundaries enforced")
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(done)) as! [String: Any]
        legacyJSON.removeValue(forKey: "completedNaturally")
        let legacy = try JSONDecoder().decode(FocusState.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        expect(legacy.logs == done.logs && legacy.completedNaturally == nil, "old files migrate without losing history")
        expect(original.applying(.selectDuration(.nan)) == original, "invalid preset rejected")
        let encoded = try JSONEncoder().encode(resumed)
        expect(try JSONDecoder().decode(FocusState.self, from: encoded) == resumed, "state survives restart")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterglow-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory)
        try store.update(.start, at: start)
        let cold = FocusStore(directory: directory)
        expect(try cold.snapshot(at: start.addingTimeInterval(60)).status == .running, "cold process reads active session")
        try cold.update(.pause, at: start.addingTimeInterval(60))
        expect(try store.snapshot(at: start.addingTimeInterval(80)).remaining == 1440, "other process state is not overwritten")
        let retained = try store.startRest(at: start.addingTimeInterval(80))
        expect(retained.mode == .focus && retained.status == .paused, "stale rest click preserves focus")
        try store.update(.finish, at: start.addingTimeInterval(80))
        expect(try store.startRest(at: start.addingTimeInterval(100)).mode == .rest, "rest action updates and starts transactionally")
        let expiredToggle = try store.toggle(at: start.addingTimeInterval(500))
        expect(expiredToggle.status == .done, "expired widget pause settles without starting another phase")
        let nextToggle = try store.toggle(at: start.addingTimeInterval(501))
        expect(nextToggle.status == .running && nextToggle.mode == .focus, "completed widget primary starts next phase")

        let corrupt = directory.appendingPathComponent("focus-state.json")
        let invalidBytes = Data("broken-json".utf8)
        try invalidBytes.write(to: corrupt)
        do {
            _ = try store.snapshot()
            fatalError("Corrupt data should throw")
        } catch {
            expect(try Data(contentsOf: corrupt) == invalidBytes, "corrupt file preserved")
        }

        let sharedDirectory = directory.appendingPathComponent("cross-process")
        var workers: [Process] = []
        for _ in 0..<6 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0])
            process.arguments = ["--worker", sharedDirectory.path]
            try process.run()
            workers.append(process)
        }
        for worker in workers { worker.waitUntilExit(); expect(worker.terminationStatus == 0, "worker finished") }
        let shared = try FocusStore(directory: sharedDirectory).snapshot(at: Date(timeIntervalSince1970: 100_000))
        expect(shared.status == .paused, "246 concurrent toggles remain serialized")
        try shared.validate()
        try testTodos(at: start)
        try testTodoDueDates(at: start)
        try testCompletionUndo(at: start)
        try testMigration(at: start)
        try testCapacity(at: start)
        try testCollections(at: start)
        try testStepsAndRecurrence(at: start)
        try testRepeatCalendar()
        try testRepeatCapacity(at: start)
        try testVersion4Migration(at: start)
        try testFocusSummaries(at: start)
        try testConcurrentRepeatCompletion(at: start)
        print("PASS: \(count) checks; includes 6 processes / 246 toggles and 4 processes / 20 recurring completions.")
    }

    static func testTodos(at start: Date) throws {
        let writing = FocusTodo(title: "  写初稿  ", minutes: 240)
        let reading = FocusTodo(title: "读论文")
        let finished = FocusTodo(title: "整理桌面", estimatedMinutes: 5, isCompleted: true)
        let base = FocusState(duration: 900).applying(.addTodo(writing), at: start)
            .applying(.addTodo(reading), at: start).applying(.addTodo(finished), at: start)
        expect(base.version == FocusState.currentVersion && base.todos.count == 3 && base.todos[0].title == "写初稿", "new tasks use the current schema and normalized titles")
        expect(base.todos[1].estimatedMinutes == nil && base.todos[1].minutes == 0, "title-only task needs no estimate")
        expect(base.todos[1].createdAt == start && base.todos[2].completedAt == nil, "new creation known, historic completion never invented")
        expect(base.applying(.addTodo(writing)) == base, "duplicate task ID rejected")
        for item in [FocusTodo(title: " \n"), FocusTodo(title: "x", minutes: 0), FocusTodo(title: "x", minutes: 10_081), FocusTodo(title: String(repeating: "字", count: 181))] {
            expect(base.applying(.addTodo(item)) == base, "invalid todo cannot enter store")
        }
        expect(FocusTodo.parseEstimatedMinutes(" ２４０ ") == 240 && FocusTodo.parseEstimatedMinutes("2.5") == nil, "estimates support long tasks and full-width input")
        let single = base.applying(.selectTarget(.todo(writing.id)))
        expect(single.duration == 900 && single.plannedTask == "写初稿", "task estimate never determines the focus block")
        expect(single.durationLimit == FocusState.maximumDuration && single.applying(.selectDuration(10_801)) == single, "focus duration limit stays separate from task estimate")
        let all = single.applying(.selectTarget(.list))
        expect(all.duration == 900 && all.todoList?.selected.count == 2, "legacy list selection uses a focus block, not summed estimates")
        expect(base.applying(.selectTarget(.todo(finished.id))) == base, "cannot focus completed item")
        expect(base.applying(.selectTarget(.todo(UUID()))) == base, "stale task selection ignored")
        let adjusted = single.applying(.selectDuration(600))
        expect(adjusted.duration == 600 && adjusted.todos[0].estimatedMinutes == 240 && adjusted.focusDuration == 900, "session override does not overwrite estimate or free duration")
        let reestimated = adjusted.applying(.editTodo(writing.id, title: "润色", minutes: 50))
        expect(reestimated.duration == 600 && reestimated.todoList?.durationOverride == 600, "estimate changes do not reschedule a planned block")
        let running = single.applying(.start, at: start)
        expect(running.sessionTodoIDs == [writing.id], "session freezes task association")
        expect(running.applying(.selectTarget(.free), at: start) == running, "running target is immutable")
        let edited = running.applying(.editTodo(writing.id, title: "改名", minutes: 1), at: start.addingTimeInterval(2))
        expect(edited.deadline == running.deadline && edited.currentTask == "写初稿", "task edit does not reschedule or relabel active focus")
        let completed = edited.applying(.setTodoCompleted(writing.id, true), at: start.addingTimeInterval(60))
        expect(completed.status == .done && completed.logs.last?.seconds == 60 && completed.logs.last?.todoIDs == [writing.id], "completing the focused task ends its real session and links history")
        expect(completed.logs.last?.task == "写初稿" && completed.todos[0].completedAt == start.addingTimeInterval(60), "completion keeps immutable history title and accurate task timestamp")
        let restored = completed.applying(.setTodoCompleted(writing.id, false), at: start.addingTimeInterval(120))
        expect(restored.status == .done && restored.logs == completed.logs && restored.todos[0].completedAt == nil, "reopening a task cannot restart elapsed focus")
        let otherCompleted = running.applying(.setTodoCompleted(reading.id, true), at: start.addingTimeInterval(60))
        expect(otherCompleted.deadline == running.deadline && otherCompleted.status == .running, "completing another task never stops focus")
        let paused = running.applying(.pause, at: start.addingTimeInterval(10))
        let pausedCompleted = paused.applying(.setTodoCompleted(writing.id, true), at: start.addingTimeInterval(60))
        expect(pausedCompleted.logs.last?.seconds == 10 && pausedCompleted.status == .done, "completion of paused focus logs active seconds only")
        let listRunning = all.applying(.start, at: start)
        expect(listRunning.applying(.setTodoCompleted(writing.id, true), at: start.addingTimeInterval(1)).status == .running, "legacy multi-task session is not abandoned by completing one member")
        let timedOut = running.applying(.settle, at: start.addingTimeInterval(1000))
        expect(!timedOut.todos[0].isCompleted && timedOut.logs.last?.todoIDs == [writing.id], "timer expiry does not complete the task")
        let trashed = single.applying(.trashTodo(writing.id), at: start)
        expect(trashed.todos.count == 3 && trashed.todos[0].deletedAt == start && trashed.focusTarget == .free, "trash retains task and removes dangling focus target")
        expect(trashed.todoList?.pending.map(\.id) == [reading.id], "trash hidden from pending list")
        expect(trashed.applying(.restoreTodo(writing.id), at: start).todos[0].isPending, "trash restores without requiring an undo receipt")
        let legacyLog = FocusLog(id: UUID(), task: "旧标题", startedAt: start, endedAt: start.addingTimeInterval(60), seconds: 60, completed: true)
        expect(try JSONDecoder().decode(FocusLog.self, from: JSONEncoder().encode(legacyLog)).todoIDs == nil, "legacy logs keep unknown task links nil")
        for value in [base, single, adjusted, all, edited, completed, restored, pausedCompleted, timedOut, trashed] {
            try value.validate()
            expect(try JSONDecoder().decode(FocusState.self, from: JSONEncoder().encode(value)) == value, "todo and timer state survive restart")
        }
        var invalid = base
        invalid.todoList?.items.append(writing)
        expectThrows("duplicate persisted task IDs rejected") { try invalid.validate() }
        invalid = base
        invalid.todoList?.items[0].estimatedMinutes = -1
        expectThrows("invalid persisted estimates rejected") { try invalid.validate() }
    }

    static func testTodoDueDates(at start: Date) throws {
        let undated = FocusTodo(title: "无日期")
        let later = FocusTodo(title: "明天", dueDate: start.addingTimeInterval(86_400), hasDueTime: true)
        let early = FocusTodo(title: "今天", dueDate: start, hasDueTime: true)
        let tied = FocusTodo(title: "同一截止", dueDate: start, hasDueTime: true)
        let base = [undated, later, early, tied].reduce(FocusState()) { $0.applying(.addTodo($1), at: start) }
        expect(base.todoList?.pending.map(\.id) == [early.id, tied.id, later.id, undated.id], "deadlines sort ascending with stable ties and undated items last")
        expect(base.deadline == nil && base.status == .idle, "task deadlines never arm the focus clock")
        var timed = early
        timed.plannedDate = start.addingTimeInterval(-86_400)
        timed.reminderDate = start.addingTimeInterval(-3600)
        let planned = base.applying(.upsertTodo(timed), at: start)
        expect(planned.todos.first(where: { $0.id == early.id })?.reminderDate == timed.reminderDate && planned.deadline == nil,
               "planned day, deadline and reminder remain independent")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        expect(nextDay.timeIntervalSince(day) == 23 * 3600, "DST fixture spans a 23-hour day")
        var dateOnly = FocusTodo(title: "日期截止", dueDate: day)
        expect(!dateOnly.isOverdue(at: nextDay.addingTimeInterval(-1), calendar: calendar), "date-only deadline remains valid through its calendar day")
        expect(dateOnly.isOverdue(at: nextDay, calendar: calendar), "date-only deadline becomes overdue next calendar day")
        dateOnly.hasDueTime = true
        expect(dateOnly.isOverdue(at: day, calendar: calendar), "timed deadline is due at its exact instant")
        dateOnly.isCompleted = true
        expect(!dateOnly.isOverdue(at: nextDay, calendar: calendar), "completed task is not overdue")
        let raw = try JSONSerialization.data(withJSONObject: ["id": early.id.uuidString, "title": early.title,
                                                               "minutes": 30, "isCompleted": false, "dueDate": 1.0])
        let old = try JSONDecoder().decode(FocusTodo.self, from: raw)
        expect(old.estimatedMinutes == 30 && old.hasDueTime && old.createdAt == nil && old.completedAt == nil,
               "legacy minutes and precise due date migrate without invented metadata")
        for date in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan), Date.distantFuture.addingTimeInterval(60)] {
            expect(!FocusTodo(title: "无效日期", dueDate: date).isValid, "invalid dates cannot enter storage")
            expect(!FocusTodo(title: "无效提醒", reminderDate: date).isValid, "invalid reminder dates cannot enter storage")
        }
        var invalid = timed
        invalid.isCompleted = false
        invalid.completedAt = start
        expect(!invalid.isValid, "pending task cannot carry stale completion metadata")
    }

    static func testCompletionUndo(at start: Date) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-undo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FocusStore(directory: directory)
        let second = FocusStore(directory: directory)
        let writing = FocusTodo(title: "写初稿", estimatedMinutes: 240, createdAt: start)
        let reading = FocusTodo(title: "读论文", createdAt: start)
        let additions = try first.performTodoActions([.upsertTodo(writing), .upsertTodo(reading)], at: start)
        expect(additions.undo?.itemIDs.count == 2 && additions.undo?.collectionIDs.isEmpty == true, "batch creates one receipt containing only changed tasks")
        let undoneAdd = try first.undoTodo(additions.undo!, at: start)
        expect(undoneAdd.state.todos.isEmpty && undoneAdd.undo != nil, "batch add undone atomically")
        let redoneAdd = try first.undoTodo(undoneAdd.undo!, at: start)
        expect(Set(redoneAdd.state.todos.map(\.id)) == [writing.id, reading.id], "inverse receipt redoes the batch")
        try first.update(.selectTarget(.todo(writing.id)), at: start)
        try first.update(.start, at: start)
        let completion = try first.performTodoAction(.setTodoCompleted(writing.id, true), at: start.addingTimeInterval(20))
        expect(completion.undo?.itemIDs == [writing.id] && completion.undo!.estimatedByteCount < 4_096,
               "completion receipt retains one bounded task payload")
        let completedLog = completion.state.logs
        var renamed = reading
        renamed.title = "新的阅读标题"
        try second.performTodoAction(.upsertTodo(renamed), at: start.addingTimeInterval(25))
        let restored = try first.undoTodo(completion.undo!, at: start.addingTimeInterval(30))
        expect(!restored.state.todos.first(where: { $0.id == writing.id })!.isCompleted && restored.state.logs == completedLog
               && restored.state.status == .done, "undo restores task, never elapsed time or a stopped session")
        expect(restored.state.todos.first(where: { $0.id == reading.id })?.title == renamed.title, "undo retains unrelated external edits")
        expectThrows("same receipt cannot silently apply twice") { _ = try first.undoTodo(completion.undo!, at: start) }
        let redone = try first.undoTodo(restored.undo!, at: start.addingTimeInterval(35))
        expect(redone.state.todos.first(where: { $0.id == writing.id })!.isCompleted && redone.state.logs == completedLog,
               "redo completion cannot duplicate actual focus logs")
        var externalEdit = redone.state.todos.first { $0.id == writing.id }!
        externalEdit.notes = "外部编辑"
        try second.performTodoAction(.upsertTodo(externalEdit), at: start)
        expectThrows("undo conflicts instead of overwriting an affected task's later edit") { _ = try first.undoTodo(redone.undo!, at: start) }
        expect(try first.snapshot(at: start).todos.first(where: { $0.id == writing.id })?.notes == "外部编辑", "conflicting undo preserves latest file")
        let trashed = try first.performTodoAction(.trashTodo(reading.id), at: start)
        expect(trashed.state.todos.first(where: { $0.id == reading.id })?.deletedAt == start, "trash timestamp persisted")
        let cold = FocusStore(directory: directory)
        let restoredTrash = try cold.performTodoAction(.restoreTodo(reading.id), at: start)
        expect(restoredTrash.state.todos.first(where: { $0.id == reading.id })?.isPending == true, "trash can be restored after relaunch")
        let beforeInvalid = try Data(contentsOf: directory.appendingPathComponent("focus-state.json"))
        expectThrows("invalid second action aborts whole batch") {
            _ = try first.performTodoActions([.upsertTodo(FocusTodo(title: "应取消")), .upsertTodo(FocusTodo(title: ""))], at: start)
        }
        expect(try Data(contentsOf: directory.appendingPathComponent("focus-state.json")) == beforeInvalid, "failed batch leaves original bytes unchanged")
        expectThrows("timer actions cannot enter task undo batches") { _ = try first.performTodoActions([.start], at: start) }
        let pending = try first.performTodoAction(.setTodoCompleted(writing.id, false), at: start)
        let legacy = try first.completeTodo(writing.id, at: start)
        let legacyRestore = try first.update(.undoTodoCompletion(legacy.undo!), at: start)
        expect(legacyRestore.todos == pending.state.todos && legacyRestore.logs == pending.state.logs,
               "legacy completion receipt preserves task data and logs without retaining the list")
        expect(try second.completeTodo(writing.id, at: start).undo != nil, "new completion has a receipt")
        expect(try second.completeTodo(writing.id, at: start).undo == nil, "stale repeated completion has no misleading receipt")
        for index in 0..<25 {
            let preciseDate = start.addingTimeInterval(Double(index) * 0.000_013_7)
            let change = try first.performTodoAction(.upsertTodo(FocusTodo(title: "精确日期 \(index)",
                plannedDate: preciseDate, dueDate: preciseDate, hasDueTime: true,
                reminderDate: preciseDate, createdAt: preciseDate)), at: preciseDate)
            let undone = try second.undoTodo(change.undo!, at: preciseDate)
            expect(!undone.state.todos.contains(where: { $0.id == change.undo!.itemIDs[0] }),
                   "sub-millisecond JSON round trip cannot cause a false undo conflict")
        }
        let atomic = try first.performActions([.selectTarget(.todo(reading.id)), .selectDuration(300), .start], at: start)
        expect(atomic.status == .running && atomic.sessionTodoIDs == [reading.id] && atomic.duration == 300, "compound timer command commits its chosen task and duration")
        let switched = try first.performActions([.finish, .selectTarget(.free), .selectDuration(600), .start], at: start.addingTimeInterval(10))
        expect(switched.status == .running && switched.duration == 600 && switched.focusTarget == .free
               && switched.logs.last?.todoIDs == [reading.id], "atomic task switch preserves completed real elapsed time")
        expectThrows("stale compound target cannot silently stop current focus") {
            _ = try first.performActions([.finish, .selectTarget(.todo(UUID())), .start], at: start.addingTimeInterval(15))
        }
        expect(try first.snapshot(at: start.addingTimeInterval(15)).sessionID == switched.sessionID,
               "failed compound switch leaves current session intact")
    }

    static func testMigration(at start: Date) throws {
        for version in 1...3 {
            for status in [FocusStatus.idle, .running, .paused, .done] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-v\(version)-\(UUID())")
                defer { try? FileManager.default.removeItem(at: directory) }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let taskID = UUID()
                var legacy = FocusState(duration: 1500, task: "旧任务")
                if version >= 2 {
                    legacy.todoList = FocusTodoList()
                    legacy.todoList?.items = [FocusTodo(id: taskID, title: "旧清单", minutes: 180,
                                                       dueDate: version == 3 ? start.addingTimeInterval(172_800) : nil)]
                    legacy.todoList?.target = .todo(taskID)
                    legacy.duration = 10_800
                    legacy.remaining = 10_800
                }
                if status != .idle { legacy = legacy.applying(.start, at: start) }
                if status == .paused { legacy = legacy.applying(.pause, at: start.addingTimeInterval(20)) }
                if status == .done { legacy = legacy.applying(.finish, at: start.addingTimeInterval(20)) }
                legacy.version = version
                // Produce actual old key names, without v4 metadata/log associations.
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
                var json = try JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
                if var list = json["todoList"] as? [String: Any], var items = list["items"] as? [[String: Any]] {
                    items = items.map { item in
                        var old = item
                        old["minutes"] = old.removeValue(forKey: "estimatedMinutes")
                        for key in ["notes", "plannedDate", "hasDueTime", "reminderDate", "listID", "createdAt", "completedAt", "deletedAt", "sortOrder"] { old.removeValue(forKey: key) }
                        return old
                    }
                    list["items"] = items; list.removeValue(forKey: "collections"); json["todoList"] = list
                }
                if var logs = json["logs"] as? [[String: Any]] { for index in logs.indices { logs[index].removeValue(forKey: "todoIDs") }; json["logs"] = logs }
                let bytes = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                let file = directory.appendingPathComponent("focus-state.json")
                try bytes.write(to: file)
                let migrated = try FocusStore(directory: directory).snapshot(at: start.addingTimeInterval(30))
                expect(migrated.version == FocusState.currentVersion && migrated.status == status, "v\(version) \(status) migrates to current schema")
                expect(migrated.sessionID == legacy.sessionID && migrated.startedAt == legacy.startedAt
                       && migrated.sessionTodoIDs == legacy.sessionTodoIDs && migrated.sessionTask == legacy.sessionTask,
                       "migration preserves identity and session membership")
                if status == .running || status == .paused {
                    expect(migrated.duration == legacy.duration && migrated.remaining == legacy.remaining && migrated.deadline == legacy.deadline,
                           "legacy long active sessions preserve duration and deadline")
                }
                if status == .idle && version >= 2 { expect(migrated.duration == 1500, "idle migrated tasks use independent focus block") }
                if version >= 2 {
                    expect(migrated.todos[0].id == taskID && migrated.todos[0].estimatedMinutes == 180
                           && migrated.todos[0].createdAt == nil && migrated.todos[0].completedAt == nil,
                           "migration keeps task identity/estimate and unknown dates")
                }
                if version == 3 { expect(migrated.todos[0].dueDate == legacy.todos[0].dueDate && migrated.todos[0].hasDueTime, "precise legacy deadline preserved") }
                expect(migrated.logs.count == legacy.logs.count && migrated.logs.allSatisfy { $0.todoIDs == nil }, "legacy history retains unknown task association")
                let backupDirectory = directory.appendingPathComponent("Backups")
                let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
                expect(try backups.count == 1 && Data(contentsOf: backups[0]) == bytes, "migration retains exact pre-upgrade backup")
                let saved = try Data(contentsOf: file)
                _ = try FocusStore(directory: directory).snapshot(at: start.addingTimeInterval(31))
                expect(try Data(contentsOf: file) == saved, "unchanged subsequent snapshot does not rewrite data")
                expect(try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil).count == 1, "migration backup is created only once")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-invalid-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("focus-state.json")
        let bytes = Data("{\"version\":3,\"todoList\":{\"items\":[{\"title\":\"broken\"}]}}".utf8)
        try bytes.write(to: file)
        expectThrows("invalid legacy migration must fail without resetting") { _ = try FocusStore(directory: directory).snapshot(at: start) }
        expect(try Data(contentsOf: file) == bytes, "invalid migration preserves original bytes")
        expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Backups").path), "invalid migration does not falsely mark a backup upgrade")
        var validLegacy = FocusState(); validLegacy.version = 1
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let legacyBytes = try encoder.encode(validLegacy)
        try legacyBytes.write(to: file)
        try Data("blocked backup directory".utf8).write(to: directory.appendingPathComponent("Backups"))
        expectThrows("migration cannot proceed without a successful backup") { _ = try FocusStore(directory: directory).snapshot(at: start) }
        expect(try Data(contentsOf: file) == legacyBytes, "backup failure leaves original legacy file unchanged")
        var future = validLegacy; future.version = FocusState.currentVersion + 1
        let futureBytes = try encoder.encode(future)
        try futureBytes.write(to: file)
        expectThrows("future schema rejected without downgrade") { _ = try FocusStore(directory: directory).snapshot(at: start) }
        expect(try Data(contentsOf: file) == futureBytes, "future schema bytes untouched")
    }

    static func testCapacity(at start: Date) throws {
        var full = FocusState()
        full.todoList = FocusTodoList()
        full.todoList?.items = (0..<FocusTodo.maximumCount).map { FocusTodo(title: "事项 \($0)", sortOrder: $0) }
        try full.validate()
        expect(full.applying(.upsertTodo(FocusTodo(title: "超额")), at: start) == full, "active capacity rejects without dropping items")
        let completedID = full.todos[0].id
        var archived = full.applying(.setTodoCompleted(completedID, true), at: start)
        let newTask = FocusTodo(title: "完成后可新增")
        archived = archived.applying(.upsertTodo(newTask), at: start)
        expect(archived.todos.count == FocusTodo.maximumCount + 1 && archived.todoList?.pending.count == FocusTodo.maximumCount,
               "completed history consumes no active slot")
        expect(archived.applying(.setTodoCompleted(completedID, false), at: start) == archived, "restore respects active capacity without deleting completed task")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-capacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("focus-state.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(archived).write(to: file)
        let store = FocusStore(directory: directory)
        expectThrows("capacity failure is reported by transactional API") { _ = try store.performTodoAction(.upsertTodo(FocusTodo(title: "超额")), at: start) }
        expectThrows("reopening at active limit is reported") { _ = try store.performTodoAction(.setTodoCompleted(completedID, false), at: start) }
        let trashed = try store.performTodoAction(.trashTodo(newTask.id), at: start)
        expect(trashed.state.todoList?.pending.count == FocusTodo.maximumCount - 1, "trash frees active slot")
        let fill = try store.performTodoAction(.upsertTodo(FocusTodo(title: "替代")), at: start)
        expectThrows("restoring pending trash at active limit is reported") { _ = try store.performTodoAction(.restoreTodo(newTask.id), at: start) }
        expectThrows("undo cannot exceed active capacity after unrelated additions") { _ = try store.undoTodo(trashed.undo!, at: start) }
        expect(try store.snapshot(at: start).todos == fill.state.todos, "failed restore and undo preserve every task")
        var retained = FocusState(); retained.todoList = FocusTodoList()
        retained.todoList?.items = (0..<FocusTodo.maximumStoredCount).map { FocusTodo(title: "历史 \($0)", isCompleted: true, sortOrder: $0) }
        try retained.validate()
        expect(retained.applying(.upsertTodo(FocusTodo(title: "超额历史")), at: start) == retained, "total storage limit never silently trims history")
        var oversized = FocusState(); oversized.todoList = FocusTodoList()
        oversized.todoList?.items = (0..<2_000).map { FocusTodo(title: "长备注 \($0)", notes: String(repeating: "x", count: 10_000), isCompleted: true) }
        try encoder.encode(FocusState()).write(to: file)
        // Valid individual records can still exceed the serialized file budget.
        expectThrows("encoded file budget rejects a large batch atomically") {
            _ = try store.performTodoActions(oversized.todos.map(FocusAction.upsertTodo), at: start)
        }
        expect(try store.snapshot(at: start).todos.isEmpty, "oversized write keeps previous state intact")
    }

    static func testCollections(at start: Date) throws {
        let work = TodoCollection(title: " 工作 ")
        let a = FocusTodo(title: "A", listID: work.id)
        let b = FocusTodo(title: "B")
        let c = FocusTodo(title: "C", listID: work.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-collections-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory)
        let base = try store.performTodoActions([.upsertCollection(work), .upsertTodo(a), .upsertTodo(b), .upsertTodo(c)], at: start)
        expect(base.state.todoList?.collections.first?.title == "工作", "collection name normalized")
        let reordered = try store.performTodoAction(.reorderTodos([c.id, a.id]), at: start)
        let order = reordered.state.todos.sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
        expect(order == [c.id, b.id, a.id], "filtered reorder preserves slots occupied by hidden tasks")
        let undoneOrder = try store.undoTodo(reordered.undo!, at: start)
        expect(undoneOrder.state.todos.sorted { $0.sortOrder < $1.sortOrder }.map(\.id) == [a.id, b.id, c.id], "manual order has one reversible transaction")
        let deleted = try store.performTodoAction(.deleteCollection(work.id), at: start)
        expect(deleted.state.todoList?.collections.isEmpty == true && deleted.state.todos.allSatisfy { $0.listID == nil }, "deleting collection moves its tasks to inbox")
        let restored = try store.undoTodo(deleted.undo!, at: start)
        expect(restored.state.todoList?.collections == [work] && restored.state.todos.filter { $0.listID == work.id }.count == 2,
               "undo restores collection and task memberships together")
        let another = TodoCollection(title: "另一个")
        let added = try store.performTodoAction(.upsertCollection(another), at: start)
        try store.performTodoAction(.upsertTodo(FocusTodo(title: "后来的事项", listID: another.id)), at: start)
        expectThrows("undo collection creation cannot orphan a subsequently added task") { _ = try store.undoTodo(added.undo!, at: start) }
        expectThrows("unknown collection membership rejected") { _ = try store.performTodoAction(.upsertTodo(FocusTodo(title: "无效", listID: UUID())), at: start) }
        expectThrows("invalid reorder cannot drop items") { _ = try store.performTodoAction(.reorderTodos([a.id, a.id]), at: start) }
        var unknown = FocusState(); unknown.todoList = FocusTodoList(); unknown.todoList?.items = [FocusTodo(title: "无效引用", listID: UUID())]
        expectThrows("invalid persisted collection references rejected") { try unknown.validate() }
    }

    static func testStepsAndRecurrence(at start: Date) throws {
        let steps = [TodoStep(title: "准备", isCompleted: true), TodoStep(title: "检查")]
        let rule = TodoRepeatRule(frequency: .daily, anchorDate: start, timeZoneIdentifier: "Asia/Shanghai")
        let fixedID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let task = FocusTodo(id: fixedID, title: "每日整理", estimatedMinutes: 30, notes: "重复保留备注",
                             plannedDate: start, dueDate: start.addingTimeInterval(86_400), hasDueTime: false,
                             reminderDate: start.addingTimeInterval(1800), createdAt: start,
                             steps: steps, repeatRule: rule, repeatScheduledDate: start)
        expect(task.isValid && task.steps.map(\.id) == steps.map(\.id), "steps preserve stable IDs within a task")
        expect(try JSONDecoder().decode(FocusTodo.self, from: JSONEncoder().encode(task)) == task, "steps and repeat metadata round trip")
        expect(task.generatedNextOccurrenceID == UUID(uuidString: "F459FD2D-55C6-8F67-8F5E-A11C86DAA002"), "recurrence child identity matches the stable on-disk namespace contract")
        var invalid = task; invalid.steps.append(steps[0])
        expect(!invalid.isValid, "duplicate step IDs rejected")
        invalid = task; invalid.steps = [TodoStep(title: " ")]
        expect(!invalid.isValid, "empty saved step rejected")
        invalid = task; invalid.steps = [TodoStep(title: String(repeating: "x", count: 181))]
        expect(!invalid.isValid, "long saved step rejected")
        invalid = task; invalid.steps = (0...FocusTodo.maximumStepCount).map { TodoStep(title: "步骤 \($0)") }
        expect(!invalid.isValid, "step count bounded to one hundred")
        invalid = task; invalid.repeatRule?.timeZoneIdentifier = "Not/A_TimeZone"
        expect(!invalid.isValid, "unknown recurrence time zone rejected")
        invalid = task; invalid.nextOccurrenceID = task.id
        expect(!invalid.isValid, "self-recurring identity rejected")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-repeat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory)
        let other = FocusStore(directory: directory)
        let added = try store.performTodoAction(.upsertTodo(task), at: start).state
        expect(added.todos.count == 1, "creating a repeat rule does not generate another task")
        var deferred = added.todos[0]; deferred.plannedDate = start.addingTimeInterval(5 * 86_400)
        try store.performTodoAction(.replaceTodo(expected: added.todos[0], replacement: deferred), at: start)
        expect(try store.snapshot(at: start).todos.count == 1, "deferring a repeating task never generates a backlog")
        let running = try store.performActions([.selectTarget(.todo(task.id)), .start], at: start)
        let completion = try store.performTodoAction(.setTodoCompleted(task.id, true), at: start.addingTimeInterval(30))
        let source = completion.state.todos.first { $0.id == task.id }!
        let next = completion.state.todos.first { $0.id == task.generatedNextOccurrenceID }!
        expect(completion.state.todos.count == 2 && source.nextOccurrenceID == next.id && next.isPending,
               "completion creates exactly one linked pending occurrence")
        expect(completion.state.logs.last?.seconds == 30 && completion.state.logs.last?.todoIDs == [task.id]
               && completion.state.status == .done, "recurrence completion ends focus and logs once")
        expect(next.title == task.title && next.notes == task.notes && next.estimatedMinutes == 30 && next.repeatRule == rule,
               "next occurrence retains reusable task metadata")
        expect(next.steps.allSatisfy { !$0.isCompleted } && next.steps.map(\.title) == steps.map(\.title)
               && Set(next.steps.map(\.id)).isDisjoint(with: Set(steps.map(\.id))), "next occurrence resets steps with new stable identities")
        expect(next.nextOccurrenceID == nil && next.completedAt == nil && next.deletedAt == nil && next.createdAt == start.addingTimeInterval(30),
               "new occurrence does not inherit completion/deletion or generation marker")
        expect(next.plannedDate == next.repeatScheduledDate && next.plannedDate! > start,
               "new occurrence has one future planned day")
        expect(completion.undo?.itemIDs.count == 2, "source and generated occurrence share one undo receipt")
        let duplicate = try other.performTodoAction(.setTodoCompleted(task.id, true), at: start.addingTimeInterval(31))
        expect(duplicate.state.todos.count == 2 && duplicate.undo == nil, "repeated completion cannot create another occurrence")
        let undone = try store.undoTodo(completion.undo!, at: start.addingTimeInterval(32))
        expect(undone.state.todos.count == 1 && !undone.state.todos[0].isCompleted && undone.state.todos[0].nextOccurrenceID == nil,
               "undo removes generated occurrence and restores source together")
        expect(undone.state.logs == completion.state.logs && undone.state.status == .done && undone.state.sessionID == running.sessionID,
               "repeat undo never restarts focus or removes real work")
        let redone = try store.undoTodo(undone.undo!, at: start.addingTimeInterval(7 * 86_400))
        expect(redone.state.todos.first { $0.id == next.id } == next, "redo retains original generated date and IDs, never recomputes next week")
        var childEdit = next; childEdit.notes = "保护下一项的用户修改"
        try store.performTodoAction(.replaceTodo(expected: next, replacement: childEdit), at: start)
        expectThrows("an edited child alone blocks undoing generation") { _ = try store.undoTodo(redone.undo!, at: start) }
        expect(try store.snapshot(at: start).todos.first { $0.id == source.id } == source,
               "failed child-conflict undo does not partially reopen source")
        try store.performTodoAction(.replaceTodo(expected: childEdit, replacement: next), at: start)
        try store.performTodoAction(.setTodoCompleted(task.id, false), at: start.addingTimeInterval(7 * 86_400))
        let recompleted = try store.performTodoAction(.setTodoCompleted(task.id, true), at: start.addingTimeInterval(8 * 86_400))
        expect(recompleted.state.todos.count == 2 && recompleted.state.todos.first { $0.id == next.id } == next,
               "explicit reopen and recomplete leave the existing next occurrence untouched")
        var editedNext = next; editedNext.notes = "用户编辑了下一项"
        try store.performTodoAction(.replaceTodo(expected: next, replacement: editedNext), at: start)
        expectThrows("undo generation cannot remove an edited next occurrence") { _ = try store.undoTodo(completion.undo!, at: start) }
        expect(try store.snapshot(at: start).todos.first { $0.id == next.id }?.notes == editedNext.notes, "failed recurrence undo preserves next-occurrence edits")
        // Old archives can replace the source generation marker. Stable child
        // identity deduplicates without overwriting an already edited child.
        try store.mergeTodos([task], collections: [], at: start)
        let importedRecompletion = try store.performTodoAction(.setTodoCompleted(task.id, true), at: start)
        expect(importedRecompletion.state.todos.count == 2 && importedRecompletion.state.todos.first { $0.id == next.id }?.notes == editedNext.notes,
               "restoring an old source archive cannot duplicate or overwrite its next occurrence")
        let nextCompleted = try store.performTodoAction(.setTodoCompleted(next.id, true), at: next.plannedDate!.addingTimeInterval(12 * 3600))
        expect(nextCompleted.state.todos.count == 3 && nextCompleted.state.todos.contains { $0.id == next.generatedNextOccurrenceID },
               "each completed occurrence can generate one following occurrence")
        try store.performTodoActions([.trashTodo(next.id), .purgeTodos([next.id])], at: start)
        try store.performTodoAction(.setTodoCompleted(task.id, false), at: start)
        expect(try store.performTodoAction(.setTodoCompleted(task.id, true), at: start).state.todos.count == 2,
               "recompleting source never recreates an explicitly purged next occurrence while marker remains")
        let compatibilityTask = FocusTodo(title: "兼容重复", repeatRule: rule)
        try store.performTodoAction(.upsertTodo(compatibilityTask), at: start)
        let compatibility = try store.completeTodo(compatibilityTask.id, at: start)
        let compatibilityUndone = try store.update(.undoTodoCompletion(compatibility.undo!), at: start)
        expect(compatibilityUndone.todos.contains { $0.id == compatibilityTask.id && !$0.isCompleted }
               && !compatibilityUndone.todos.contains { $0.id == compatibilityTask.generatedNextOccurrenceID }, "legacy completion undo also reverses occurrence generation")
    }

    static func testRepeatCalendar() throws {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, calendar: Calendar) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let january = date(2026, 1, 31, calendar: utc)
        let monthly = TodoRepeatRule(frequency: .monthly, anchorDate: january, timeZoneIdentifier: "UTC")
        let february = monthly.nextDate(after: january, completedAt: january)!
        expect(february == date(2026, 2, 28, calendar: utc), "monthly January 31 clamps to February's last day")
        expect(monthly.nextDate(after: february, completedAt: february) == date(2026, 3, 31, calendar: utc), "monthly anchor returns to March 31 rather than drifting to 28")
        expect(monthly.nextDate(after: january, completedAt: date(2026, 1, 1, calendar: utc)) == february,
               "early completion advances after the actual scheduled occurrence")
        expect(monthly.nextDate(after: january, completedAt: date(2026, 10, 8, calendar: utc)) == date(2026, 10, 31, calendar: utc),
               "long overdue monthly task skips missed months without backfilling")
        let leapAnchor = date(2028, 1, 31, calendar: utc)
        let leap = TodoRepeatRule(frequency: .monthly, anchorDate: leapAnchor, timeZoneIdentifier: "UTC")
        expect(leap.nextDate(after: leapAnchor, completedAt: leapAnchor) == date(2028, 2, 29, calendar: utc), "leap-year month end preserved")
        let monday = date(2026, 1, 5, calendar: utc)
        let weekly = TodoRepeatRule(frequency: .weekly, anchorDate: monday, timeZoneIdentifier: "UTC")
        expect(weekly.nextDate(after: monday, completedAt: monday) == date(2026, 1, 12, calendar: utc), "weekly advances one anchored weekday")
        expect(weekly.nextDate(after: monday, completedAt: date(2026, 1, 21, calendar: utc)) == date(2026, 1, 26, calendar: utc), "overdue weekly picks next anchored weekday")
        var pacific = Calendar(identifier: .gregorian); pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let march7 = date(2026, 3, 7, calendar: pacific)
        let daily = TodoRepeatRule(frequency: .daily, anchorDate: march7, timeZoneIdentifier: pacific.timeZone.identifier)
        let march8 = daily.nextDate(after: march7, completedAt: march7)!
        let march9 = daily.nextDate(after: march8, completedAt: march8)!
        expect(march9.timeIntervalSince(march8) == 23 * 3600 && pacific.component(.hour, from: march9) == 0,
               "daily recurrence crosses spring DST by calendar day")
        let november1 = date(2026, 11, 1, calendar: pacific)
        let november2 = daily.nextDate(after: november1, completedAt: november1)!
        expect(november2.timeIntervalSince(november1) == 25 * 3600, "daily recurrence crosses fall DST by calendar day")
        let missingClock = date(2026, 3, 7, 2, 30, calendar: pacific)
        let timed = FocusTodo(title: "跨 DST", plannedDate: march7, dueDate: missingClock, hasDueTime: true,
                              reminderDate: missingClock, repeatRule: daily, repeatScheduledDate: march7)
        let shifted = timed.nextOccurrence(completedAt: date(2026, 3, 7, 12, calendar: pacific))!
        expect(pacific.component(.hour, from: shifted.dueDate!) == 3 && pacific.component(.minute, from: shifted.dueDate!) == 30,
               "missing spring local time keeps minutes at the next valid hour")
        expect(shifted.reminderDate == shifted.dueDate, "deadline and reminder shift consistently across spring DST")
        let october31 = date(2026, 10, 31, calendar: pacific)
        let repeatedClock = date(2026, 10, 31, 1, 30, calendar: pacific)
        let autumn = FocusTodo(title: "秋季 DST", plannedDate: october31, dueDate: repeatedClock, hasDueTime: true,
                               reminderDate: repeatedClock, repeatRule: daily, repeatScheduledDate: october31)
        let repeated = autumn.nextOccurrence(completedAt: october31)!
        expect(pacific.timeZone.secondsFromGMT(for: repeated.reminderDate!) == -7 * 3600,
               "fall DST reminder uses first matching local time once")
        let offset = FocusTodo(title: "月末偏移", plannedDate: january, dueDate: date(2026, 2, 2, calendar: utc),
                              repeatRule: monthly, repeatScheduledDate: january).nextOccurrence(completedAt: january)!
        expect(offset.dueDate == date(2026, 3, 2, calendar: utc) && !offset.hasDueTime, "date-only deadline retains its calendar-day offset")
        expect(daily.nextDate(after: .distantFuture, completedAt: .distantFuture) == nil, "unrepresentable future occurrence fails safely")
    }

    static func testRepeatCapacity(at start: Date) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-repeat-capacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("focus-state.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let task = FocusTodo(title: "重复容量", repeatRule: TodoRepeatRule(frequency: .daily, anchorDate: start, timeZoneIdentifier: "UTC"))
        var full = FocusState(); full.todoList = FocusTodoList()
        full.todoList?.items = [task] + (1..<FocusTodo.maximumStoredCount).map { FocusTodo(title: "历史 \($0)", isCompleted: true) }
        full = full.applying(.selectTarget(.todo(task.id)), at: start).applying(.start, at: start)
        try full.validate()
        let before = try encoder.encode(full); try before.write(to: file)
        let store = FocusStore(directory: directory)
        expectThrows("repeat completion reports total capacity failure") { _ = try store.performTodoAction(.setTodoCompleted(task.id, true), at: start.addingTimeInterval(10)) }
        expect(try Data(contentsOf: file) == before, "failed occurrence creation atomically preserves source, timer and logs")
        expect(full.applying(.setTodoCompleted(task.id, true), at: start.addingTimeInterval(10)) == full, "pure transition also rejects capacity before ending focus")
        var activeFull = FocusState(); activeFull.todoList = FocusTodoList()
        activeFull.todoList?.items = [task] + (1..<FocusTodo.maximumCount).map { FocusTodo(title: "待办 \($0)") }
        try encoder.encode(activeFull).write(to: file)
        let replaced = try store.performTodoAction(.setTodoCompleted(task.id, true), at: start)
        expect(replaced.state.todos.filter(\.isPending).count == FocusTodo.maximumCount && replaced.state.todos.count == FocusTodo.maximumCount + 1,
               "recurrence replaces one active slot at the active-task limit")
        var impossible = task
        impossible.repeatRule?.anchorDate = .distantFuture
        impossible.repeatScheduledDate = .distantFuture
        var base = FocusState(); base.todoList = FocusTodoList(); base.todoList?.items = [impossible]
        try encoder.encode(base).write(to: file)
        expectThrows("invalid next date is reported without completing source") { _ = try store.performTodoAction(.setTodoCompleted(task.id, true), at: start) }
        expect(try store.snapshot(at: start).todos[0].isPending, "unrepresentable recurrence leaves task pending")
    }

    static func testVersion4Migration(at start: Date) throws {
        let collection = TodoCollection(title: "迁移清单")
        let first = FocusTodo(title: "保持元数据", notes: "备注", plannedDate: start, dueDate: start.addingTimeInterval(3600),
                              hasDueTime: true, reminderDate: start.addingTimeInterval(1800), listID: collection.id,
                              createdAt: start.addingTimeInterval(-86_400), sortOrder: 42)
        let second = FocusTodo(title: "未知完成时间", isCompleted: true, deletedAt: start, sortOrder: 7)
        for status in [FocusStatus.idle, .running, .paused, .done] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-v4-v5-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var legacy = FocusState(); legacy.todoList = FocusTodoList()
            legacy.todoList?.items = [first, second]; legacy.todoList?.collections = [collection]
            legacy = legacy.applying(.selectTarget(.todo(first.id)), at: start).applying(.selectDuration(420), at: start)
            if status != .idle { legacy = legacy.applying(.start, at: start) }
            if status == .paused { legacy = legacy.applying(.pause, at: start.addingTimeInterval(10)) }
            if status == .done { legacy = legacy.applying(.finish, at: start.addingTimeInterval(10)) }
            legacy.version = 4
            try legacy.validate()
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            let bytes = try encoder.encode(legacy)
            let file = directory.appendingPathComponent("focus-state.json"); try bytes.write(to: file)
            var expected = legacy; expected.version = 5
            let migrated = try FocusStore(directory: directory).snapshot(at: start.addingTimeInterval(20))
            expect(migrated == expected, "v4 migration changes only schema, preserving manual order, durations, metadata and logs")
            expect(migrated.todos.allSatisfy { $0.steps.isEmpty && $0.repeatRule == nil && $0.nextOccurrenceID == nil }, "legacy tasks gain empty step/repeat defaults without invented values")
            let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
            expect(try backups.count == 1 && backups[0].lastPathComponent.hasPrefix("pre-v5-v4-") && Data(contentsOf: backups[0]) == bytes,
                   "v4 upgrade keeps byte-exact versioned backup")
        }
        var wrongVersion = FocusState().applying(.upsertTodo(FocusTodo(title: "新步骤", steps: [TodoStep(title: "步骤")])), at: start)
        wrongVersion.version = 4
        expectThrows("v5 fields cannot masquerade as v4 and be dropped by old apps") { try wrongVersion.validate() }
    }

    static func testFocusSummaries(at start: Date) throws {
        let first = UUID(), second = UUID()
        func log(_ ids: [UUID]?, seconds: TimeInterval, completed: Bool, offset: TimeInterval) -> FocusLog {
            FocusLog(id: UUID(), task: "记录", startedAt: start, endedAt: start.addingTimeInterval(offset), seconds: seconds,
                     completed: completed, todoIDs: ids)
        }
        let one = log([first], seconds: 60, completed: true, offset: 60)
        let two = log([first], seconds: 30, completed: false, offset: 120)
        var state = FocusState()
        state.logs = [one, two, log([second], seconds: 45, completed: true, offset: 45),
                      log([first, second], seconds: 1000, completed: true, offset: 1000),
                      log(nil, seconds: 500, completed: true, offset: 500), log([], seconds: 100, completed: true, offset: 100)]
        let summaries = state.todoFocusSummaries
        expect(summaries[first]?.totalSeconds == 90 && summaries[first]?.sessionCount == 2
               && summaries[first]?.completedSessionCount == 1 && summaries[first]?.lastFocusedAt == start.addingTimeInterval(120),
               "single-task summary counts saved work once with separate natural completions")
        expect(summaries[second]?.totalSeconds == 45 && summaries.count == 2, "legacy multi-task and free sessions are never duplicated or divided into task totals")
        state.logs.append(one)
        expect(state.todoFocusSummaries[first]?.totalSeconds == 90, "defensive summary never counts a duplicated log ID twice")
    }

    static func testConcurrentRepeatCompletion(at start: Date) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moro-repeat-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory)
        let task = FocusTodo(title: "并发完成", repeatRule: TodoRepeatRule(frequency: .daily, anchorDate: start, timeZoneIdentifier: "UTC"))
        try store.performTodoAction(.upsertTodo(task), at: start)
        try store.performActions([.selectTarget(.todo(task.id)), .start], at: start)
        var workers: [Process] = []
        for _ in 0..<4 {
            let worker = Process()
            worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            worker.arguments = ["--complete-worker", directory.path, task.id.uuidString, String(start.addingTimeInterval(30).timeIntervalSince1970)]
            try worker.run(); workers.append(worker)
        }
        for worker in workers { worker.waitUntilExit(); expect(worker.terminationStatus == 0, "recurrence worker finished") }
        let result = try store.snapshot(at: start.addingTimeInterval(30))
        expect(result.todos.count == 2 && result.todos.filter(\.isPending).count == 1
               && result.todos.first { $0.id == task.id }?.nextOccurrenceID == task.generatedNextOccurrenceID,
               "twenty concurrent completion attempts create exactly one occurrence")
        expect(result.logs.count == 1 && result.logs[0].seconds == 30 && result.logs[0].todoIDs == [task.id],
               "concurrent repeating completion stops focus exactly once")
    }

    static func expectThrows(_ message: String, _ work: () throws -> Void) {
        do { try work(); fatalError("FAIL: \(message)") }
        catch { expect(true, message) }
    }
}
