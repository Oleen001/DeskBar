import XCTest
@testable import DeskBar

@MainActor
final class DeskBarPreferencesTests: XCTestCase {
    func testPreferencesPersistAcrossInstances() throws {
        let suiteName = "DeskBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DeskBarPreferences(defaults: defaults)
        preferences.displayMode = .mainDisplay
        preferences.density = .compact
        preferences.accent = .purple
        preferences.shortcutPreset = .commandShiftD
        preferences.refreshRate = .live
        preferences.showClock = false
        preferences.showNetwork = false
        preferences.maximumApps = 6
        preferences.maximumPanelWidth = 980
        preferences.bottomInset = 34
        preferences.glassIntensity = 0.75
        preferences.cpuAlertThreshold = 72
        preferences.ramAlertThreshold = 88
        preferences.aiAlertThreshold = 65
        preferences.codexPlanLabel = "  Custom Codex  "
        preferences.claudePlanLabel = "Max"

        let reloaded = DeskBarPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.displayMode, .mainDisplay)
        XCTAssertEqual(reloaded.density, .compact)
        XCTAssertEqual(reloaded.accent, .purple)
        XCTAssertEqual(reloaded.shortcutPreset, .commandShiftD)
        XCTAssertEqual(reloaded.refreshRate, .live)
        XCTAssertFalse(reloaded.showClock)
        XCTAssertFalse(reloaded.showNetwork)
        XCTAssertEqual(reloaded.maximumApps, 6)
        XCTAssertEqual(reloaded.maximumPanelWidth, 980)
        XCTAssertEqual(reloaded.bottomInset, 34)
        XCTAssertEqual(reloaded.glassIntensity, 0.75)
        XCTAssertEqual(reloaded.cpuAlertThreshold, 72)
        XCTAssertEqual(reloaded.ramAlertThreshold, 88)
        XCTAssertEqual(reloaded.aiAlertThreshold, 65)
        XCTAssertEqual(reloaded.codexPlanLabel, "Custom Codex")
        XCTAssertEqual(reloaded.claudePlanLabel, "Max")
        XCTAssertEqual(reloaded.planOverride(for: "Codex"), "Custom Codex")
        XCTAssertEqual(reloaded.planOverride(for: "Claude"), "Max")
    }

    func testNumericPreferencesAreClamped() throws {
        let suiteName = "DeskBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DeskBarPreferences(defaults: defaults)
        preferences.maximumApps = 99
        preferences.maximumPanelWidth = 200
        preferences.bottomInset = -10
        preferences.glassIntensity = 5
        preferences.cpuAlertThreshold = 10
        preferences.ramAlertThreshold = 100
        preferences.aiAlertThreshold = 120

        XCTAssertEqual(preferences.maximumApps, 12)
        XCTAssertEqual(preferences.maximumPanelWidth, 760)
        XCTAssertEqual(preferences.bottomInset, 8)
        XCTAssertEqual(preferences.glassIntensity, 1.35)
        XCTAssertEqual(preferences.cpuAlertThreshold, 50)
        XCTAssertEqual(preferences.ramAlertThreshold, 98)
        XCTAssertEqual(preferences.aiAlertThreshold, 95)
    }

    func testPanelHeightRespondsToVisibleDashboardWidgetsAndDensity() throws {
        let suiteName = "DeskBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DeskBarPreferences(defaults: defaults)

        XCTAssertEqual(preferences.panelHeight(isCompact: false), 276)
        XCTAssertEqual(preferences.panelHeight(isCompact: true), 436)

        preferences.showAILimits = false
        XCTAssertEqual(preferences.panelHeight(isCompact: true), 276)

        preferences.showSystemMonitor = false
        XCTAssertEqual(preferences.panelHeight(isCompact: true), 92)

        preferences.density = .spacious
        XCTAssertEqual(preferences.panelHeight(isCompact: true), 124)
    }
}
