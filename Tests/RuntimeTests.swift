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

    private static func process(arguments: [String], output: Pipe? = nil) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = arguments
        if let output { child.standardOutput = output }
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
        expect(active.reminders == nil && active.error == nil, "isolated model avoids the system notification service")
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

        active.send(.start)
        active.send(.pause)
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
        // No manual refresh or other file writes: only the production one-shot
        // timer can settle this already observed session at its deadline.
        await waitUntil("one-shot deadline settles the session", timeout: 3) { active.state.status == .done }
        expect(active.state.logs.count == 1 && active.state.logs[0].completed, "deadline records exactly one completed session")
        expect(abs(active.state.logs[0].endedAt.timeIntervalSince(almostDone.deadline!)) < 0.001,
               "completion retains the original deadline")
        let completedFile = try FileSnapshot(directory.appendingPathComponent("focus-state.json"))
        active.refresh()
        active.refresh()
        await delay(0.15)
        expect(completions == 1 && active.state.logs.count == 1, "watcher echoes and repeated refreshes do not duplicate completion")
        expect(try FileSnapshot(directory.appendingPathComponent("focus-state.json")) == completedFile,
               "settled sessions do not repeatedly rewrite history")

        let cancellation = FocusState(duration: 60).applying(.start, at: Date().addingTimeInterval(-59))
        try write(cancellation, to: directory)
        await waitUntil("new external session replaces the previous deadline") { active.state.sessionID == cancellation.sessionID }
        active.send(.pause)
        await delay(1.2)
        expect(active.state.status == .paused && active.state.logs.isEmpty, "pausing invalidates the pending deadline callback")
        expect(active.error == nil, "event-driven model completes without storage errors")
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
                try await modelReleaseTest(directory)
            } catch { failure = error }
            finished = true
        }
        let timeout = Date().addingTimeInterval(45)
        while !finished, Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(finished, "runtime regression suite finishes within its timeout")
        if let failure { throw failure }
        print("PASS: \(checks) runtime checks; notification races, atomic directory events, cross-process updates, one-shot completion, and no idle polling.")
    }
}
