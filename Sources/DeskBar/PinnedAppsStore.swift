import Combine
import Foundation

@MainActor
final class PinnedAppsStore: ObservableObject {
    @Published private(set) var bundleIdentifiers: [String]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "DeskBar.pinnedApplicationBundleIdentifiers"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        bundleIdentifiers = Self.normalized(defaults.stringArray(forKey: storageKey) ?? [])
    }

    func contains(_ bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(Self.normalized(bundleIdentifier))
    }

    @discardableResult
    func pin(_ bundleIdentifier: String) -> Bool {
        let normalizedIdentifier = Self.normalized(bundleIdentifier)
        guard !normalizedIdentifier.isEmpty,
              !bundleIdentifiers.contains(normalizedIdentifier) else {
            return false
        }

        bundleIdentifiers.append(normalizedIdentifier)
        persist()
        return true
    }

    func unpin(_ bundleIdentifier: String) {
        let normalizedIdentifier = Self.normalized(bundleIdentifier)
        let updatedIdentifiers = bundleIdentifiers.filter { $0 != normalizedIdentifier }
        guard updatedIdentifiers != bundleIdentifiers else { return }

        bundleIdentifiers = updatedIdentifiers
        persist()
    }

    @discardableResult
    func toggle(_ bundleIdentifier: String) -> Bool {
        if contains(bundleIdentifier) {
            unpin(bundleIdentifier)
            return false
        }

        return pin(bundleIdentifier)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reorderedIdentifiers = bundleIdentifiers
        let movingIdentifiers = source.sorted().map { reorderedIdentifiers[$0] }

        for index in source.sorted(by: >) {
            reorderedIdentifiers.remove(at: index)
        }

        let removedBeforeDestination = source.filter { $0 < destination }.count
        let adjustedDestination = max(
            0,
            min(destination - removedBeforeDestination, reorderedIdentifiers.count)
        )
        reorderedIdentifiers.insert(contentsOf: movingIdentifiers, at: adjustedDestination)

        guard reorderedIdentifiers != bundleIdentifiers else { return }
        bundleIdentifiers = reorderedIdentifiers
        persist()
    }

    func replace(with bundleIdentifiers: [String]) {
        let normalizedIdentifiers = Self.normalized(bundleIdentifiers)
        guard normalizedIdentifiers != self.bundleIdentifiers else { return }

        self.bundleIdentifiers = normalizedIdentifiers
        persist()
    }

    private func persist() {
        defaults.set(bundleIdentifiers, forKey: storageKey)
    }

    private static func normalized(_ bundleIdentifiers: [String]) -> [String] {
        var seen: Set<String> = []
        return bundleIdentifiers.compactMap { bundleIdentifier in
            let normalizedIdentifier = normalized(bundleIdentifier)
            guard !normalizedIdentifier.isEmpty,
                  seen.insert(normalizedIdentifier).inserted else {
                return nil
            }
            return normalizedIdentifier
        }
    }

    private static func normalized(_ bundleIdentifier: String) -> String {
        bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
