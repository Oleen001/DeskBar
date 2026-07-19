import Lottie
import SwiftUI

/// The new DeskBar companion uses the supplied Lottie artwork directly. For now it remains
/// in its calm idle loop; the other supplied reactions are bundled for later state mapping.
struct WhiteDogView: View {
    static let stripHeight: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dogSize = CGSize(width: 96, height: 96)

    var body: some View {
        GeometryReader { proxy in
            WhiteDogLottieView(plays: !reduceMotion)
                .frame(width: dogSize.width, height: dogSize.height)
                .clipped()
                .position(
                    x: restingX(in: proxy.size.width),
                    y: Self.stripHeight / 2
                )
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("White dog companion resting")
    }

    private func restingX(in width: CGFloat) -> CGFloat {
        let halfWidth = dogSize.width / 2
        return min(max(halfWidth, width * 0.16), max(halfWidth, width - halfWidth))
    }
}

private struct WhiteDogLottieView: NSViewRepresentable {
    let plays: Bool

    func makeNSView(context: Context) -> WhiteDogAnimationContainer {
        let container = WhiteDogAnimationContainer()
        updatePlayback(of: container.animationView)
        return container
    }

    func updateNSView(_ container: WhiteDogAnimationContainer, context: Context) {
        updatePlayback(of: container.animationView)
    }

    private func updatePlayback(of view: LottieAnimationView) {
        if plays {
            guard !view.isAnimationPlaying else { return }
            view.play()
        } else {
            view.stop()
            view.currentProgress = 0
        }
    }
}

private final class WhiteDogAnimationContainer: NSView {
    let animationView = LottieAnimationView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        animationView.animation = LottieAnimation.named(
            "idle-white-dog-character",
            bundle: .main,
            subdirectory: "WhiteDog"
        )
        animationView.loopMode = .loop
        animationView.contentMode = .scaleAspectFit
        animationView.backgroundBehavior = .pauseAndRestore
        animationView.frame = bounds
        animationView.autoresizingMask = [.width, .height]
        addSubview(animationView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        animationView.frame = bounds
    }
}
