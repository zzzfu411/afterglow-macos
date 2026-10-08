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

/// Vibrancy belongs to navigation and chrome; the task reading surface stays
/// opaque so a busy desktop cannot reduce text contrast.
struct NativeWindowMaterial: NSViewRepresentable {
    var opaque: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = opaque ? .windowBackground : .sidebar
        view.state = .followsWindowActiveState
        view.appearance = nil
    }
}

struct NativeSidebarSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Unshown tests can exercise either branch without changing system settings.
    /// Production callers omit this and always honor the accessibility preference.
    var forceOpaque: Bool? = nil

    var body: some View {
        Group {
            if forceOpaque ?? reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                NativeWindowMaterial(opaque: false)
            }
        }
        .ignoresSafeArea()
    }
}

struct NativeWindowSurface: View {
    var body: some View {
        Color(nsColor: .textBackgroundColor).ignoresSafeArea()
    }
}
