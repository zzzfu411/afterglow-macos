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
                if let reminders = model.reminders {
                    ReminderSettings(reminders: reminders, state: model.state)
                    Divider()
                }
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

private struct ReminderSettings: View {
    @ObservedObject var reminders: FocusReminders
    let state: FocusState

    var body: some View {
        HStack {
            Label("到点提醒", systemImage: "bell")
            Spacer()
            if reminders.authorization == .allowed {
                Text("已开启").foregroundStyle(.secondary)
            } else if reminders.authorization == .unknown {
                Button("开启") { reminders.reconcile(state, requestPermission: true) }
            } else {
                Text("未开启").foregroundStyle(.secondary)
            }
            if reminders.authorization != .unknown {
                Button("系统设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                }
            }
        }
        .task { await reminders.refreshAuthorization() }
        if let issue = reminders.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
    }
}
