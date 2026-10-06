import SwiftUI
import WidgetKit

struct FocusEntry: TimelineEntry {
    let date: Date
    let state: FocusState
    var unavailable = false
}

struct FocusProvider: TimelineProvider {
    func placeholder(in context: Context) -> FocusEntry { FocusEntry(date: Date(), state: FocusState()) }
    func getSnapshot(in context: Context, completion: @escaping (FocusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FocusEntry>) -> Void) {
        let current = entry()
        if current.state.status == .running, let end = current.state.deadline, end > current.date {
            let finished = current.state.applying(.settle, at: end)
            completion(Timeline(entries: [current, FocusEntry(date: end, state: finished)], policy: .after(end)))
        } else {
            completion(Timeline(entries: [current], policy: .after(current.date.addingTimeInterval(900))))
        }
    }
    private func entry() -> FocusEntry {
        do { return FocusEntry(date: Date(), state: try FocusStore.shared.snapshot()) }
        catch { return FocusEntry(date: Date(), state: FocusState(), unavailable: true) }
    }
}

struct FocusWidgetView: View {
    let entry: FocusEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    var body: some View {
        Group {
            if entry.unavailable {
                Link(destination: URL(string: "afterglow://open")!) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "rectangle.3.group").font(.title2)
                        Text("打开 Moro").font(.headline)
                        Text("检查共享数据").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            } else {
                FocusWidgetFace(state: entry.state, medium: family == .systemMedium, date: entry.date) {
                    Button(intent: ToggleTimerIntent()) {
                        TimerSymbol(symbol: entry.state.primarySymbol, primary: true, diameter: family == .systemMedium ? 46 : 34)
                    }
                    .buttonStyle(.plain)
                    .widgetAccentable()
                    .accessibilityLabel(entry.state.primaryLabel)
                } secondary: {
                    if entry.state.isActive {
                        Button(intent: FinishTimerIntent()) { TimerSymbol(symbol: "stop.fill", diameter: 34) }
                            .buttonStyle(.plain).accessibilityLabel("结束")
                    } else if entry.state.status == .done {
                        Button(intent: WrapUpTimerIntent()) { TimerSymbol(symbol: "checkmark", diameter: 34) }
                            .buttonStyle(.plain).accessibilityLabel("收工")
                    } else {
                        Button(intent: RestTimerIntent()) { TimerSymbol(symbol: "cup.and.saucer", diameter: 34) }
                            .buttonStyle(.plain).accessibilityLabel("开始休息")
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .containerBackground(for: .widget) { FocusGlassSurface() }
        // macOS owns transparency in vibrant/accented modes. Keep all decoration
        // removable and preserve foreground opacity instead of painting a card.
        .environment(\.colorScheme, foregroundScheme)
        .widgetURL(URL(string: "afterglow://open"))
    }

    @Environment(\.colorScheme) private var colorScheme
    private var foregroundScheme: ColorScheme {
        renderingMode == .fullColor || showsBackground ? colorScheme : .dark
    }
}

@main
struct AfterglowWidgets: WidgetBundle {
    var body: some Widget { AfterglowWidget() }
}

struct AfterglowWidget: Widget {
    let kind = "AfterglowFocus"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FocusProvider()) { FocusWidgetView(entry: $0) }
            .configurationDisplayName("Moro")
            .description("专注片刻，休息一下。")
            .supportedFamilies([.systemSmall, .systemMedium])
            .containerBackgroundRemovable(true)
    }
}
