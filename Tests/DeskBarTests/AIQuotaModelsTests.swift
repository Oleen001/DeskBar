import XCTest

@testable import DeskBar

final class AIQuotaModelsTests: XCTestCase {
    func testReadingClampsDisplayFractionWithoutChangingRawValues() {
        let reading = AIQuotaReading(used: 125, limit: 100, unit: .requests)

        XCTAssertEqual(reading.used, 125)
        XCTAssertEqual(reading.limit, 100)
        XCTAssertEqual(reading.fractionUsed, 1)
        XCTAssertEqual(reading.fractionRemaining, 0)
    }

    func testReadingWithoutPositiveLimitHasNoFraction() {
        XCTAssertNil(AIQuotaReading(used: 4, limit: 0, unit: .messages).fractionUsed)
        XCTAssertNil(AIQuotaReading(used: 4, limit: 0, unit: .messages).fractionRemaining)
    }

    func testFreshnessBoundaryIsStale() {
        let boundary = Date(timeIntervalSince1970: 100)
        let timing = AIQuotaTiming(
            fetchedAt: Date(timeIntervalSince1970: 50),
            freshUntil: boundary
        )

        XCTAssertTrue(timing.isStale(at: boundary))
    }

    func testRefreshFailurePreservesReadingAndMarksItStale() {
        let failureDate = Date(timeIntervalSince1970: 200)
        let snapshot = AIQuotaSnapshot(
            providerID: .openAI,
            providerName: "OpenAI",
            confidence: .verified,
            reading: .init(used: 20, limit: 100, unit: .credits),
            source: .init(label: "Official API"),
            timing: .init(
                fetchedAt: Date(timeIntervalSince1970: 100),
                freshUntil: Date(timeIntervalSince1970: 300)
            ),
            statusMessage: "Current"
        )

        let failed = snapshot.markingRefreshFailure(message: "Refresh failed", at: failureDate)

        XCTAssertEqual(failed.reading, snapshot.reading)
        XCTAssertEqual(failed.timing.fetchedAt, snapshot.timing.fetchedAt)
        XCTAssertTrue(failed.timing.isStale(at: failureDate))
        XCTAssertEqual(failed.statusMessage, "Refresh failed")
    }
}
