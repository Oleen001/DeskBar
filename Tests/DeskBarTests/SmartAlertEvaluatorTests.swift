import XCTest
@testable import DeskBar

final class SmartAlertEvaluatorTests: XCTestCase {
    func testSustainedSystemCandidatesCarryExpectedThresholds() {
        let candidates = SmartAlertEvaluator.systemCandidates(
            cpuUsage: 84,
            memoryUsage: 99,
            networkBytesPerSecond: nil,
            networkHistory: [],
            thermalState: .nominal
        )

        let cpu = candidates.first { $0.alert.id == "system.cpu" }
        let memory = candidates.first { $0.alert.id == "system.memory" }
        XCTAssertEqual(cpu?.alert.severity, .warning)
        XCTAssertEqual(cpu?.requiredSamples, 3)
        XCTAssertEqual(memory?.alert.severity, .critical)
        XCTAssertEqual(memory?.requiredSamples, 3)
    }

    func testNormalSystemStateHasNoCandidates() {
        let candidates = SmartAlertEvaluator.systemCandidates(
            cpuUsage: 42,
            memoryUsage: 67,
            networkBytesPerSecond: 900_000,
            networkHistory: Array(repeating: 850_000, count: 10),
            thermalState: .fair
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testNetworkSpikeUsesRecentMedianAndMinimumFloor() {
        let megabyte = Double(1_024 * 1_024)
        let history = Array(repeating: megabyte, count: 8) + [8 * megabyte]
        let candidates = SmartAlertEvaluator.systemCandidates(
            cpuUsage: nil,
            memoryUsage: nil,
            networkBytesPerSecond: 8 * megabyte,
            networkHistory: history,
            thermalState: .unknown
        )

        XCTAssertEqual(candidates.map(\.alert.id), ["system.network"])
        XCTAssertEqual(candidates.first?.requiredSamples, 1)
    }

    func testAIAlertsWarnAtEightyAndBecomeCriticalAtNinetyPercent() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = now.addingTimeInterval(3_600)
        let warning = snapshot(id: "claude-five-hour", used: 80, now: now, reset: reset)
        let critical = snapshot(id: "claude-weekly", used: 92, now: now, reset: reset)

        let alerts = SmartAlertEvaluator.aiAlerts(
            snapshots: [warning, critical],
            now: now
        )

        XCTAssertEqual(alerts.map(\.severity), [.critical, .warning])
        XCTAssertTrue(alerts.first?.message.contains("8% remaining") == true)
        XCTAssertTrue(alerts.last?.message.contains("20% remaining") == true)
    }

    func testStaleAIReadingDoesNotAlert() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stale = AIQuotaSnapshot(
            providerID: "stale",
            providerName: "Stale AI",
            confidence: .verified,
            reading: AIQuotaReading(used: 99, limit: 100, unit: .messages),
            source: AIQuotaSource(label: "Test"),
            timing: AIQuotaTiming(
                fetchedAt: now.addingTimeInterval(-600),
                freshUntil: now.addingTimeInterval(-1),
                resetsAt: nil
            ),
            statusMessage: "Test"
        )

        XCTAssertTrue(SmartAlertEvaluator.aiAlerts(snapshots: [stale], now: now).isEmpty)
    }

    func testCustomThresholdsControlSystemAndAIWarnings() {
        let thresholds = SmartAlertThresholds(
            cpuWarning: 70,
            cpuCritical: 80,
            memoryWarning: 85,
            memoryCritical: 90,
            aiWarning: 60,
            aiCritical: 70
        )
        let system = SmartAlertEvaluator.systemCandidates(
            cpuUsage: 75,
            memoryUsage: 92,
            networkBytesPerSecond: nil,
            networkHistory: [],
            thermalState: .nominal,
            thresholds: thresholds
        )
        XCTAssertEqual(system.first { $0.alert.id == "system.cpu" }?.alert.severity, .warning)
        XCTAssertEqual(system.first { $0.alert.id == "system.memory" }?.alert.severity, .critical)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let quota = snapshot(id: "custom", used: 65, now: now, reset: now.addingTimeInterval(600))
        XCTAssertEqual(
            SmartAlertEvaluator.aiAlerts(
                snapshots: [quota], now: now, thresholds: thresholds
            ).first?.severity,
            .warning
        )
    }

    private func snapshot(
        id: AIProviderID,
        used: Double,
        now: Date,
        reset: Date
    ) -> AIQuotaSnapshot {
        AIQuotaSnapshot(
            providerID: id,
            providerName: "Claude",
            windowLabel: id.rawValue.contains("weekly") ? "Weekly" : "5 hours",
            confidence: .verified,
            reading: AIQuotaReading(used: used, limit: 100, unit: .messages),
            source: AIQuotaSource(label: "Test"),
            timing: AIQuotaTiming(
                fetchedAt: now,
                freshUntil: now.addingTimeInterval(600),
                resetsAt: reset
            ),
            statusMessage: "Test"
        )
    }
}
