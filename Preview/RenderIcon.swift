import AppKit
import SwiftUI

private func hex(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 255) / 255,
          green: Double((value >> 8) & 255) / 255,
          blue: Double(value & 255) / 255)
}

private struct DawnMark: View {
    var small = false
    var monochrome = false
    private let center = CGPoint(x: 512, y: 506)
    private let radius: CGFloat = 188

    private var sunColor: LinearGradient {
        LinearGradient(colors: monochrome
            ? [hex(0x313743), hex(0x313743)]
            : [hex(0xF499B7), hex(0xF5AD96), hex(0xF3C98D)],
            startPoint: UnitPoint(x: 0.5, y: 0.311),
            endPoint: UnitPoint(x: 0.5, y: 0.542))
    }

    // About three fifths of the raised disk sit above the water. Its lower edge follows
    // the same wave as the sea, leaving a narrow, genuinely transparent gap.
    private var sun: Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2))
    }

    private var aboveWater: Path {
        Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: 1024, y: 0))
            p.addLine(to: CGPoint(x: 1024, y: 542))
            p.addLine(to: CGPoint(x: 742, y: 542))
            p.addCurve(to: CGPoint(x: 578, y: 542), control1: CGPoint(x: 678, y: 516), control2: CGPoint(x: 642, y: 516))
            p.addCurve(to: CGPoint(x: 446, y: 542), control1: CGPoint(x: 544, y: 556), control2: CGPoint(x: 480, y: 556))
            p.addCurve(to: CGPoint(x: 282, y: 542), control1: CGPoint(x: 382, y: 516), control2: CGPoint(x: 346, y: 516))
            p.addLine(to: CGPoint(x: 0, y: 542))
            p.closeSubpath()
        }
    }

    private var upperWave: Path {
        Path { p in
            p.move(to: CGPoint(x: 282, y: 578))
            p.addCurve(to: CGPoint(x: 446, y: 578), control1: CGPoint(x: 346, y: 552), control2: CGPoint(x: 382, y: 552))
            p.addCurve(to: CGPoint(x: 578, y: 578), control1: CGPoint(x: 480, y: 592), control2: CGPoint(x: 544, y: 592))
            p.addCurve(to: CGPoint(x: 742, y: 578), control1: CGPoint(x: 642, y: 552), control2: CGPoint(x: 678, y: 552))
        }
    }

    private var lowerWave: Path {
        Path { p in
            p.move(to: CGPoint(x: 354, y: 649))
            p.addCurve(to: CGPoint(x: 463, y: 649), control1: CGPoint(x: 403, y: 635), control2: CGPoint(x: 430, y: 635))
            p.addCurve(to: CGPoint(x: 561, y: 649), control1: CGPoint(x: 488, y: 661), control2: CGPoint(x: 536, y: 661))
            p.addCurve(to: CGPoint(x: 670, y: 649), control1: CGPoint(x: 594, y: 635), control2: CGPoint(x: 621, y: 635))
        }
    }

    var body: some View {
        ZStack {
            sun.fill(sunColor).mask(aboveWater.fill(.white))
            upperWave
                .stroke(LinearGradient(colors: monochrome
                    ? [hex(0x313743), hex(0x313743)]
                    : [hex(0xA7AEEF), hex(0x8F96DF)], startPoint: UnitPoint(x: 0.5, y: 0.52), endPoint: UnitPoint(x: 0.5, y: 0.59)),
                        style: StrokeStyle(lineWidth: small ? 40 : 34, lineCap: .round, lineJoin: .round))
            lowerWave
                .stroke(LinearGradient(colors: monochrome
                    ? [hex(0x313743), hex(0x313743)]
                    : [hex(0xABB9ED), hex(0x94A4DF)], startPoint: UnitPoint(x: 0.5, y: 0.61), endPoint: UnitPoint(x: 0.5, y: 0.66)),
                        style: StrokeStyle(lineWidth: small ? 30 : 24, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 1024, height: 1024)
    }
}

private struct AppIconView: View {
    let size: CGFloat
    var tile = true
    var monochrome = false
    var body: some View {
        ZStack {
            if tile {
                RoundedRectangle(cornerRadius: 190, style: .continuous)
                    .fill(LinearGradient(colors: [.white, hex(0xF8FAFD)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: 190, style: .continuous)
                            .strokeBorder(hex(0xCDD3DD).opacity(0.35), lineWidth: 1.2)
                    }
                    .frame(width: 824, height: 824)
                    .shadow(color: hex(0x24314D).opacity(0.10), radius: 16, y: 10)
            }
            DawnMark(small: size <= 64, monochrome: monochrome)
        }
        .frame(width: 1024, height: 1024)
        .scaleEffect(size / 1024)
        .frame(width: size, height: size)
    }
}

@main private struct RenderIcon {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let view = AppIconView(size: CGFloat(pixels)).environment(\.colorScheme, .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                guard let image = renderer.cgImage else { fatalError("Icon render failed") }
                let suffix = scale == 2 ? "@2x" : ""
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
    }
}
