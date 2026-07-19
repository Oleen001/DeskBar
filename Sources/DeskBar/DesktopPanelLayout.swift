import CoreGraphics

enum DesktopPanelLayout {
    static func dashboardSize(
        visibleFrame: CGRect,
        maximumWidth: CGFloat = 1200,
        horizontalInset: CGFloat = 28,
        compactBreakpoint: CGFloat = 1080,
        wideHeight: CGFloat = 276,
        compactHeight: CGFloat = 436
    ) -> CGSize {
        let width = min(maximumWidth, max(1, visibleFrame.width - horizontalInset * 2))
        return CGSize(
            width: width,
            height: width < compactBreakpoint ? compactHeight : wideHeight
        )
    }

    static func frame(
        visibleFrame: CGRect,
        preferredSize: CGSize,
        horizontalInset: CGFloat = 28,
        bottomInset: CGFloat = 18
    ) -> CGRect {
        let availableWidth = max(1, visibleFrame.width - horizontalInset * 2)
        let width = min(preferredSize.width, availableWidth)
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + bottomInset,
            width: width,
            height: preferredSize.height
        )
    }

    static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }
}
