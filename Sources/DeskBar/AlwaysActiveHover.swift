import AppKit
import SwiftUI

private struct AlwaysActiveHoverView: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        HoverTrackingNSView(onHover: onHover)
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onHover = onHover
    }
}

private final class HoverTrackingNSView: NSView {
    var onHover: (Bool) -> Void
    private var hoverTrackingArea: NSTrackingArea?

    init(onHover: @escaping (Bool) -> Void) {
        self.onHover = onHover
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension View {
    func alwaysActiveHover(_ onHover: @escaping (Bool) -> Void) -> some View {
        background(AlwaysActiveHoverView(onHover: onHover))
    }
}
