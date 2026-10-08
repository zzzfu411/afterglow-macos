import Foundation

/// Both known boundaries are in the timeline, so the display still advances if
/// WidgetKit defers the refresh request. Static widgets only wake at local midnight.
enum TodoWidgetSchedule {
    static func dates(after now: Date, snapshot: TodoWidgetSnapshot, calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)), midnight > now {
            dates.append(midnight)
        }
        if snapshot.timer.status == .running, let deadline = snapshot.timer.deadline, deadline > now {
            dates.append(deadline)
        }
        return Array(Set(dates)).sorted()
    }
}

#if !MORO_WIDGET_SNAPSHOT_TESTS
import SwiftUI
import WidgetKit

struct FocusEntry: TimelineEntry {
    let date: Date
    let snapshot: TodoWidgetSnapshot
    var unavailable = false
    var state: FocusState { snapshot.timer }
    var today: [TodoWidgetItem] { snapshot.today(at: date) }
}

struct FocusProvider: TimelineProvider {
    func placeholder(in context: Context) -> FocusEntry {
        let now = Date(), day = Calendar.current.startOfDay(for: now)
        var state = FocusState()
        for (index, title) in ["整理今天的安排", "留一段时间阅读", "散步十分钟"].enumerated() {
            state = state.applying(.upsertTodo(FocusTodo(title: title, plannedDate: day, sortOrder: index)), at: now)
        }
        return FocusEntry(date: now, snapshot: TodoWidgetSnapshot(state: state))
    }

    func getSnapshot(in context: Context, completion: @escaping (FocusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FocusEntry>) -> Void) {
        let current = entry()
        let boundaries = TodoWidgetSchedule.dates(after: current.date, snapshot: current.snapshot)
        let future = boundaries.map { date in
            FocusEntry(date: date, snapshot: current.snapshot.settled(at: date), unavailable: current.unavailable)
        }
        let policy: TimelineReloadPolicy = boundaries.first.map { .after($0) } ?? .never
        completion(Timeline(entries: [current] + future, policy: policy))
    }

    private func entry() -> FocusEntry {
        let now = Date()
        guard let directory = FocusStore.shared.directoryURL,
              let snapshot = try? TodoWidgetCache.read(directory: directory, at: now) else {
            return FocusEntry(date: now, snapshot: TodoWidgetSnapshot(state: FocusState()), unavailable: true)
        }
        return FocusEntry(date: now, snapshot: snapshot)
    }
}

struct FocusWidgetView: View {
    let entry: FocusEntry
    /// Only the static renderer supplies these values. Runtime widgets obtain
    /// their family and live dates from WidgetKit as usual.
    var previewFamily: WidgetFamily? = nil
    var live = true
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    @Environment(\.colorScheme) private var colorScheme

    private var medium: Bool { (previewFamily ?? family) == .systemMedium }
    private var itemLimit: Int { medium ? 3 : 2 }
    private var openURL: URL { URL(string: "afterglow://open")! }

    @ViewBuilder var body: some View {
        if previewFamily != nil { content }
        else {
            content
                .containerBackground(for: .widget) { FocusGlassSurface() }
                .widgetURL(openURL)
        }
    }

    private var content: some View {
        Group {
            if entry.unavailable { unavailable }
            else { todayList }
        }
        .foregroundStyle(.primary)
        // All decoration stays in the removable container. The desktop controls
        // material; text retains contrast when the system removes that container.
        .environment(\.colorScheme, foregroundScheme)
    }

    private var todayList: some View {
        let items = entry.today
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max").font(.system(size: 12, weight: .medium)).widgetAccentable()
                Text("今天").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                if !items.isEmpty {
                    Text(items.count.formatted()).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(secondaryColor)
                        .accessibilityLabel("今天 \(items.count) 项")
                }
            }
            if items.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "checkmark.circle").font(.system(size: 22, weight: .light))
                    Text("今天没有待办").font(.system(size: 12))
                }
                .foregroundStyle(secondaryColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: medium ? 5 : 7) {
                    ForEach(Array(items.prefix(itemLimit))) { item in
                        Link(destination: URL(string: "afterglow://todo/\(item.id.uuidString)")!) {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Image(systemName: "circle.fill").font(.system(size: 3)).foregroundStyle(secondaryColor)
                                    .accessibilityHidden(true)
                                Text(item.title).font(.system(size: 13))
                                    .lineLimit(medium ? 1 : 2).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: medium ? 19 : 23, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开事项：\(item.title)")
                    }
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(secondaryColor.opacity(0.2)).frame(height: 0.5).accessibilityHidden(true)
            timerFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var timerFooter: some View {
        if entry.state.isActive {
            HStack(spacing: 4) {
                if medium {
                    Label(entry.state.mode.title, systemImage: entry.state.mode.symbol)
                        .font(.system(size: 11)).foregroundStyle(secondaryColor)
                }
                TimerReadout(state: entry.state, size: 17, date: entry.date, live: live)
                    .accessibilityHint(entry.state.status == .paused ? "计时已暂停" : "剩余时间")
                Spacer(minLength: 2)
                Button(intent: ToggleTimerIntent()) {
                    Image(systemName: entry.state.status == .running ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .medium)).frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .widgetAccentable()
                .accessibilityLabel((entry.state.status == .running ? "暂停" : "继续") + entry.state.mode.title)
                Button(intent: FinishTimerIntent()) {
                    Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("结束本轮")
            }
            .buttonStyle(.plain)
        } else {
            Link(destination: openURL) {
                HStack(spacing: 5) {
                    if entry.state.status == .done {
                        Image(systemName: "checkmark")
                        Text(entry.state.mode == .focus ? "专注结束" : "休息结束")
                    } else { Text("Moro") }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward")
                }
                .font(.system(size: 11)).foregroundStyle(secondaryColor)
                .frame(minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.state.status == .done ? "本轮结束，打开 Moro" : "打开 Moro")
        }
    }

    private var unavailable: some View {
        Link(destination: openURL) {
            VStack(alignment: .leading, spacing: 11) {
                Image(systemName: "checklist").font(.system(size: 25, weight: .light))
                Label("打开 Moro", systemImage: "arrow.up.forward").font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var foregroundScheme: ColorScheme {
        previewFamily != nil || renderingMode == .fullColor || showsBackground ? colorScheme : .dark
    }
    private var secondaryColor: Color {
        renderingMode == .fullColor ? .secondary : .primary.opacity(0.85)
    }
}

#if !MORO_WIDGET_PREVIEW
@main
struct AfterglowWidgets: WidgetBundle {
    var body: some Widget { AfterglowWidget() }
}
#endif

struct AfterglowWidget: Widget {
    let kind = "AfterglowFocus"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FocusProvider()) { FocusWidgetView(entry: $0) }
            .configurationDisplayName("Moro")
            .description("今天的待办与当前专注。")
            .supportedFamilies([.systemSmall, .systemMedium])
            .containerBackgroundRemovable(true)
    }
}
#endif
