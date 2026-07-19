import Combine
import Foundation

enum EstimatedQuotaStoreError: Error, LocalizedError, Sendable {
    case configurationNotFound
    case unreadableStoredData

    var errorDescription: String? {
        switch self {
        case .configurationNotFound:
            "The estimated quota configuration could not be found."
        case .unreadableStoredData:
            "Saved AI limits are unreadable. Reset the saved limits before adding new ones."
        }
    }
}

/// Local-only persistence for user-entered quota estimates.
@MainActor
final class EstimatedQuotaStore: ObservableObject {
    @Published private(set) var configurations: [EstimatedQuotaConfiguration]
    @Published private(set) var loadWarning: String?

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var preservedUnknownEntries: [Any] = []
    private var hasUnreadableStoredData = false

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "DeskBar.estimatedAIQuotaConfigurations"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        encoder = JSONEncoder()
        decoder = JSONDecoder()

        guard let data = defaults.data(forKey: storageKey) else {
            configurations = []
            return
        }

        if let decoded = try? decoder.decode([EstimatedQuotaConfiguration].self, from: data) {
            configurations = Self.removingDuplicateIDs(from: decoded)
            return
        }

        guard let rawEntries = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            configurations = []
            hasUnreadableStoredData = true
            loadWarning = "Saved AI limits could not be decoded and were left untouched."
            return
        }

        var recovered: [EstimatedQuotaConfiguration] = []
        for entry in rawEntries {
            guard JSONSerialization.isValidJSONObject(entry),
                  let entryData = try? JSONSerialization.data(withJSONObject: entry),
                  let configuration = try? decoder.decode(
                    EstimatedQuotaConfiguration.self,
                    from: entryData
                  ) else {
                preservedUnknownEntries.append(entry)
                continue
            }
            recovered.append(configuration)
        }
        configurations = Self.removingDuplicateIDs(from: recovered)
        if !preservedUnknownEntries.isEmpty {
            loadWarning = "Some saved AI limits use an unreadable format. They were preserved but are not displayed."
        }
    }

    @discardableResult
    func add(
        providerName: String,
        windowLabel: String? = nil,
        used: Double,
        limit: Double,
        unit: AIQuotaUnit,
        currencyCode: String? = nil,
        resetDate: Date? = nil
    ) throws -> EstimatedQuotaConfiguration {
        let configuration = try EstimatedQuotaConfiguration(
            providerName: providerName,
            windowLabel: windowLabel,
            used: used,
            limit: limit,
            unit: unit,
            currencyCode: currencyCode,
            resetDate: resetDate
        )
        var updated = configurations
        updated.append(configuration)
        try commit(updated)
        return configuration
    }

    func update(_ configuration: EstimatedQuotaConfiguration) throws {
        guard let index = configurations.firstIndex(where: { $0.id == configuration.id }) else {
            throw EstimatedQuotaStoreError.configurationNotFound
        }
        var updated = configurations
        updated[index] = configuration
        try commit(updated)
    }

    func delete(id: UUID) throws {
        let updated = configurations.filter { $0.id != id }
        guard updated.count != configurations.count else { return }
        try commit(updated)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        guard source.allSatisfy(configurations.indices.contains) else { return }

        var reordered = configurations
        let moving = source.sorted().map { reordered[$0] }
        for index in source.sorted(by: >) {
            reordered.remove(at: index)
        }

        let removedBeforeDestination = source.filter { $0 < destination }.count
        let adjustedDestination = max(
            0,
            min(destination - removedBeforeDestination, reordered.count)
        )
        reordered.insert(contentsOf: moving, at: adjustedDestination)
        guard reordered != configurations else { return }
        try commit(reordered)
    }

    func providers() -> [EstimatedQuotaProvider] {
        configurations.map(EstimatedQuotaProvider.init(configuration:))
    }

    func discardUnreadableData() {
        preservedUnknownEntries.removeAll()
        hasUnreadableStoredData = false
        loadWarning = nil
        defaults.removeObject(forKey: storageKey)
        configurations = []
    }

    private func commit(_ updated: [EstimatedQuotaConfiguration]) throws {
        guard !hasUnreadableStoredData else {
            throw EstimatedQuotaStoreError.unreadableStoredData
        }

        var entries: [Any] = try updated.map { configuration in
            let data = try encoder.encode(configuration)
            return try JSONSerialization.jsonObject(with: data)
        }
        entries.append(contentsOf: preservedUnknownEntries)
        let data = try JSONSerialization.data(withJSONObject: entries)
        defaults.set(data, forKey: storageKey)
        configurations = updated
    }

    private static func removingDuplicateIDs(
        from configurations: [EstimatedQuotaConfiguration]
    ) -> [EstimatedQuotaConfiguration] {
        var seen: Set<UUID> = []
        return configurations.filter { seen.insert($0.id).inserted }
    }
}
