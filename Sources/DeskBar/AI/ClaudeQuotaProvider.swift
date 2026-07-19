import Foundation

struct ClaudeCodeRateLimitWindow: Codable, Equatable, Sendable {
    let usedPercentage: Double
    let resetsAt: Double

    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

/// The exact rate-limit subtree documented for Claude Code status-line commands.
/// No credential, transcript, prompt, or account field is decoded or persisted.
struct ClaudeCodeRateLimits: Codable, Equatable, Sendable {
    let fiveHour: ClaudeCodeRateLimitWindow?
    let sevenDay: ClaudeCodeRateLimitWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

enum ClaudeQuotaWindow: String, CaseIterable, Sendable {
    case fiveHour
    case sevenDay

    var providerID: AIProviderID {
        switch self {
        case .fiveHour: .claudeCodeFiveHour
        case .sevenDay: .claudeCodeSevenDay
        }
    }

    var label: String {
        switch self {
        case .fiveHour: "5 hours"
        case .sevenDay: "7 days"
        }
    }

    fileprivate func reading(from rateLimits: ClaudeCodeRateLimits) -> ClaudeCodeRateLimitWindow? {
        switch self {
        case .fiveHour: rateLimits.fiveHour
        case .sevenDay: rateLimits.sevenDay
        }
    }
}

struct ClaudeQuotaProvider: AIQuotaProvider {
    static let documentationURL = URL(string: "https://code.claude.com/docs/en/statusline")

    let window: ClaudeQuotaWindow
    let cacheURL: URL
    let freshnessInterval: TimeInterval
    let now: @Sendable () -> Date

    var id: AIProviderID { window.providerID }
    let displayName = "Claude"

    init(
        window: ClaudeQuotaWindow,
        cacheURL: URL = ClaudeStatusLineBridgePaths.default.cacheURL,
        freshnessInterval: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.window = window
        self.cacheURL = cacheURL
        self.freshnessInterval = max(1, freshnessInterval)
        self.now = now
    }

    func fetchQuota() async throws -> AIQuotaSnapshot {
        let fetchedAt = now()
        let source = AIQuotaSource(
            label: "Claude Code status-line rate limits",
            documentationURL: Self.documentationURL
        )

        guard let cacheData = try? Data(contentsOf: cacheURL) else {
            return .unavailable(
                providerID: id,
                providerName: displayName,
                message: "Connect the Claude Code status-line bridge, then send a Claude Code message to receive usage data.",
                source: source,
                fetchedAt: fetchedAt
            )
        }

        guard let rateLimits = try? JSONDecoder().decode(ClaudeCodeRateLimits.self, from: cacheData),
              let rateLimit = window.reading(from: rateLimits),
              rateLimit.usedPercentage.isFinite,
              rateLimit.resetsAt.isFinite,
              rateLimit.resetsAt > 0 else {
            return .unavailable(
                providerID: id,
                providerName: displayName,
                message: "Claude Code has not supplied the \(window.label) subscription limit yet.",
                source: source,
                fetchedAt: fetchedAt
            )
        }

        let fileTimestamp = min(cacheModificationDate() ?? fetchedAt, fetchedAt)
        let resetDate = Date(timeIntervalSince1970: rateLimit.resetsAt)
        let cacheFreshUntil = fileTimestamp.addingTimeInterval(freshnessInterval)
        let freshUntil = min(cacheFreshUntil, resetDate)
        let statusMessage: String
        if fetchedAt >= resetDate {
            statusMessage = "The \(window.label) window has reset. Waiting for the next Claude Code update."
        } else if fetchedAt >= cacheFreshUntil {
            statusMessage = "Last updated by Claude Code more than \(Int(freshnessInterval / 60)) minutes ago."
        } else {
            statusMessage = "Verified from Claude Code's documented status-line payload."
        }
        return AIQuotaSnapshot(
            providerID: id,
            providerName: displayName,
            windowLabel: window.label,
            confidence: .verified,
            reading: AIQuotaReading(
                used: min(max(rateLimit.usedPercentage, 0), 100),
                limit: 100,
                unit: .credits
            ),
            source: source,
            timing: AIQuotaTiming(
                fetchedAt: fileTimestamp,
                freshUntil: freshUntil,
                resetsAt: resetDate
            ),
            statusMessage: statusMessage
        )
    }

    private func cacheModificationDate() -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}
