import SwiftUI
import WidgetKit

@MainActor
final class FocusModel: ObservableObject {
    @Published var state = FocusState()
    @Published var error: String?
    @Published var showHistory = false
    private var poll: Timer?
    private let store = FocusStore.shared

    var shared: Bool { store.isShared }

    init() {
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        do {
            let previousStatus = state.status
            let updated = try store.snapshot()
            if updated != state { state = updated }
            if previousStatus != updated.status, store.isShared { WidgetCenter.shared.reloadAllTimelines() }
        } catch {
            if self.error == nil { self.error = error.localizedDescription }
        }
    }

    func send(_ action: FocusAction) {
        do {
            state = try store.update(action)
            if store.isShared { WidgetCenter.shared.reloadAllTimelines() }
        } catch { self.error = error.localizedDescription }
    }
}

@main
struct AfterglowApp: App {
    @StateObject private var model = FocusModel()
    @StateObject private var appearance = FocusAppearanceController(
        selection: FocusAppearance(rawValue: UserDefaults.standard.string(forKey: "afterglow.appearance") ?? "system") ?? .system,
        defaults: .standard
    )

    var body: some Scene {
        Window("留白", id: "main") {
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
                .accessibilityLabel("留白")
        }
        .menuBarExtraStyle(.window)

        Settings {
            VStack(alignment: .leading, spacing: 20) {
                Picker("外观", selection: $appearance.selection) {
                    ForEach(FocusAppearance.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Divider()
                Label("桌面小组件", systemImage: "rectangle.3.group")
                    .font(.headline)
                if model.shared {
                    Text("右键桌面 → 编辑小组件 → 留白")
                } else {
                    Text("本地预览版").foregroundStyle(.secondary)
                    Text("桌面小组件需完成 Xcode 签名构建。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                LabeledContent("开始 / 暂停", value: "空格")
                LabeledContent("结束", value: "⌘ .")
                LabeledContent("数据", value: "仅保存在本机")
            }
            .font(.system(size: 13))
            .padding(28)
            .frame(width: 370)
            .foregroundStyle(.primary)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance.colorScheme)
        }
        .windowResizability(.contentSize)
    }
}

private struct TimerCommands: Commands {
    // The Settings scene intentionally has no focused timer. Space should
    // operate its selected control, not start a session behind the window.
    @FocusedObject private var model: FocusModel?

    var body: some Commands {
        CommandMenu("计时") {
            Button(model?.state.primaryLabel ?? "开始") {
                guard let model else { return }
                model.send(model.state.primaryAction)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model == nil)
            Button("结束") { model?.send(.finish) }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model?.state.isActive != true)
        }
    }
}
