import CoreGraphics
import XCTest
@testable import DeskBar

final class DesktopPanelLayoutTests: XCTestCase {
    func testDashboardUsesWideAndCompactHeightsBasedOnAvailableWidth() {
        let wide = DesktopPanelLayout.dashboardSize(
            visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 956)
        )
        let compact = DesktopPanelLayout.dashboardSize(
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 956)
        )

        XCTAssertEqual(wide, CGSize(width: 1200, height: 276))
        XCTAssertEqual(compact, CGSize(width: 744, height: 436))
    }

    func testPanelCentersWithinEachDisplayCoordinateSpace() {
        let externalDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

        let frame = DesktopPanelLayout.frame(
            visibleFrame: externalDisplay,
            preferredSize: CGSize(width: 920, height: 86)
        )

        XCTAssertEqual(frame.midX, externalDisplay.midX)
        XCTAssertEqual(frame.minY, 18)
        XCTAssertEqual(frame.width, 920)
        XCTAssertEqual(frame.height, 86)
    }

    func testPanelShrinksOnNarrowDisplayWithoutLeavingBounds() {
        let narrowDisplay = CGRect(x: 1440, y: 100, width: 500, height: 700)

        let frame = DesktopPanelLayout.frame(
            visibleFrame: narrowDisplay,
            preferredSize: CGSize(width: 920, height: 86)
        )

        XCTAssertEqual(frame.minX, narrowDisplay.minX + 28)
        XCTAssertEqual(frame.maxX, narrowDisplay.maxX - 28)
        XCTAssertEqual(frame.minY, narrowDisplay.minY + 18)
    }

    func testPointerSelectsDisplayAcrossNegativeAndPositiveCoordinates() {
        let displays = [
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1470, height: 956),
            CGRect(x: 1470, y: -400, width: 1280, height: 1024)
        ]

        XCTAssertEqual(
            DesktopPanelLayout.screenIndex(containing: CGPoint(x: -300, y: 500), frames: displays),
            0
        )
        XCTAssertEqual(
            DesktopPanelLayout.screenIndex(containing: CGPoint(x: 800, y: 500), frames: displays),
            1
        )
        XCTAssertEqual(
            DesktopPanelLayout.screenIndex(containing: CGPoint(x: 2000, y: -100), frames: displays),
            2
        )
    }
}
