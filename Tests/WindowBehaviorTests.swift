import AppKit
import SwiftUI

@MainActor
private final class AppearanceReadback {
    var scheme: ColorScheme?
    var view: NSView?
}

private struct AppearanceProbe: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    let readback: AppearanceReadback

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        readback.view = view
        readback.scheme = scheme
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        readback.scheme = scheme
    }
}

private struct AppearanceHost: View {
    @ObservedObject var controller: FocusAppearanceController
    let readback: AppearanceReadback
    var sidebar = false
    var reduceTransparency = false

    var body: some View {
        AppearanceProbe(readback: readback)
            .frame(width: 360, height: 400)
            .background {
                if sidebar { NativeSidebarSurface(forceOpaque: reduceTransparency) }
                else { NativeWindowSurface() }
            }
            .environment(\.colorScheme, controller.colorScheme)
    }
}

@main
struct WindowBehaviorTests {
    @MainActor private static var count = 0

    @MainActor private static func expect(_ assertion: Bool, _ message: String) {
        guard assertion else { fatalError("FAIL: \(message)") }
        count += 1
    }

    @MainActor private static func scheme(_ appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    @MainActor private static func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    @MainActor private static func backdrop(in view: NSView) -> NSVisualEffectView? {
        if let result = view as? NSVisualEffectView { return result }
        return view.subviews.lazy.compactMap { backdrop(in: $0) }.first
    }

    @MainActor static func main() {
        // A separate test process, with an unshown window and isolated defaults.
        // No system appearance, real timer state, or user preferences are changed.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        let suite = "afterglow-window-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FocusAppearanceController(selection: .system, application: application, defaults: defaults)
        let readback = AppearanceReadback()
        let host = NSHostingView(rootView: AppearanceHost(controller: controller, readback: readback))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let sidebarReadback = AppearanceReadback()
        let sidebarHost = NSHostingView(rootView: AppearanceHost(controller: controller, readback: sidebarReadback, sidebar: true))
        let sidebarWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 196, height: 400),
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sidebarWindow.isReleasedWhenClosed = false
        sidebarWindow.contentView = sidebarHost
        defer { sidebarWindow.close() }

        for selection in [FocusAppearance.dark, .system, .light, .system, .dark, .light, .system] {
            controller.selection = selection
            settle(host); settle(sidebarHost)
            let expected = scheme(application.effectiveAppearance)
            expect(controller.colorScheme == expected, "controller resolves \(selection) from AppKit")
            expect(readback.scheme == expected, "hosted SwiftUI content matches \(selection)")
            expect(scheme(window.effectiveAppearance) == expected, "native window matches \(selection); app=\(application.effectiveAppearance.name), window=\(window.effectiveAppearance.name), windowOverride=\(String(describing: window.appearance?.name)), host=\(host.effectiveAppearance.name)")
            expect(readback.view.map { scheme($0.effectiveAppearance) } == expected, "native content matches \(selection)")
            expect(backdrop(in: host) == nil, "task content remains a stable opaque surface in \(selection)")
            expect(window.isOpaque, "task surface does not make the native window transparent")
            guard let material = backdrop(in: sidebarHost) else { fatalError("Missing native sidebar material") }
            expect(material.material == .sidebar, "vibrancy is restricted to the sidebar material")
            expect(material.state == .followsWindowActiveState, "sidebar responds to active and inactive windows")
            expect(material.appearance == nil, "sidebar inherits instead of retaining an override")
            expect(scheme(material.effectiveAppearance) == expected, "sidebar material and foreground agree")
            expect(sidebarReadback.scheme == expected, "sidebar text follows \(selection)")
            if selection == .system {
                expect(application.appearance == nil, "Auto removes explicit app appearance")
            }
        }
        expect(defaults.string(forKey: "afterglow.appearance") == "system", "selection persists in isolated defaults")

        // Emulate an effective-appearance change inside this test process. The
        // automatic controller must react through observation, not a timer.
        let previousScheme = controller.colorScheme
        application.appearance = NSAppearance(named: previousScheme == .dark ? .aqua : .darkAqua)
        settle(host)
        expect(controller.selection == .system && controller.colorScheme != previousScheme, "Auto observes effective appearance changes")
        expect(readback.scheme == controller.colorScheme, "observed change reaches SwiftUI")
        application.appearance = nil
        settle(host)
        expect(readback.scheme == scheme(application.effectiveAppearance), "return to inherited appearance reaches content")

        sidebarHost.rootView = AppearanceHost(controller: controller, readback: sidebarReadback,
                                              sidebar: true, reduceTransparency: true)
        settle(sidebarHost)
        expect(backdrop(in: sidebarHost) == nil, "the Reduce Transparency fallback replaces sidebar vibrancy with a solid surface")
        expect(sidebarReadback.scheme == controller.colorScheme, "solid sidebar keeps the same readable appearance")
        sidebarHost.rootView = AppearanceHost(controller: controller, readback: sidebarReadback, sidebar: true)
        settle(sidebarHost)
        expect(backdrop(in: sidebarHost)?.material == .sidebar, "leaving the solid fallback restores sidebar material")

        let minimum = FocusWindowLayout.minimumSize
        expect(minimum == CGSize(width: 360, height: 400), "compact task window retains a readable single column")
        expect(FocusWindowLayout.defaultSize == CGSize(width: 760, height: 540), "default window gives tasks the primary reading area")
        expect(FocusWindowLayout.sidebarMinimumWidth == 160, "sidebar still supports the requested narrow width")
        expect(FocusWindowLayout.sidebarCollapseWidth > minimum.width + FocusWindowLayout.sidebarMinimumWidth,
               "navigation collapses before squeezing the task list below its minimum")
        for width: CGFloat in [560, 620, 760, 900] {
            let sidebarWidth = FocusWindowLayout.sidebarWidthLimit(windowWidth: width)
            expect(sidebarWidth >= FocusWindowLayout.sidebarMinimumWidth
                   && sidebarWidth <= FocusWindowLayout.sidebarMaximumWidth
                   && width - sidebarWidth - 1 >= minimum.width,
                   "sidebar resize leaves the full task list visible in a \(width)-point window")
        }
        let splitDetail = CGSize(width: FocusWindowLayout.defaultSize.width - FocusWindowLayout.sidebarIdealWidth - 1,
                                 height: FocusWindowLayout.defaultSize.height)
        expect(splitDetail.width >= minimum.width, "default split leaves enough space for long task titles and inline details")
        // The optional focus view is bounded; increasing the task window must
        // not turn the list into a large timer or remove content padding.
        for size in [minimum, splitDetail, CGSize(width: 900, height: 800)] {
            let layout = FocusWindowLayout(size: size)
            expect(layout.contentWidth <= min(480, size.width - 40), "optional focus view retains bounded content and horizontal insets")
            expect(layout.contentHeight <= size.height, "optional focus view fits beneath the native title bar")
            expect(layout.timerSize >= 72 && layout.timerSize <= 112, "optional readout has a bounded font size")
        }

        // Static and paused readouts must match the system live timer's format.
        for (duration, expected) in [(60.0, "1:00"), (1500.0, "25:00"), (3600.0, "1:00:00"),
                                     (5400.0, "1:30:00"), (10800.0, "3:00:00")] {
            expect(FocusState(duration: duration).clock() == expected, "consistent duration display: \(expected)")
        }
        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        let longPause = FocusState(duration: 5400).applying(.start, at: startedAt)
            .applying(.pause, at: startedAt.addingTimeInterval(1))
        expect(longPause.clock() == "1:29:59", "pausing does not switch hours into total minutes")
        for (seconds, expected) in [(0.2, "不足 1 秒"), (5.9, "5 秒"), (59.9, "59 秒"),
                                    (60.0, "1 分"), (61.0, "1 分 1 秒"), (1500.0, "25 分")] {
            let log = FocusLog(id: UUID(), task: "", startedAt: startedAt,
                               endedAt: startedAt.addingTimeInterval(seconds), seconds: seconds, completed: false)
            expect(log.durationLabel == expected, "history does not round up worked time: \(expected)")
        }
        print("PASS: \(count) window checks; real AppKit/SwiftUI appearance transitions and responsive size bounds.")
    }
}
