import Foundation

/// Keep the timer readable at the minimum size without stretching a compact
/// utility into a full-window dashboard when the window is enlarged.
struct FocusWindowLayout {
    static let minimumSize = CGSize(width: 320, height: 400)
    static let defaultSize = CGSize(width: 348, height: 430)
    static let toolbarHeight: CGFloat = 34

    let timerSize: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat

    init(size: CGSize) {
        let scale = min(size.width / Self.defaultSize.width, size.height / Self.defaultSize.height)
        timerSize = min(112, max(72, 78 * scale))
        contentWidth = min(480, max(0, size.width - 40))
        contentHeight = min(480, max(0, size.height - Self.toolbarHeight))
    }
}
