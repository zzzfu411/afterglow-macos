import Combine
import Foundation
import UserNotifications

/// A small notification snapshot. Notes and the rest of the task stay in the store.
struct TodoReminder: Equatable, Sendable {
    static let identifierPrefix = "moro.todo-reminder."

    let taskID: UUID
    let title: String
    let date: Date

    var identifier: String { Self.identifierPrefix + taskID.uuidString }
}

struct PendingTodoReminder: Equatable, Sendable {
    let identifier: String
    /// nil also represents notifications owned by another feature.
    let reminder: TodoReminder?
}

@MainActor
protocol TodoReminderDelivery: AnyObject {
    func authorization() async -> ReminderAuthorization
    func requestAuthorization() async throws -> Bool
    func pendingRequests() async -> [PendingTodoReminder]
    func schedule(_ reminder: TodoReminder) async throws
    func cancel(identifiers: [String])
}

/// Shares the existing notification delegate with session reminders.
@MainActor
final class SystemTodoReminderDelivery: TodoReminderDelivery {
    private let center: UNUserNotificationCenter
    private static let dateKey = "moroReminderDate"

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func authorization() async -> ReminderAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .unknown
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func pendingRequests() async -> [PendingTodoReminder] {
        await center.pendingNotificationRequests().map { request in
            var reminder: TodoReminder?
            if request.identifier.hasPrefix(TodoReminder.identifierPrefix),
               let taskID = UUID(uuidString: String(request.identifier.dropFirst(TodoReminder.identifierPrefix.count))),
               let timestamp = request.content.userInfo[Self.dateKey] as? NSNumber,
               timestamp.doubleValue.isFinite {
                reminder = TodoReminder(taskID: taskID, title: request.content.body,
                                        date: Date(timeIntervalSince1970: timestamp.doubleValue))
            }
            return PendingTodoReminder(identifier: request.identifier, reminder: reminder)
        }
    }

    func schedule(_ reminder: TodoReminder) async throws {
        let interval = reminder.date.timeIntervalSinceNow
        guard interval.isFinite, interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "待办提醒"
        content.body = reminder.title
        content.sound = .default
        content.userInfo = ["taskID": reminder.taskID.uuidString,
                            Self.dateKey: reminder.date.timeIntervalSince1970]
        let request = UNNotificationRequest(
            identifier: reminder.identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        )
        try await center.add(request)
    }

    func cancel(identifiers: [String]) {
        // A second ownership check prevents accidentally cancelling session reminders.
        let owned = identifiers.filter { $0.hasPrefix(TodoReminder.identifierPrefix) }
        guard !owned.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: owned)
    }
}

/// Event-driven scheduling: no timer, polling, delegate replacement or file access.
/// A single worker serializes asynchronous notification calls and discards stale work.
@MainActor
final class TodoReminders: ObservableObject {
    /// Leave room for the existing session-end notification and other system requests.
    static let maximumPendingCount = 48
    private static let deliveryGrace: TimeInterval = 60

    @Published private(set) var authorization: ReminderAuthorization = .unknown
    @Published private(set) var issue: String?
    @Published private(set) var deferredCount = 0

    private let delivery: TodoReminderDelivery
    private let now: () -> Date
    private var desired: [UUID: TodoReminder] = [:]
    private var revision = 0
    private var permissionRequested = false
    private var worker: Task<Void, Never>?

    init(delivery: TodoReminderDelivery, now: @escaping () -> Date = Date.init) {
        self.delivery = delivery
        self.now = now
    }

    func reconcile(todos: [FocusTodo], requestPermission: Bool = false) {
        var reminders: [UUID: TodoReminder] = [:]
        for todo in todos where !todo.isCompleted && todo.deletedAt == nil {
            guard let date = todo.reminderDate, date.timeIntervalSince1970.isFinite,
                  (Date.distantPast...Date.distantFuture).contains(date) else { continue }
            reminders[todo.id] = TodoReminder(taskID: todo.id, title: todo.title, date: date)
        }
        desired = reminders
        permissionRequested = permissionRequested || requestPermission
        startWorker()
    }

