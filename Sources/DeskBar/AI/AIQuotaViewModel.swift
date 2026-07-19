import Combine
import Foundation

@MainActor
final class AIQuotaViewModel: ObservableObject {
    @Published private(set) var snapshots: [AIQuotaSnapshot] = []
    @Published private(set) var isRefreshing = false

    private let store: AIQuotaStore
    let estimatedStore: EstimatedQuotaStore
    private var refreshTask: Task<Void, Never>?
    private var estimatedSyncTask: Task<Void, Never>?
    private var estimatedStoreObserver: AnyCancellable?
    private var estimatedSyncGeneration: UInt64 = 0
    private var refreshQueued = false
    private var refreshInterval: TimeInterval = 15 * 60
    private var isRunning = false

    init(
        store: AIQuotaStore = AIQuotaStore(
            providers: [
                OpenAIQuotaProvider(window: .primary),
                OpenAIQuotaProvider(window: .secondary),
                ClaudeQuotaProvider(window: .fiveHour),
                ClaudeQuotaProvider(window: .sevenDay)
            ]
        ),
        estimatedStore: EstimatedQuotaStore = EstimatedQuotaStore()
    ) {
        self.store = store
        self.estimatedStore = estimatedStore
        estimatedStoreObserver = estimatedStore.$configurations
            .dropFirst()
            .sink { [weak self] configurations in
                self?.queueEstimatedProviderSynchronization(configurations)
            }
    }

    func start() {
        isRunning = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if let self {
                await self.synchronizeEstimatedProviders(self.estimatedStore.configurations)
            }
            while !Task.isCancelled {
                await self?.refresh()
                guard await self?.completeQueuedRefreshBeforeSleeping() == true,
                      let refreshInterval = self?.refreshInterval else { return }
                do {
                    try await Task.sleep(for: .seconds(refreshInterval))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        estimatedSyncTask?.cancel()
        estimatedSyncTask = nil
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        let normalized = min(max(interval, 60), 60 * 60)
        guard normalized != refreshInterval else { return }
        refreshInterval = normalized
        if isRunning { start() }
    }

    private func completeQueuedRefreshBeforeSleeping() async -> Bool {
        while isRefreshing {
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        guard !Task.isCancelled else { return false }
        if refreshQueued { await refresh() }
        return !Task.isCancelled
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true
        repeat {
            refreshQueued = false
            _ = await store.refreshAll()
            guard !Task.isCancelled else {
                isRefreshing = false
                return
            }
            snapshots = await store.allSnapshots().sorted(by: snapshotSort)
        } while refreshQueued
        isRefreshing = false
    }

    private func queueEstimatedProviderSynchronization(
        _ configurations: [EstimatedQuotaConfiguration]
    ) {
        estimatedSyncGeneration &+= 1
        let generation = estimatedSyncGeneration
        estimatedSyncTask?.cancel()
        estimatedSyncTask = Task { [weak self] in
            guard let self else { return }
            let applied = await self.synchronizeEstimatedProviders(
                configurations,
                generation: generation
            )
            guard applied, !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    @discardableResult
    private func synchronizeEstimatedProviders(
        _ configurations: [EstimatedQuotaConfiguration],
        generation: UInt64? = nil
    ) async -> Bool {
        let providers = configurations.map(EstimatedQuotaProvider.init(configuration:))
        if generation == nil { estimatedSyncGeneration &+= 1 }
        return await store.replaceEstimatedProviders(
            providers,
            generation: generation ?? estimatedSyncGeneration
        )
    }

    private func snapshotSort(_ lhs: AIQuotaSnapshot, _ rhs: AIQuotaSnapshot) -> Bool {
        let rank: (AIQuotaConfidence) -> Int = {
            switch $0 {
            case .verified: 0
            case .estimated: 1
            case .unavailable: 2
            }
        }
        let lhsRank = rank(lhs.confidence)
        let rhsRank = rank(rhs.confidence)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.providerName.localizedCaseInsensitiveCompare(rhs.providerName) == .orderedAscending
    }
}
