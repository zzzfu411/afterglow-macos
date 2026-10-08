import AppKit
import Combine
import Darwin
import Foundation

@MainActor
private final class ControlledReminderDelivery: ReminderDelivery {
    var status: ReminderAuthorization = .allowed
    var grantsPermission = false
    var holdNextSchedule = false
    private(set) var permissionRequests = 0
    private(set) var schedules: [FocusReminder] = []
    private(set) var pending: FocusReminder?
    private(set) var cancellations = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func authorization() async -> ReminderAuthorization { status }

    func requestAuthorization() async throws -> Bool {
        permissionRequests += 1
        status = grantsPermission ? .allowed : .denied
        return grantsPermission
    }

    func schedule(_ reminder: FocusReminder) async throws {
        schedules.append(reminder)
        if holdNextSchedule {
            holdNextSchedule = false
            await withCheckedContinuation { continuation = $0 }
        }
        // Model the service accepting an already in-flight request even if a
        // cancellation arrived while its asynchronous add was suspended.
        pending = reminder
    }

    func cancel() { cancellations += 1; pending = nil }

    func releaseSchedule() {
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return total }
    func increment() { lock.lock(); total += 1; lock.unlock() }
}

private final class WeakReference<Object: AnyObject> {
    weak var value: Object?
    init(_ value: Object?) { self.value = value }
}

private struct FileSnapshot: Equatable {
    let bytes: Data
    let modified: Date?
    let inode: UInt64?

    init(_ url: URL) throws {
        bytes = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        modified = attributes[.modificationDate] as? Date
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

private struct RuntimeMemory {
    let rss: UInt64
    let footprint: UInt64

    static func sample() throws -> RuntimeMemory {
        var basic = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let basicCapacity = Int(basicCount)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: basicCapacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        guard basicResult == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(basicResult)) }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let vmCapacity = Int(vmCount)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: vmCapacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        guard vmResult == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(vmResult)) }
        return RuntimeMemory(rss: basic.resident_size, footprint: vm.phys_footprint)
    }
    var description: String {
        String(format: "RSS %.2f MiB / footprint %.2f MiB", Double(rss) / 1_048_576, Double(footprint) / 1_048_576)
    }
}

