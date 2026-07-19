import XCTest
@testable import DeskBar

final class AIQuotaDisplayGroupTests: XCTestCase {
    func testGroupingCombinesMultipleWindowsForOneProviderAndPreservesOrder() {
        let snapshots = [
            snapshot(id: "claude-5h", provider: "Claude", window: "5 hours"),
            snapshot(id: "claude-week", provider: " claude ", window: "Weekly"),
            snapshot(id: "openai", provider: "OpenAI", window: nil)
        ]

        let groups = AIQuotaDisplayGroup.grouping(snapshots)

        XCTAssertEqual(groups.map(\.providerName), ["Claude", "OpenAI"])
        XCTAssertEqual(groups[0].snapshots.map(\.windowLabel), ["5 hours", "Weekly"])
        XCTAssertEqual(groups[1].snapshots.map(\.providerID.rawValue), ["openai"])
    }

    func testGroupingCarriesPlanAndResetCreditMetadata() {
        let snapshots = [
            AIQuotaSnapshot(
                providerID: .openAI,
                providerName: "Codex",
                planName: "Pro Lite",
                windowLabel: "Weekly",
                resetCreditsAvailable: 3,
                confidence: .verified,
                reading: .init(used: 10, limit: 100, unit: .messages),
                source: .init(label: "Codex"),
                statusMessage: "Current"
            )
        ]

        let group = try! XCTUnwrap(AIQuotaDisplayGroup.grouping(snapshots).first)
        XCTAssertEqual(group.planName, "Pro Lite")
        XCTAssertEqual(group.resetCreditsAvailable, 3)
    }

    private func snapshot(id: String, provider: String, window: String?) -> AIQuotaSnapshot {
        AIQuotaSnapshot(
            providerID: AIProviderID(rawValue: id),
            providerName: provider,
            windowLabel: window,
            confidence: .estimated,
            reading: AIQuotaReading(used: 1, limit: 2, unit: .messages),
            source: AIQuotaSource(label: "Test"),
            statusMessage: "Test"
        )
    }
}
