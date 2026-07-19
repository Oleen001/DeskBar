import XCTest
@testable import DeskBar

final class SystemMetricModelsTests: XCTestCase {
    func testMetricHistoryRejectsInvalidSamplesAndKeepsNewestValues() {
        var history = MetricHistory(capacity: 3)

        history.append(1)
        history.append(.nan)
        history.append(-1)
        history.append(2)
        history.append(3)
        history.append(4)

        XCTAssertEqual(history.values, [2, 3, 4])
    }

    func testDiskUsageIsClampedAndFormatted() {
        let metric = SystemDiskMetric(totalBytes: 1_000, availableBytes: 250)

        XCTAssertEqual(metric.usedBytes, 750)
        XCTAssertEqual(metric.usagePercentage, 75)
        XCTAssertFalse(metric.displayValue.isEmpty)
    }

    func testInvalidTransferRateShowsUnavailable() {
        XCTAssertEqual(SystemMetricFormatter.transferRate(bytesPerSecond: -.infinity), "—")
        XCTAssertEqual(SystemMetricFormatter.transferRate(bytesPerSecond: nil), "—")
    }
}

@MainActor
final class SystemMonitorLifecycleTests: XCTestCase {
    func testPauseStopsAutomaticPollingAndResetsSamplingBaselines() {
        let monitor = SystemMonitor()
        monitor.start(mode: .active)
        monitor.setPollingMode(.paused)

        XCTAssertEqual(monitor.pollingMode, .paused)
        XCTAssertNil(monitor.effectivePollingInterval)
        XCTAssertNil(monitor.cpuUsage)
        XCTAssertEqual(monitor.networkRate, "—")
        monitor.stop()
    }

    func testResumeSelectsAnAutomaticPollingInterval() {
        let monitor = SystemMonitor()
        monitor.start(mode: .paused)
        monitor.setPollingMode(.idle)

        XCTAssertEqual(monitor.pollingMode, .idle)
        XCTAssertNotNil(monitor.effectivePollingInterval)
        monitor.stop()
    }

    func testPollingIntervalScaleChangesEffectiveCadence() throws {
        let monitor = SystemMonitor()
        monitor.start(mode: .idle)
        let baseline = try XCTUnwrap(monitor.effectivePollingInterval)

        monitor.setPollingIntervalScale(2)

        XCTAssertEqual(monitor.effectivePollingInterval, baseline * 2)
        monitor.stop()
    }
}
