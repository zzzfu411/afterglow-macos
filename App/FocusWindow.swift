import SwiftUI

struct FocusWindow: View {
    @ObservedObject var model: FocusModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var durationPicker = DurationPickerState()

    var body: some View {
        GeometryReader { geometry in
            let layout = FocusWindowLayout(size: geometry.size)
            VStack(spacing: 0) {
                windowActions
                timerContent(layout: layout)
                    .frame(width: layout.contentWidth, height: layout.contentHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: FocusWindowLayout.minimumSize.width, minHeight: FocusWindowLayout.minimumSize.height)
        .background(NativeWindowSurface())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.state.status)
        .onChange(of: phase) { _, phase in if phase == .active { model.refresh() } }
        .onChange(of: durationPicker.isPresented) { _, presented in
            model.isEditingDuration = presented
            if presented { model.showTodos = false; model.showHistory = false }
        }
        .onChange(of: model.showTodos) { _, presented in
            if presented { durationPicker.isPresented = false; model.showHistory = false }
        }
        .onChange(of: model.showHistory) { _, presented in
            if presented { durationPicker.isPresented = false; model.showTodos = false }
        }
        .onDisappear {
            durationPicker.isPresented = false
            model.isEditingDuration = false
            model.showHistory = false
            model.showTodos = false
        }
        .alert("计时数据暂不可用", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("重试") { model.retryStorage() }
            Button("关闭", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var windowActions: some View {
        HStack(spacing: 8) {
            WindowDragRegion()
                .accessibilityHidden(true)
            if let reminders = model.reminders { ReminderIndicator(reminders: reminders) }
            Button { model.showTodos.toggle() } label: {
                Image(systemName: "checklist")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .help("待办清单").accessibilityLabel("待办清单")
            Button { model.showHistory.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help("专注记录")
            .accessibilityLabel("专注记录")
            .popover(isPresented: $model.showHistory, arrowEdge: .bottom) {
                HistoryView(state: model.state)
            }
            SettingsLink {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help("设置")
            .accessibilityLabel("设置")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .frame(height: FocusWindowLayout.toolbarHeight)
    }

    private func timerContent(layout: FocusWindowLayout) -> some View {
        VStack(spacing: 0) {
            Picker("模式", selection: Binding(get: { model.state.mode }, set: { model.send(.selectMode($0)) })) {
                Label("专注", systemImage: "circle.dotted.circle").tag(FocusMode.focus)
                Label("休息", systemImage: "cup.and.saucer").tag(FocusMode.rest)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 164)
            .disabled(model.state.isActive)
            .padding(.top, 14)

            Group {
                if model.state.mode == .focus {
                    Button { model.showTodos = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checklist")
                            Text(model.state.focusTargetTitle).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                        }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.state.focusTargetTitle)
                    .accessibilityLabel("专注事项：\(model.state.focusTargetTitle)")
                } else {
                    Color.clear.frame(height: 28).accessibilityHidden(true)
                }
            }
            .padding(.top, 6)
            .popover(isPresented: $model.showTodos, arrowEdge: .bottom) {
                FocusTodosView(model: model)
            }

            Spacer(minLength: 12)

            VStack(spacing: 9) {
                TimerReadout(state: model.state, size: layout.timerSize)
                .frame(height: ceil(layout.timerSize * 1.16))
                statusLine.frame(height: 18)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                ForEach(model.state.mode.presets, id: \.self) { minutes in
                    Button { model.send(.selectDuration(TimeInterval(minutes * 60))) } label: {
                        Text("\(minutes) 分")
                            .font(.system(size: 12, weight: selected(minutes) ? .medium : .regular))
                            .foregroundStyle(selected(minutes) ? Color.primary : Color.secondary)
                            .frame(width: 58, height: 29)
                            .background(selected(minutes) ? Color.primary.opacity(0.085) : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected(minutes) ? 0.05 : 0), lineWidth: 0.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.state.isActive)
                    .accessibilityAddTraits(selected(minutes) ? .isSelected : [])
                }
                Button {
                    let duration = model.state.status == .done
                        ? (model.state.mode == .focus ? model.state.plannedFocusDuration : model.state.restDuration)
                        : model.state.duration
                    durationPicker.text = String(Int(duration / 60))
                    durationPicker.maximumMinutes = Int(model.state.durationLimit / 60)
                    model.isEditingDuration = true
                    durationPicker.isPresented = true
                } label: {
                    Label(customDurationSelected ? model.state.shortDuration : "自定", systemImage: "pencil")
                        .font(.system(size: 12, weight: customDurationSelected ? .medium : .regular))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .frame(width: 64, height: 29)
                        .background(customDurationSelected ? Color.primary.opacity(0.085) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("自定时长")
                .accessibilityLabel("自定时长")
                .accessibilityValue("\(Int(model.state.duration / 60)) 分钟")
                .accessibilityAddTraits(customDurationSelected ? .isSelected : [])
                .disabled(model.state.isActive)
                .popover(isPresented: $durationPicker.isPresented, arrowEdge: .bottom) {
                    DurationEditor(picker: durationPicker) { minutes in
                        model.send(.selectDuration(TimeInterval(minutes * 60)))
                    }
                }
            }
            .opacity(model.state.isActive ? 0.45 : 1)

            HStack(spacing: 24) {
                Color.clear.frame(width: 38, height: 38)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Button { model.send(model.state.primaryAction) } label: {
                    TimerSymbol(symbol: model.state.primarySymbol, primary: true, diameter: 56, nativeGlass: true)
                        .modifier(ControlCaption(text: model.state.status == .done ? model.state.primaryLabel : nil))
                }
                .buttonStyle(.plain)
                .help("\(model.state.primaryLabel)（空格）")
                .accessibilityLabel(model.state.primaryLabel)
                Button { model.send(model.state.status == .done ? .reset : .finish) } label: {
                    TimerSymbol(symbol: model.state.status == .done ? "checkmark" : "stop.fill", diameter: 34, nativeGlass: true)
                        .frame(width: 38, height: 38)
                        .modifier(ControlCaption(text: model.state.status == .done ? "收工" : nil))
                }
                .buttonStyle(.plain)
                .help(model.state.status == .done ? "收工" : "结束（⌘ .）")
                .accessibilityLabel(model.state.status == .done ? "收工" : "结束")
                .disabled(model.state.status == .idle)
                .opacity(model.state.status == .idle ? 0 : 1)
                .allowsHitTesting(model.state.status != .idle)
                .accessibilityHidden(model.state.status == .idle)
            }
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
    }

    private func selected(_ minutes: Int) -> Bool { Int(model.state.duration / 60) == minutes }

    private var customDurationSelected: Bool {
        !model.state.mode.presets.contains(Int(model.state.duration / 60))
    }

    private var statusLine: some View {
        Group {
            switch model.state.status {
            case .running:
                if let end = model.state.deadline {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                        Text(end, style: .time)
                    }
                }
            case .paused: Text("已暂停")
            case .done:
                if model.state.mode == .focus && !(model.state.sessionTodoIDs ?? []).isEmpty {
                    Button { model.showTodos = true } label: {
                        Label("整理待办", systemImage: "checklist")
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("整理本轮待办事项")
                } else {
                    Label(model.state.mode == .focus ? "专注结束" : "休息结束", systemImage: "checkmark")
                }
            case .idle: Text("")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// This is only the empty portion of the toolbar; controls retain their normal
/// click behavior, while the native title bar remains available above it.
private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var model: FocusModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Label(model.state.mode.title, systemImage: model.state.mode.symbol)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("打开留白").accessibilityLabel("打开留白")
            }
            TimerReadout(state: model.state, size: 58)
            if model.state.mode == .focus {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    model.showTodos = true
                } label: {
                    Label(model.state.focusTargetTitle, systemImage: "checklist")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help("选择或查看待办")
            }
            if model.state.status == .paused {
                Text("已暂停").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Color.clear.frame(width: 40, height: 40)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Button { model.send(model.state.primaryAction) } label: {
                    TimerSymbol(symbol: model.state.primarySymbol, primary: true, nativeGlass: true)
                        .modifier(ControlCaption(text: model.state.status == .done ? model.state.primaryLabel : nil))
                }
                .help("\(model.state.primaryLabel)（空格）")
                .accessibilityLabel(model.state.primaryLabel)
                Button { model.send(model.state.status == .done ? .reset : .finish) } label: {
                    TimerSymbol(symbol: model.state.status == .done ? "checkmark" : "stop.fill", nativeGlass: true)
                        .modifier(ControlCaption(text: model.state.status == .done ? "收工" : nil))
                }
                    .help(model.state.status == .done ? "收工" : "结束（⌘ .）")
                    .accessibilityLabel(model.state.status == .done ? "收工" : "结束")
                    .disabled(model.state.status == .idle)
                    .opacity(model.state.status == .idle ? 0 : 1)
                    .allowsHitTesting(model.state.status != .idle)
                    .accessibilityHidden(model.state.status == .idle)
            }
            if let error = model.error {
                VStack(spacing: 6) {
                    Text("计时数据暂不可用").font(.caption).help(error)
                    Button("重试") { model.retryStorage() }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(24)
        .frame(width: 252)
        .onAppear { model.refresh() }
    }
}

struct HistoryView: View {
    let state: FocusState
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("专注记录").font(.headline)
            if state.logs.isEmpty {
                Label("还没有专注记录", systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(Array(state.logs.reversed()), id: \.id) { log in
                            HStack(spacing: 12) {
                                Image(systemName: log.completed ? "checkmark.circle" : "circle.lefthalf.filled")
                                    .foregroundStyle(.secondary)
                                    .help(log.completed ? "计时完成" : "提前结束")
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(log.task.isEmpty ? "专注" : log.task).lineLimit(2).help(log.task)
                                    Text(log.endedAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(log.durationLabel).monospacedDigit().fixedSize()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isStaticText)
                            .accessibilityLabel("\(log.task.isEmpty ? "专注" : log.task)，\(log.completed ? "计时完成" : "提前结束")，\(log.durationLabel)，\(log.endedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }.frame(maxHeight: 270)
                if state.logs.count == FocusState.maximumLogCount {
                    Text("保留最近 \(FocusState.maximumLogCount) 条")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 13))
        .padding(22)
        .frame(width: 290)
    }
}

private final class DurationPickerState: ObservableObject {
    @Published var isPresented = false
    @Published var text = "25"
    var maximumMinutes = 180

    var minutes: Int? {
        guard let value = Int(text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...maximumMinutes).contains(value) else { return nil }
        return value
    }
}

private struct DurationEditor: View {
    @ObservedObject var picker: DurationPickerState
    @SwiftUI.FocusState private var inputFocused: Bool
    let onConfirm: (Int) -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                TextField("", text: $picker.text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 74)
                    .focused($inputFocused)
                    .onSubmit(confirm)
                    .accessibilityLabel("自定分钟数")
                    .help("1–\(picker.maximumMinutes) 分钟")
                Text("分钟")
                Stepper("分钟", value: Binding(
                    get: { picker.minutes ?? 1 },
                    set: { picker.text = String($0) }
                ), in: 1...picker.maximumMinutes)
                .labelsHidden()
                .fixedSize()
                .disabled(picker.minutes == nil)
                .accessibilityLabel("调整分钟数")
            }
            .font(.system(size: 20, weight: .medium))
            .monospacedDigit()

            Text(picker.minutes == nil ? "输入 1–\(picker.maximumMinutes) 的整数" : "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 14)
                .accessibilityHidden(picker.minutes != nil)

            Button("确定", action: confirm)
                .keyboardShortcut(.defaultAction)
                .disabled(picker.minutes == nil)
        }
        .padding(22)
        .frame(width: 230)
        .defaultFocus($inputFocused, true)
        .onExitCommand { picker.isPresented = false }
    }

    private func confirm() {
        guard picker.isPresented, let minutes = picker.minutes else { return }
        onConfirm(minutes)
        picker.isPresented = false
    }
}

struct TimerCommands: Commands {
    // Settings intentionally has no focused timer model.
    @FocusedObject private var model: FocusModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("添加待办") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model?.newTodo()
            }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model == nil || model?.isEditingDuration == true || model?.error != nil)
        }
        CommandMenu("计时") {
            Button(model?.state.primaryLabel ?? "开始") {
                guard let model, canControlTimer else { return }
                model.send(model.state.primaryAction)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model == nil || model?.isEditingDuration == true || model?.showHistory == true || model?.showTodos == true || model?.error != nil)
            Button("结束") {
                guard canControlTimer else { return }
                model?.send(.finish)
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(model?.state.isActive != true || model?.isEditingDuration == true || model?.showHistory == true || model?.showTodos == true || model?.error != nil)
        }
    }

    // A key equivalent can arrive before SwiftUI refreshes the menu's disabled
    // state. Also protect the native field editor at the time of the action.
    private var canControlTimer: Bool {
        model != nil && model?.isEditingDuration != true && model?.showHistory != true && model?.showTodos != true && model?.error == nil
            && !(NSApp.keyWindow?.firstResponder is NSTextView)
    }
}

private struct ControlCaption: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize().offset(y: 19).accessibilityHidden(true)
            }
        }
    }
}

private struct ReminderIndicator: View {
    @ObservedObject var reminders: FocusReminders
    var body: some View {
        if reminders.authorization == .denied || reminders.issue != nil {
            SettingsLink {
                Image(systemName: "bell.slash")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .help("到点提醒不可用，打开设置")
            .accessibilityLabel("到点提醒不可用，打开设置")
        }
    }
}
