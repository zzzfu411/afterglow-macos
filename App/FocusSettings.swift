import SwiftUI

struct FocusSettings: View {
    @ObservedObject var model: FocusModel
    @ObservedObject var appearance: FocusAppearanceController

    var body: some View {
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
            Label("桌面小组件", systemImage: "rectangle.3.group").font(.headline)
            if model.shared {
                Text("右键桌面 → 编辑小组件 → 留白")
            } else {
                HStack {
                    Text("此版本暂不可用").foregroundStyle(.secondary)
                    Spacer()
                    Link("安装说明", destination: URL(string: "https://github.com/zzzfu411/afterglow-macos/blob/main/docs/BUILDING.md")!)
                }
            }
            Divider()
            LabeledContent("开始 / 暂停", value: "空格")
            LabeledContent("结束", value: "⌘ .")
            LabeledContent("添加待办", value: "⌘ N")
            LabeledContent("待办边栏", value: "⌘ B")
            LabeledContent("数据", value: "仅保存在本机")
        }
        .font(.system(size: 13))
        .padding(28)
        .frame(width: 370)
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, appearance.colorScheme)
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
        if let issue = reminders.issue {
            HStack {
                Text(issue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重试") { reminders.reconcile(state, requestPermission: true) }
            }
        }
    }
}
