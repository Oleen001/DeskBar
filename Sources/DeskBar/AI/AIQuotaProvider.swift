import Foundation

/// Provider implementations must use official APIs only and must never expose credentials in errors.
protocol AIQuotaProvider: Sendable {
    var id: AIProviderID { get }
    var displayName: String { get }

    func fetchQuota() async throws -> AIQuotaSnapshot
}

/// An error that is safe to present without including credentials or raw provider responses.
enum AIQuotaProviderError: Error, LocalizedError, Sendable {
    case credentialsRequired
    case unsupported(message: String)
    case temporarilyUnavailable

    var errorDescription: String? {
        switch self {
        case .credentialsRequired:
            "Credentials are required for this provider."
        case let .unsupported(message):
            message
        case .temporarilyUnavailable:
            "Quota data is temporarily unavailable."
        }
    }
}

/// Concurrency-safe registry and cache for quota providers.
actor AIQuotaStore {
    private var providers: [AIProviderID: any AIQuotaProvider] = [:]
    private var snapshots: [AIProviderID: AIQuotaSnapshot] = [:]
    private var providerRevisions: [AIProviderID: UInt64] = [:]
    private var estimatedProviderIDs: Set<AIProviderID> = []
    private var estimatedProviderGeneration: UInt64 = 0

    init(providers: [any AIQuotaProvider] = []) {
        for provider in providers {
            self.providers[provider.id] = provider
            providerRevisions[provider.id, default: 0] &+= 1
        }
    }

    func register(_ provider: any AIQuotaProvider) {
        providers[provider.id] = provider
        providerRevisions[provider.id, default: 0] &+= 1
    }

    func unregister(providerID: AIProviderID) {
        providers.removeValue(forKey: providerID)
        snapshots.removeValue(forKey: providerID)
        providerRevisions[providerID, default: 0] &+= 1
    }

    @discardableResult
    func replaceEstimatedProviders(
        _ replacements: [EstimatedQuotaProvider],
        generation: UInt64
    ) -> Bool {
        guard generation >= estimatedProviderGeneration else { return false }
        estimatedProviderGeneration = generation

        for providerID in estimatedProviderIDs {
            providers.removeValue(forKey: providerID)
            snapshots.removeValue(forKey: providerID)
            providerRevisions[providerID, default: 0] &+= 1
        }
        for provider in replacements {
            providers[provider.id] = provider
            providerRevisions[provider.id, default: 0] &+= 1
        }
        estimatedProviderIDs = Set(replacements.map(\.id))
        return true
    }

    func snapshot(for providerID: AIProviderID) -> AIQuotaSnapshot? {
        snapshots[providerID]
    }

    func allSnapshots() -> [AIQuotaSnapshot] {
        snapshots.values.sorted {
            $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending
        }
    }

    @discardableResult
    func refresh(providerID: AIProviderID) async throws -> AIQuotaSnapshot {
        guard let provider = providers[providerID] else {
            throw AIQuotaProviderError.unsupported(message: "This AI provider is not configured.")
        }
        let revision = providerRevisions[providerID, default: 0]

        let snapshot = try await provider.fetchQuota()
        guard snapshot.providerID == providerID,
              providers[providerID] != nil,
              providerRevisions[providerID] == revision else {
            throw AIQuotaProviderError.temporarilyUnavailable
        }
        snapshots[providerID] = snapshot
        return snapshot
    }

    /// Refreshes providers independently so one provider failure cannot discard other valid readings.
    func refreshAll() async -> [AIProviderID: Result<AIQuotaSnapshot, AIQuotaProviderError>] {
        var results: [AIProviderID: Result<AIQuotaSnapshot, AIQuotaProviderError>] = [:]

        await withTaskGroup(
            of: (AIProviderID, UInt64, Result<AIQuotaSnapshot, AIQuotaProviderError>).self
        ) { group in
            for provider in providers.values {
                let revision = providerRevisions[provider.id, default: 0]
                group.addTask {
                    do {
                        return (provider.id, revision, .success(try await provider.fetchQuota()))
                    } catch let error as AIQuotaProviderError {
                        return (provider.id, revision, .failure(error))
                    } catch {
                        return (provider.id, revision, .failure(.temporarilyUnavailable))
                    }
                }
            }

            for await (providerID, revision, result) in group {
                guard providers[providerID] != nil,
                      providerRevisions[providerID] == revision else {
                    continue
                }
                if case let .success(snapshot) = result, snapshot.providerID == providerID {
                    snapshots[providerID] = snapshot
                    results[providerID] = result
                } else if case .success = result {
                    results[providerID] = .failure(.temporarilyUnavailable)
                } else {
                    if let cached = snapshots[providerID] {
                        let message: String
                        if case let .failure(error) = result {
                            message = error.localizedDescription
                        } else {
                            message = "Quota refresh failed."
                        }
                        snapshots[providerID] = cached.markingRefreshFailure(
                            message: "\(message) Showing the last known reading."
                        )
                    }
                    results[providerID] = result
                }
            }
        }

        return results
    }
}
