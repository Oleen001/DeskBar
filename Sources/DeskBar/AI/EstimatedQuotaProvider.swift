import Foundation

/// Adapts a user-entered limit to the common quota provider contract.
struct EstimatedQuotaProvider: AIQuotaProvider {
    let configuration: EstimatedQuotaConfiguration

    var id: AIProviderID { configuration.providerID }
    var displayName: String { configuration.providerName }

    func fetchQuota() async throws -> AIQuotaSnapshot {
        snapshot(at: .now)
    }

    func snapshot(at date: Date) -> AIQuotaSnapshot {
        AIQuotaSnapshot(
            providerID: id,
            providerName: displayName,
            windowLabel: configuration.windowLabel,
            confidence: .estimated,
            reading: AIQuotaReading(
                used: configuration.used,
                limit: configuration.limit,
                unit: configuration.unit,
                currencyCode: configuration.currencyCode
            ),
            source: AIQuotaSource(label: "User-entered estimate"),
            timing: AIQuotaTiming(
                fetchedAt: date,
                freshUntil: configuration.resetDate,
                resetsAt: configuration.resetDate
            ),
            statusMessage: statusMessage(at: date)
        )
    }

    private func statusMessage(at date: Date) -> String {
        if let resetDate = configuration.resetDate, resetDate <= date {
            return "The user-entered estimate is past its reset date. Update the usage before relying on it."
        }
        return "Based on a limit entered on this Mac, not provider-verified usage."
    }
}
