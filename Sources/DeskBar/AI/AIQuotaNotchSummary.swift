import Foundation

/// The two compact readings shown in the MacBook notch ribbon. When a provider reports more than
/// one window, show the least remaining capacity so the status stays conservative and useful.
struct AIQuotaNotchSummary: Identifiable, Equatable, Sendable {
    enum Provider: String, CaseIterable, Sendable {
        case claude
        case codex

        var displayName: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            }
        }
    }

    let provider: Provider
    let remainingPercentage: Int?
    let windowLabel: String?

    var id: Provider { provider }

    static func summaries(from snapshots: [AIQuotaSnapshot]) -> [Self] {
        Provider.allCases.map { provider in
            // Only supported provider integrations belong in the compact account status. A
            // manually entered estimate can share a display name, but must never displace a
            // verified account's value while still looking like that account.
            let matches = snapshots.filter { provider.matchesIntegration($0.providerID) }
            let tightestWindow = matches.compactMap { snapshot -> (AIQuotaSnapshot, Double)? in
                guard let remaining = snapshot.reading?.fractionRemaining else { return nil }
                return (snapshot, remaining)
            }
            .min { $0.1 < $1.1 }

            return Self(
                provider: provider,
                remainingPercentage: tightestWindow.map { Int(($0.1 * 100).rounded()) },
                windowLabel: tightestWindow?.0.windowLabel
            )
        }
    }
}

extension AIQuotaNotchSummary.Provider {
    fileprivate func matchesIntegration(_ providerID: AIProviderID) -> Bool {
        switch self {
        case .claude:
            return providerID == .claudeCodeFiveHour || providerID == .claudeCodeSevenDay
        case .codex:
            return providerID == .openAI || providerID == .openAICodexSecondary
        }
    }
}
