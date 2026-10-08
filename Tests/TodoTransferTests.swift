import Foundation

@main
struct TodoTransferTests {
    static var count = 0
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: \(message)") }
        count += 1
    }
    static func throwsError(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("FAIL: \(message)") } catch { expect(true, message) }
    }
    static func directory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moro-transfer-\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func main() throws {
        try roundTrip()
        try validation()
        try mergeAndPreview()
        try purge()
        try capacity()
        try conditionalReplace()
        print("PASS: \(count) todo archive/import/purge/conflict checks.")
    }

    static func roundTrip() throws {
        let dir = try directory("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = TodoCollection(title: "旅行")
        let pending = FocusTodo(title: "准备路线", estimatedMinutes: 240, notes: "保留备注和日期",
                                plannedDate: now, dueDate: now.addingTimeInterval(86_400), hasDueTime: false,
                                reminderDate: now.addingTimeInterval(3600), listID: list.id, createdAt: now, sortOrder: 5)
        let completed = FocusTodo(title: "旧任务", isCompleted: true, sortOrder: 7)
        let deleted = FocusTodo(title: "已删除", deletedAt: now, sortOrder: 8)
        let source = FocusStore(directory: dir.appendingPathComponent("store"))
        let state = try source.mergeTodos([pending, completed, deleted], collections: [list], at: now).state
        try source.performActions([.selectTarget(.todo(pending.id)), .start], at: now)
        let active = try source.snapshot(at: now.addingTimeInterval(10))
        let archive = try TodoTransfer.archive(from: active, at: now)
        expect(archive.todos == state.todos && archive.collections == [list], "archive exports all task metadata including completion and trash")
        let data = try TodoTransfer.encode(archive)
        let dictionary = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        expect(dictionary["status"] == nil && dictionary["logs"] == nil && dictionary["deadline"] == nil, "archive omits timer and history")
        let decoded = try TodoTransfer.decode(data)
        expect(decoded == archive && decoded.todos[1].completedAt == nil && decoded.todos[1].createdAt == nil,
               "round trip retains IDs and unknown legacy timestamps")
        let url = dir.appendingPathComponent("Moro.moro.json")
        try TodoTransfer.export(archive, to: url)
        expect(try TodoTransfer.read(from: url) == archive, "atomic file export can be read back")
        var invalid = archive; invalid.todos[0].title = ""
        let before = try Data(contentsOf: url)
        throwsError("invalid export cannot replace a valid archive") { try TodoTransfer.export(invalid, to: url) }
        expect(try Data(contentsOf: url) == before, "failed export preserves previous file")
        throwsError("network export destination rejected") { try TodoTransfer.export(archive, to: URL(string: "https://example.com/test.json")!) }
    }

    static func validation() throws {
        let one = FocusTodo(title: "事项")
        let valid = TodoArchive(todos: [one], exportedAt: now)
        var invalid = valid; invalid.todos.append(one)
        throwsError("duplicate task IDs rejected") { _ = try TodoTransfer.encode(invalid) }
        let collection = TodoCollection(title: "工作")
        invalid = valid; invalid.collections = [collection, collection]
        throwsError("duplicate collection IDs rejected") { _ = try TodoTransfer.encode(invalid) }
        invalid = valid; invalid.todos[0].listID = UUID()
        throwsError("unknown collection reference rejected") { _ = try TodoTransfer.encode(invalid) }
        invalid = valid; invalid.todos[0].reminderDate = Date(timeIntervalSince1970: .infinity)
        throwsError("invalid reminder date rejected") { _ = try TodoTransfer.encode(invalid) }
        invalid = valid; invalid.version = 2
        throwsError("unknown archive schema rejected") { _ = try TodoTransfer.encode(invalid) }
        invalid = valid; invalid.format = "unrelated-format"
        throwsError("wrong format identifier rejected") { _ = try TodoTransfer.encode(invalid) }
        invalid = valid; invalid.todos = (0...FocusTodo.maximumCount).map { FocusTodo(title: "任务 \($0)") }
        throwsError("archive active-task cap enforced") { _ = try TodoTransfer.encode(invalid) }
        throwsError("malformed JSON rejected") { _ = try TodoTransfer.decode(Data("not-json".utf8)) }
        throwsError("oversized input rejected before decoding") { _ = try TodoTransfer.decode(Data(repeating: 32, count: TodoTransfer.maximumFileBytes + 1)) }
        let fullState = try JSONEncoder().encode(FocusState())
        throwsError("raw timer state cannot masquerade as task archive") { _ = try TodoTransfer.decode(fullState) }
        let malformed = try JSONSerialization.jsonObject(with: TodoTransfer.encode(valid)) as! [String: Any]
        var badJSON = malformed; badJSON["todos"] = [["title": "缺少 ID"]]
        throwsError("malformed task schema rejected") { _ = try TodoTransfer.decode(JSONSerialization.data(withJSONObject: badJSON)) }
        badJSON = malformed; badJSON["version"] = 999
        throwsError("untrusted future archive version rejected") { _ = try TodoTransfer.decode(JSONSerialization.data(withJSONObject: badJSON)) }
        badJSON = malformed
        let originalTodos = malformed["todos"] as! [[String: Any]]
        badJSON["todos"] = originalTodos + originalTodos
        throwsError("untrusted duplicate task IDs rejected") { _ = try TodoTransfer.decode(JSONSerialization.data(withJSONObject: badJSON)) }
        badJSON = malformed
        var dangling = originalTodos[0]; dangling["listID"] = UUID().uuidString
        badJSON["todos"] = [dangling]
        throwsError("untrusted dangling collection reference rejected") { _ = try TodoTransfer.decode(JSONSerialization.data(withJSONObject: badJSON)) }
    }

    static func mergeAndPreview() throws {
        let dir = try directory("merge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FocusStore(directory: dir)
        let otherProcess = FocusStore(directory: dir)
        let list = TodoCollection(title: "工作")
        let current = FocusTodo(title: "当前专注", estimatedMinutes: 120, listID: list.id, createdAt: now, sortOrder: 1)
        let untouched = FocusTodo(title: "保留本地", createdAt: now, sortOrder: 2)
        try store.mergeTodos([current, untouched], collections: [list], at: now)
        let running = try store.performActions([.selectTarget(.todo(current.id)), .selectDuration(600), .start], at: now)
        var incoming = current
        incoming.title = "归档旧标题"
        incoming.isCompleted = true
        incoming.completedAt = now.addingTimeInterval(-86_400)
        incoming.sortOrder = 77
        var incomingList = list; incomingList.title = "归档清单名"
        let new = FocusTodo(title: "新增", createdAt: nil, sortOrder: 19)
        let archive = TodoArchive(todos: [incoming, new], collections: [incomingList], exportedAt: now)
        let preview = try TodoTransfer.preview(archive, mergingInto: running)
        expect(preview.addedTodoCount == 1 && preview.updatedTodoCount == 1 && preview.unchangedTodoCount == 0
               && preview.updatedCollectionCount == 1 && preview.overwriteCount == 2, "preview reports overwritten tasks and collections")
        expect(preview.pendingTodoCountAfterMerge == 2 && preview.totalTodoCountAfterMerge == 3 && preview.hasConflicts,
               "preview capacity describes final merged state")
        var unrelatedEdit = untouched; unrelatedEdit.title = "别处修改的本地事项"
        try otherProcess.performTodoAction(.upsertTodo(unrelatedEdit), at: now)
        let imported = try TodoTransfer.mergeArchive(archive, into: store, preview: preview, at: now.addingTimeInterval(20))
        expect(imported.state.todos.count == 3 && imported.state.todos.first { $0.id == current.id } == incoming,
               "same-ID import updates once and preserves original completion date/order")
        expect(imported.state.todos.first { $0.id == new.id }?.createdAt == nil, "import does not invent creation dates")
        expect(imported.state.todos.first { $0.id == untouched.id }?.title == unrelatedEdit.title, "unrelated post-preview changes are retained")
        expect(imported.state.status == .running && imported.state.deadline == running.deadline
               && imported.state.duration == running.duration && imported.state.sessionID == running.sessionID
               && imported.state.sessionTask == running.sessionTask && imported.state.logs == running.logs,
               "archive never stops or replaces actual focus session/history")
        let undo = try store.undoTodo(imported.undo!, at: now.addingTimeInterval(30))
        expect(undo.state.todos.count == 2 && undo.state.todos.first { $0.id == current.id } == current,
               "one undo reverses complete import")
        expect(undo.state.deadline == running.deadline && undo.state.sessionID == running.sessionID, "undo import cannot rewind focus")
        let redo = try store.undoTodo(undo.undo!, at: now.addingTimeInterval(40))
        expect(redo.state.todos.first { $0.id == current.id } == incoming, "import redo restores original archived metadata")
        let noChanges = try TodoTransfer.preview(archive, mergingInto: redo.state)
        expect(noChanges.updatedTodoCount == 0 && noChanges.unchangedTodoCount == 2 && !noChanges.hasConflicts,
               "reimport of unchanged IDs is idempotent")
        expect(try TodoTransfer.mergeArchive(archive, into: store, preview: noChanges, at: now.addingTimeInterval(41)).undo == nil,
               "idempotent import produces no spurious undo")
        let stale = try TodoTransfer.preview(archive, mergingInto: redo.state)
        var conflict = incoming; conflict.notes = "预览后的编辑"
        try otherProcess.performTodoAction(.upsertTodo(conflict), at: now.addingTimeInterval(42))
        throwsError("affected post-preview edit aborts whole import") {
            _ = try TodoTransfer.mergeArchive(archive, into: store, preview: stale, at: now.addingTimeInterval(43))
        }
        expect(try store.snapshot(at: now.addingTimeInterval(44)).todos.first { $0.id == incoming.id }?.notes == conflict.notes,
               "stale preview cannot overwrite a newer edit")
        var alteredArchive = archive; alteredArchive.todos[0].title = "另一个文件"
        throwsError("preview cannot authorize a different archive") { _ = try TodoTransfer.mergeArchive(alteredArchive, into: store, preview: stale, at: now) }
        let freshTask = FocusTodo(title: "原先不存在")
        let freshArchive = TodoArchive(todos: [freshTask], exportedAt: now)
        let state = try store.snapshot(at: now.addingTimeInterval(44))
        let absentPreview = try TodoTransfer.preview(freshArchive, mergingInto: state)
        var collision = freshTask; collision.title = "新创建的同 ID"
        try otherProcess.performTodoAction(.upsertTodo(collision), at: now.addingTimeInterval(45))
        throwsError("new ID collision after preview cannot silently overwrite") { _ = try TodoTransfer.mergeArchive(freshArchive, into: store, preview: absentPreview, at: now) }
        let collectionArchive = TodoArchive(todos: [], collections: [incomingList], exportedAt: now)
        let collectionPreview = try TodoTransfer.preview(collectionArchive, mergingInto: store.snapshot(at: now.addingTimeInterval(46)))
        var renamedList = incomingList; renamedList.title = "预览后改清单名"
        try otherProcess.performTodoAction(.upsertCollection(renamedList), at: now.addingTimeInterval(47))
        throwsError("collection edit after preview aborts import") {
            _ = try TodoTransfer.mergeArchive(collectionArchive, into: store, preview: collectionPreview, at: now.addingTimeInterval(48))
        }
        expect(try store.snapshot(at: now.addingTimeInterval(49)).todoList?.collections.first?.title == renamedList.title,
               "failed import keeps newer collection name")
    }

    static func purge() throws {
        let dir = try directory("purge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FocusStore(directory: dir)
        let first = FocusTodo(title: "A", sortOrder: 0)
        let second = FocusTodo(title: "B", sortOrder: 0)
        let third = FocusTodo(title: "C", sortOrder: 0)
        try store.mergeTodos([first, second, third], collections: [], at: now)
        try store.performActions([.selectTarget(.todo(second.id)), .start], at: now)
        try store.performTodoAction(.trashTodo(second.id), at: now.addingTimeInterval(5))
        let before = try store.snapshot(at: now.addingTimeInterval(5))
        throwsError("purge never accepts live tasks") { _ = try store.performTodoAction(.purgeTodos([first.id]), at: now) }
        throwsError("mixed valid/invalid purge is all-or-nothing") { _ = try store.performTodoAction(.purgeTodos([second.id, third.id]), at: now) }
        let purged = try store.performTodoAction(.purgeTodos([second.id]), at: now.addingTimeInterval(10))
        expect(purged.state.todos.map(\.id) == [first.id, third.id], "purge really frees total record capacity")
        expect(purged.state.status == .running && purged.state.deadline == before.deadline
               && purged.state.sessionTodoIDs == [second.id], "purging trashed current task does not destroy running session")
        let restored = try store.undoTodo(purged.undo!, at: now.addingTimeInterval(15))
        expect(restored.state.todos == before.todos, "purge undo restores exact task metadata and insertion position")
        let redo = try store.undoTodo(restored.undo!, at: now.addingTimeInterval(20))
        expect(redo.state.todos.map(\.id) == [first.id, third.id], "purge redo removes exactly the intended trash item")
        let ended = try store.update(.finish, at: now.addingTimeInterval(30))
        expect(ended.logs.last?.todoIDs == [second.id] && ended.logs.last?.task == "B" && ended.logs.last?.seconds == 30,
               "purged task focus history keeps stable ID, title and elapsed time")
        let undoAfterLog = try store.undoTodo(redo.undo!, at: now.addingTimeInterval(35))
        expect(undoAfterLog.state.logs == ended.logs && undoAfterLog.state.status == .done,
               "restoring purged task cannot remove a later focus log")
    }

    static func capacity() throws {
        let dir = try directory("capacity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FocusStore(directory: dir)
        let items = (0..<FocusTodo.maximumCount).map { FocusTodo(title: "事项 \($0)", sortOrder: $0) }
        let oldCompleted = FocusTodo(title: "可恢复的旧事项", isCompleted: true)
        let full = try store.mergeTodos(items + [oldCompleted], collections: [], at: now).state
        var archivedCompletion = items[0]
        archivedCompletion.isCompleted = true
        archivedCompletion.completedAt = now.addingTimeInterval(-86_400)
        var reopen = oldCompleted; reopen.isCompleted = false
        // The order intentionally reopens before freeing an active slot. A
        // sequential upsert implementation would reject this valid final state.
        let swap = TodoArchive(todos: [reopen, archivedCompletion], exportedAt: now)
        let preview = try TodoTransfer.preview(swap, mergingInto: full)
        expect(preview.pendingTodoCountAfterMerge == FocusTodo.maximumCount, "preview checks final merged capacity")
        let merged = try TodoTransfer.mergeArchive(swap, into: store, preview: preview, at: now)
        expect(merged.state.todos.first { $0.id == oldCompleted.id }?.isPending == true
               && merged.state.todos.first { $0.id == items[0].id }?.completedAt == archivedCompletion.completedAt,
               "atomic import can exchange pending/completed slots at capacity while retaining dates")
        let overflow = TodoArchive(todos: [FocusTodo(title: "超额")], exportedAt: now)
        throwsError("preview rejects combined active overflow") { _ = try TodoTransfer.preview(overflow, mergingInto: merged.state) }
        let file = dir.appendingPathComponent("focus-state.json")
        let bytes = try Data(contentsOf: file)
        throwsError("merge independently rejects overflow without preview") { _ = try TodoTransfer.mergeArchive(overflow, into: store, at: now) }
        expect(try Data(contentsOf: file) == bytes, "rejected merge leaves saved bytes intact")
        let oversized = TodoArchive(todos: (0..<2_000).map {
            FocusTodo(title: "历史 \($0)", notes: String(repeating: "x", count: 10_000), isCompleted: true)
        }, exportedAt: now)
        throwsError("in-memory archive export also enforces byte budget") { _ = try TodoTransfer.encode(oversized) }
        throwsError("in-memory archive merge enforces byte budget") { _ = try TodoTransfer.mergeArchive(oversized, into: store, at: now) }
        expect(try Data(contentsOf: file) == bytes, "oversized merge never alters live state")
    }

    static func conditionalReplace() throws {
        let dir = try directory("replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FocusStore(directory: dir)
        let second = FocusStore(directory: dir)
        let date = now.addingTimeInterval(0.000_013_7)
        let original = FocusTodo(title: "原题", dueDate: date, hasDueTime: true, createdAt: date)
        let saved = try first.performTodoAction(.upsertTodo(original), at: date).state.todos[0]
        var changed = saved; changed.title = "新标题"
        let result = try first.performTodoAction(.replaceTodo(expected: saved, replacement: changed), at: date)
        expect(result.state.todos[0].title == "新标题", "canonical sub-millisecond snapshot passes conditional replacement")
        let stale = result.state.todos[0]
        try second.performTodoAction(.setTodoCompleted(stale.id, true), at: now.addingTimeInterval(1))
        var staleEdit = stale; staleEdit.notes = "旧草稿"
        throwsError("stale edit cannot overwrite a concurrent completion") {
            _ = try first.performTodoAction(.replaceTodo(expected: stale, replacement: staleEdit), at: now.addingTimeInterval(2))
        }
        let completed = try first.snapshot(at: now.addingTimeInterval(2)).todos[0]
        expect(completed.isCompleted && completed.notes.isEmpty, "concurrent completion remains intact")
        try second.performTodoAction(.trashTodo(completed.id), at: now.addingTimeInterval(3))
        var moved = completed; moved.title = "旧移动草稿"
        throwsError("stale move cannot resurrect a concurrently trashed task") {
            _ = try first.performTodoAction(.replaceTodo(expected: completed, replacement: moved), at: now.addingTimeInterval(4))
        }
        let trashed = try first.snapshot(at: now.addingTimeInterval(4)).todos[0]
        expect(trashed.deletedAt != nil && trashed.title == "新标题", "concurrent trash remains intact")
        let mismatch = FocusTodo(title: "另一个 ID")
        throwsError("replace cannot change task identity") { _ = try first.performTodoAction(.replaceTodo(expected: trashed, replacement: mismatch), at: now) }
    }
}
