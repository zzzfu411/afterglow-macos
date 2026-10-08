import Foundation

private enum DeliveryError: Error { case unavailable }

@MainActor
private final class ControlledTodoDelivery: TodoReminderDelivery {
    var status: ReminderAuthorization = .allowed
    var grantsPermission = true
    var permissionError = false
    var holdNextAuthorization = false
    var holdNextPermission = false
    var holdNextPendingRead = false
    var holdNextSchedule = false
    var failuresRemaining: [UUID: Int] = [:]
    var pending: [PendingTodoReminder] = []
    private(set) var authorizationReads = 0
    private(set) var permissionRequests = 0
    private(set) var schedules: [TodoReminder] = []
    private(set) var cancellations: [String] = []
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var permissionContinuation: CheckedContinuation<Void, Never>?
    private var pendingContinuation: CheckedContinuation<Void, Never>?
    private var scheduleContinuation: CheckedContinuation<Void, Never>?
    var isAuthorizationSuspended: Bool { authorizationContinuation != nil }
    var isPermissionSuspended: Bool { permissionContinuation != nil }
    var isPendingReadSuspended: Bool { pendingContinuation != nil }
    var isScheduleSuspended: Bool { scheduleContinuation != nil }

    func authorization() async -> ReminderAuthorization {
        authorizationReads += 1
        if holdNextAuthorization {
            holdNextAuthorization = false
            await withCheckedContinuation { authorizationContinuation = $0 }
        }
        return status
    }

    func requestAuthorization() async throws -> Bool {
        permissionRequests += 1
        if holdNextPermission {
            holdNextPermission = false
            await withCheckedContinuation { permissionContinuation = $0 }
        }
        if permissionError { throw DeliveryError.unavailable }
        status = grantsPermission ? .allowed : .denied
        return grantsPermission
    }

    func pendingRequests() async -> [PendingTodoReminder] {
        // Return a captured snapshot, as the system service can do.
        let snapshot = pending
        if holdNextPendingRead {
            holdNextPendingRead = false
            await withCheckedContinuation { pendingContinuation = $0 }
        }
        return snapshot
    }

    func schedule(_ reminder: TodoReminder) async throws {
        schedules.append(reminder)
        if holdNextSchedule {
            holdNextSchedule = false
            await withCheckedContinuation { scheduleContinuation = $0 }
        }
        if failuresRemaining[reminder.taskID, default: 0] > 0 {
            failuresRemaining[reminder.taskID, default: 0] -= 1
            throw DeliveryError.unavailable
        }
        pending.removeAll { $0.identifier == reminder.identifier }
        pending.append(PendingTodoReminder(identifier: reminder.identifier, reminder: reminder))
    }

