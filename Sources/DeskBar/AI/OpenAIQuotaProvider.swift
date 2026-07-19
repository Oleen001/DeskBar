import Foundation

enum CodexRateLimitWindowSelection: Sendable {
    case primary
    case secondary
}

struct OpenAIQuotaProvider: AIQuotaProvider {
    let id: AIProviderID
    let displayName = "Codex"

    private let window: CodexRateLimitWindowSelection
    private let bridge: CodexRateLimitBridge

    init(
        window: CodexRateLimitWindowSelection = .primary,
        bridge: CodexRateLimitBridge = .shared
    ) {
        self.window = window
        self.bridge = bridge
        id = window == .primary ? .openAI : AIProviderID(rawValue: "openai.codex.secondary")
    }

    init(
        window: CodexRateLimitWindowSelection = .primary,
        transport: any CodexAppServerTransport,
        // A cold Codex app-server can warm its plugin/config cache before answering.
        timeout: TimeInterval = 15,
        cacheLifetime: TimeInterval = 5,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.init(
            window: window,
            bridge: CodexRateLimitBridge(
                transport: transport,
                timeout: timeout,
                cacheLifetime: cacheLifetime,
                now: now
            )
        )
    }

    func fetchQuota() async throws -> AIQuotaSnapshot {
        do {
            let record = try await bridge.fetch()
            return snapshot(from: record, isStale: false, statusMessage: nil)
        } catch {
            if let record = await bridge.lastSuccessfulRecord() {
                return snapshot(
                    from: record,
                    isStale: true,
                    statusMessage: "Codex rate limits are temporarily unavailable. Showing the last known reading."
                )
            }

            let message: String
            if case CodexAppServerError.executableNotFound = error {
                message = "Codex CLI is not installed or is not available to DeskBar."
            } else {
                message = "Codex rate limits are temporarily unavailable."
            }
            return .unavailable(
                providerID: id,
                providerName: displayName,
                message: message,
                source: Self.source,
                fetchedAt: await bridge.currentDate()
            )
        }
    }

    private func snapshot(
        from record: CodexRateLimitRecord,
        isStale: Bool,
        statusMessage: String?
    ) -> AIQuotaSnapshot {
        let value: CodexRateLimitWindow?
        switch window {
        case .primary: value = record.snapshot.primary
        case .secondary: value = record.snapshot.secondary
        }

        guard let value else {
            return .unavailable(
                providerID: id,
                providerName: displayName,
                message: "This Codex account did not report a \(fallbackWindowLabel.lowercased()) rate-limit window.",
                source: Self.source,
                fetchedAt: record.fetchedAt
            )
        }

        let usedPercent = min(max(value.usedPercent, 0), 100)
        let label = value.windowDurationMinutes
            .map(Self.windowLabel(durationMinutes:)) ?? fallbackWindowLabel
        let resetDate = value.resetsAtEpochSeconds.flatMap {
            $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
        }
        let stateMessage = statusMessage
            ?? "\(usedPercent)% of the \(label.lowercased()) Codex limit is used."
        let freshUntil = isStale
            ? record.staleAt ?? record.fetchedAt
            : record.fetchedAt.addingTimeInterval(20 * 60)

        return AIQuotaSnapshot(
            providerID: id,
            providerName: displayName,
            planName: record.snapshot.planName.flatMap(Self.displayPlanName),
            windowLabel: label,
            // Reset credits can change independently of the cached usage windows. Never
            // present a stale count as if it were currently available.
            resetCreditsAvailable: isStale ? nil : record.snapshot.resetCreditsAvailable,
            confidence: .verified,
            reading: AIQuotaReading(
                used: Double(usedPercent),
                limit: 100,
                unit: .messages
            ),
            source: Self.source,
            timing: AIQuotaTiming(
                fetchedAt: record.fetchedAt,
                freshUntil: freshUntil,
                resetsAt: resetDate
            ),
            statusMessage: stateMessage
        )
    }

    private var fallbackWindowLabel: String {
        switch window {
        case .primary: "Primary"
        case .secondary: "Secondary"
        }
    }

    private static func windowLabel(durationMinutes: Int64) -> String {
        guard durationMinutes > 0 else { return "Rate limit" }
        if durationMinutes % 10_080 == 0 {
            let weeks = durationMinutes / 10_080
            return weeks == 1 ? "Weekly" : "\(weeks) weeks"
        }
        if durationMinutes % 1_440 == 0 {
            let days = durationMinutes / 1_440
            return days == 1 ? "Daily" : "\(days) days"
        }
        if durationMinutes % 60 == 0 {
            let hours = durationMinutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return "\(durationMinutes) minutes"
    }

    private static func displayPlanName(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "prolite": return "Pro Lite"
        case "plus": return "Plus"
        case "free": return "Free"
        case "go": return "Go"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business", "self_serve_business_usage_based": return "Business"
        case "enterprise", "enterprise_cbp_usage_based": return "Enterprise"
        case "edu": return "Edu"
        case "", "unknown": return nil
        default: return value
        }
    }

