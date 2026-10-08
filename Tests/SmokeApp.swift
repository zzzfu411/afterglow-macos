import SwiftUI

/// A separate bundle and store for UI checks; never opens real focus history.
@main
struct SmokeApp: App {
    @StateObject private var model: FocusModel
    @StateObject private var quickEntry: QuickEntryController
    init() {
        let model = FocusModel(store: FocusStore(directory: URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["AFTERGLOW_SMOKE_DATA"] ?? NSTemporaryDirectory() + "afterglow-smoke-data",
            isDirectory: true)), remindersEnabled: false, preferences: .standard)
        _model = StateObject(wrappedValue: model)
        _quickEntry = StateObject(wrappedValue: QuickEntryController(model: model))
    }
    @StateObject private var appearance = FocusAppearanceController(selection: .system, defaults: UserDefaults.standard)

    var body: some Scene {
        Window("Moro · 检查", id: "main") {
            FocusWindow(model: model)
                .environment(\.colorScheme, appearance.colorScheme)
                .focusedSceneObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: FocusWindowLayout.defaultSize.width, height: FocusWindowLayout.defaultSize.height)
        .commands { TimerCommands(quickEntry: quickEntry) }
        MenuBarExtra {
            MenuPanel(model: model, quickEntry: quickEntry)
                .environment(\.colorScheme, appearance.colorScheme)
                .focusedSceneObject(model)
        } label: { Image(systemName: "circle.dotted.circle") }
        .menuBarExtraStyle(.window)
        Settings {
            FocusSettings(model: model, appearance: appearance, quickEntry: quickEntry)
        }
        .windowResizability(.contentSize)
    }
}
