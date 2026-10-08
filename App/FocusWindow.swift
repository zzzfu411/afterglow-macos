import SwiftUI

struct FocusWindow: View {
    @ObservedObject var model: FocusModel
    @Environment(\.scenePhase) private var phase
    @SwiftUI.FocusState private var searchFocused: Bool
    @StateObject private var durationPicker = DurationPickerState()

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { model.showSidebar ? .all : .detailOnly },
                set: { model.showSidebar = $0 != .detailOnly })
    }
    var body: some View {
        GeometryReader { window in
            NavigationSplitView(columnVisibility: sidebarVisibility) {
                TodoNavigationView(model: model)
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(min: FocusWindowLayout.sidebarMinimumWidth,
                                                    ideal: FocusWindowLayout.sidebarIdealWidth,
                                                    max: FocusWindowLayout.sidebarWidthLimit(windowWidth: window.size.width))
            } detail: {
                VStack(spacing: 0) {
                    if model.showSearch {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("搜索所有事项", text: $model.searchText)
                                .textFieldStyle(.plain).focused($searchFocused)
                                .task(id: model.searchRequest) {
                                    searchFocused = false
                                    await Task.yield()
                                    searchFocused = true
                                }
                                .accessibilityLabel("搜索所有事项")
                            Button { model.searchText = ""; model.showSearch = false } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭搜索")
                        }
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        Divider()
                    }
                    if model.showFocus { focusView }
                    else { FocusTodosView(model: model) }
                    if let notice = model.notice {
                        HStack {
                            Text(notice).lineLimit(2)
                            Spacer(minLength: 8)
                            if model.canUndoTodo { Button("撤销") { model.undoTodoChange() }.disabled(model.isBusy) }
                            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                                .help("关闭提示").accessibilityLabel("关闭提示")
                        }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 8)
                    }
                    if model.state.status != .idle && !model.showFocus {
                        Divider()
                        CompactFocusBar(model: model)
                    }
                }
                .frame(minWidth: 280)
                .background(NativeWindowSurface())
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(of: window.size.width, initial: true) { _, width in
                if width < FocusWindowLayout.sidebarCollapseWidth && model.showSidebar { model.showSidebar = false }
            }
        }
        .frame(minWidth: FocusWindowLayout.minimumSize.width, minHeight: FocusWindowLayout.minimumSize.height)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help("显示或隐藏侧边栏（⌘B）").accessibilityLabel("显示或隐藏侧边栏")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showSearch = true; model.showFocus = false; model.searchRequest += 1 } label: { Image(systemName: "magnifyingglass") }
                    .help("搜索（⌘F）").accessibilityLabel("搜索事项")
                if model.state.status == .idle {
                    Button { model.startFreeFocus() } label: { Image(systemName: "play.circle") }
                        .help("自由专注").accessibilityLabel("自由专注").disabled(model.isBusy)
                }
                Button { model.showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("专注记录").accessibilityLabel("专注记录")
                    .popover(isPresented: $model.showHistory) { HistoryView(state: model.state) }
                SettingsLink { Image(systemName: "slider.horizontal.3") }.help("设置").accessibilityLabel("设置")
            }
        }
        .onChange(of: phase) { _, value in if value == .active { model.refresh() } }
        .onChange(of: durationPicker.isPresented) { _, value in model.isEditingDuration = value }
        .alert("无法保存更改", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("重试") { model.retryStorage() }
            Button("关闭", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("导入待办归档？", isPresented: Binding(get: { model.pendingImport != nil }, set: { if !$0 { model.pendingImport = nil } })) {
            Button("取消", role: .cancel) { model.pendingImport = nil }
            Button("导入") { model.confirmImport() }
        } message: {
            if let preview = model.pendingImport?.preview {
                Text("新增 \(preview.addedTodoCount) 项事项、\(preview.addedCollectionCount) 个清单。归档内容将覆盖 \(preview.updatedTodoCount) 项现有事项和 \(preview.updatedCollectionCount) 个清单。当前专注和历史记录保留。")
            }
        }
        .alert("永久删除这些事项？", isPresented: Binding(get: { !model.pendingPurgeIDs.isEmpty }, set: { if !$0 { model.pendingPurgeIDs = [] } })) {
            Button("取消", role: .cancel) { model.pendingPurgeIDs = [] }
            Button("永久删除", role: .destructive) { model.confirmPurgeTodos() }
        } message: { Text("将删除 \(model.pendingPurgeIDs.count) 项。建议先导出归档。") }
        .alert("切换专注事项？", isPresented: Binding(get: { model.pendingFocusID != nil }, set: { if !$0 { model.pendingFocusID = nil } })) {
            Button("取消", role: .cancel) { model.pendingFocusID = nil }
            Button("结束并切换") { model.confirmSwitchFocus() }
        } message: { Text("本轮已投入的时间会保存。") }
    }

    private var focusView: some View {
        VStack(spacing: 22) {
            HStack {
                Button { model.showFocus = false } label: { Label("返回清单", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
            }
            Spacer(minLength: 0)
            Text(model.state.mode == .rest ? "休息" : model.state.currentTask.isEmpty ? "自由专注" : model.state.currentTask)
                .font(.system(size: 17, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            TimerReadout(state: model.state, size: 76)
            if model.state.status == .paused { Text("已暂停").foregroundStyle(.secondary) }
            HStack(spacing: 20) {
                Button { model.toggleFocus() } label: {
                    Image(systemName: model.state.status == .running ? "pause.fill" : "play.fill")
                        .frame(width: 40, height: 36)
                }
                .help(model.state.status == .running ? "暂停" : "开始").accessibilityLabel(model.state.status == .running ? "暂停" : "开始")
                if model.state.isActive {
                    Button { model.send(.finish) } label: { Image(systemName: "stop.fill").frame(width: 40, height: 36) }
                        .help("结束专注").accessibilityLabel("结束专注")
                }
            }
            .disabled(model.isBusy)
            if !model.state.isActive {
                Button("\(Int(model.state.focusDuration / 60)) 分钟") {
                    durationPicker.text = String(Int(model.state.focusDuration / 60))
                    durationPicker.isPresented = true
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .popover(isPresented: $durationPicker.isPresented) {
                    DurationEditor(picker: durationPicker) { model.send(.selectDuration(TimeInterval($0 * 60))) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CompactFocusBar: View {
    @ObservedObject var model: FocusModel
    var body: some View {
        HStack(spacing: 12) {
            Button { model.showCurrentTodo() } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.state.mode == .rest ? "休息" : (model.state.currentTask.isEmpty ? "自由专注" : model.state.currentTask))
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text((model.queueProgress.map { $0 + " · " } ?? "") + (model.state.status == .done ? "本轮结束" : model.state.status == .paused ? "已暂停" : "专注中"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("查看当前事项").accessibilityLabel("查看当前专注事项")
            .contextMenu {
                if model.queueProgress != nil { Button("退出队列，保留当前专注") { model.clearFocusQueue() } }
            }
            if model.state.status == .done {
                if model.hasNextQueueItem {
                    Button("下一项") { model.advanceFocusQueue() }.controlSize(.small)
                } else { Button("休息") { model.startRest() }.controlSize(.small) }
                Button { model.send(.reset) } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .help("收起计时").accessibilityLabel("收起计时")
            } else {
                TimerReadout(state: model.state, size: 23).frame(width: 67)
                Button { model.send(model.state.status == .running ? .pause : .start) } label: {
                    Image(systemName: model.state.status == .running ? "pause.fill" : "play.fill").frame(width: 24, height: 28)
                }
                .help(model.state.status == .running ? "暂停（⌘Return）" : "继续（⌘Return）")
                .accessibilityLabel(model.state.status == .running ? "暂停" : "继续")
                Button { model.send(.finish) } label: { Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 24, height: 28) }
                    .help("结束（⌘.）").accessibilityLabel("结束本轮专注")
            }
            if model.hasNextQueueItem && model.state.isActive {
                Button { model.advanceFocusQueue() } label: { Image(systemName: "forward.end").frame(width: 24, height: 28) }
                    .help("跳过并专注下一项；当前事项保持待办").accessibilityLabel("跳过并专注下一项")
            }
            Button { model.showFocus = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11)).frame(width: 24, height: 28) }
                .help("专注视图").accessibilityLabel("展开专注视图")
        }
        .buttonStyle(.plain).disabled(model.isBusy)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct MenuPanel: View {
    @ObservedObject var model: FocusModel
    var quickEntry: QuickEntryController? = nil
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Moro").font(.headline)
                Spacer()
                if let quickEntry {
                    Button { quickEntry.show() } label: { Image(systemName: "square.and.pencil") }
                        .help("快速录入").accessibilityLabel("快速录入")
                }
                Button {
                    openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("打开 Moro").accessibilityLabel("打开 Moro")
            }
            HStack {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("快速添加到收件箱", text: $model.quickEntryText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        guard (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
                        model.section = .inbox; model.quickAddTodo()
                    }
            }
            .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            if model.state.status != .idle { CompactFocusBar(model: model) }
            else {
                HStack {
                    Text("今天 \(model.count(in: .today)) 项").foregroundStyle(.secondary)
                    Spacer()
                    Button("自由专注") { model.startFreeFocus() }.disabled(model.isBusy)
                }
            }
        }
        .font(.system(size: 12)).padding(16).frame(width: 340)
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
    var quickEntry: QuickEntryController? = nil
    @FocusedObject private var model: FocusModel?
    @Environment(\.openWindow) private var openWindow
    private var textEditor: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }
    private var canControlTimer: Bool { model?.allowsTimerKeyboard == true && textEditor == nil }
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("添加事项") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); model?.newTodo() }
                .keyboardShortcut("n").disabled(model == nil)
            if let quickEntry { Button("快速录入…") { quickEntry.show() } }
            Divider()
            Button("导入待办…") { model?.importTodos() }.disabled(model == nil || model?.isBusy == true)
            Button("导出待办…") { model?.exportTodos() }.disabled(model == nil || model?.isBusy == true)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") {
                if let textEditor { textEditor.undoManager?.undo() } else { model?.undoTodoChange() }
            }.keyboardShortcut("z").disabled(textEditor == nil && (model?.canUndoTodo != true || model?.isBusy == true))
            Button("重做") {
                if let textEditor { textEditor.undoManager?.redo() } else { model?.redoTodoChange() }
            }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(textEditor == nil && (model?.canRedoTodo != true || model?.isBusy == true))
        }
        CommandGroup(after: .sidebar) {
            Button(model?.showSidebar == true ? "隐藏侧边栏" : "显示侧边栏") { model?.showSidebar.toggle() }
                .keyboardShortcut("b").disabled(model == nil)
            Button("搜索事项") { model?.showSearch = true; model?.showFocus = false; model?.searchRequest += 1 }
                .keyboardShortcut("f").disabled(model == nil)
        }
        CommandMenu("专注") {
            Button(model?.state.status == .running ? "暂停" : "开始 / 继续") { if canControlTimer { model?.toggleFocus() } }
                .keyboardShortcut(.return, modifiers: .command).disabled(model?.allowsTimerKeyboard != true)
            Button("开始 / 暂停专注视图") {
                if canControlTimer && model?.showFocus == true { model?.toggleFocus() }
            }.keyboardShortcut(.space, modifiers: []).disabled(model?.showFocus != true || model?.allowsTimerKeyboard != true)
            Button("结束本轮") { if canControlTimer { model?.send(.finish) } }
                .keyboardShortcut(".").disabled(model?.state.isActive != true)
            Divider()
            Button("专注视图") { model?.showFocus.toggle() }.disabled(model == nil)
        }
    }
}
