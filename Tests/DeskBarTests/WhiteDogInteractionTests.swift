import XCTest
@testable import DeskBar

@MainActor
final class WhiteDogInteractionTests: XCTestCase {
    func testReactionCandidatesExcludeIdleAndPreviousReaction() {
        for previous in WhiteDogAnimation.reactions {
            let candidates = WhiteDogAnimation.reactionCandidates(after: previous)

            XCTAssertEqual(candidates.count, WhiteDogAnimation.reactions.count - 1)
            XCTAssertFalse(candidates.contains(.idle))
            XCTAssertFalse(candidates.contains(previous))
        }
    }

    func testEveryBundledReactionIsReachableFromIdle() {
        XCTAssertEqual(
            Set(WhiteDogAnimation.reactionCandidates(after: nil)),
            Set(WhiteDogAnimation.reactions)
        )
        XCTAssertEqual(WhiteDogAnimation.reactions.count, 6)
    }

    func testAnimationFrameOverlapsPanelWhileKeepingRoomAboveDog() {
        let centerY = WhiteDogView.stripHeight
            - (WhiteDogView.animationSize.height / 2)
            + WhiteDogView.animationFrameOverlap
        let frameTop = centerY - (WhiteDogView.animationSize.height / 2)
        let frameBottom = centerY + (WhiteDogView.animationSize.height / 2)

        XCTAssertGreaterThanOrEqual(frameTop, 0)
        XCTAssertEqual(frameBottom - WhiteDogView.stripHeight, 10)
    }
}
