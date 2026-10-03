import AppKit
import SwiftUI

struct WidgetPreview: View {
    let state: FocusState
    let medium: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        FocusWidgetFace(state: state, medium: medium, live: false) {
            TimerSymbol(symbol: state.primarySymbol, primary: true, diameter: medium ? 46 : 34)
        } secondary: {
            TimerSymbol(symbol: state.isActive ? "stop.fill" : "cup.and.saucer", diameter: 34)
        }
        .padding(18)
        .frame(width: medium ? 344 : 170, height: 170)
        .background {
            // ImageRenderer cannot sample a WindowServer/WidgetKit backdrop.
            // This is an explicit translucent color study, not a fake desktop capture.
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            shape.fill(scheme == .dark ? FocusPalette.slate.opacity(0.77) : FocusPalette.mist.opacity(0.88))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.65))
        }
        .shadow(color: .black.opacity(0.12), radius: 15, y: 9)
    }
}

struct PreviewBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.68, green: 0.80, blue: 0.87), Color(red: 0.26, green: 0.40, blue: 0.52)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Path { path in
                    let w = geometry.size.width, h = geometry.size.height
                    path.move(to: CGPoint(x: 0, y: h * 0.7))
                    path.addCurve(to: CGPoint(x: w, y: h * 0.27), control1: CGPoint(x: w * 0.48, y: h * 0.68), control2: CGPoint(x: w * 0.58, y: h * 0.23))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                }
                .fill(Color(red: 0.11, green: 0.25, blue: 0.35).opacity(0.36))
                .blur(radius: 16)
            }
        }
    }
}

struct PreviewSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .firstTextBaseline) {
                Text("留白").font(.system(size: 23, weight: .medium))
                Spacer()
                Text("字体与配色预览").font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
            }
            .foregroundStyle(.white)
            HStack(spacing: 28) {
                WidgetPreview(state: FocusState(), medium: false)
                WidgetPreview(state: FocusState(), medium: true)
            }
            .environment(\.colorScheme, .dark)
            HStack(spacing: 28) {
                WidgetPreview(state: FocusState(mode: .rest), medium: false)
                WidgetPreview(state: FocusState(duration: 1500).applying(.start).applying(.pause, at: Date().addingTimeInterval(227)), medium: true)
            }
            .environment(\.colorScheme, .light)
            Text("静态材质示意 · 实际模糊与透明效果由 macOS 合成")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
        }
        .padding(48)
        .background(PreviewBackdrop())
        .environment(\.colorScheme, .light)
    }
}

@main
struct RenderPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let output = CommandLine.arguments.dropFirst().first ?? "widget-preview.png"
        let renderer = ImageRenderer(content: PreviewSheet())
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { fatalError("SwiftUI render failed") }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        print(output)
    }
}
