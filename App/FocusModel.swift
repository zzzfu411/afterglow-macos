import SwiftUI
import WidgetKit

@MainActor
final class FocusModel: ObservableObject {
    static let shared = FocusModel()
    @Published private(set) var state = FocusState()
    @Published var error: String?
    @Published var showHistory = false
    @Published var isEditingDuration = false
    let reminders: FocusReminders?
    private let store: FocusStore
    private var deadlineTimer: Timer?
    private var scheduledDeadline: Date?
    private var observation: FocusStoreObservation?
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?

    var shared: Bool { store.isShared }

    init(store: FocusStore = .shared, remindersEnabled: Bool = true) {
        self.store = store
        reminders = remindersEnabled ? FocusReminders(delivery: SystemReminderDelivery()) : nil
        observeStore()
        refresh(force: true)
        for name in [NSApplication.didBecomeActiveNotification, .NSSystemClockDidChange] {
            applicationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            })
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
    }

    deinit {
        deadlineTimer?.invalidate()
        for observer in applicationObservers { NotificationCenter.default.removeObserver(observer) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    private func observeStore() {
        do {
            observation = try FocusStoreObservation(directory: store.directoryURL) { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func resume() {
        // Reopen the directory after a wake/activation in case it was replaced.
        observeStore()
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        do { accept(try store.snapshot(), force: force) }
        catch { if self.error == nil { self.error = error.localizedDescription } }
    }

    func send(_ action: FocusAction) {
        do {
            let updated = try store.update(action)
            let starting = updated.status == .running && state.status != .running
            accept(updated)
            // Ask once, in context of a start click in the app. Widget intents
            // never show a permission sheet or foreground the app unexpectedly.
            if starting { reminders?.reconcile(updated, requestPermission: true) }
        } catch { self.error = error.localizedDescription }
    }

    func performIntent(_ action: IntentAction) async throws {
        let updated: FocusState
        switch action {
        case .toggle: updated = try store.toggle()
        case .finish: updated = try store.update(.finish)
        case .rest: updated = try store.startRest()
        case .reset: updated = try store.update(.reset)
        }
        accept(updated, force: true)
        await reminders?.flush()
    }

    enum IntentAction { case toggle, finish, rest, reset }

    private func accept(_ updated: FocusState, force: Bool = false) {
        let changed = updated != state
        if changed { state = updated }
        let nextDeadline = state.status == .running ? state.deadline : nil
        if nextDeadline != scheduledDeadline || force {
            deadlineTimer?.invalidate()
            deadlineTimer = nil
            scheduledDeadline = nextDeadline
            if let deadline = nextDeadline {
                let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
                timer.tolerance = 0.1
                RunLoop.main.add(timer, forMode: .common)
                deadlineTimer = timer
            }
        }
        if changed || force { reminders?.reconcile(state) }
        if changed, shared { WidgetCenter.shared.reloadAllTimelines() }
    }
}
