import SwiftUI

struct FocusWindow: View {
    @ObservedObject var model: FocusModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .alert("无法保存", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var windowActions: some View {
        HStack(spacing: 8) {
            WindowDragRegion()
                .accessibilityHidden(true)
            Button { model.showHistory.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help("记录")
            .accessibilityLabel("记录")
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

            Spacer(minLength: 12)

            VStack(spacing: 9) {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    TimerReadout(state: model.state, size: layout.timerSize, date: context.date, live: false)
                }
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
                            .frame(width: 63, height: 29)
                            .background(selected(minutes) ? Color.primary.opacity(0.085) : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected(minutes) ? 0.05 : 0), lineWidth: 0.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.state.isActive)
                    .accessibilityAddTraits(selected(minutes) ? .isSelected : [])
                }
            }
            .opacity(model.state.isActive ? 0.45 : 1)

            HStack(spacing: 24) {
                Color.clear.frame(width: 38, height: 38)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Button { model.send(model.state.primaryAction) } label: {
                    TimerSymbol(symbol: model.state.primarySymbol, primary: true, diameter: 56, nativeGlass: true)
                }
                .buttonStyle(.plain)
                .help("\(model.state.primaryLabel)（空格）")
                .accessibilityLabel(model.state.primaryLabel)
                Button { model.send(.finish) } label: {
                    TimerSymbol(symbol: "stop.fill", diameter: 34, nativeGlass: true)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .help("结束（⌘ .）")
                .accessibilityLabel("结束")
                .disabled(!model.state.isActive)
                .opacity(model.state.isActive ? 1 : 0)
                .allowsHitTesting(model.state.isActive)
                .accessibilityHidden(!model.state.isActive)
            }
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
    }

    private func selected(_ minutes: Int) -> Bool { Int(model.state.duration / 60) == minutes }

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
            case .done: Label("已结束", systemImage: "checkmark")
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
            HStack(spacing: 16) {
                Color.clear.frame(width: 40, height: 40)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Button { model.send(model.state.primaryAction) } label: {
                    TimerSymbol(symbol: model.state.primarySymbol, primary: true, nativeGlass: true)
                }
                .help("\(model.state.primaryLabel)（空格）")
                .accessibilityLabel(model.state.primaryLabel)
                Button { model.send(.finish) } label: { TimerSymbol(symbol: "stop.fill", nativeGlass: true) }
                    .help("结束（⌘ .）")
                    .accessibilityLabel("结束")
                    .disabled(!model.state.isActive)
                    .opacity(model.state.isActive ? 1 : 0)
                    .allowsHitTesting(model.state.isActive)
                    .accessibilityHidden(!model.state.isActive)
            }
        }
        .buttonStyle(.plain)
        .padding(24)
        .frame(width: 252)
    }
}

struct HistoryView: View {
    let state: FocusState
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("记录").font(.headline)
            if state.logs.isEmpty {
                Label("还没有记录", systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(Array(state.logs.reversed().prefix(30)), id: \.id) { log in
                            HStack(spacing: 12) {
                                Image(systemName: log.completed ? "checkmark.circle" : "circle.lefthalf.filled")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(log.task.isEmpty ? "专注" : log.task).lineLimit(1)
                                    Text(log.endedAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(max(1, Int(ceil(log.seconds / 60)))) 分").monospacedDigit()
                            }
                        }
                    }
                }.frame(maxHeight: 270)
            }
        }
        .font(.system(size: 13))
        .padding(22)
        .frame(width: 290)
    }
}