    func cancel(identifiers: [String]) {
        cancellations.append(contentsOf: identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func releaseAuthorization() {
        let continuation = authorizationContinuation
        authorizationContinuation = nil
        continuation?.resume()
    }
    func releasePendingRead() {
        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume()
    }
    func releasePermission() {
        let continuation = permissionContinuation
        permissionContinuation = nil
        continuation?.resume()
    }
    func releaseSchedule() {
        let continuation = scheduleContinuation
        scheduleContinuation = nil
        continuation?.resume()
    }

    var reminders: [TodoReminder] { pending.compactMap(\.reminder) }
}

@main
struct TodoReminderTests {
    @MainActor private static var checks = 0
    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private static let sessionIdentifier = "afterglow.session-end"

    @MainActor private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        checks += 1
    }

    @MainActor private static func waitUntil(_ message: String, _ condition: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        expect(condition(), message)
    }

    private static func task(_ title: String = "整理笔记", offset: TimeInterval? = 600,
                             completed: Bool = false, deleted: Bool = false) -> FocusTodo {
        var todo = FocusTodo(title: title, minutes: 25, isCompleted: completed)
        todo.reminderDate = offset.map { epoch.addingTimeInterval($0) }
        todo.deletedAt = deleted ? epoch : nil
        return todo
    }

    private static func reminder(_ todo: FocusTodo) -> TodoReminder {
        TodoReminder(taskID: todo.id, title: todo.title, date: todo.reminderDate!)
    }

    private static func pending(_ todo: FocusTodo) -> PendingTodoReminder {
        let snapshot = reminder(todo)
        return PendingTodoReminder(identifier: snapshot.identifier, reminder: snapshot)
    }

    @MainActor private static func filteringAndOwnershipTests() async {
        let delivery = ControlledTodoDelivery()
        let foreign = PendingTodoReminder(identifier: sessionIdentifier, reminder: nil)
        let malformed = PendingTodoReminder(identifier: TodoReminder.identifierPrefix + "obsolete", reminder: nil)
        let removed = task("已删除的存储记录")
        delivery.pending = [foreign, malformed, pending(removed)]
        let scheduler = TodoReminders(delivery: delivery, now: { epoch })
        let valid = task()
        var dueOnly = task("只有截止日期", offset: nil)
        dueOnly.dueDate = epoch.addingTimeInterval(50)
        var invalid = task("无效日期")
        invalid.reminderDate = Date(timeIntervalSince1970: .infinity)
        let completed = task(completed: true)
        let deleted = task(deleted: true)
        scheduler.reconcile(todos: [task(offset: -1), task(offset: 0), dueOnly, completed, deleted, invalid, valid])
        await scheduler.flush()
        expect(delivery.reminders == [reminder(valid)], "only an explicit future reminder on a pending task schedules")
        expect(delivery.pending.contains(foreign), "session notification survives todo reconciliation")
        expect(!delivery.cancellations.contains(sessionIdentifier), "the timer identifier is never passed to cancel")
        expect(delivery.cancellations.contains(malformed.identifier), "malformed owned requests are cleaned up")
        expect(delivery.cancellations.contains(reminder(removed).identifier), "removed tasks cancel persisted requests")
        expect(delivery.permissionRequests == 0, "reconciliation with allowed permission does not prompt")
        expect(scheduler.issue == nil && scheduler.deferredCount == 0, "successful scheduling has no warning")
        let scheduleCount = delivery.schedules.count
        scheduler.reconcile(todos: [valid])
        await scheduler.flush()
        expect(delivery.schedules.count == scheduleCount, "unchanged reminder is not repeatedly submitted")

        let restarted = TodoReminders(delivery: delivery, now: { epoch })
        restarted.reconcile(todos: [valid])
        await restarted.flush()
        expect(delivery.schedules.count == scheduleCount, "relaunch recognizes existing system requests")
        restarted.reconcile(todos: [])
        await restarted.flush()
        expect(delivery.pending == [foreign], "empty task data removes only task reminders")
    }

    @MainActor private static func editCompleteRestoreTests() async {
        let delivery = ControlledTodoDelivery()
        let scheduler = TodoReminders(delivery: delivery, now: { epoch })
        var todo = task()
        scheduler.reconcile(todos: [todo])
        await scheduler.flush()
        todo.title = "更新后的标题"
        todo.reminderDate = epoch.addingTimeInterval(900)
        scheduler.reconcile(todos: [todo])
        await scheduler.flush()
        expect(delivery.reminders == [reminder(todo)], "editing replaces both date and notification title")
        expect(delivery.cancellations.contains(reminder(todo).identifier), "outdated date is removed before replacement")
        todo.isCompleted = true
        scheduler.reconcile(todos: [todo])
        await scheduler.flush()
        expect(delivery.reminders.isEmpty, "completing cancels the pending reminder")
        todo.isCompleted = false
        scheduler.reconcile(todos: [todo])
        await scheduler.flush()
        expect(delivery.reminders == [reminder(todo)], "undo completion restores a still-future reminder")
        todo.deletedAt = epoch
        scheduler.reconcile(todos: [todo])
        await scheduler.flush()
        expect(delivery.reminders.isEmpty, "moving to trash cancels the reminder")
        todo.deletedAt = nil
        todo.reminderDate = nil
        todo.dueDate = epoch.addingTimeInterval(900)
        scheduler.reconcile(todos: [todo])
        await scheduler.flush()
        expect(delivery.reminders.isEmpty, "disabling reminders never falls back to the deadline")
    }

    @MainActor private static func authorizationTests() async {
        let delivery = ControlledTodoDelivery()
        delivery.status = .unknown
        let scheduler = TodoReminders(delivery: delivery, now: { epoch })
        let todo = task()
        scheduler.reconcile(todos: [todo])
        await scheduler.flush()
        expect(delivery.permissionRequests == 0 && delivery.schedules.isEmpty, "background reconciliation never requests permission")
        await scheduler.refreshAuthorization()
        expect(delivery.permissionRequests == 0, "authorization refresh never prompts")
        scheduler.reconcile(todos: [], requestPermission: true)
        await scheduler.flush()
        expect(delivery.permissionRequests == 0, "an empty or disabled reminder never prompts")
        scheduler.reconcile(todos: [task(offset: -1)], requestPermission: true)
        await scheduler.flush()
        expect(delivery.permissionRequests == 0, "an expired reminder never prompts")
        scheduler.reconcile(todos: [todo], requestPermission: true)
        await scheduler.flush()
        expect(delivery.permissionRequests == 1 && scheduler.authorization == .allowed, "explicit save may request notification permission")
        expect(delivery.reminders == [reminder(todo)], "granting permission schedules the saved reminder")

        delivery.status = .denied
        await scheduler.refreshAuthorization()
        expect(delivery.reminders.isEmpty && scheduler.authorization == .denied, "revoked authorization cancels pending task notifications")
        expect(scheduler.issue != nil, "denial is visible without discarding the task")
        scheduler.reconcile(todos: [todo], requestPermission: true)
        await scheduler.flush()
        expect(delivery.permissionRequests == 1, "denied permission is not repeatedly requested")
        delivery.status = .allowed
        await scheduler.refreshAuthorization()
        expect(delivery.reminders == [reminder(todo)] && scheduler.issue == nil, "returning from system settings restores reminders")

        let deniedDelivery = ControlledTodoDelivery()
        deniedDelivery.status = .unknown
        deniedDelivery.grantsPermission = false
        let deniedScheduler = TodoReminders(delivery: deniedDelivery, now: { epoch })
        deniedScheduler.reconcile(todos: [todo], requestPermission: true)
        await deniedScheduler.flush()
        expect(deniedScheduler.authorization == .denied && deniedDelivery.reminders.isEmpty, "a declined prompt leaves all reminders unscheduled")

        let errorDelivery = ControlledTodoDelivery()
        errorDelivery.status = .unknown
        errorDelivery.permissionError = true
        let errorScheduler = TodoReminders(delivery: errorDelivery, now: { epoch })
        errorScheduler.reconcile(todos: [todo], requestPermission: true)
        await errorScheduler.flush()
        expect(errorScheduler.issue != nil && errorDelivery.reminders.isEmpty, "permission service failure is reported")
        errorDelivery.permissionError = false
        errorScheduler.reconcile(todos: [todo], requestPermission: true)
        await errorScheduler.flush()
        expect(errorScheduler.issue == nil && errorDelivery.reminders.count == 1, "a later explicit save retries a failed permission request")
    }

    @MainActor private static func reentrancyTests() async {
        let delivery = ControlledTodoDelivery()
        delivery.holdNextSchedule = true
        let scheduler = TodoReminders(delivery: delivery, now: { epoch })
        var todo = task()
        scheduler.reconcile(todos: [todo])
        await waitUntil("notification add is suspended") { delivery.isScheduleSuspended }
        todo.isCompleted = true
        scheduler.reconcile(todos: [todo])
        delivery.releaseSchedule()
        await scheduler.flush()
        expect(delivery.reminders.isEmpty, "completion removes an add accepted after completion")

        todo.isCompleted = false
        delivery.holdNextSchedule = true
        scheduler.reconcile(todos: [todo])
        await waitUntil("old date add is suspended") { delivery.isScheduleSuspended }
        todo.reminderDate = epoch.addingTimeInterval(1_000)
        scheduler.reconcile(todos: [todo])
        todo.title = "最新编辑"
        scheduler.reconcile(todos: [todo])
        delivery.releaseSchedule()
        await scheduler.flush()
        expect(delivery.reminders == [reminder(todo)], "rapid edits leave only the latest notification snapshot")

        delivery.holdNextPendingRead = true
        scheduler.reconcile(todos: [todo])
        await waitUntil("pending request read is suspended") { delivery.isPendingReadSuspended }
        scheduler.reconcile(todos: [])
        delivery.releasePendingRead()
        await scheduler.flush()
        expect(delivery.reminders.isEmpty, "a stale pending read cannot resurrect a deleted task")

        let authDelivery = ControlledTodoDelivery()
        authDelivery.status = .unknown
        authDelivery.holdNextAuthorization = true
        let authScheduler = TodoReminders(delivery: authDelivery, now: { epoch })
        authScheduler.reconcile(todos: [todo], requestPermission: true)
        await waitUntil("authorization read is suspended") { authDelivery.isAuthorizationSuspended }
        authScheduler.reconcile(todos: [])
        authDelivery.releaseAuthorization()
        await authScheduler.flush()
        expect(authDelivery.permissionRequests == 0, "removing the reminder before authorization finishes suppresses the prompt")
        expect(authDelivery.schedules.isEmpty, "authorization reentrancy never schedules the old task")

        authDelivery.holdNextPermission = true
        authScheduler.reconcile(todos: [todo], requestPermission: true)
        await waitUntil("permission dialog is suspended") { authDelivery.isPermissionSuspended }
        authScheduler.reconcile(todos: [])
        authDelivery.releasePermission()
        await authScheduler.flush()
        expect(authScheduler.authorization == .allowed && authDelivery.schedules.isEmpty,
               "granting an in-flight permission request does not resurrect a removed task")
    }

    @MainActor private static func capacityAndClockTests() async {
        let delivery = ControlledTodoDelivery()
        delivery.pending = [PendingTodoReminder(identifier: sessionIdentifier, reminder: nil)]
        var clock = epoch
        let scheduler = TodoReminders(delivery: delivery, now: { clock })
        let todos = (1...55).map { task("任务 \($0)", offset: TimeInterval($0 * 100)) }
        scheduler.reconcile(todos: todos.reversed())
        await scheduler.flush()
        expect(delivery.reminders.count == TodoReminders.maximumPendingCount, "pending task notifications are bounded")
        expect(Set(delivery.reminders.map(\.taskID)) == Set(todos.prefix(48).map(\.id)), "the nearest reminder dates win regardless of task order")
        expect(scheduler.deferredCount == 7 && scheduler.issue?.contains("后台") == true, "deferred coverage is explicitly reported")
        expect(delivery.pending.contains { $0.identifier == sessionIdentifier }, "batch limit reserves the existing session notification")
        clock = epoch.addingTimeInterval(650)
        // Model notifications that the system delivered while the app was inactive.
        delivery.pending.removeAll { $0.reminder.map { $0.date <= clock } ?? false }
        await scheduler.refreshAuthorization()
        expect(delivery.reminders.count == 48 && scheduler.deferredCount == 1, "activation fills slots freed by delivery")
        expect(delivery.reminders.allSatisfy { $0.date > clock }, "activation does not replay expired reminders")

        let graceDelivery = ControlledTodoDelivery()
        var graceClock = epoch
        let graceScheduler = TodoReminders(delivery: graceDelivery, now: { graceClock })
        var near = task(offset: 1)
        graceScheduler.reconcile(todos: [near])
        await graceScheduler.flush()
        graceClock = epoch.addingTimeInterval(1)
        graceScheduler.reconcile(todos: [near])
        await graceScheduler.flush()
        expect(graceDelivery.reminders.count == 1, "a simultaneous activation does not cancel delivery at its firing time")
        expect(graceDelivery.schedules.count == 1, "delivery grace does not submit the past reminder again")
        near.isCompleted = true
        graceScheduler.reconcile(todos: [near])
        await graceScheduler.flush()
        expect(graceDelivery.reminders.isEmpty, "completion cancels even during the delivery grace interval")

        near.isCompleted = false
        graceDelivery.pending = [pending(near)]
        graceClock = epoch.addingTimeInterval(62)
        graceScheduler.reconcile(todos: [near])
        await graceScheduler.flush()
        expect(graceDelivery.reminders.isEmpty, "expired lingering requests are eventually cleaned up")
    }

    @MainActor private static func failureAndIdleTests() async {
        let delivery = ControlledTodoDelivery()
        let scheduler = TodoReminders(delivery: delivery, now: { epoch })
        let first = task("失败后重试", offset: 100)
        let second = task("继续排入", offset: 200)
        delivery.failuresRemaining[first.id] = 1
        scheduler.reconcile(todos: [first, second])
        await scheduler.flush()
        expect(delivery.reminders == [reminder(second)], "one failed add does not prevent other reminders")
        expect(scheduler.issue?.contains("1") == true, "partial failure reports the failed count")
        await scheduler.refreshAuthorization()
        expect(Set(delivery.reminders.map(\.taskID)) == Set([first.id, second.id]), "the next event retries only missing requests")
        expect(delivery.schedules.filter { $0.taskID == second.id }.count == 1, "retry does not resubmit successful requests")
        expect(scheduler.issue == nil, "successful retry clears the old error")

        var edited = first
        edited.reminderDate = epoch.addingTimeInterval(1_000)
        delivery.failuresRemaining[first.id] = 1
        scheduler.reconcile(todos: [edited, second])
        await scheduler.flush()
        expect(!delivery.reminders.contains { $0.taskID == first.id }, "failed rescheduling does not leave an obsolete time armed")
        expect(delivery.reminders.contains(reminder(second)), "rescheduling failure does not cancel unrelated tasks")
        scheduler.reconcile(todos: [edited, second])
        await scheduler.flush()
        expect(delivery.reminders.contains(reminder(edited)), "later data reconciliation retries failed rescheduling")

        let authorizationReads = delivery.authorizationReads
        let schedules = delivery.schedules.count
        let cancellations = delivery.cancellations.count
        try? await Task.sleep(nanoseconds: 100_000_000)
        expect(delivery.authorizationReads == authorizationReads && delivery.schedules.count == schedules
            && delivery.cancellations.count == cancellations, "idle scheduler performs no periodic work")
    }

    @MainActor static func main() async {
        await filteringAndOwnershipTests()
        await editCompleteRestoreTests()
        await authorizationTests()
        await reentrancyTests()
        await capacityAndClockTests()
        await failureAndIdleTests()
        print("PASS: \(checks) todo reminder checks (fake delivery; no system permissions or user data)")
    }
}
