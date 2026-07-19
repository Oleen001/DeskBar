import XCTest
@testable import DeskBar

@MainActor
final class PinnedAppsStoreTests: XCTestCase {
    func testPinsPersistWithoutDuplicates() throws {
        let suiteName = "DeskBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PinnedAppsStore(defaults: defaults, storageKey: "pins")
        XCTAssertTrue(store.pin(" com.apple.Safari "))
        XCTAssertFalse(store.pin("com.apple.Safari"))

        let reloaded = PinnedAppsStore(defaults: defaults, storageKey: "pins")
        XCTAssertEqual(reloaded.bundleIdentifiers, ["com.apple.Safari"])
    }

    func testMovePreservesAllPinnedIdentifiers() throws {
        let suiteName = "DeskBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PinnedAppsStore(defaults: defaults, storageKey: "pins")
        store.replace(with: ["one", "two", "three"])

        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(store.bundleIdentifiers, ["two", "three", "one"])
    }
}
