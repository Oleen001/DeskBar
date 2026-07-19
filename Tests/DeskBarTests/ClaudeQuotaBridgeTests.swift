import Foundation
import XCTest
@testable import DeskBar

final class ClaudeQuotaProviderTests: XCTestCase {
    func testReadsOfficialFiveHourWindowAndResetTime() async throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fixture.writeRateLimits(
            fiveHourUsed: 23.5,
            fiveHourReset: 2_000_003_600,
            sevenDayUsed: 41.2,
            sevenDayReset: 2_000_086_400,
            modificationDate: now.addingTimeInterval(-60)
        )

        let snapshot = try await ClaudeQuotaProvider(
            window: .fiveHour,
            cacheURL: fixture.paths.cacheURL,
            freshnessInterval: 300,
            now: { now }
        ).fetchQuota()

        XCTAssertEqual(snapshot.providerID, .claudeCodeFiveHour)
        XCTAssertEqual(snapshot.providerName, "Claude")
        XCTAssertEqual(snapshot.windowLabel, "5 hours")
        XCTAssertEqual(snapshot.confidence, .verified)
        XCTAssertEqual(snapshot.reading?.used, 23.5)
        XCTAssertEqual(snapshot.reading?.limit, 100)
        XCTAssertEqual(snapshot.timing.resetsAt, Date(timeIntervalSince1970: 2_000_003_600))
        XCTAssertFalse(snapshot.timing.isStale(at: now))
    }

    func testMarksOldCacheReadingStale() async throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fixture.writeRateLimits(
            fiveHourUsed: 75,
            fiveHourReset: 2_000_003_600,
            sevenDayUsed: 50,
            sevenDayReset: 2_000_086_400,
            modificationDate: now.addingTimeInterval(-301)
        )

        let snapshot = try await ClaudeQuotaProvider(
            window: .fiveHour,
            cacheURL: fixture.paths.cacheURL,
            freshnessInterval: 300,
            now: { now }
        ).fetchQuota()

        XCTAssertTrue(snapshot.timing.isStale(at: now))
        XCTAssertTrue(
            snapshot.statusMessage.contains("more than 5 minutes"),
            snapshot.statusMessage
        )
    }

    func testMissingCacheReturnsUnavailableWithoutCredentials() async throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }

        let snapshot = try await ClaudeQuotaProvider(
            window: .sevenDay,
            cacheURL: fixture.paths.cacheURL
        ).fetchQuota()

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertNil(snapshot.reading)
        XCTAssertFalse(snapshot.statusMessage.localizedCaseInsensitiveContains("token"))
    }

    func testReadingBecomesStaleWhenItsWindowHasReset() async throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fixture.writeRateLimits(
            fiveHourUsed: 100,
            fiveHourReset: now.addingTimeInterval(-1).timeIntervalSince1970,
            sevenDayUsed: 50,
            sevenDayReset: now.addingTimeInterval(1_000).timeIntervalSince1970,
            modificationDate: now
        )

        let snapshot = try await ClaudeQuotaProvider(
            window: .fiveHour,
            cacheURL: fixture.paths.cacheURL,
            freshnessInterval: 300,
            now: { now }
        ).fetchQuota()

        XCTAssertTrue(snapshot.timing.isStale(at: now))
    }
}

