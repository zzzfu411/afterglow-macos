import SwiftUI

/// A separate bundle and store for UI checks; never opens real focus history.
@main
struct SmokeApp: App {
    @StateObject private var model = FocusModel(
        store: FocusStore(directory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["AFTERGLOW_SMOKE_DATA"]
            ?? NSTemporaryDirectory() + "afterglow-smoke-data", isDirectory: true)),
        preferences: .standard
    )
    @StateObject private var appearance = FocusAppearanceController(selection: .system, defaults: UserDefaults.standard)

    var body: some Scene {
        Window("留白 · 检查", id: "main") {
            FocusWindow(model: model)
                .environment(\.colorScheme, appearance.colorScheme)
                .focusedSceneObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: FocusWindowLayout.defaultSize.width, height: FocusWindowLayout.defaultSize.height)
        .commands { TimerCommands() }
        MenuBarExtra {
            MenuPanel(model: model)
                .environment(\.colorScheme, appearance.colorScheme)
                .focusedSceneObject(model)
        } label: { Image(systemName: "circle.dotted.circle") }
        .menuBarExtraStyle(.window)
        Settings {
            FocusSettings(model: model, appearance: appearance)
        }
        .windowResizability(.contentSize)
    }
}
