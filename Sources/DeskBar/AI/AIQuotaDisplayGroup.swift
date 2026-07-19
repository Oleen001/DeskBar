import Foundation

struct AIQuotaDisplayGroup: Identifiable, Equatable, Sendable {
    let id: String
    let providerName: String
    let planName: String?
    let resetCreditsAvailable: Int?
    let snapshots: [AIQuotaSnapshot]

    static func grouping(_ snapshots: [AIQuotaSnapshot]) -> [AIQuotaDisplayGroup] {
        var orderedKeys: [String] = []
        var grouped: [String: [AIQuotaSnapshot]] = [:]
        var displayNames: [String: String] = [:]

        for snapshot in snapshots {
            let key = normalizedKey(snapshot.providerName)
            if grouped[key] == nil {
                orderedKeys.append(key)
                displayNames[key] = snapshot.providerName
            }
            grouped[key, default: []].append(snapshot)
        }

        return orderedKeys.compactMap { key in
            guard let snapshots = grouped[key], let providerName = displayNames[key] else {
                return nil
            }
            return AIQuotaDisplayGroup(
                id: key,
                providerName: providerName,
                planName: snapshots.compactMap(\.planName).first,
                resetCreditsAvailable: snapshots.compactMap(\.resetCreditsAvailable).first,
                snapshots: snapshots
            )
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