@MainActor
final class ClaudeStatusLineBridgeInstallerTests: XCTestCase {
    func testInstallComposesExistingStatusLineAndCachesOnlyRateLimits() throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }
        try fixture.writeSettings([
            "env": ["EXISTING": "value"],
            "statusLine": [
                "type": "command",
                "command": "/usr/bin/plutil -extract model.display_name raw -o - - | /usr/bin/sed 's/Opus/Claude Opus/'",
                "padding": 2
            ]
        ])

        let installer = ClaudeStatusLineBridgeInstaller(paths: fixture.paths)
        installer.install()

        XCTAssertEqual(installer.state, .installed)
        XCTAssertNil(installer.lastError)
        let installedSettings = try fixture.readSettings()
        XCTAssertEqual((installedSettings["env"] as? [String: String])?["EXISTING"], "value")
        let statusLine = try XCTUnwrap(installedSettings["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
        XCTAssertEqual(statusLine["command"] as? String, "'\(fixture.paths.scriptURL.path)'")

        let payload = """
        {
          "session_id": "must-not-be-cached",
          "oauth_token": "must-not-be-cached",
          "model": {"display_name": "Opus"},
          "rate_limits": {
            "five_hour": {"used_percentage": 23.5, "resets_at": 2000003600},
            "seven_day": {"used_percentage": 41.2, "resets_at": 2000086400}
          }
        }
        """
        let output = try fixture.runBridge(input: Data(payload.utf8))

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "Claude Opus")
        let cachedData = try Data(contentsOf: fixture.paths.cacheURL)
        let cachedText = try XCTUnwrap(String(data: cachedData, encoding: .utf8))
        XCTAssertFalse(cachedText.contains("session_id"))
        XCTAssertFalse(cachedText.contains("oauth"))
        let cachedLimits = try JSONDecoder().decode(ClaudeCodeRateLimits.self, from: cachedData)
        XCTAssertEqual(cachedLimits.fiveHour?.usedPercentage, 23.5)
        XCTAssertEqual(cachedLimits.sevenDay?.resetsAt, 2_000_086_400)
    }

    func testUninstallRestoresOnlyStatusLineAndPreservesLaterSettings() throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }
        let originalStatusLine: [String: Any] = [
            "type": "command",
            "command": "printf original",
            "padding": 4
        ]
        try fixture.writeSettings([
            "theme": "dark",
            "statusLine": originalStatusLine
        ])
        let installer = ClaudeStatusLineBridgeInstaller(paths: fixture.paths)
        installer.install()
        try Data(#"{"five_hour":{"used_percentage":90,"resets_at":2000003600}}"#.utf8)
            .write(to: fixture.paths.cacheURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.cacheURL.path))

        var changedSettings = try fixture.readSettings()
        changedSettings["theme"] = "light"
        changedSettings["newSetting"] = true
        var changedStatusLine = try XCTUnwrap(changedSettings["statusLine"] as? [String: Any])
        changedStatusLine["padding"] = 8
        changedSettings["statusLine"] = changedStatusLine
        try fixture.writeSettings(changedSettings)
        installer.uninstall()

        XCTAssertEqual(installer.state, .notInstalled)
        let restoredSettings = try fixture.readSettings()
        XCTAssertEqual(restoredSettings["theme"] as? String, "light")
        XCTAssertEqual(restoredSettings["newSetting"] as? Bool, true)
        XCTAssertEqual(
            (restoredSettings["statusLine"] as? [String: Any])?["command"] as? String,
            "printf original"
        )
        XCTAssertEqual(
            (restoredSettings["statusLine"] as? [String: Any])?["padding"] as? Int,
            8
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.scriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.cacheURL.path))
    }

    func testFailedSettingsWriteRollsBackNewArtifactsAndAllowsRetry() throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }
        let originalSettings: [String: Any] = [
            "theme": "dark",
            "statusLine": [
                "type": "command",
                "command": "printf original"
            ]
        ]
        try fixture.writeSettings(originalSettings)

        let failingInstaller = ClaudeStatusLineBridgeInstaller(
            paths: fixture.paths,
            settingsWriteOverride: { _ in throw BridgeWriteTestError.failed }
        )
        failingInstaller.install()

        XCTAssertNotNil(failingInstaller.lastError)
        XCTAssertEqual(failingInstaller.state, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.scriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.cacheURL.path))
        XCTAssertEqual(
            (try fixture.readSettings()["statusLine"] as? [String: Any])?["command"] as? String,
            "printf original"
        )

        let retryInstaller = ClaudeStatusLineBridgeInstaller(paths: fixture.paths)
        retryInstaller.install()
        XCTAssertEqual(retryInstaller.state, .installed)
        XCTAssertNil(retryInstaller.lastError)
    }

    func testUninstallFinishesCleanupAfterSettingsWereAlreadyRestored() throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }
        try fixture.writeSettings([:])
        let installer = ClaudeStatusLineBridgeInstaller(paths: fixture.paths)
        installer.install()
        XCTAssertEqual(installer.state, .installed)

        // Simulate a previous uninstall that committed settings restoration but was
        // interrupted before DeskBar-owned artifacts could be removed.
        try fixture.writeSettings([:])
        installer.refresh()
        guard case .needsRecovery = installer.state else {
            return XCTFail("Expected an incomplete cleanup state")
        }

        installer.uninstall()

        XCTAssertEqual(installer.state, .notInstalled)
        XCTAssertNil(installer.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.scriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.backupURL.path))
    }

    func testInvalidSettingsAreNeverOverwritten() throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }
        let invalidData = Data("{ invalid json".utf8)
        try invalidData.write(to: fixture.paths.settingsURL)

        let installer = ClaudeStatusLineBridgeInstaller(paths: fixture.paths)
        installer.install()

        XCTAssertNotNil(installer.lastError)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.settingsURL), invalidData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.scriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.backupURL.path))
    }

    func testChangedStatusLineIsNotOverwrittenDuringUninstall() throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }
        try fixture.writeSettings([:])
        let installer = ClaudeStatusLineBridgeInstaller(paths: fixture.paths)
        installer.install()

        var settings = try fixture.readSettings()
        settings["statusLine"] = ["type": "command", "command": "new-user-command"]
        try fixture.writeSettings(settings)
        installer.uninstall()

        XCTAssertNotNil(installer.lastError)
        XCTAssertEqual(
            (try fixture.readSettings()["statusLine"] as? [String: Any])?["command"] as? String,
            "new-user-command"
        )
    }

    func testSymbolicLinkSettingsAreLeftUntouched() throws {
        let fixture = try TemporaryClaudeBridgeFixture()
        defer { fixture.remove() }
        let managedSettingsURL = fixture.root.appendingPathComponent("managed-settings.json")
        let originalData = try JSONSerialization.data(withJSONObject: ["managed": true])
        try originalData.write(to: managedSettingsURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.settingsURL,
            withDestinationURL: managedSettingsURL
        )

        let installer = ClaudeStatusLineBridgeInstaller(paths: fixture.paths)
        installer.install()

        XCTAssertNotNil(installer.lastError)
        XCTAssertEqual(try Data(contentsOf: managedSettingsURL), originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.scriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.backupURL.path))
    }
}

