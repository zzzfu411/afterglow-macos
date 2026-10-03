import AppKit
import SwiftUI

struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 190, style: .continuous)
                .fill(Color.white)
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.14), radius: 18, y: 9)
            ForEach(0..<12, id: \.self) { tick in
                Circle().fill(Color(red: 0.76, green: 0.78, blue: 0.81))
                    .frame(width: 20, height: 20)
                    .offset(y: -257)
                    .rotationEffect(.degrees(Double(tick) * 30))
            }
            Circle().stroke(Color(red: 0.15, green: 0.17, blue: 0.20), lineWidth: 26)
                .frame(width: 344, height: 344)
            Circle().trim(from: 0, to: 0.23)
                .stroke(Color(red: 0, green: 0.48, blue: 1), style: StrokeStyle(lineWidth: 28, lineCap: .round))
                .frame(width: 344, height: 344)
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 1024, height: 1024)
    }
}

@main struct RenderIcon {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let renderer = ImageRenderer(content: AppIconView().scaleEffect(CGFloat(pixels) / 1024).frame(width: CGFloat(pixels), height: CGFloat(pixels)))
                renderer.scale = 1
                guard let cgImage = renderer.cgImage else { fatalError("Icon render failed") }
                let suffix = scale == 2 ? "@2x" : ""
                let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])!
                try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
    }
}
