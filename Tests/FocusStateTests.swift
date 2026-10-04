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
        try testCompletionUndo(at: start)
        print("PASS: \(count) checks; includes 6 processes / 246 shared-store transactions.")
    }

    static func testTodos(at start: Date) throws {
        let writing = FocusTodo(title: "  写初稿  ", minutes: 40)
        let reading = FocusTodo(title: "读论文", minutes: 20)
        let finished = FocusTodo(title: "整理桌面", minutes: 5, isCompleted: true)
        let base = FocusState(duration: 900).applying(.addTodo(writing)).applying(.addTodo(reading)).applying(.addTodo(finished))
        expect(base.version == 2 && base.todos.count == 3 && base.todos[0].title == "写初稿", "todo creation normalizes and versions data")
        expect(base.duration == 900 && base.focusTarget == .free, "adding a todo does not opt into task timing")
        expect(base.applying(.addTodo(writing)) == base, "duplicate task ID rejected")
        for item in [FocusTodo(title: " \n", minutes: 25), FocusTodo(title: "x", minutes: 0), FocusTodo(title: "x", minutes: 181), FocusTodo(title: String(repeating: "字", count: 181), minutes: 1)] {
            expect(base.applying(.addTodo(item)) == base, "invalid todo cannot enter store")
        }
        expect(FocusTodo.parseMinutes(" ３０ ") == 30 && FocusTodo.parseMinutes("2.5") == nil, "full-width minute input is validated")
        let single = base.applying(.selectTarget(.todo(writing.id)))
        expect(single.duration == 2400 && single.plannedTask == "写初稿", "single selection uses estimate and title")
        expect(single.durationLimit == FocusState.maximumDuration && single.applying(.selectDuration(10_801)) == single, "single-task edits keep the normal duration limit")
        let all = single.applying(.selectTarget(.list))
        expect(all.duration == 3600 && all.todoList?.selected.count == 2 && all.plannedTask.contains("读论文"), "whole list sums only pending items")
        expect(base.applying(.selectTarget(.todo(finished.id))) == base, "cannot select completed item")
        expect(base.applying(.selectTarget(.todo(UUID()))) == base, "stale task selection ignored")
        expect(all.applying(.selectTarget(.free)).duration == 900, "free timer retains separate duration")
        let adjusted = single.applying(.selectDuration(600))
        expect(adjusted.duration == 600 && adjusted.todos[0].minutes == 40 && adjusted.focusDuration == 900, "session override never overwrites estimates or free duration")
        expect(adjusted.applying(.selectTarget(.todo(writing.id))) == adjusted, "reselecting a task preserves its adjusted time and completion status")
        let renamed = adjusted.applying(.editTodo(writing.id, title: "润色", minutes: 40))
        expect(renamed.duration == 600 && renamed.plannedTask == "润色", "rename retains an explicit time override")
        expect(adjusted.applying(.editTodo(reading.id, title: "另一本", minutes: 30)).duration == 600, "unrelated edit preserves selected override")
        let reestimated = adjusted.applying(.editTodo(writing.id, title: "写初稿", minutes: 50))
        expect(reestimated.duration == 3000 && reestimated.todoList?.durationOverride == nil, "estimate change recalculates next session")
        let restful = all.applying(.selectMode(.rest)).applying(.selectDuration(420))
        expect(restful.applying(.selectMode(.focus)).duration == 3600 && restful.restDuration == 420, "breaks retain focus selection")
        let running = all.applying(.start, at: start)
        expect(running.sessionTodoIDs == [writing.id, reading.id], "session freezes selected members")
        expect(running.applying(.selectTarget(.free), at: start) == running, "active target cannot be changed")
        let edited = running.applying(.editTodo(writing.id, title: "改名", minutes: 1), at: start.addingTimeInterval(2))
            .applying(.deleteTodo(reading.id), at: start.addingTimeInterval(3))
        expect(edited.deadline == running.deadline && edited.duration == running.duration, "active list edits never reschedule timer")
        expect(edited.currentTask == running.sessionTask && edited.sessionTodoIDs == running.sessionTodoIDs, "active labels survive rename and deletion")
        let paused = edited.applying(.pause, at: start.addingTimeInterval(10))
        let checked = paused.applying(.setTodoCompleted(writing.id, true), at: start.addingTimeInterval(12))
        expect(checked.remaining == paused.remaining && checked.status == .paused, "checking task preserves paused session")
        let ended = edited.applying(.finish, at: start.addingTimeInterval(60))
        expect(ended.logs.last?.task == running.sessionTask && ended.logs.last?.seconds == 60, "history saves original target and active seconds")
        expect(ended.currentTask == running.sessionTask, "done view retains original target")
        let timedOut = running.applying(.settle, at: start.addingTimeInterval(4000))
        expect(timedOut.todos.filter(\.isCompleted).count == 1, "timer completion never completes tasks automatically")
        expect(timedOut.applying(.startNext, at: start.addingTimeInterval(4001)).mode == .rest, "task completion still offers one-click break")
        let completed = single.applying(.setTodoCompleted(writing.id, true))
        expect(completed.focusTarget == .free && completed.duration == 900, "completed selected task falls back to remembered free timer")
        expect(completed.applying(.setTodoCompleted(writing.id, false)).todos[0].isCompleted == false, "completion is reversible")
        let deleted = single.applying(.deleteTodo(writing.id))
        expect(deleted.focusTarget == .free && deleted.todos.count == 2, "deleting selected task removes dangling selection")
        expect(all.applying(.setTodoCompleted(writing.id, true)).duration == 1200, "whole list shrinks to remaining estimates before start")
        expect(all.applying(.setTodoCompleted(writing.id, true)).applying(.setTodoCompleted(reading.id, true)).focusTarget == .free, "empty list returns to free focus")

        var many = FocusState()
        for i in 0..<FocusTodo.maximumCount {
            many = many.applying(.addTodo(FocusTodo(title: "事项 \(i)", minutes: 180)))
        }
        expect(many.applying(.addTodo(FocusTodo(title: "超额", minutes: 1))) == many, "bounded list never silently drops existing tasks")
        let long = many.applying(.selectTarget(.list)).applying(.start, at: start)
        expect(long.duration == FocusState.maximumPlanDuration, "whole-list sum is not truncated at 180 minutes")
        expect(long.durationLimit == long.duration, "large-list editor supports its full aggregate duration")
        try long.validate()
        let longDone = long.applying(.settle, at: start.addingTimeInterval(long.duration))
        try longDone.validate()
        expect(longDone.logs.last?.seconds == long.duration, "long-list completion remains valid")
        for value in [base, single, adjusted, all, edited, checked, ended, timedOut, longDone] {
            try value.validate()
            expect(try JSONDecoder().decode(FocusState.self, from: JSONEncoder().encode(value)) == value, "todo state survives restart")
        }
        var malformed = base
        malformed.todoList?.items[0].minutes = -1
        do { try malformed.validate(); fatalError("invalid todo accepted") }
        catch { expect(true, "invalid persisted estimates rejected") }
        malformed = base
        malformed.todoList?.items.append(writing)
        do { try malformed.validate(); fatalError("duplicate persisted ID accepted") }
        catch { expect(true, "duplicate persisted IDs rejected") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterglow-todos-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FocusStore(directory: directory)
        let second = FocusStore(directory: directory)
        try first.update(.addTodo(writing), at: start)
        try second.update(.addTodo(reading), at: start)
        let shared = try first.update(.selectTarget(.list), at: start)
        expect(shared.todos.count == 2 && shared.duration == 3600, "independent stores merge changes transactionally")
        try first.update(.start, at: start)
        try second.update(.deleteTodo(reading.id), at: start.addingTimeInterval(1))
        expect(try first.snapshot(at: start.addingTimeInterval(2)).deadline == start.addingTimeInterval(3600), "external task edits preserve active deadline")
    }

    static func testCompletionUndo(at start: Date) throws {
        let writing = FocusTodo(title: "写初稿", minutes: 40)
        let reading = FocusTodo(title: "读论文", minutes: 20)
        let base = FocusState(duration: 900).applying(.addTodo(writing)).applying(.addTodo(reading))
            .applying(.selectTarget(.todo(writing.id))).applying(.selectDuration(600))
        let completed = base.applying(.setTodoCompleted(writing.id, true), at: start)
        let undo = FocusTodoCompletionUndo(id: writing.id, previous: base, updated: completed)!
        let restored = completed.applying(.undoTodoCompletion(undo), at: start)
        expect(restored == base, "undo recovers selected task and custom duration without replacing history")
        expect(restored.applying(.undoTodoCompletion(undo), at: start) == restored, "repeat undo is harmless")
        let renamed = completed.applying(.editTodo(writing.id, title: "新标题", minutes: 50), at: start)
            .applying(.undoTodoCompletion(undo), at: start)
        expect(renamed.todos[0].title == "新标题" && renamed.todos[0].minutes == 50 && !renamed.todos[0].isCompleted,
               "undo restores completion without overwriting later task edits")
        let switched = completed.applying(.selectTarget(.todo(reading.id))).applying(.selectDuration(420))
            .applying(.undoTodoCompletion(undo), at: start)
        expect(switched.focusTarget == .todo(reading.id) && switched.duration == 420 && !switched.todos[0].isCompleted,
               "undo does not override a subsequently selected task or time")
        let retimed = completed.applying(.selectDuration(1800)).applying(.undoTodoCompletion(undo), at: start)
        expect(retimed.focusTarget == .free && retimed.duration == 1800, "undo retains a later free-timer adjustment")
        let deleted = completed.applying(.deleteTodo(writing.id))
        expect(deleted.applying(.undoTodoCompletion(undo), at: start) == deleted, "undo never resurrects a deleted task")
        let nextSession = completed.applying(.start, at: start)
        let nextRestored = nextSession.applying(.undoTodoCompletion(undo), at: start.addingTimeInterval(10))
        expect(nextRestored.deadline == nextSession.deadline && nextRestored.sessionTask == nextSession.sessionTask
               && nextRestored.focusTarget == .free, "undo cannot rewind or relabel a session started after completion")

        let list = base.applying(.selectTarget(.list)).applying(.selectDuration(2700))
        let listCompleted = list.applying(.setTodoCompleted(writing.id, true), at: start)
        let listUndo = FocusTodoCompletionUndo(id: writing.id, previous: list, updated: listCompleted)!
        expect(listCompleted.applying(.undoTodoCompletion(listUndo), at: start) == list, "undo restores whole-list membership and adjusted duration")
        let sole = FocusState().applying(.addTodo(writing)).applying(.selectTarget(.list))
        let empty = sole.applying(.setTodoCompleted(writing.id, true))
        let soleUndo = FocusTodoCompletionUndo(id: writing.id, previous: sole, updated: empty)!
        expect(empty.applying(.undoTodoCompletion(soleUndo)) == sole, "undo last completion restores whole-list selection")

        for state in [base.applying(.start, at: start),
                      base.applying(.start, at: start).applying(.pause, at: start.addingTimeInterval(10)),
                      base.applying(.start, at: start).applying(.finish, at: start.addingTimeInterval(10))] {
            let checked = state.applying(.setTodoCompleted(writing.id, true), at: start.addingTimeInterval(15))
            let receipt = FocusTodoCompletionUndo(id: writing.id, previous: state, updated: checked)!
            let undone = checked.applying(.undoTodoCompletion(receipt), at: start.addingTimeInterval(20))
            expect(undone == state, "completion undo preserves running, paused and finished session state exactly")
            try undone.validate()
        }
        let running = base.applying(.start, at: start)
        let checked = running.applying(.setTodoCompleted(writing.id, true), at: start)
        let receipt = FocusTodoCompletionUndo(id: writing.id, previous: running, updated: checked)!
        let elapsedUndo = checked.applying(.undoTodoCompletion(receipt), at: start.addingTimeInterval(700))
        expect(elapsedUndo.status == .done && elapsedUndo.logs.count == 1 && !elapsedUndo.todos[0].isCompleted,
               "undo at expiry settles the timer once without completing the restored task")
        try elapsedUndo.validate()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterglow-undo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FocusStore(directory: directory)
        let second = FocusStore(directory: directory)
        try first.update(.addTodo(writing), at: start)
        try second.update(.selectTarget(.todo(writing.id)), at: start)
        let latest = try second.update(.selectDuration(480), at: start)
        let change = try first.completeTodo(writing.id, at: start)
        expect(change.undo != nil && change.state.todos[0].isCompleted, "completion persists before returning an undo receipt")
        expect(try first.update(.undoTodoCompletion(change.undo!), at: start) == latest, "undo receipt captures external edits under the transaction lock")
        let again = try first.completeTodo(writing.id, at: start)
        expect(try second.completeTodo(writing.id, at: start).undo == nil, "stale completion produces no misleading undo receipt")
        let restoredOnRestart = try FocusStore(directory: directory).update(.setTodoCompleted(writing.id, false), at: start)
        expect(!restoredOnRestart.todos[0].isCompleted && restoredOnRestart.todos[0].title == writing.title,
               "explicit restore remains available after relaunch without an undo receipt")
        expect(again.undo != nil, "each real completion can be undone")
    }
}