    /// Reconcile as well as reading authorization, so enabling notifications in
    /// System Settings or waking the app retries previously unscheduled tasks.
    func refreshAuthorization() async {
        startWorker()
        await flush()
    }

    func flush() async {
        while let currentWorker = worker { await currentWorker.value }
    }

    private func startWorker() {
        revision &+= 1
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while true {
            let currentRevision = revision
            authorization = await delivery.authorization()
            if currentRevision != revision { continue }

            var permissionIssue: String?
            let hasFutureReminder = desired.values.contains { $0.date > now() }
            let shouldAsk = permissionRequested && hasFutureReminder && authorization == .unknown
            permissionRequested = false
            if shouldAsk {
                do {
                    authorization = try await delivery.requestAuthorization() ? .allowed : .denied
                } catch {
                    permissionIssue = "无法申请待办通知权限，请稍后重试。"
                }
                if currentRevision != revision { continue }
            }

            let pending = await delivery.pendingRequests()
            if currentRevision != revision { continue }
            let owned = pending.filter { $0.identifier.hasPrefix(TodoReminder.identifierPrefix) }
            let currentDate = now()

            guard authorization == .allowed else {
                delivery.cancel(identifiers: owned.map(\.identifier))
                deferredCount = 0
                issue = permissionIssue ?? (hasFutureReminder && authorization == .denied
                    ? "待办提醒未开启，请在系统设置中允许 Moro 发送通知。" : nil)
                if currentRevision == revision { break }
                continue
            }

            // Do not race the notification service at the exact firing time. A
            // completed, deleted or rescheduled task never receives this grace.
            let finishing = owned.filter { request in
                guard let reminder = request.reminder, desired[reminder.taskID] == reminder else { return false }
                return reminder.date <= currentDate
                    && currentDate.timeIntervalSince(reminder.date) <= Self.deliveryGrace
            }
            let future = desired.values.filter { $0.date > currentDate }.sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.taskID.uuidString < $1.taskID.uuidString
            }
            let capacity = max(0, Self.maximumPendingCount - finishing.count)
            let selected = Array(future.prefix(capacity))
            let expected = Dictionary(uniqueKeysWithValues: selected.map { ($0.identifier, $0) })
            let finishingIDs = Set(finishing.map(\.identifier))
            let cancelIDs = owned.filter { request in
                !finishingIDs.contains(request.identifier)
                    && (expected[request.identifier] == nil || expected[request.identifier] != request.reminder)
            }.map(\.identifier)
            delivery.cancel(identifiers: cancelIDs)
            let unchanged = Set(owned.filter { request in
                expected[request.identifier] != nil && expected[request.identifier] == request.reminder
            }.map(\.identifier))

            var failures = 0
            for reminder in selected where !unchanged.contains(reminder.identifier) {
                // A long authorization dialog or many requests can pass the date.
                guard reminder.date > now() else { continue }
                do { try await delivery.schedule(reminder) }
                catch { failures += 1 }
                if currentRevision != revision {
                    // An in-flight add can finish after completion or a date edit.
                    // Remove that stale request before starting the newest pass.
                    if desired[reminder.taskID] != reminder {
                        delivery.cancel(identifiers: [reminder.identifier])
                    }
                    break
                }
            }
            if currentRevision != revision { continue }

            deferredCount = max(0, future.count - selected.count)
            if failures > 0 {
                issue = "有 \(failures) 项待办提醒未能设置，请重试。"
            } else if deferredCount > 0 {
                issue = "还有 \(deferredCount) 项提醒待排入；返回 Moro 时补排，未排入的提醒不会在后台送达。"
            } else {
                issue = nil
            }
            break
        }
        worker = nil
    }
}
