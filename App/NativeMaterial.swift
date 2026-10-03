import AppKit
import SwiftUI

enum FocusAppearance: String, CaseIterable {
    case system, light, dark
    var title: String {
        switch self { case .system: "自动"; case .light: "浅色"; case .dark: "深色" }
    }
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// One appearance owner for both AppKit window chrome and SwiftUI content.
/// Per-presentation preferredColorScheme overrides can leave a Settings window's
/// native background and SwiftUI text out of sync when the preference becomes nil.
@MainActor
final class FocusAppearanceController: ObservableObject {
    @Published var selection: FocusAppearance {
        didSet {
            guard selection != oldValue else { return }
            defaults?.set(selection.rawValue, forKey: "afterglow.appearance")
            applySelection()
        }
    }
    @Published private(set) var colorScheme: ColorScheme

    private let application: NSApplication
    private let defaults: UserDefaults?
    private var appearanceObservation: NSKeyValueObservation?

    init(selection: FocusAppearance, application: NSApplication? = nil, defaults: UserDefaults? = nil) {
        self.selection = selection
        self.application = application ?? .shared
        self.defaults = defaults
        colorScheme = .light
        applySelection()
        appearanceObservation = self.application.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // AppKit can notify while updating its views. Publish on the next
            // main-loop turn, and read the latest appearance after rapid changes.
            DispatchQueue.main.async { [weak self] in self?.refreshColorScheme() }
        }
    }

    private func applySelection() {
        // nil removes the app override, so future system changes keep flowing
        // to existing windows, popovers, and newly created presentations.
        application.appearance = selection.appKitAppearance
        refreshColorScheme()
    }

    private func refreshColorScheme() {
        let match = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let resolved: ColorScheme = match == .darkAqua ? .dark : .light
        if colorScheme != resolved { colorScheme = resolved }
    }
}

/// An actual WindowServer backdrop. SwiftUI Material alone only blurs content
/// inside an otherwise opaque window and cannot reveal the user's desktop.
struct NativeWindowMaterial: NSViewRepresentable {
    var opaque: Bool

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.appearance = nil
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.material = opaque ? .windowBackground : .hudWindow
        view.state = .active
        // Inherit the same AppKit appearance as the window and text. A separate
        // vibrantLight/vibrantDark override can drift after returning to Auto.
        view.appearance = nil
    }

    final class BackdropView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.titlebarAppearsTransparent = true
        }
    }
}

struct NativeWindowSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            NativeWindowMaterial(opaque: reduceTransparency)
            if reduceTransparency {
                (scheme == .dark ? FocusPalette.slate : FocusPalette.mist)
            } else {
                (scheme == .dark ? FocusPalette.slate : FocusPalette.mist).opacity(scheme == .dark ? 0.30 : 0.08)
            }
        }
        .ignoresSafeArea()
    }
}