    private static let source = AIQuotaSource(label: "Local Codex app-server")
}

actor CodexRateLimitBridge {
    static let shared = CodexRateLimitBridge(transport: LocalCodexAppServerTransport())

    private let transport: any CodexAppServerTransport
    private let timeout: TimeInterval
    private let cacheLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var cachedRecord: CodexRateLimitRecord?
    private var inFlight: Task<CodexRateLimitRecord, Error>?

    init(
        transport: any CodexAppServerTransport,
        // A cold Codex app-server can warm its plugin/config cache before answering.
        timeout: TimeInterval = 15,
        cacheLifetime: TimeInterval = 5,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport
        self.timeout = max(0.01, timeout)
        self.cacheLifetime = max(0, cacheLifetime)
        self.now = now
    }

    func fetch() async throws -> CodexRateLimitRecord {
        let requestDate = now()
        if let cachedRecord,
           requestDate.timeIntervalSince(cachedRecord.fetchedAt) < cacheLifetime {
            return cachedRecord
        }
        if let inFlight {
            return try await inFlight.value
        }

        let transport = self.transport
        let timeout = self.timeout
        let now = self.now
        let task = Task<CodexRateLimitRecord, Error> {
            let data = try await Self.request(transport: transport, timeout: timeout)
            return CodexRateLimitRecord(
                snapshot: try CodexRateLimitDecoder.decode(data),
                fetchedAt: now(),
                staleAt: nil
            )
        }
        inFlight = task

        do {
            let record = try await task.value
            cachedRecord = record
            inFlight = nil
            return record
        } catch {
            inFlight = nil
            throw error
        }
    }

    func lastSuccessfulRecord() -> CodexRateLimitRecord? {
        guard var cachedRecord else { return nil }
        cachedRecord.staleAt = now()
        return cachedRecord
    }

    func currentDate() -> Date {
        now()
    }

    private static func request(
        transport: any CodexAppServerTransport,
        timeout: TimeInterval
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await transport.readRateLimits()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw CodexAppServerError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CodexAppServerError.invalidResponse
            }
            return result
        }
    }
}

struct CodexRateLimitRecord: Sendable {
    let snapshot: CodexRateLimitSnapshot
    let fetchedAt: Date
    var staleAt: Date?
}

struct CodexRateLimitSnapshot: Decodable, Sendable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let planName: String?
    let resetCreditsAvailable: Int?
}

struct CodexRateLimitWindow: Decodable, Sendable {
    let usedPercent: Int
    let windowDurationMinutes: Int64?
    let resetsAtEpochSeconds: Int64?

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMinutes = "windowDurationMins"
        case resetsAtEpochSeconds = "resetsAt"
    }
}

private enum CodexRateLimitDecoder {
    private struct Response: Decodable {
        let id: Int
        let result: ResultPayload?
        let error: ErrorPayload?
    }

    private struct ResultPayload: Decodable {
        let rateLimits: RateLimitPayload
        let rateLimitsByLimitID: [String: RateLimitPayload]?
        let rateLimitResetCredits: RateLimitResetCreditsSummary?

        private enum CodingKeys: String, CodingKey {
            case rateLimits
            case rateLimitsByLimitID = "rateLimitsByLimitId"
            case rateLimitResetCredits
        }

        var codexRateLimits: RateLimitPayload {
            if let codex = rateLimitsByLimitID?["codex"] { return codex }
            if let matching = rateLimitsByLimitID?.values.first(where: { $0.limitID == "codex" }) {
                return matching
            }
            return rateLimits
        }
    }

    private struct RateLimitPayload: Decodable {
        let limitID: String?
        let planType: String?
        let primary: CodexRateLimitWindow?
        let secondary: CodexRateLimitWindow?

        private enum CodingKeys: String, CodingKey {
            case limitID = "limitId"
            case planType
            case primary
            case secondary
        }
    }

    private struct RateLimitResetCreditsSummary: Decodable {
        let availableCount: Int64
    }

    private struct ErrorPayload: Decodable {
        let code: Int?
    }

    static func decode(_ data: Data) throws -> CodexRateLimitSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CodexAppServerError.invalidResponse
        }
        guard response.id == 2, response.error == nil, let result = response.result else {
            throw CodexAppServerError.serverRejected
        }
        let rateLimits = result.codexRateLimits
        guard rateLimits.primary != nil || rateLimits.secondary != nil else {
            throw CodexAppServerError.invalidResponse
        }
        return CodexRateLimitSnapshot(
            primary: rateLimits.primary,
            secondary: rateLimits.secondary,
            planName: rateLimits.planType,
            resetCreditsAvailable: result.rateLimitResetCredits.map { Int(clamping: $0.availableCount) }
        )
    }
}
