import Foundation

/// The task list owns the window. Focus mode reuses a compact, bounded layout.
struct FocusWindowLayout {
    static let minimumSize = CGSize(width: 360, height: 400)
    static let defaultSize = CGSize(width: 760, height: 540)
    static let timerReferenceSize = CGSize(width: 348, height: 430)
    static let sidebarMinimumWidth: CGFloat = 160
    static let sidebarIdealWidth: CGFloat = 196
    static let sidebarMaximumWidth: CGFloat = 260

    static let sidebarCollapseWidth: CGFloat = 560

    /// A restored or user-resized sidebar must leave a readable task list.
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
