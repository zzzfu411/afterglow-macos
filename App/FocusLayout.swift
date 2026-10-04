import Foundation

/// Keep the timer readable at the minimum size without stretching a compact
/// utility into a full-window dashboard when the window is enlarged.
struct FocusWindowLayout {
    static let minimumSize = CGSize(width: 320, height: 400)
    static let defaultSize = CGSize(width: 620, height: 480)
    static let timerReferenceSize = CGSize(width: 348, height: 430)
    static let sidebarMinimumWidth: CGFloat = 160
    static let sidebarIdealWidth: CGFloat = 210
    static let sidebarMaximumWidth: CGFloat = 340

    /// A restored or user-resized sidebar must leave room for the timer.
    static func sidebarWidthLimit(windowWidth: CGFloat) -> CGFloat {
        min(sidebarMaximumWidth, max(sidebarMinimumWidth, windowWidth - minimumSize.width - 1))
    }

    let timerSize: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat

    init(size: CGSize) {
        let scale = min(size.width / Self.timerReferenceSize.width, size.height / Self.timerReferenceSize.height)
        timerSize = min(112, max(72, 78 * scale))
        contentWidth = min(480, max(0, size.width - 40))
        // The native title-bar toolbar is already outside the detail geometry.
        contentHeight = min(480, max(0, size.height))
    }
}
