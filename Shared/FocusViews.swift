import SwiftUI

enum FocusPalette {
    static let ice = Color(red: 0.73, green: 0.84, blue: 0.91)
    static let slate = Color(red: 0.17, green: 0.23, blue: 0.29)
    static let mist = Color(red: 0.88, green: 0.93, blue: 0.96)
}

/// WidgetKit may replace this entire background with its desktop glass material.
/// Foreground content never contains an opaque card or a wallpaper image.
struct FocusGlassSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(scheme == .dark ? FocusPalette.slate : FocusPalette.mist)
            } else {
                shape.fill(.ultraThinMaterial).opacity(scheme == .dark ? 0.72 : 0.82)
                shape.fill(scheme == .dark ? FocusPalette.slate.opacity(0.13) : FocusPalette.mist.opacity(0.08))
            }
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.32 : 0.68), .white.opacity(0.06), .white.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 0.65
            )
        }
    }
}

extension FocusMode {
    var title: String { self == .focus ? "专注" : "休息" }
    var symbol: String { self == .focus ? "circle.dotted.circle" : "cup.and.saucer" }
    var presets: [Int] { self == .focus ? [15, 25, 45] : [5, 10, 15] }
}

extension FocusState {
    var primarySymbol: String {
        if status == .done { return mode == .focus ? "cup.and.saucer" : "play.fill" }
        return status == .running ? "pause.fill" : "play.fill"
    }
    var primaryLabel: String {
        if status == .done { return mode == .focus ? "休息 \(Int(restDuration / 60)) 分" : "专注 \(Int(focusDuration / 60)) 分" }
        return status == .running ? "暂停" : (status == .paused ? "继续" : "开始")
    }
    var primaryAction: FocusAction { status == .done ? .startNext : (status == .running ? .pause : .start) }
    func clock(at date: Date = Date()) -> String {
        let seconds = max(0, Int(ceil(remaining(at: date))))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension FocusLog {
    var durationLabel: String {
        let wholeSeconds = max(0, Int(seconds.rounded(.down)))
        if wholeSeconds == 0 { return "不足 1 秒" }
        let minutes = wholeSeconds / 60
        let remainder = wholeSeconds % 60
        if minutes == 0 { return "\(wholeSeconds) 秒" }
        return remainder == 0 ? "\(minutes) 分" : "\(minutes) 分 \(remainder) 秒"
    }
}

struct TimerReadout: View {
    let state: FocusState
    var size: CGFloat = 80
    var date = Date()
    var live = true

    var body: some View {
        Group {
            if live, state.status == .running, let deadline = state.deadline, deadline > date {
                Text(timerInterval: date...deadline, countsDown: true)
            } else {
                Text(state.clock(at: date))
            }
        }
        .font(.system(size: size, weight: .light, design: .default))
        .monospacedDigit()
        .tracking(-size * 0.045)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .foregroundStyle(.primary)
    }
}

struct TimerSymbol: View {
    let symbol: String
    var primary = false
    var diameter: CGFloat = 40
    var nativeGlass = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if nativeGlass && !reduceTransparency {
            nativeControl
        } else {
            glyph
                .background(Color.primary.opacity(primary ? 0.13 : 0.055), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(primary ? 0.13 : 0.075), lineWidth: 0.65))
        }
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.28, weight: .medium))
            .offset(x: symbol == "play.fill" ? 1 : 0)
            .frame(width: diameter, height: diameter)
            .foregroundStyle(Color.primary.opacity(primary ? 0.94 : 0.70))
            .contentShape(Circle())
    }

    @ViewBuilder private var nativeControl: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glyph.glassEffect(.regular.tint(primary ? FocusPalette.ice.opacity(0.16) : nil).interactive(), in: Circle())
        } else {
            legacyControl
        }
        #else
        legacyControl
        #endif
    }

    private var legacyControl: some View {
        glyph
            .background(.thinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(scheme == .dark ? 0.20 : 0.65), lineWidth: 0.7))
    }
}

/// The same content is used by WidgetKit and the native design preview renderer.
/// WidgetKit supplies the real container, margins, appearance, and intent buttons.
struct FocusWidgetFace<Primary: View, Secondary: View>: View {
    let state: FocusState
    var medium = false
    var date = Date()
    var live = true
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary

    var body: some View {
        if medium {
            HStack(alignment: .center, spacing: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    modeLabel
                    Spacer(minLength: 10)
                    TimerReadout(state: state, size: 64, date: date, live: live)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 10)
                    footer
                }
                VStack(spacing: 12) {
                    primary()
                    secondary()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                modeLabel
                Spacer(minLength: 8)
                TimerReadout(state: state, size: 48, date: date, live: live)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                HStack {
                    footer
                    Spacer(minLength: 4)
                    primary()
                }
            }
        }
    }

    private var modeLabel: some View {
        Label(state.mode.title, systemImage: state.mode.symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary.opacity(0.78))
            .labelStyle(.titleAndIcon)
    }

    private var footer: some View {
        Group {
            if state.status == .done {
                Label("已结束", systemImage: "checkmark")
            } else if state.status == .paused {
                Text("已暂停")
            } else if state.status == .running, let deadline = state.deadline {
                Label {
                    Text(deadline, style: .time)
                } icon: {
                    Image(systemName: "clock")
                }
                .accessibilityLabel("结束时间 \(deadline.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("")
            }
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(.primary.opacity(0.65))
        .lineLimit(1)
    }
}
