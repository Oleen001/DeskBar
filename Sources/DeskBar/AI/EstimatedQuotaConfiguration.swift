import Foundation

enum EstimatedQuotaValidationError: Error, LocalizedError, Sendable {
    case providerNameRequired
    case limitMustBePositive

    var errorDescription: String? {
        switch self {
        case .providerNameRequired:
            "Enter a provider name."
        case .limitMustBePositive:
            "The estimated limit must be a positive, finite number."
        }
    }
}

/// A local, user-entered quota. Its UUID remains stable across edits and persistence.
struct EstimatedQuotaConfiguration: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let providerName: String
    let windowLabel: String?
    let used: Double
    let limit: Double
    let unit: AIQuotaUnit
    let currencyCode: String?
    let resetDate: Date?

    var providerID: AIProviderID {
        AIProviderID(rawValue: "estimated.\(id.uuidString.lowercased())")
    }

    init(
        id: UUID = UUID(),
        providerName: String,
        windowLabel: String? = nil,
        used: Double,
        limit: Double,
        unit: AIQuotaUnit,
        currencyCode: String? = nil,
        resetDate: Date? = nil
    ) throws {
        let normalizedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw EstimatedQuotaValidationError.providerNameRequired
        }
        guard limit.isFinite, limit > 0 else {
            throw EstimatedQuotaValidationError.limitMustBePositive
        }

        self.id = id
        self.providerName = normalizedName
        self.windowLabel = Self.normalizedOptionalLabel(windowLabel)
        self.limit = limit
        self.used = used.isFinite ? min(max(used, 0), limit) : 0
        self.unit = unit
        self.currencyCode = Self.normalizedCurrencyCode(currencyCode, for: unit)
        self.resetDate = resetDate
    }

    private static func normalizedCurrencyCode(_ value: String?, for unit: AIQuotaUnit) -> String? {
        guard unit == .currency,
              let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.uppercased()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case providerName
        case windowLabel
        case used
        case limit
        case unit
        case currencyCode
        case resetDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            providerName: container.decode(String.self, forKey: .providerName),
            windowLabel: container.decodeIfPresent(String.self, forKey: .windowLabel),
            used: container.decode(Double.self, forKey: .used),
            limit: container.decode(Double.self, forKey: .limit),
            unit: container.decode(AIQuotaUnit.self, forKey: .unit),
            currencyCode: container.decodeIfPresent(String.self, forKey: .currencyCode),
            resetDate: container.decodeIfPresent(Date.self, forKey: .resetDate)
        )
    }

    private static func normalizedOptionalLabel(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return nil }
        return normalized
    }
}
