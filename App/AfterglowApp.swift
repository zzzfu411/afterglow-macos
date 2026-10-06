import SwiftUI
import WidgetKit

@main
struct AfterglowApp: App {
    @StateObject private var model = FocusModel.shared
    @StateObject private var appearance = FocusAppearanceController(
        selection: FocusAppearance(rawValue: UserDefaults.standard.string(forKey: "afterglow.appearance") ?? "system") ?? .system,
        defaults: .standard
    )

    var body: some Scene {
        Window("Moro", id: "main") {
            FocusWindow(model: model)
                .environment(\.colorScheme, appearance.colorScheme)
                .focusedSceneObject(model)
                .onOpenURL { _ in NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: FocusWindowLayout.defaultSize.width, height: FocusWindowLayout.defaultSize.height)
        .defaultPosition(.center)
        .commands { TimerCommands() }

        MenuBarExtra {
            MenuPanel(model: model)
                .environment(\.colorScheme, appearance.colorScheme)
                .focusedSceneObject(model)
        } label: {
            // A stable image avoids AppKit status-item layout churn from a
            // constantly invalidating date Text. The popover shows the timer.
            Image(systemName: "circle.dotted.circle")
                .accessibilityLabel("Moro")
        }
        .menuBarExtraStyle(.window)

        Settings {
            FocusSettings(model: model, appearance: appearance)
        }
        .windowResizability(.contentSize)
    }
}
