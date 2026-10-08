import SwiftUI

struct FocusSettings: View {
    @ObservedObject var model: FocusModel
    @ObservedObject var appearance: FocusAppearanceController
    var quickEntry: QuickEntryController? = nil
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
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
            if let todoReminders = model.todoReminders {
                TodoReminderSettings(reminders: todoReminders, todos: model.state.todos)
                Divider()
            }
            DefaultDurationSetting(model: model)
            if let quickEntry { QuickEntrySettings(controller: quickEntry) }
            Divider()
            HStack {
                Label("待办归档", systemImage: "externaldrive")
                Spacer()
                Button("导入…") {
                    openWindow(id: "main")
                    model.importTodos()
                }
                Button("导出…") { model.exportTodos() }
            }.disabled(model.isBusy)
            Label("桌面小组件", systemImage: "rectangle.3.group").font(.headline)
            if model.shared {
                Text("右键桌面 → 编辑小组件 → Moro")
            } else {
                HStack {
                    Text("此版本暂不可用").foregroundStyle(.secondary)
                    Spacer()
                    Link("安装说明", destination: URL(string: "https://github.com/zzzfu411/afterglow-macos/blob/main/docs/BUILDING.md")!)
                }
            }
            Divider()
            LabeledContent("开始 / 暂停", value: "⌘ Return")
            LabeledContent("搜索事项", value: "⌘ F")
            LabeledContent("撤销 / 重做", value: "⌘ Z / ⇧⌘ Z")
            LabeledContent("结束", value: "⌘ .")
            LabeledContent("添加待办", value: "⌘ N")
            LabeledContent("待办边栏", value: "⌘ B")
            LabeledContent("数据", value: "仅保存在本机")
        }
        .font(.system(size: 13))
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 560)
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

private struct TodoReminderSettings: View {
    @ObservedObject var reminders: TodoReminders
    let todos: [FocusTodo]
    var body: some View {
        HStack {
            Label("待办提醒", systemImage: "bell.badge")
            Spacer()
            Text(reminders.authorization == .allowed ? "已开启" : "未开启").foregroundStyle(.secondary)
            Button("重试") { reminders.reconcile(todos: todos, requestPermission: true) }
        }
        if let issue = reminders.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
    }
}

private final class DurationSettingState: ObservableObject { @Published var text = "25" }
private struct DefaultDurationSetting: View {
    @ObservedObject var model: FocusModel
    @StateObject private var field = DurationSettingState()
    private var minutes: Int? {
        guard let value = Int(field.text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)), (1...180).contains(value) else { return nil }
        return value
    }
    var body: some View {
        LabeledContent("默认专注") {
            TextField("分钟", text: $field.text).textFieldStyle(.roundedBorder).frame(width: 55)
                .onSubmit(save).accessibilityLabel("默认专注分钟数").help("1–180 分钟，回车保存")
            Text("分钟").foregroundStyle(.secondary)
            Button("保存", action: save).disabled(minutes == nil || minutes == Int(model.state.focusDuration / 60))
        }
        .disabled(model.state.isActive || model.isBusy)
        .onAppear { field.text = String(Int(model.state.focusDuration / 60)) }
    }
    private func save() { if let minutes { model.setFocusDuration(minutes) } }
}
