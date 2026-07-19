import XCTest
@testable import DeskBar

final class EstimatedQuotaConfigurationTests: XCTestCase {
    func testConfigurationNormalizesAndClampsInput() throws {
        let configuration = try EstimatedQuotaConfiguration(
            providerName: "  My AI  ",
            windowLabel: "  Weekly  ",
            used: 150,
            limit: 100,
            unit: .currency,
            currencyCode: " thb "
        )

        XCTAssertEqual(configuration.providerName, "My AI")
        XCTAssertEqual(configuration.windowLabel, "Weekly")
        XCTAssertEqual(configuration.used, 100)
        XCTAssertEqual(configuration.limit, 100)
        XCTAssertEqual(configuration.currencyCode, "THB")
    }

    func testConfigurationRejectsInvalidIdentityAndLimit() {
        XCTAssertThrowsError(
            try EstimatedQuotaConfiguration(
                providerName: "  ",
                used: 0,
                limit: 10,
                unit: .requests
            )
        )
        XCTAssertThrowsError(
            try EstimatedQuotaConfiguration(
                providerName: "Provider",
                used: 0,
                limit: .infinity,
                unit: .requests
            )
        )
    }

    func testProviderReturnsEstimatedSnapshotWithStableMetadata() throws {
        let resetDate = Date(timeIntervalSince1970: 2_000)
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let configuration = try EstimatedQuotaConfiguration(
            id: UUID(uuidString: "21D77CF4-F790-4017-A7BC-A937AD892B70")!,
            providerName: "Local limit",
            windowLabel: "5 hours",
            used: 4,
            limit: 10,
            unit: .messages,
            resetDate: resetDate
        )

        let snapshot = EstimatedQuotaProvider(configuration: configuration).snapshot(at: fetchedAt)

        XCTAssertEqual(snapshot.providerID, configuration.providerID)
        XCTAssertEqual(snapshot.windowLabel, "5 hours")
        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertEqual(snapshot.reading?.fractionUsed, 0.4)
        XCTAssertEqual(snapshot.timing.fetchedAt, fetchedAt)
        XCTAssertEqual(snapshot.timing.freshUntil, resetDate)
        XCTAssertEqual(snapshot.timing.resetsAt, resetDate)
        XCTAssertEqual(snapshot.source.label, "User-entered estimate")
        XCTAssertFalse(snapshot.timing.isStale(at: fetchedAt))
    }

    func testPastResetMakesEstimatedSnapshotStale() throws {
        let configuration = try EstimatedQuotaConfiguration(
            providerName: "Local limit",
            used: 1,
            limit: 10,
            unit: .messages,
            resetDate: Date(timeIntervalSince1970: 100)
        )
        let snapshot = EstimatedQuotaProvider(configuration: configuration)
            .snapshot(at: Date(timeIntervalSince1970: 200))

        XCTAssertTrue(snapshot.isStale)
    }
}

@MainActor
final class EstimatedQuotaStoreTests: XCTestCase {
    func testStorePersistsStableIDsAndSupportsUpdateReorderDelete() throws {
        let suiteName = "DeskBarTests.EstimatedQuota.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = EstimatedQuotaStore(defaults: defaults, storageKey: "estimated")
        let first = try store.add(
            providerName: "First",
            windowLabel: "Weekly",
            used: 1,
            limit: 10,
            unit: .requests
        )
        let second = try store.add(
            providerName: "Second",
            used: -5,
            limit: 20,
            unit: .tokens
        )
        XCTAssertEqual(second.used, 0)

        let editedFirst = try EstimatedQuotaConfiguration(
            id: first.id,
            providerName: "Renamed",
            windowLabel: first.windowLabel,
            used: 5,
            limit: first.limit,
            unit: first.unit,
            resetDate: first.resetDate
        )
        try store.update(editedFirst)
        try store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        let reloaded = EstimatedQuotaStore(defaults: defaults, storageKey: "estimated")
        XCTAssertEqual(reloaded.configurations.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded.configurations[1].providerName, "Renamed")
        XCTAssertEqual(reloaded.configurations[1].windowLabel, "Weekly")
        XCTAssertEqual(reloaded.providers().map(\.id), reloaded.configurations.map(\.providerID))

        try reloaded.delete(id: second.id)
        XCTAssertEqual(reloaded.configurations.map(\.id), [first.id])
    }

    func testStoreRecoversValidEntriesAndPreservesUnknownEntries() throws {
        let suiteName = "DeskBarTests.EstimatedQuota.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "estimated"
        let valid = try EstimatedQuotaConfiguration(
            providerName: "Known",
            used: 1,
            limit: 10,
            unit: .requests
        )
        let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
        let unknownObject: [String: Any] = ["schemaVersion": 99, "futureValue": "preserve-me"]
        defaults.set(
            try JSONSerialization.data(withJSONObject: [validObject, unknownObject]),
            forKey: storageKey
        )

        let store = EstimatedQuotaStore(defaults: defaults, storageKey: storageKey)
        XCTAssertEqual(store.configurations.map(\.id), [valid.id])
        XCTAssertNotNil(store.loadWarning)
        _ = try store.add(providerName: "New", used: 2, limit: 20, unit: .messages)

        let persisted = try XCTUnwrap(defaults.data(forKey: storageKey))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [Any])
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.contains { ($0 as? [String: Any])?["futureValue"] as? String == "preserve-me" })
    }

    func testStoreDoesNotOverwriteCompletelyUnreadableDataWithoutConsent() throws {
        let suiteName = "DeskBarTests.EstimatedQuota.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "estimated"
        let original = Data([0xFF, 0x00, 0x7F])
        defaults.set(original, forKey: storageKey)

        let store = EstimatedQuotaStore(defaults: defaults, storageKey: storageKey)
        XCTAssertNotNil(store.loadWarning)
        XCTAssertThrowsError(
            try store.add(providerName: "New", used: 1, limit: 10, unit: .requests)
        )
        XCTAssertEqual(defaults.data(forKey: storageKey), original)

        store.discardUnreadableData()
        XCTAssertNil(defaults.data(forKey: storageKey))
        XCTAssertNil(store.loadWarning)
    }
}
