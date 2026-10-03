import AppKit
import Combine
import UserNotifications

struct FocusReminder: Equatable {
    let sessionID: UUID
    let mode: FocusMode
    let deadline: Date
}

enum ReminderDirective: Equatable {
    case schedule(FocusReminder)
    case cancel
    case keep

    init(state: FocusState) {
        if state.status == .running, let id = state.sessionID, let deadline = state.deadline {
            self = .schedule(FocusReminder(sessionID: id, mode: state.mode, deadline: deadline))
        } else if state.status == .done, state.completedNaturally != false {
            // Let the system deliver the already scheduled reminder. Cancelling
            // at the deadline can otherwise race the notification service.
            self = .keep
        } else {
            self = .cancel
        }
    }
}

enum ReminderAuthorization { case unknown, allowed, denied }

@MainActor
protocol ReminderDelivery: AnyObject {
    func authorization() async -> ReminderAuthorization
    func requestAuthorization() async throws -> Bool
    func schedule(_ reminder: FocusReminder) async throws
    func cancel()
}

@MainActor
final class SystemReminderDelivery: NSObject, ReminderDelivery, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private static let identifier = "afterglow.session-end"

    override init() {
        super.init()
        center.delegate = self
    }

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

    func schedule(_ reminder: FocusReminder) async throws {
        let interval = reminder.deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = reminder.mode == .focus ? "专注完成" : "休息结束"
        content.body = reminder.mode == .focus ? "休息一下。" : "准备好了就开始。"
        content.sound = .default
        content.userInfo = ["sessionID": reminder.sessionID.uuidString]
        let request = UNNotificationRequest(
            identifier: Self.identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        )
        // Reusing one identifier replaces a resumed session's old deadline.
        try await center.add(request)
    }

    func cancel() { center.removePendingNotificationRequests(withIdentifiers: [Self.identifier]) }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            NSWorkspace.shared.open(URL(string: "afterglow://open")!)
            completionHandler()
        }
    }
}

/// One worker coalesces rapid start/pause/resume actions across asynchronous
/// permission and scheduling calls. Actors alone do not prevent reentrancy.
@MainActor
final class FocusReminders: ObservableObject {
    @Published private(set) var authorization: ReminderAuthorization = .unknown
    @Published private(set) var issue: String?
    private let delivery: ReminderDelivery
    private var desired: ReminderDirective = .keep
    private var revision = 0
    private var permissionRequested = false
    private var worker: Task<Void, Never>?

    init(delivery: ReminderDelivery) { self.delivery = delivery }

    func reconcile(_ state: FocusState, requestPermission: Bool = false) {
        desired = ReminderDirective(state: state)
        revision += 1
        permissionRequested = permissionRequested || requestPermission
        if desired == .cancel { delivery.cancel() }
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    func refreshAuthorization() async { authorization = await delivery.authorization() }
    func flush() async { await worker?.value }

    private func drain() async {
        while true {
            let current = revision
            let shouldAsk = permissionRequested
            permissionRequested = false
            do {
                // Settings can change while the timer is idle or paused. This
                // runs on state/activation events, never on a polling timer.
                authorization = await delivery.authorization()
                if shouldAsk, authorization == .unknown {
                    authorization = try await delivery.requestAuthorization() ? .allowed : .denied
                }
                if current != revision { continue }
                switch desired {
                case .schedule(let reminder):
                    if authorization == .allowed { try await delivery.schedule(reminder) }
                    else { delivery.cancel() }
                case .cancel: delivery.cancel()
                case .keep: break
                }
                issue = nil
            } catch { issue = "未能设置到点提醒，请重试。" }
            if current == revision { break }
        }
        worker = nil
    }
}