private enum BridgeWriteTestError: Error {
    case failed
}

private final class TemporaryClaudeBridgeFixture: @unchecked Sendable {
    let root: URL
    let paths: ClaudeStatusLineBridgePaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskBarClaudeTests-\(UUID().uuidString)", isDirectory: true)
        paths = ClaudeStatusLineBridgePaths(
            settingsURL: root.appendingPathComponent(".claude/settings.json"),
            scriptURL: root.appendingPathComponent(".claude/deskbar-statusline-bridge.sh"),
            backupURL: root.appendingPathComponent(".claude/deskbar-statusline-backup.json"),
            cacheURL: root.appendingPathComponent("cache/claude-code-rate-limits.json")
        )
        try FileManager.default.createDirectory(
            at: paths.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings)
        try data.write(to: paths.settingsURL, options: .atomic)
    }

    func readSettings() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.settingsURL))
        return try XCTUnwrap(object as? [String: Any])
    }

    func writeRateLimits(
        fiveHourUsed: Double,
        fiveHourReset: Double,
        sevenDayUsed: Double,
        sevenDayReset: Double,
        modificationDate: Date
    ) throws {
        try FileManager.default.createDirectory(
            at: paths.cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rateLimits: [String: Any] = [
            "five_hour": [
                "used_percentage": fiveHourUsed,
                "resets_at": fiveHourReset
            ],
            "seven_day": [
                "used_percentage": sevenDayUsed,
                "resets_at": sevenDayReset
            ]
        ]
        try JSONSerialization.data(withJSONObject: rateLimits).write(
            to: paths.cacheURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: paths.cacheURL.path
        )
    }

    func runBridge(input: Data) throws -> String {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = paths.scriptURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(input)
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