@main
struct RuntimeTests {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ assertion: Bool, _ message: String) {
        guard assertion else { fatalError("FAIL: \(message)") }
        checks += 1
    }

    @MainActor private static func waitUntil(_ message: String, timeout: TimeInterval = 3,
                                            _ condition: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { await delay(0.01) }
        expect(condition(), message)
    }

    private static func delay(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func write(_ state: FocusState, to directory: URL) throws {
        try state.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(to: directory.appendingPathComponent("focus-state.json"), options: .atomic)
    }

    private static func descriptors(for url: URL) throws -> Int {
        let expected = url.resolvingSymlinksInPath().path
        return try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").reduce(0) { count, name in
            guard let descriptor = Int32(name) else { return count }
            var path = [CChar](repeating: 0, count: Int(PATH_MAX))
            let result = path.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
            guard result == 0 else { return count }
            let actual = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
            return count + (actual == expected ? 1 : 0)
        }
    }

    private static func process(arguments: [String], output: Pipe? = nil, input: Pipe? = nil) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = arguments
        if let output { child.standardOutput = output }
        if let input { child.standardInput = input }
        try child.run()
        return child
    }

    // Child processes touch only the parent test's random temporary directory.
    private static func runWorker() throws -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 3, args[1].hasPrefix("--") else { return false }
        let directory = URL(fileURLWithPath: args[2])
        guard directory.pathComponents.contains(where: { $0.hasPrefix("afterglow-runtime-tests-") }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        switch args[1] {
        case "--write-task":
            guard args.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
            try FocusStore(directory: directory).update(.setTask(args[3]))
        case "--hold-lock":
            let descriptor = open(directory.appendingPathComponent("focus-state.lock").path, O_RDWR | O_CLOEXEC)
            guard descriptor >= 0 else { throw FocusStoreError.fileLockFailed(errno) }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw FocusStoreError.fileLockFailed(errno) }
            defer { flock(descriptor, LOCK_UN) }
            FileHandle.standardOutput.write(Data([1]))
            Thread.sleep(forTimeInterval: 4)
        case "--edit-under-lock":
            guard args.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
            let descriptor = open(directory.appendingPathComponent("focus-state.lock").path, O_RDWR | O_CLOEXEC)
            guard descriptor >= 0 else { throw FocusStoreError.fileLockFailed(errno) }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw FocusStoreError.fileLockFailed(errno) }
            defer { flock(descriptor, LOCK_UN) }
            FileHandle.standardOutput.write(Data([1]))
            guard FileHandle.standardInput.readData(ofLength: 1) == Data([1]) else { throw CocoaError(.fileReadUnknown) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let saved = try decoder.decode(FocusState.self, from: Data(contentsOf: directory.appendingPathComponent("focus-state.json")))
            guard var item = saved.todos.first else { throw FocusStateError.invalidData }
            item.title = args[3]; item.isCompleted = true
            try write(saved.applying(.upsertTodo(item)), to: directory)
        default: throw CocoaError(.fileReadInvalidFileName)
        }
        return true
    }

    @MainActor private static func reminderTests() async {
        let start = Date().addingTimeInterval(10)
        let running = FocusState(duration: 60).applying(.start, at: start)
        let paused = running.applying(.pause, at: start.addingTimeInterval(10))
        let resumed = paused.applying(.start, at: start.addingTimeInterval(30))

        let pausedDelivery = ControlledReminderDelivery()
        pausedDelivery.holdNextSchedule = true
        let pauseCoordinator = FocusReminders(delivery: pausedDelivery)
        pauseCoordinator.reconcile(running)
        await waitUntil("start reached the suspended notification service") { pausedDelivery.schedules.count == 1 }
        pauseCoordinator.reconcile(paused)
        pausedDelivery.releaseSchedule()
        await pauseCoordinator.flush()
        expect(pausedDelivery.pending == nil, "pause cancels an add that finishes after the pause")
        expect(pausedDelivery.schedules.count == 1, "pause never reschedules the old reminder")

        let resumedDelivery = ControlledReminderDelivery()
        resumedDelivery.holdNextSchedule = true
        let resumeCoordinator = FocusReminders(delivery: resumedDelivery)
        resumeCoordinator.reconcile(running)
        await waitUntil("resume test has an in-flight old deadline") { resumedDelivery.schedules.count == 1 }
        resumeCoordinator.reconcile(paused)
        resumeCoordinator.reconcile(resumed)
        resumedDelivery.releaseSchedule()
        await resumeCoordinator.flush()
        expect(resumedDelivery.schedules.count == 2, "rapid resume schedules the newest deadline after the old add")
        expect(resumedDelivery.pending?.sessionID == running.sessionID, "resume retains the same session identity")
        expect(resumedDelivery.pending?.deadline == resumed.deadline, "resume replaces the old deadline")

        let completedDelivery = ControlledReminderDelivery()
        completedDelivery.holdNextSchedule = true
        let completionCoordinator = FocusReminders(delivery: completedDelivery)
        completionCoordinator.reconcile(running)
        await waitUntil("completion test has an in-flight notification") { completedDelivery.schedules.count == 1 }
        completionCoordinator.reconcile(running.applying(.settle, at: start.addingTimeInterval(61)))
        completedDelivery.releaseSchedule()
        await completionCoordinator.flush()
        expect(completedDelivery.pending?.deadline == running.deadline, "natural completion preserves the scheduled delivery")
        expect(completedDelivery.cancellations == 0 && completedDelivery.schedules.count == 1,
               "natural completion neither cancels nor sends a duplicate")
        completionCoordinator.reconcile(running.applying(.finish, at: start.addingTimeInterval(1)))
        await completionCoordinator.flush()
        expect(completedDelivery.pending == nil, "early finish cancels the reminder")

        let deniedDelivery = ControlledReminderDelivery()
        deniedDelivery.status = .unknown
        let deniedCoordinator = FocusReminders(delivery: deniedDelivery)
        deniedCoordinator.reconcile(running, requestPermission: true)
        await deniedCoordinator.flush()
        for _ in 0..<3 {
            deniedCoordinator.reconcile(resumed, requestPermission: true)
            await deniedCoordinator.flush()
        }
        expect(deniedDelivery.permissionRequests == 1, "denied authorization is not requested repeatedly")
        expect(deniedDelivery.schedules.isEmpty && deniedDelivery.pending == nil, "denied authorization never schedules")
        let backgroundDelivery = ControlledReminderDelivery()
        backgroundDelivery.status = .unknown
        let backgroundCoordinator = FocusReminders(delivery: backgroundDelivery)
        backgroundCoordinator.reconcile(running)
        await backgroundCoordinator.flush()
        expect(backgroundDelivery.permissionRequests == 0 && backgroundDelivery.schedules.isEmpty,
               "background reconciliation never requests unknown permission")

        let idleDelivery = ControlledReminderDelivery()
        idleDelivery.status = .denied
        let idleCoordinator = FocusReminders(delivery: idleDelivery)
        idleCoordinator.reconcile(FocusState())
        await idleCoordinator.flush()
        expect(idleCoordinator.authorization == .denied, "idle app shows disabled notifications without starting a timer")
        idleDelivery.status = .allowed
        idleCoordinator.reconcile(FocusState())
        await idleCoordinator.flush()
        expect(idleCoordinator.authorization == .allowed, "returning from settings refreshes idle authorization")
        expect(idleDelivery.permissionRequests == 0 && idleDelivery.schedules.isEmpty,
               "idle permission refresh neither prompts nor schedules")
    }

    @MainActor private static func observationTests(_ root: URL) async throws {
        let directory = root.appendingPathComponent("observation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseline = try descriptors(for: directory)
        let counter = ChangeCounter()
        var observation: FocusStoreObservation? = try FocusStoreObservation(directory: directory) { counter.increment() }
        let released = WeakReference(observation)
        for index in 0..<6 {
            let before = counter.value
            try write(FocusState(task: "atomic-\(index)"), to: directory)
            await waitUntil("directory watcher sees atomic replacement \(index)") { counter.value > before }
            await delay(0.04)
        }
        expect(counter.value <= 60, "atomic writes produce a bounded number of coalesced callbacks")
        observation = nil
        expect(released.value == nil, "observation is not retained by its event handler")
        await waitUntil("cancelled observation closes its directory descriptor") {
            (try? descriptors(for: directory)) == baseline
        }
        await delay(0.08)
        let afterCancel = counter.value
        try write(FocusState(task: "after-cancel"), to: directory)
        await delay(0.15)
        expect(counter.value == afterCancel, "cancelled observation produces no callbacks for later writes")
        for _ in 0..<20 {
            var temporary: FocusStoreObservation? = try FocusStoreObservation(directory: directory) { }
            temporary = nil
            _ = temporary
        }
        await waitUntil("repeated create/cancel cycles do not leak file descriptors") {
            (try? descriptors(for: directory)) == baseline
        }
    }

    @MainActor private static func noPolling(_ model: FocusModel, directory: URL, label: String) async throws {
        // Let callbacks caused by the preceding explicit state write drain.
        await delay(0.2)
        let file = directory.appendingPathComponent("focus-state.json")
        let before = try FileSnapshot(file)
        let state = model.state
        let ready = Pipe()
        let holder = try process(arguments: ["--hold-lock", directory.path], output: ready)
        defer {
            if holder.isRunning { holder.terminate() }
            holder.waitUntilExit()
        }
        expect(ready.fileHandleForReading.readData(ofLength: 1) == Data([1]), "\(label) lock probe started")
        let started = Date()
        await delay(1.7)
        // A one-second main-thread poll would block on the child's four-second
        // lock. A background poll instead leaves a blocked lock descriptor open.
        expect(Date().timeIntervalSince(started) < 3, "\(label) does not poll storage on the main run loop")
        expect(try descriptors(for: directory.appendingPathComponent("focus-state.lock")) == 0,
               "\(label) has no background polling reader waiting for the file lock")
        expect(model.state == state, "\(label) remains stable without external events")
        expect(try FileSnapshot(file) == before, "\(label) does not rewrite its data file")
    }

    @MainActor private static func modelTests(_ root: URL) async throws {
        let directory = root.appendingPathComponent("model")
        try write(FocusState(task: "initial"), to: directory)
        let active = FocusModel(store: FocusStore(directory: directory), remindersEnabled: false)
        await active.flush()
        expect(active.reminders == nil && active.todoReminders == nil && active.error == nil,
               "isolated model avoids all system notification services")
        expect(active.state.task == "initial", "flush awaits the initial asynchronous read")
        expect(active.showSidebar && active.allowsTimerKeyboard, "navigation is visible by default without blocking timer keys")
        try await noPolling(active, directory: directory, label: "idle")

        let writer = try process(arguments: ["--write-task", directory.path, "other-process"])
        await waitUntil("model receives an external process update without polling") { active.state.task == "other-process" }
        await waitUntil("external writer exits") { !writer.isRunning }
        expect(writer.terminationStatus == 0, "external store writer succeeded")
        let external = FocusStore(directory: directory)
        for index in 0..<3 {
            try external.update(.setTask("another-store-\(index)"))
            await waitUntil("model observes repeated atomic writes \(index)") { active.state.task == "another-store-\(index)" }
        }
        await active.flush()

        active.section = .inbox
        active.quickEntryText = "检查待办"
        active.quickAddTodo()
        active.quickEntryText = "下一条尚未提交"
        await active.flush()
        expect(active.state.todos.count == 1 && active.state.todos[0].estimatedMinutes == nil,
               "title-only quick entry creates a task without forcing an estimate")
        expect(active.quickEntryText == "下一条尚未提交", "asynchronous save never clears text typed for the next task")
        let todo = active.state.todos[0]
        active.quickEntryText = ""
        active.editTodo(todo.id)
        active.todoDraft?.title = "仍在编辑"
        active.editTodo(todo.id)
        expect(active.todoDraft?.title == "仍在编辑", "clicking the same task preserves an unsaved draft")
        active.showSidebar = false
        expect(active.todoDraft?.title == "仍在编辑" && !active.allowsTimerKeyboard,
               "hiding navigation preserves the task draft and its keyboard protection")
        active.newTodo()
        expect(active.todoDraft?.title == "仍在编辑", "requesting quick entry does not discard an unfinished edit")
        active.todoDraft?.minutes = "０"
        active.saveTodo()
        await active.flush()
        expect(active.todoDraft != nil && active.state.todos[0].estimatedMinutes == nil, "invalid estimate cannot save or disappear")
        active.todoDraft?.minutes = "３０"
        let dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        active.todoDraft?.dueDate = dueDate
        active.saveTodo()
        await active.flush()
        expect(active.state.todos[0].estimatedMinutes == 30 && active.todoDraft == nil,
               "draft saves the normalized estimate and clears only after successful persistence")
        expect(active.state.todos[0].dueDate == dueDate && active.state.version == FocusState.currentVersion,
               "optional deadline persists in the current data format")
        let originalDuration = active.state.duration
        active.selectFocusTarget(.todo(todo.id))
        await active.flush()
        expect(active.state.duration == originalDuration && active.state.duration != 1_800,
               "task estimate does not become the next focus block duration")
        try await noPolling(active, directory: directory, label: "idle with todo list")

        active.editTodo(todo.id)
        active.todoDraft?.title = "编辑后的待办"
        active.todoDraft?.dueDate = nil
        active.saveTodo()
        await active.flush()
        expect(active.state.todos.count == 1 && active.state.todos[0].title == "编辑后的待办",
               "editing does not duplicate the existing item")
        expect(active.state.todos[0].dueDate == nil && active.state.version == FocusState.currentVersion,
               "a deadline can be cleared without downgrading data")
        active.editTodo(todo.id)
        active.todoDraft?.title = "提交的版本"
        active.saveTodo()
        active.todoDraft?.title = "写入期间继续编辑"
        await active.flush()
        expect(active.state.todos[0].title == "提交的版本" && active.todoDraft?.title == "写入期间继续编辑",
               "saving one draft snapshot never clears edits made while the write was in flight")
        active.saveTodo()
        await active.flush()
        expect(active.state.todos[0].title == "写入期间继续编辑" && active.todoDraft == nil,
               "the retained draft can be saved against the newly persisted version")
        active.quickEntryText = "计时中仍可整理的任务"
        active.quickAddTodo()
        await active.flush()
        let other = active.state.todos.first { $0.id != todo.id }!
        active.send(.selectDuration(480))
        await active.flush()
        active.startFocus(todo.id)
        await active.flush()
        let runningID = active.state.sessionID
        let runningDeadline = active.state.deadline
        expect(active.state.status == .running && active.state.sessionTodoIDs == [todo.id], "a task starts one independent focus block")
        active.selectTodo(other.id)
        active.editTodo(other.id)
        active.todoDraft?.notes = "专注期间整理，不影响计时"
        active.saveTodo()
        await active.flush()
        expect(active.selectedTodoID == other.id && active.state.sessionTodoIDs == [todo.id],
               "list selection and editing remain independent from the active focus task")
        expect(active.state.deadline == runningDeadline && active.state.sessionID == runningID,
               "editing another task cannot change the running deadline or session identity")
        active.completeTodo(other.id)
        await active.flush()
        expect(active.canUndoTodo && active.state.todos.first { $0.id == other.id }?.isCompleted == true,
               "completion creates a reversible task operation")
        active.undoTodoChange()
        await active.flush()
        expect(active.canRedoTodo && active.state.todos.first { $0.id == other.id }?.isCompleted == false,
               "undo restores only the completed task")
        expect(active.state.deadline == runningDeadline && active.state.sessionID == runningID,
               "task undo never rolls back the active timer")
        active.redoTodoChange()
        await active.flush()
        expect(active.state.todos.first { $0.id == other.id }?.isCompleted == true, "redo reapplies task completion")
        active.completeTodo(todo.id)
        await active.flush()
        let settledLogs = active.state.logs
        expect(active.state.status == .done && !settledLogs.isEmpty, "completing the active task settles its real elapsed time")
        active.undoTodoChange()
        await active.flush()
        expect(active.state.status == .done && active.state.logs == settledLogs
               && active.state.todos.first { $0.id == todo.id }?.isCompleted == false,
               "undoing completion does not restart a settled focus or rewrite its history")

        active.trashTodo(todo.id)
        await active.flush()
        expect(active.state.todos.first { $0.id == todo.id }?.isDeleted == true, "delete moves a task into reversible trash")
        active.restoreTodo(todo.id)
        await active.flush()
        expect(active.state.todos.first { $0.id == todo.id }?.isPending == true, "restore recovers a deleted pending task")
        active.completeTodo(todo.id)
        await active.flush()
        let diskFile = directory.appendingPathComponent("focus-state.json")
        let savedCompletion = try Data(contentsOf: diskFile)
        try Data("invalid".utf8).write(to: diskFile, options: .atomic)
        active.undoTodoChange()
        await active.flush()
        expect(active.error != nil && active.canUndoTodo && active.state.todos.first { $0.id == todo.id }?.isCompleted == true,
               "failed undo preserves its receipt and last known task state")
        try savedCompletion.write(to: diskFile, options: .atomic)
        active.retryStorage()
        await active.flush()
        active.undoTodoChange()
        await active.flush()
        expect(active.error == nil && active.state.todos.first { $0.id == todo.id }?.isPending == true,
               "undo safely retries after storage recovery")

        active.startFocus(todo.id)
        await active.flush()
        active.send(.pause)
        await active.flush()
        expect(active.state.status == .paused, "model pauses the running timer")
        try await noPolling(active, directory: directory, label: "paused")
        var completions = 0
        let subscription = active.$state.sink { if $0.status == .done { completions += 1 } }
        defer { subscription.cancel() }
        let now = Date()
        let almostDone = FocusState(duration: 60).applying(.start, at: now.addingTimeInterval(-58.6))
        try write(almostDone, to: directory)
        await waitUntil("external running state arms a deadline timer", timeout: 1) {
            active.state.sessionID == almostDone.sessionID && active.state.status == .running
        }
        await waitUntil("one-shot deadline settles the session", timeout: 3) { active.state.status == .done }
        expect(active.state.logs.count == 1 && active.state.logs[0].completed, "deadline records exactly one completed session")
        expect(abs(active.state.logs[0].endedAt.timeIntervalSince(almostDone.deadline!)) < 0.001,
               "completion retains the original deadline")
        let completedFile = try FileSnapshot(diskFile)
        active.refresh(); active.refresh()
        await active.flush()
        expect(completions == 1 && active.state.logs.count == 1, "watcher echoes and repeated refreshes do not duplicate completion")
        expect(try FileSnapshot(diskFile) == completedFile, "settled sessions do not repeatedly rewrite history")
        let cancellation = FocusState(duration: 60).applying(.start, at: Date().addingTimeInterval(-59))
        try write(cancellation, to: directory)
        await waitUntil("new external session replaces the previous deadline") { active.state.sessionID == cancellation.sessionID }
        active.send(.pause)
        await active.flush()
        await delay(1.2)
        expect(active.state.status == .paused && active.state.logs.isEmpty, "pausing invalidates the pending deadline callback")
        expect(active.error == nil, "event-driven model completes without storage errors")

        let preserved = try Data(contentsOf: diskFile)
        try Data("invalid".utf8).write(to: diskFile, options: .atomic)
        await waitUntil("unreadable data exposes a recoverable error") { active.error != nil }
        active.todoDraft = TodoDraft()
        active.todoDraft?.title = "写入失败时保留"
        active.saveTodo()
        await active.flush()
        expect(active.todoDraft?.title == "写入失败时保留", "failed persistence keeps the draft intact")
        try preserved.write(to: diskFile, options: .atomic)
        active.retryStorage()
        await active.flush()
        expect(active.error == nil && active.state.status == .paused, "storage recovery does not reset the timer")
    }

    @MainActor private static func sidebarPreferencesTest(_ root: URL) async throws {
        let suite = "afterglow-sidebar-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FocusStore(directory: root.appendingPathComponent("sidebar-preferences"))
        let first = FocusModel(store: store, remindersEnabled: false, preferences: defaults)
        await first.flush()
        expect(first.showSidebar, "new installs show navigation")
        let before = try store.snapshot()
        first.showSidebar = false
        let reopened = FocusModel(store: store, remindersEnabled: false, preferences: defaults)
        await reopened.flush()
        expect(!reopened.showSidebar, "relaunch remembers a deliberately collapsed sidebar")
        let request = reopened.quickEntryRequest
        reopened.newTodo()
        expect(reopened.quickEntryRequest == request + 1 && !reopened.showSidebar,
               "quick entry works in the main list without expanding collapsed navigation")
        expect(try store.snapshot() == before, "navigation preferences and quick entry focus never alter stored data")
    }

    @MainActor private static func asynchronousQueueTests(_ root: URL) async throws {
        let directory = root.appendingPathComponent("asynchronous-queue")
        try write(FocusState(), to: directory)
        let model = FocusModel(store: FocusStore(directory: directory), remindersEnabled: false)
        await model.flush()
        await delay(0.15)
        let ready = Pipe()
        let holder = try process(arguments: ["--hold-lock", directory.path], output: ready)
        defer { if holder.isRunning { holder.terminate() }; holder.waitUntilExit() }
        expect(ready.fileHandleForReading.readData(ofLength: 1) == Data([1]), "blocked-write lock probe started")
        model.quickEntryText = "等待锁的事项"
        model.quickAddTodo()
        var didFlush = false
        let waiter = Task { @MainActor in await model.flush(); didFlush = true }
        await delay(0.1)
        expect(!didFlush && model.isBusy, "flush waits for an asynchronous transaction blocked on the file lock")
        model.quickEntryText = "后续仍可输入"
        expect(model.state.todos.isEmpty, "main actor remains responsive without pretending the blocked write succeeded")
        holder.terminate(); holder.waitUntilExit()
        await waiter.value
        expect(model.state.todos.count == 1 && model.quickEntryText == "后续仍可输入" && !model.isBusy,
               "flush returns after persistence and preserves text typed during the write")

        await delay(0.15)
        let intentReady = Pipe()
        let intentHolder = try process(arguments: ["--hold-lock", directory.path], output: intentReady)
        defer { if intentHolder.isRunning { intentHolder.terminate() }; intentHolder.waitUntilExit() }
        expect(intentReady.fileHandleForReading.readData(ofLength: 1) == Data([1]), "blocked-intent lock probe started")
        var intentFinished = false
        let intent = Task { @MainActor in try await model.performIntent(.toggle); intentFinished = true }
        await delay(0.1)
        var intentFlushed = false
        let intentWaiter = Task { @MainActor in await model.flush(); intentFlushed = true }
        await delay(0.1)
        expect(!intentFinished && !intentFlushed, "flush also waits for an in-flight system intent")
        intentHolder.terminate(); intentHolder.waitUntilExit()
        try await intent.value
        await intentWaiter.value
        expect(model.state.status == .running && intentFlushed, "system intent commits through the same awaited queue")
    }

    @MainActor private static func presentationAndScaleTests(_ root: URL) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var planned = FocusTodo(title: "安排到今天", plannedDate: calendar.startOfDay(for: today))
        expect(TodoSection.today.contains(planned, at: today, calendar: calendar), "planned date places a task in Today")
        expect(!TodoSection.upcoming.contains(planned, at: today, calendar: calendar), "Today is not incorrectly tomorrow across DST")
        planned.plannedDate = tomorrow
        expect(TodoSection.upcoming.contains(planned, at: today, calendar: calendar), "future plan enters Upcoming")
        planned.dueDate = calendar.date(byAdding: .day, value: -1, to: today)
        expect(TodoSection.today.contains(planned, at: today, calendar: calendar), "an overdue deadline remains visible even with a future plan")
        planned.isCompleted = true
        expect(!TodoSection.today.contains(planned, at: today, calendar: calendar)
               && TodoSection.completed.contains(planned, at: today, calendar: calendar), "completed tasks leave planning views")
        let custom = TodoSection.collection(UUID())
        expect(TodoSection(key: custom.persistenceKey) == custom, "custom-list navigation round-trips through preferences")
        var draft = TodoDraft()
        draft.title = "仅标题"
        expect(draft.isValid && draft.applying(to: nil).estimatedMinutes == nil, "a title-only draft is valid")
        draft.minutes = "２４０"
        expect(draft.isValid && draft.applying(to: nil).estimatedMinutes == 240, "task estimates may exceed one focus session")

        let directory = root.appendingPathComponent("scale")
        var state = FocusState()
        var list = FocusTodoList()
        // Legacy migrations have equal ordering values: this catches a quadratic
        // fallback comparator that a newly created, uniquely ordered list misses.
        list.items = (0..<1_000).map { FocusTodo(title: String(format: "任务 %04d", $0), notes: "本地检索", sortOrder: 0) }
        state.todoList = list
        try write(state, to: directory)
        let model = FocusModel(store: FocusStore(directory: directory), remindersEnabled: false)
        await model.flush()
        model.section = .all
        expect(model.visibleTodoCount == 1_000 && model.visibleTodos.count == 100 && model.hasMoreTodos,
               "a thousand tasks render only the first page")
        expect(model.visibleTodos.map(\.id) == Array(list.items.prefix(100)).map(\.id), "equal-order legacy tasks retain stable insertion order")
        model.loadMoreTodos()
        expect(model.visibleTodos.count == 200, "loading another page grows the visible slice only on demand")
        var searchSamples: [Double] = []
        var listSamples: [Double] = []
        for index in 0..<20 {
            let listStart = CFAbsoluteTimeGetCurrent()
            model.searchText = ""
            listSamples.append((CFAbsoluteTimeGetCurrent() - listStart) * 1_000)
            let searchStart = CFAbsoluteTimeGetCurrent()
            model.searchText = index.isMultiple(of: 2) ? "任务 00" : "本地"
            searchSamples.append((CFAbsoluteTimeGetCurrent() - searchStart) * 1_000)
        }
        let listP95 = listSamples.sorted()[18]
        let searchP95 = searchSamples.sorted()[18]
        print(String(format: "PERF: 1,000 equal-order tasks, list p95 %.2f ms, search p95 %.2f ms (-O)", listP95, searchP95))
        expect(listP95 < 100 && searchP95 < 150, "thousand-task list and search meet the planned response targets")
        model.searchText = "任务 0999"
        expect(model.visibleTodoCount == 1 && model.visibleTodos[0].id == list.items[999].id,
               "search finds tasks beyond the currently loaded page")
        model.searchText = ""
        expect(model.visibleTodos.count == 100, "leaving search resets to bounded paging")
        model.openTodo(list.items[135].id)
        expect(model.selectedTodoID == list.items[135].id && model.visibleTodos.count == 200
               && model.visibleTodos.contains { $0.id == list.items[135].id },
               "opening an off-page task reveals only the page needed to locate it")
        model.todoDraft?.notes = "定位前尚未保存的编辑"
        let sectionBeforeNavigation = model.section
        model.openTodo(list.items[999].id)
        expect(model.selectedTodoID == list.items[135].id && model.section == sectionBeforeNavigation
               && model.todoDraft?.notes == "定位前尚未保存的编辑",
               "opening another task preserves both navigation and an unsaved draft")
        model.startFocus(list.items[999].id)
        await model.flush()
        model.showCurrentTodo()
        expect(model.selectedTodoID == list.items[135].id && model.todoDraft?.id == list.items[135].id,
               "jumping to the active timer task cannot hide a different unsaved draft")
        model.cancelTodoDraft()
        model.showCurrentTodo()
        expect(model.selectedTodoID == list.items[999].id && model.visibleTodos.contains { $0.id == list.items[999].id },
               "after resolving the draft the current focus task can be located beyond page one")
    }

    @MainActor private static func concurrentDraftTest(_ root: URL) async throws {
        let directory = root.appendingPathComponent("concurrent-draft")
        let original = FocusTodo(title: "原始标题")
        try write(FocusState().applying(.addTodo(original)), to: directory)
        let model = FocusModel(store: FocusStore(directory: directory), remindersEnabled: false)
        await model.flush()
        await delay(0.15)
        model.editTodo(original.id)
        model.todoDraft?.title = "本地未保存修改"
        let ready = Pipe(), release = Pipe()
        let editor = try process(arguments: ["--edit-under-lock", directory.path, "另一个进程已更新"],
                                 output: ready, input: release)
        defer { if editor.isRunning { editor.terminate() }; editor.waitUntilExit() }
        expect(ready.fileHandleForReading.readData(ofLength: 1) == Data([1]), "concurrent edit owns the lock before local save")
        model.saveTodo()
        await waitUntil("local task save waits behind the external edit") {
            ((try? descriptors(for: directory.appendingPathComponent("focus-state.lock"))) ?? 0) > 0
        }
        try release.fileHandleForWriting.write(contentsOf: Data([1]))
        await waitUntil("external edit completes") { !editor.isRunning }
        expect(editor.terminationStatus == 0, "concurrent edit test process succeeded")
        await model.flush()
        await waitUntil("model accepts the external task after the write conflict") {
            model.state.todos.first?.title == "另一个进程已更新"
        }
        let disk = try FocusStore(directory: directory).snapshot()
        expect(disk.todos.first?.title == "另一个进程已更新" && disk.todos.first?.isCompleted == true,
               "a stale draft never overwrites external edits or reverses external completion")
        expect(model.error != nil && model.todoDraft?.title == "本地未保存修改" && !model.canUndoTodo,
               "write conflict preserves the local draft and creates no invalid undo receipt")

        model.cancelTodoDraft(); model.error = nil; model.notice = nil
        model.editTodo(original.id)
        model.todoDraft?.notes = "仍在输入的本地备注"
        let external = FocusStore(directory: directory)
        var externallyEdited = try external.snapshot().todos[0]
        externallyEdited.title = "草稿打开后收到的新标题"
        try external.performTodoAction(.upsertTodo(externallyEdited))
        await waitUntil("open draft receives an external model refresh") {
            model.state.todos.first?.title == externallyEdited.title
        }
        model.saveTodo()
        await model.flush()
        let afterRefreshConflict = try external.snapshot().todos[0]
        expect(afterRefreshConflict.title == externallyEdited.title && afterRefreshConflict.notes.isEmpty,
               "a draft cannot silently overwrite an external edit already delivered to the model")
        expect(model.todoDraft?.notes == "仍在输入的本地备注" && (model.error != nil || model.notice != nil),
               "the original draft baseline detects edit conflicts and preserves unsaved text")
    }

    @MainActor private static func focusQueueTests(_ root: URL) async throws {
        let directory = root.appendingPathComponent("focus-queue")
        let collection = TodoCollection(title: "工作")
        let a = FocusTodo(title: "A"), b = FocusTodo(title: "B 已完成", isCompleted: true)
        let c = FocusTodo(title: "C"), d = FocusTodo(title: "D 已删除", deletedAt: Date())
        let e = FocusTodo(title: "E 稍后完成"), f = FocusTodo(title: "F 稍后删除")
        let g = FocusTodo(title: "G", listID: collection.id)
        var state = FocusState()
        var list = FocusTodoList()
        list.items = [a, b, c, d, e, f, g]; list.collections = [collection]
        state.todoList = list
        let oldEnd = Date().addingTimeInterval(-1_000)
        state.logs = [
            FocusLog(id: UUID(), task: "旧整表", startedAt: oldEnd.addingTimeInterval(-60), endedAt: oldEnd,
                     seconds: 60, completed: true, todoIDs: [a.id, c.id]),
            FocusLog(id: UUID(), task: "C", startedAt: oldEnd.addingTimeInterval(-120), endedAt: oldEnd.addingTimeInterval(-60),
                     seconds: 60, completed: true)
        ]
        try write(state, to: directory)
        let model = FocusModel(store: FocusStore(directory: directory), remindersEnabled: false)
        await model.flush()
        expect(model.summary(for: a.id) == nil && model.summary(for: c.id) == nil,
               "legacy multi-task and unlinked logs are not guessed or double-attributed")
        model.editTodo(g.id)
        model.todoDraft?.notes = "保留编辑内容"
        model.startFocusQueue([b.id, c.id, a.id, c.id, d.id, e.id, f.id, g.id, UUID()])
        await model.flush()
        expect(model.focusQueue == [c.id, a.id, e.id, f.id, g.id] && model.queueIndex == 0,
               "queue retains requested order while excluding duplicates, completed, deleted, and absent tasks")
        expect(model.state.sessionTodoIDs == [c.id] && model.state.status == .running,
               "the queue starts only its first task")
        expect(model.todoDraft?.notes == "保留编辑内容", "starting a queue preserves an unrelated task draft")
        await delay(0.03)
        model.advanceFocusQueue()
        await model.flush()
        expect(model.state.sessionTodoIDs == [a.id] && model.queueIndex == 1,
               "explicit skip advances to the next task in order")
        expect(model.state.todos.first { $0.id == c.id }?.isPending == true,
               "skipping never marks the previous task complete")
        expect(model.state.logs.filter { $0.todoIDs == [c.id] }.count == 1,
               "skipping settles exactly one log associated only with the skipped task")
        model.completeTodo(e.id)
        await model.flush()
        model.trashTodo(f.id)
        await model.flush()
        await delay(0.03)
        model.completeTodo(a.id)
        await model.flush()
        expect(model.state.status == .done && model.state.sessionTodoIDs == [a.id] && model.hasNextQueueItem,
               "completion settles the current focus and waits for an explicit next action")
        model.advanceFocusQueue()
        await model.flush()
        expect(model.state.sessionTodoIDs == [g.id] && model.queueIndex == 4,
               "advancing skips tasks completed or deleted after the queue was created")
        let currentSession = model.state.sessionID
        model.startFocusQueue([g.id, c.id])
        expect(model.state.sessionID == currentSession && model.focusQueue == [g.id, c.id],
               "rebuilding a queue around the already running first task does not restart its timer")
        model.section = .collection(collection.id)
        model.selectedTodoID = g.id
        model.quickEntryText = "主窗口未提交标题"
        let captured = try await model.captureInbox(title: "  独立快速录入  ")
        await model.flush()
        let inbox = model.state.todos.first { $0.id == captured }!
        expect(inbox.title == "独立快速录入" && inbox.listID == nil && inbox.plannedDate == nil && inbox.estimatedMinutes == nil,
               "global capture always creates a title-only Inbox task")
        expect(model.section == .collection(collection.id) && model.selectedTodoID == g.id
               && model.quickEntryText == "主窗口未提交标题" && model.todoDraft?.notes == "保留编辑内容",
               "global capture leaves main-window navigation, selection, quick input, and editing intact")
        expect(model.state.sessionID == currentSession && model.state.sessionTodoIDs == [g.id],
               "global capture does not replace the current queue session")
        await delay(0.03)
        model.completeTodo(g.id)
        await model.flush()
        expect(model.todoDraft?.notes == "保留编辑内容", "explicit completion still preserves unsaved task text")
        expect(model.summary(for: c.id)?.sessionCount == 1 && model.summary(for: a.id)?.sessionCount == 1
               && model.summary(for: g.id)?.sessionCount == 1, "each queue item receives exactly its own session summary")
        expect(model.summary(for: b.id) == nil && model.summary(for: e.id) == nil && model.summary(for: f.id) == nil,
               "tasks that were never focused do not acquire other tasks' time")
        let logIDs = model.state.logs.map(\.id)
        model.refresh(); model.refresh()
        await model.flush()
        expect(model.state.logs.map(\.id) == logIDs && Set(logIDs).count == logIDs.count,
               "repeated refresh does not duplicate settled queue logs")

        model.cancelTodoDraft()
        model.startFreeFocus()
        await model.flush()
        let oldSession = model.state.sessionID, oldDeadline = model.state.deadline
        model.startFocusQueue([c.id, captured])
        expect(model.pendingFocusID == c.id && model.state.sessionID == oldSession && model.state.deadline == oldDeadline,
               "starting a different queue asks before ending the old session")
        await delay(0.03)
        model.confirmSwitchFocus()
        await model.flush()
        expect(model.state.sessionID != oldSession && model.state.sessionTodoIDs == [c.id]
               && model.focusQueue == [c.id, captured], "confirmation atomically settles the old session and starts the requested queue")
        let survivingSession = model.state.sessionID, survivingDeadline = model.state.deadline
        model.startFocus(captured)
        expect(model.pendingFocusID == captured, "another task waits for the switch confirmation")
        model.completeTodo(captured)
        await model.flush()
        model.confirmSwitchFocus()
        await model.flush()
        expect(model.state.sessionID == survivingSession && model.state.deadline == survivingDeadline
               && model.state.sessionTodoIDs == [c.id], "a target completed while confirmation is open cannot replace the old session")
        let removedTarget = try await model.captureInbox(title: "确认前删除")
        model.startFocus(removedTarget)
        model.trashTodo(removedTarget)
        await model.flush()
        model.confirmSwitchFocus()
        await model.flush()
        expect(model.state.sessionID == survivingSession && model.state.deadline == survivingDeadline,
               "a target deleted while confirmation is open cannot end the old session")
        let queueBeforeInvalidStart = model.focusQueue
        model.startFocusQueue([b.id, d.id])
        await model.flush()
        expect(model.state.sessionID == survivingSession && model.focusQueue == queueBeforeInvalidStart,
               "an empty effective queue leaves the existing session and queue intact")
    }

    @MainActor private static func customFocusDurationTests(_ root: URL) async throws {
        let directory = root.appendingPathComponent("custom-focus-duration")
        let a = FocusTodo(title: "预计九十分钟", estimatedMinutes: 90)
        let b = FocusTodo(title: "预计十分钟", estimatedMinutes: 10)
        let completed = FocusTodo(title: "已完成", isCompleted: true)
        let deleted = FocusTodo(title: "已删除", deletedAt: Date())
        var seed = FocusState(duration: 33 * 60), list = FocusTodoList()
        list.items = [a, b, completed, deleted]; seed.todoList = list
        try write(seed, to: directory)
        let model = FocusModel(store: FocusStore(directory: directory), remindersEnabled: false)
        await model.flush()
        let file = directory.appendingPathComponent("focus-state.json")
        let idleState = model.state, idleFile = try FileSnapshot(file)
        for invalid in [Int.min, -1, 0, 181, Int.max] {
            model.startFocus(a.id, minutes: invalid)
            await model.flush()
            let unchangedFile = try FileSnapshot(file)
            expect(model.state == idleState && model.pendingFocusID == nil && !model.isBusy
                   && unchangedFile == idleFile,
                   "an out-of-range custom duration cannot overflow, start, or write a session")
        }
        for invalidID in [completed.id, deleted.id, UUID()] {
            model.startFocus(invalidID, minutes: 17)
            await model.flush()
            let unchangedFile = try FileSnapshot(file)
            expect(model.state == idleState && unchangedFile == idleFile,
                   "custom focus refuses completed, deleted, and missing tasks without a partial write")
        }

        model.startFocus(a.id)
        await model.flush()
        expect(model.state.status == .running && model.state.sessionTodoIDs == [a.id]
               && model.state.duration == 33 * 60,
               "omitting custom minutes preserves the existing focus default rather than using the task estimate")
        let defaultSession = model.state.sessionID, defaultState = model.state
        model.showFocus = false
        model.startFocus(a.id)
        await model.flush()
        expect(model.showFocus && model.pendingFocusID == nil && model.state == defaultState,
               "starting the active task with default minutes only reveals its existing timer")

        let defaultFile = try FileSnapshot(file)
        model.startFocus(a.id, minutes: 1)
        expect(model.pendingFocusID == a.id && model.state == defaultState && !model.isBusy,
               "a custom duration for the active task waits for confirmation even at the lower bound")
        model.pendingFocusID = nil
        model.confirmSwitchFocus()
        await model.flush()
        let cancelledSameTaskFile = try FileSnapshot(file)
        expect(model.state == defaultState && cancelledSameTaskFile == defaultFile,
               "cancelling a same-task duration change leaves the timer and disk untouched")

        model.startFocus(a.id, minutes: 180)
        expect(model.pendingFocusID == a.id && model.state == defaultState,
               "the upper-bound duration is also pending until explicitly confirmed")
        model.confirmSwitchFocus()
        await model.flush()
        expect(model.state.status == .running && model.state.sessionID != defaultSession
               && model.state.sessionTodoIDs == [a.id] && model.state.duration == 180 * 60,
               "confirming same-task custom focus starts a fresh session with the exact upper-bound duration")
        expect(model.state.logs.filter { $0.id == defaultSession }.count == 1
               && model.state.logs.first { $0.id == defaultSession }?.todoIDs == [a.id],
               "restarting the same task settles its old session exactly once")
        expect(model.state.todos.first { $0.id == a.id }?.estimatedMinutes == 90
               && model.state.focusDuration == 180 * 60 && model.pendingFocusID == nil,
               "custom session minutes become the remembered default without changing the task estimate")

        model.send(.pause)
        await model.flush()
        let paused = model.state, pausedFile = try FileSnapshot(file)
        model.startFocus(a.id, minutes: 1)
        expect(model.pendingFocusID == a.id && model.state == paused,
               "a paused session also requires confirmation before changing its duration")
        model.pendingFocusID = nil
        await model.flush()
        let cancelledPausedFile = try FileSnapshot(file)
        expect(model.state == paused && cancelledPausedFile == pausedFile,
               "cancelling custom focus preserves a paused session and its remaining time")
        model.startFocus(a.id, minutes: 1)
        model.confirmSwitchFocus()
        await model.flush()
        expect(model.state.status == .running && model.state.sessionID != paused.sessionID
               && model.state.duration == 60 && model.state.sessionTodoIDs == [a.id],
               "confirming from pause starts a new lower-bound session instead of resuming the old duration")
        expect(model.state.logs.filter { $0.id == paused.sessionID }.count == 1,
               "replacing a paused session settles that session only once")

        let beforeSwitch = model.state, beforeSwitchFile = try FileSnapshot(file)
        model.startFocus(b.id, minutes: 47)
        expect(model.pendingFocusID == b.id && model.state == beforeSwitch,
               "switching tasks with custom minutes leaves the current timer running until confirmation")
        model.pendingFocusID = nil
        await model.flush()
        let cancelledSwitchFile = try FileSnapshot(file)
        expect(model.state == beforeSwitch && cancelledSwitchFile == beforeSwitchFile,
               "cancelling a different-task custom focus does not select or reschedule anything")
        model.startFocus(b.id, minutes: 47)
        model.confirmSwitchFocus()
        await model.flush()
        expect(model.state.status == .running && model.state.sessionTodoIDs == [b.id]
               && model.state.sessionID != beforeSwitch.sessionID && model.state.duration == 47 * 60,
               "confirming another task applies its custom duration in the new session")
        expect(model.state.logs.filter { $0.id == beforeSwitch.sessionID }.count == 1
               && model.state.todos.first { $0.id == b.id }?.estimatedMinutes == 10,
               "task switching preserves its estimate and records the replaced session once")

        let beforeQueue = model.state
        model.startFocus(a.id, minutes: 79)
        model.startFocusQueue([a.id, b.id])
        expect(model.pendingFocusID == a.id && model.state == beforeQueue,
               "replacing a pending custom request with a queue still awaits confirmation")
        model.confirmSwitchFocus()
        await model.flush()
        expect(model.state.duration == 47 * 60 && model.state.sessionTodoIDs == [a.id]
               && model.focusQueue == [a.id, b.id],
               "a pending queue uses the saved default instead of the unconfirmed custom request")
        model.advanceFocusQueue()
        await model.flush()
        expect(model.state.duration == 47 * 60 && model.state.sessionTodoIDs == [b.id],
               "the next queued task uses the saved default without leaking the cancelled custom minutes")

        model.send(.finish)
        await model.flush()
        model.send(.reset)
        await model.flush()
        var published: [FocusState] = []
        let observation = model.$state.dropFirst().sink { published.append($0) }
        model.startFocus(a.id, minutes: 17)
        await model.flush()
        observation.cancel()
        expect(published.count == 1 && published[0].status == .running
               && published[0].sessionTodoIDs == [a.id] && published[0].duration == 17 * 60,
               "idle custom focus publishes only the complete target-duration-start transaction")
        let persisted = try FocusStore(directory: directory).snapshot()
        expect(persisted == model.state && persisted.focusTarget == .todo(a.id) && persisted.focusDuration == 17 * 60
               && persisted.todos.first { $0.id == a.id }?.estimatedMinutes == 90
               && persisted.todos.first { $0.id == b.id }?.estimatedMinutes == 10,
               "idle custom focus durably stores its session without rewriting either estimate")

        let surviving = model.state
        model.startFocus(b.id, minutes: 29)
        model.completeTodo(b.id)
        await model.flush()
        model.confirmSwitchFocus()
        await model.flush()
        expect(model.state.sessionID == surviving.sessionID && model.state.deadline == surviving.deadline
               && model.state.duration == surviving.duration && model.state.logs == surviving.logs,
               "a custom-focus target completed before confirmation cannot end or alter the original session")
        expect(model.pendingFocusID == nil && model.notice != nil,
               "an invalidated custom-focus request closes with visible feedback")
        model.send(.finish)
        await model.flush()
        model.startFocus(a.id)
        await model.flush()
        expect(model.state.status == .running && model.state.duration == 17 * 60
               && model.state.todos.first { $0.id == a.id }?.estimatedMinutes == 90,
               "a later default start reuses the last confirmed custom duration without changing the estimate")
    }

    @MainActor private static func customFocusInvalidationRaceTest(_ root: URL) async throws {
        let directory = root.appendingPathComponent("custom-focus-race")
        let target = FocusTodo(title: "确认时仍待办", estimatedMinutes: 90)
        let current = FocusTodo(title: "正在专注", estimatedMinutes: 20)
        var seed = FocusState(), list = FocusTodoList()
        // The existing test worker completes the first stored task while holding
        // the cross-process lock, after the model has accepted the confirmation.
        list.items = [target, current]; seed.todoList = list
        try write(seed, to: directory)
        let store = FocusStore(directory: directory)
        let model = FocusModel(store: store, remindersEnabled: false)
        await model.flush()
        model.startFocus(current.id, minutes: 19)
        await model.flush()
        await delay(0.15)
        let original = model.state
        model.startFocus(target.id, minutes: 35)
        let ready = Pipe(), release = Pipe()
        let editor = try process(arguments: ["--edit-under-lock", directory.path, "锁内已完成"],
                                 output: ready, input: release)
        defer { if editor.isRunning { editor.terminate() }; editor.waitUntilExit() }
        expect(ready.fileHandleForReading.readData(ofLength: 1) == Data([1]),
               "custom-focus race owns the file lock before confirmation starts")
        model.confirmSwitchFocus()
        await waitUntil("custom-focus transaction waits behind the external completion") {
            ((try? descriptors(for: directory.appendingPathComponent("focus-state.lock"))) ?? 0) > 0
        }
        expect(model.isBusy && model.state.sessionID == original.sessionID,
               "an in-flight custom-focus confirmation does not expose a prematurely finished session")
        try release.fileHandleForWriting.write(contentsOf: Data([1]))
        await waitUntil("external completion releases the custom-focus transaction") { !editor.isRunning }
        expect(editor.terminationStatus == 0, "custom-focus race worker completed successfully")
        await model.flush()
        let persisted = try store.snapshot()
        expect(persisted.todos.first { $0.id == target.id }?.isCompleted == true,
               "the concurrent completion remains saved after the custom-focus transaction fails")
        expect(persisted.sessionID == original.sessionID && persisted.deadline == original.deadline
               && persisted.sessionTodoIDs == original.sessionTodoIDs && persisted.duration == original.duration
               && persisted.focusDuration == original.focusDuration && persisted.logs == original.logs,
               "target invalidation rolls back finish, selection, remembered duration, and start together")
        expect(model.error != nil && model.pendingFocusID == nil,
               "a rejected custom-focus transaction reports failure instead of pretending it started")
    }

    @MainActor private static func customFocusBusyConfirmationTest(_ root: URL) async throws {
        let directory = root.appendingPathComponent("custom-focus-busy-confirmation")
        let current = FocusTodo(title: "保存期间继续计时"), target = FocusTodo(title: "确认后切换")
        var seed = FocusState(), list = FocusTodoList()
        list.items = [current, target]; seed.todoList = list
        try write(seed, to: directory)
        let model = FocusModel(store: FocusStore(directory: directory), remindersEnabled: false)
        await model.flush()
        model.startFocus(current.id, minutes: 13)
        await model.flush()
        await delay(0.15)
        let original = model.state
        model.startFocus(target.id, minutes: 42)
        let ready = Pipe()
        let holder = try process(arguments: ["--hold-lock", directory.path], output: ready)
        defer { if holder.isRunning { holder.terminate() }; holder.waitUntilExit() }
        expect(ready.fileHandleForReading.readData(ofLength: 1) == Data([1]),
               "busy-confirmation probe holds the file lock before quick capture")
        let capture = Task { @MainActor in try await model.captureInbox(title: "切换确认中的快速录入") }
        await waitUntil("quick capture blocks on storage while the focus confirmation is open") {
            model.isBusy && ((try? descriptors(for: directory.appendingPathComponent("focus-state.lock"))) ?? 0) > 0
        }
        model.confirmSwitchFocus()
        expect(model.pendingFocusID == nil && model.isBusy && model.state == original,
               "confirming during quick capture queues the transition without changing the current timer early")
        holder.terminate(); holder.waitUntilExit()
        let captured = try await capture.value
        await model.flush()
        expect(model.state.todos.contains { $0.id == captured && $0.title == "切换确认中的快速录入" && $0.listID == nil },
               "quick capture completes successfully ahead of the queued focus confirmation")
        expect(model.state.status == .running && model.state.sessionTodoIDs == [target.id]
               && model.state.duration == 42 * 60 && model.state.focusDuration == 42 * 60,
               "a confirmed custom switch is not dropped when quick capture was already saving")
        expect(model.state.logs.filter { $0.id == original.sessionID }.count == 1
               && model.error == nil && !model.isBusy,
               "the queued confirmation settles the old round once and flush waits for both writes")
    }

    @MainActor private static func modelStressTest(_ root: URL) async throws {
        let directory = root.appendingPathComponent("model-stress")
        var seed = FocusState(), list = FocusTodoList()
        list.items = (0..<999).map { FocusTodo(title: "基准事项 \($0)", notes: "仅模型压力测试", sortOrder: $0) }
        seed.todoList = list
        try write(seed, to: directory)
        var model: FocusModel? = FocusModel(store: FocusStore(directory: directory), remindersEnabled: false)
        await model!.flush()
        model!.section = .all
        var persistenceSamples: [Double] = []
        var baseline: RuntimeMemory?, midpoint: RuntimeMemory?
        for round in 0..<110 {
            let current = model!
            let isMeasured = round >= 10
            var started = CFAbsoluteTimeGetCurrent()
            let id = try await current.captureInbox(title: "压力录入 \(round)")
            await current.flush()
            if isMeasured { persistenceSamples.append((CFAbsoluteTimeGetCurrent() - started) * 1_000) }
            current.searchText = "压力录入 \(round)"
            expect(current.visibleTodoCount == 1, "stress search locates the newly persisted task")
            current.openTodo(id)
            expect(current.todoDraft?.id == id, "stress expand opens the selected task")
            current.cancelTodoDraft()
            started = CFAbsoluteTimeGetCurrent()
            current.completeTodo(id)
            await current.flush()
            if isMeasured { persistenceSamples.append((CFAbsoluteTimeGetCurrent() - started) * 1_000) }
            expect(current.state.todos.first { $0.id == id }?.isCompleted == true, "stress completion persists")
            started = CFAbsoluteTimeGetCurrent()
            current.undoTodoChange()
            await current.flush()
            if isMeasured { persistenceSamples.append((CFAbsoluteTimeGetCurrent() - started) * 1_000) }
            expect(current.state.todos.first { $0.id == id }?.isPending == true, "stress undo restores the task")
            // Undo insertion as well, so every round returns to the same data size.
            started = CFAbsoluteTimeGetCurrent()
            current.undoTodoChange()
            await current.flush()
            if isMeasured { persistenceSamples.append((CFAbsoluteTimeGetCurrent() - started) * 1_000) }
            current.searchText = ""; current.section = .all
            expect(current.state.todos.count == 999 && current.visibleTodos.count == 100 && current.error == nil,
                   "stress cleanup restores a bounded page and fixed dataset")
            if round == 9 { baseline = try RuntimeMemory.sample() }
            if round == 59 { midpoint = try RuntimeMemory.sample() }
        }
        await model!.flush()
        let after = try RuntimeMemory.sample()
        let reference = WeakReference(model)
        model = nil
        await waitUntil("stress model and its undo/draft state release") { reference.value == nil }
        await waitUntil("stress release closes its store watcher") { (try? descriptors(for: directory)) == 0 }
        await delay(0.1)
        let released = try RuntimeMemory.sample()
        let p95 = persistenceSamples.sorted()[Int(Double(persistenceSamples.count - 1) * 0.95)]
        print(String(format: "PERF: model-only 100 rounds after 10 warmups, 999 fixed tasks, %d durable transactions, p95 %.2f ms", persistenceSamples.count, p95))
        print("RESOURCE: same process, model-only baseline [\(baseline!.description)], 50 rounds [\(midpoint!.description)], 100 rounds [\(after.description)], model released [\(released.description)]")
        expect(persistenceSamples.count == 400, "model stress measures every insert, complete, restore and insertion undo")
        expect(after.footprint <= midpoint!.footprint + 16 * 1_048_576,
               "the warmed fixed-size workload does not accumulate large per-round allocations")
    }

    @MainActor private static func modelReleaseTest(_ root: URL) async throws {
        let directory = root.appendingPathComponent("release")
        try write(FocusState(duration: 60, task: "release").applying(.start), to: directory)
        var model: FocusModel? = FocusModel(store: FocusStore(directory: directory), remindersEnabled: false)
        let released = WeakReference(model)
        await delay(0.1)
        model = nil
        await waitUntil("model observers and an armed deadline do not retain the model") { released.value == nil }
        await waitUntil("model release closes the directory watcher") { (try? descriptors(for: directory)) == 0 }
    }

    @MainActor static func main() throws {
        if try runWorker() { return }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterglow-runtime-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var finished = false
        var failure: Error?
        Task { @MainActor in
            do {
                await reminderTests()
                try await observationTests(directory)
                try await modelTests(directory)
                try await sidebarPreferencesTest(directory)
                try await asynchronousQueueTests(directory)
                try await concurrentDraftTest(directory)
                try await presentationAndScaleTests(directory)
                try await focusQueueTests(directory)
                try await customFocusDurationTests(directory)
                try await customFocusInvalidationRaceTest(directory)
                try await customFocusBusyConfirmationTest(directory)
                try await modelStressTest(directory)
                try await modelReleaseTest(directory)
            } catch { failure = error }
            finished = true
        }
        let timeout = Date().addingTimeInterval(180)
        while !finished, Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(finished, "runtime regression suite finishes within its timeout")
        if let failure { throw failure }
        print("PASS: \(checks) runtime checks; notification races, asynchronous storage, reversible todos, thousand-task responsiveness, one-shot completion, and no idle polling.")
    }
}
