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

    var body: some View {
        AppearanceProbe(readback: readback)
            .frame(width: 320, height: 360)
            .background(NativeWindowSurface())
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for selection in [FocusAppearance.dark, .system, .light, .system, .dark, .light, .system] {
            controller.selection = selection
            settle(host)
            let expected = scheme(application.effectiveAppearance)
            expect(controller.colorScheme == expected, "controller resolves \(selection) from AppKit")
            expect(readback.scheme == expected, "hosted SwiftUI content matches \(selection)")
            expect(scheme(window.effectiveAppearance) == expected, "native window matches \(selection); app=\(application.effectiveAppearance.name), window=\(window.effectiveAppearance.name), windowOverride=\(String(describing: window.appearance?.name)), host=\(host.effectiveAppearance.name)")
            expect(readback.view.map { scheme($0.effectiveAppearance) } == expected, "native content matches \(selection)")
            guard let material = backdrop(in: host) else { fatalError("Missing real native backdrop") }
            expect(material.appearance == nil, "material inherits instead of retaining an override")
            expect(scheme(material.effectiveAppearance) == expected, "material and foreground agree")
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

        let minimum = FocusWindowLayout.minimumSize
        let sizes = [minimum, FocusWindowLayout.defaultSize, CGSize(width: 720, height: 640),
                     CGSize(width: 320, height: 800), CGSize(width: 900, height: 360)]
        for size in sizes {
            let layout = FocusWindowLayout(size: size)
            expect(layout.contentWidth <= size.width - 40, "content keeps horizontal insets at \(size)")
            expect(layout.contentHeight <= size.height - FocusWindowLayout.toolbarHeight, "content fits below toolbar at \(size)")
            expect(layout.timerSize >= 72 && layout.timerSize <= 112, "readout remains within readable scale bounds")
            expect(layout.contentWidth >= 205, "all three duration buttons fit")
            // Picker + readout/status + presets + controls + required gaps.
            let fixedControlsHeight: CGFloat = 220
            let requiredHeight = fixedControlsHeight + ceil(layout.timerSize * 1.16)
            expect(requiredHeight <= layout.contentHeight, "full control stack fits at \(size)")
        }
        expect(FocusWindowLayout(size: CGSize(width: 720, height: 640)).timerSize > FocusWindowLayout(size: minimum).timerSize,
               "enlarging both dimensions enlarges the timer")
        print("PASS: \(count) window checks; real AppKit/SwiftUI appearance transitions and responsive size bounds.")
    }
}
