import AppKit
import Lottie
import SwiftUI

enum WhiteDogAnimation: String, CaseIterable {
    case idle = "idle-white-dog-character"
    case ecstatic = "ecstatic-white-dog-celebrating"
    case clapping = "happy-white-dog-clapping-hands"
    case backflip = "cute-white-dog-performing-backflip"
    case sad = "sad-white-dog-sitting-alone"
    case sleepy = "sleepy-white-dog-nodding-off"
    case thinking = "thinking-white-dog-with-question-mark-bubbles"

    static let reactions = Self.allCases.filter { $0 != .idle }

    var loops: Bool { self == .idle }

    var accessibilityName: String {
        switch self {
        case .idle: "Resting"
        case .ecstatic: "Celebrating"
        case .clapping: "Clapping"
        case .backflip: "Doing a backflip"
        case .sad: "Sitting sadly"
        case .sleepy: "Nodding off"
        case .thinking: "Thinking"
        }
    }

    static func reactionCandidates(after previous: Self?) -> [Self] {
        reactions.filter { $0 != previous }
    }
}

/// The supplied white dog rests above DeskBar and plays a different one-shot reaction when clicked.
struct WhiteDogView: View {
    static let stripHeight: CGFloat = 88
    static let animationFrameOverlap: CGFloat = 10
    static let animationSize = CGSize(width: 96, height: 96)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animation: WhiteDogAnimation = .idle
    @State private var previousReaction: WhiteDogAnimation?
    @State private var isHovered = false
    @State private var isPressed = false
    @State private var reduceMotionResetTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            WhiteDogLottieView(animation: animation, plays: !reduceMotion) {
                guard animation != .idle else { return }
                animation = .idle
            }
                .frame(width: Self.animationSize.width, height: Self.animationSize.height)
                .clipped()
                .contentShape(Rectangle())
                .overlay {
                    WhiteDogInteractionView(
                        onHover: { isHovered = $0 },
                        onPressChanged: { isPressed = $0 },
                        onClick: playAnotherReaction
                    )
                }
                .scaleEffect(isPressed ? 0.96 : (isHovered ? 1.025 : 1))
                .brightness(isHovered ? 0.06 : 0)
                .opacity(isPressed ? 0.88 : 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: isHovered
                )
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.08),
                    value: isPressed
                )
                .position(
                    x: restingX(in: proxy.size.width),
                    y: Self.stripHeight - (Self.animationSize.height / 2) + Self.animationFrameOverlap
                )
                .accessibilityLabel("White dog companion")
                .accessibilityValue(animation.accessibilityName)
                .accessibilityHint("Plays another reaction")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, playAnotherReaction)
                .focusable()
                .onKeyPress(.space) {
                    playAnotherReaction()
                    return .handled
                }
                .onKeyPress(.return) {
                    playAnotherReaction()
                    return .handled
                }
        }
        .onChange(of: reduceMotion) { _, isEnabled in
            if isEnabled, animation != .idle {
                scheduleReducedMotionReset(for: animation)
            } else {
                reduceMotionResetTask?.cancel()
            }
        }
        .onDisappear { reduceMotionResetTask?.cancel() }
    }

    private func restingX(in width: CGFloat) -> CGFloat {
        let halfWidth = Self.animationSize.width / 2
        return min(max(halfWidth, width * 0.16), max(halfWidth, width - halfWidth))
    }

    private func playAnotherReaction() {
        reduceMotionResetTask?.cancel()
        guard let reaction = WhiteDogAnimation.reactionCandidates(after: previousReaction).randomElement() else {
            return
        }
        previousReaction = reaction
        animation = reaction

        if reduceMotion {
            scheduleReducedMotionReset(for: reaction)
        }
    }

    private func scheduleReducedMotionReset(for reaction: WhiteDogAnimation) {
        reduceMotionResetTask?.cancel()
        reduceMotionResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, animation == reaction else { return }
            animation = .idle
        }
    }
}

private struct WhiteDogLottieView: NSViewRepresentable {
    let animation: WhiteDogAnimation
    let plays: Bool
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinished: onFinished)
    }

    func makeNSView(context: Context) -> WhiteDogAnimationContainer {
        let container = WhiteDogAnimationContainer()
        update(container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: WhiteDogAnimationContainer, context: Context) {
        context.coordinator.onFinished = onFinished
        update(container, coordinator: context.coordinator)
    }

    private func update(_ container: WhiteDogAnimationContainer, coordinator: Coordinator) {
        container.display(animation, plays: plays) {
            coordinator.onFinished()
        }
    }

    final class Coordinator {
        var onFinished: () -> Void

        init(onFinished: @escaping () -> Void) {
            self.onFinished = onFinished
        }
    }
}

private final class WhiteDogAnimationContainer: NSView {
    let animationView = LottieAnimationView()
    private var displayedAnimation: WhiteDogAnimation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

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

    func display(
        _ animation: WhiteDogAnimation,
        plays: Bool,
        onFinished: @escaping () -> Void
    ) {
        let changedAnimation = animation != displayedAnimation
        if changedAnimation {
            animationView.stop()
            animationView.animation = LottieAnimation.named(
                animation.rawValue,
                bundle: .main,
                subdirectory: "WhiteDog"
            )
            animationView.currentProgress = 0
            displayedAnimation = animation
        }

        animationView.loopMode = animation.loops ? .loop : .playOnce

        guard plays else {
            animationView.stop()
            animationView.currentProgress = animation == .idle ? 0 : 0.5
            return
        }
        guard changedAnimation || !animationView.isAnimationPlaying else { return }

        if animation.loops {
            animationView.play()
        } else {
            animationView.play { [weak self] finished in
                guard finished, self?.displayedAnimation == animation else { return }
                onFinished()
            }
        }
    }
}

private struct WhiteDogInteractionView: NSViewRepresentable {
    let onHover: (Bool) -> Void
    let onPressChanged: (Bool) -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> WhiteDogInteractionNSView {
        WhiteDogInteractionNSView(
            onHover: onHover,
            onPressChanged: onPressChanged,
            onClick: onClick
        )
    }

    func updateNSView(_ view: WhiteDogInteractionNSView, context: Context) {
        view.onHover = onHover
        view.onPressChanged = onPressChanged
        view.onClick = onClick
    }
}

private final class WhiteDogInteractionNSView: NSView {
    var onHover: (Bool) -> Void
    var onPressChanged: (Bool) -> Void
    var onClick: () -> Void
    private var hoverTrackingArea: NSTrackingArea?

    init(
        onHover: @escaping (Bool) -> Void,
        onPressChanged: @escaping (Bool) -> Void,
        onClick: @escaping () -> Void
    ) {
        self.onHover = onHover
        self.onPressChanged = onPressChanged
        self.onClick = onClick
        super.init(frame: .zero)
        setAccessibilityElement(false)
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
        onPressChanged(false)
    }

    override func mouseDown(with event: NSEvent) {
        onPressChanged(true)
    }

    override func mouseUp(with event: NSEvent) {
        onPressChanged(false)
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onClick()
        }
    }
}
