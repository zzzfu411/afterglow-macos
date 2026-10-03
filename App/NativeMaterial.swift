import AppKit
import SwiftUI

enum FocusAppearance: String, CaseIterable {
    case system, light, dark
    var title: String {
        switch self { case .system: "自动"; case .light: "浅色"; case .dark: "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

/// An actual WindowServer backdrop. SwiftUI Material alone only blurs content
/// inside an otherwise opaque window and cannot reveal the user's desktop.
struct NativeWindowMaterial: NSViewRepresentable {
    var opaque: Bool
    var dark: Bool

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.appearance = NSAppearance(named: dark ? .vibrantDark : .vibrantLight)
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.material = opaque ? .windowBackground : .hudWindow
        view.state = .active
        view.appearance = NSAppearance(named: dark ? .vibrantDark : .vibrantLight)
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
            NativeWindowMaterial(opaque: reduceTransparency, dark: scheme == .dark)
            if reduceTransparency {
                (scheme == .dark ? FocusPalette.slate : FocusPalette.mist)
            } else {
                (scheme == .dark ? FocusPalette.slate : FocusPalette.mist).opacity(scheme == .dark ? 0.30 : 0.08)
            }
        }
        .ignoresSafeArea()
    }
}
