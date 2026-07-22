import Foundation

/// A stable identifier for an AI provider integration.
struct AIProviderID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    static let openAI: Self = "openai"
    static let openAICodexSecondary: Self = "openai.codex.secondary"
    static let gemini: Self = "gemini"
    static let claudeCodeFiveHour: Self = "claude-code.five-hour"
    static let claudeCodeSevenDay: Self = "claude-code.seven-day"
}

/// Describes how trustworthy a displayed quota value is.
enum AIQuotaConfidence: String, Codable, Sendable {
    /// Returned by an official, documented provider API for the configured account or project.
    case verified

    /// Derived from a limit entered by the user and clearly labelled as an estimate.
    case estimated

    /// The provider does not expose enough supported information to calculate a quota.
    case unavailable
}

/// The unit used by a quota reading. API spend is intentionally separate from consumer message limits.
enum AIQuotaUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case requests
    case tokens
    case currency
    case credits
    case messages

    var id: String { rawValue }
}

/// A provider-reported or user-configured quota reading.
struct AIQuotaReading: Hashable, Codable, Sendable {
    let used: Double
    let limit: Double
    let unit: AIQuotaUnit
    let currencyCode: String?

    init(used: Double, limit: Double, unit: AIQuotaUnit, currencyCode: String? = nil) {
        self.used = used.isFinite ? max(0, used) : 0
        self.limit = limit.isFinite ? max(0, limit) : 0
        self.unit = unit
        self.currencyCode = currencyCode
    }

    /// A display-safe fraction. Values over the limit remain capped while raw values are preserved.
    var fractionUsed: Double? {
        guard used.isFinite, limit.isFinite, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }

    /// The portion of the current window that is still available. UI uses this rather than
    /// the underlying used value so a fuller bar always means more capacity remains.
    var fractionRemaining: Double? {
        fractionUsed.map { 1 - $0 }
    }
}

/// Where a reading came from. Never place credentials, account identifiers, or response bodies here.
struct AIQuotaSource: Hashable, Codable, Sendable {
    let label: String
    let documentationURL: URL?

    init(label: String, documentationURL: URL? = nil) {
        self.label = label
        self.documentationURL = documentationURL
    }
}

/// Freshness and reset metadata kept separate from the reading so unavailable states remain explicit.
struct AIQuotaTiming: Hashable, Codable, Sendable {
    let fetchedAt: Date
    let freshUntil: Date?
    let resetsAt: Date?

    init(fetchedAt: Date = .now, freshUntil: Date? = nil, resetsAt: Date? = nil) {
        self.fetchedAt = fetchedAt
        self.freshUntil = freshUntil
        self.resetsAt = resetsAt
    }

    func isStale(at date: Date = .now) -> Bool {
        guard let freshUntil else { return false }
        return date >= freshUntil
    }
}

/// A complete quota result suitable for UI presentation and local caching.
struct AIQuotaSnapshot: Identifiable, Hashable, Codable, Sendable {
    var id: AIProviderID { providerID }

    let providerID: AIProviderID
    let providerName: String
    /// Optional subscription label supplied by the provider or entered as a display override.
    let planName: String?
    let windowLabel: String?
    /// Number of provider-issued reset credits currently available, when reported.
    let resetCreditsAvailable: Int?
    let confidence: AIQuotaConfidence
    let reading: AIQuotaReading?
    let source: AIQuotaSource
    let timing: AIQuotaTiming
    let statusMessage: String

    init(
        providerID: AIProviderID,
        providerName: String,
        planName: String? = nil,
        windowLabel: String? = nil,
        resetCreditsAvailable: Int? = nil,
        confidence: AIQuotaConfidence,
        reading: AIQuotaReading?,
        source: AIQuotaSource,
        timing: AIQuotaTiming = .init(),
        statusMessage: String
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.planName = planName
        self.windowLabel = windowLabel
        self.resetCreditsAvailable = resetCreditsAvailable.map { max(0, $0) }
        self.confidence = confidence
        self.reading = reading
        self.source = source
        self.timing = timing
        self.statusMessage = statusMessage
    }

    var isStale: Bool {
        timing.isStale()
    }

    func markingRefreshFailure(message: String, at date: Date = .now) -> Self {
        Self(
            providerID: providerID,
            providerName: providerName,
            planName: planName,
            windowLabel: windowLabel,
            resetCreditsAvailable: resetCreditsAvailable,
            confidence: confidence,
            reading: reading,
            source: source,
            timing: .init(
                fetchedAt: timing.fetchedAt,
                freshUntil: date,
                resetsAt: timing.resetsAt
            ),
            statusMessage: message
        )
    }

    static func unavailable(
        providerID: AIProviderID,
        providerName: String,
        message: String,
        source: AIQuotaSource,
        fetchedAt: Date = .now
    ) -> Self {
        Self(
            providerID: providerID,
            providerName: providerName,
            planName: nil,
            confidence: .unavailable,
            reading: nil,
            source: source,
            timing: .init(fetchedAt: fetchedAt),
            statusMessage: message
        )
    }
}
