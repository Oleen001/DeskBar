import XCTest

@testable import DeskBar

final class AIQuotaNotchSummaryTests: XCTestCase {
    func testShowsTightestReadableWindowAsRemainingCapacity() {
        let summaries = AIQuotaNotchSummary.summaries(from: [
            snapshot(id: .claudeCodeFiveHour, provider: "Claude", used: 20, window: "5 hours"),
            snapshot(id: .claudeCodeSevenDay, provider: "Claude", used: 65, window: "Weekly"),
            snapshot(id: .openAI, provider: "Codex", used: 42, window: "5 hours"),
        ])

        XCTAssertEqual(summaries.map(\.provider), [.claude, .codex])
        XCTAssertEqual(summaries[0].remainingPercentage, 35)
        XCTAssertEqual(summaries[0].windowLabel, "Weekly")
        XCTAssertEqual(summaries[1].remainingPercentage, 58)
    }

    func testKeepsUnavailableProviderVisible() {
        let summaries = AIQuotaNotchSummary.summaries(from: [])

        XCTAssertEqual(summaries.count, 2)
        XCTAssertNil(summaries[0].remainingPercentage)
        XCTAssertNil(summaries[1].remainingPercentage)
    }

    func testDoesNotAllowAnEstimateWithTheSameNameToDisplaceAnIntegration() {
        let summaries = AIQuotaNotchSummary.summaries(from: [
            snapshot(id: .claudeCodeFiveHour, provider: "Claude", used: 20, window: "5 hours"),
            snapshot(id: "estimate.claude", provider: "Claude", used: 99, window: "Manual"),
        ])

        XCTAssertEqual(summaries[0].remainingPercentage, 80)
        XCTAssertEqual(summaries[0].windowLabel, "5 hours")
    }

    private func snapshot(id: AIProviderID, provider: String, used: Double, window: String)
        -> AIQuotaSnapshot
    {
        AIQuotaSnapshot(
            providerID: id,
            providerName: provider,
            windowLabel: window,
            confidence: .verified,
            reading: .init(used: used, limit: 100, unit: .messages),
            source: .init(label: "Test"),
            statusMessage: "Current"
        )
    }
}
