import SwiftUI

/// A separate bundle and store for UI checks; never opens real focus history.
@main
struct SmokeApp: App {
    @StateObject private var model = FocusModel(
        store: FocusStore(directory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["AFTERGLOW_SMOKE_DATA"]
            ?? NSTemporaryDirectory() + "afterglow-smoke-data", isDirectory: true))
    )
    @StateObject private var appearance = FocusAppearanceController(selection: .system, defaults: UserDefaults.standard)

    var body: some Scene {
        Window("留白 · 检查", id: "main") {
            FocusWindow(model: model)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: FocusWindowLayout.defaultSize.width, height: FocusWindowLayout.defaultSize.height)
        Settings {
            if let reminders = model.reminders { SmokeReminderStatus(reminders: reminders, state: model.state) }
        }
    }
}

private struct SmokeReminderStatus: View {
    @ObservedObject var reminders: FocusReminders
    let state: FocusState
    var body: some View {
        VStack(spacing: 16) {
            Text("Authorization: \(String(describing: reminders.authorization))")
            Text(reminders.issue ?? "No error")
            Button("Enable reminders") { reminders.reconcile(state, requestPermission: true) }
        }
        .padding(24)
        .task { await reminders.refreshAuthorization() }
    }
}
