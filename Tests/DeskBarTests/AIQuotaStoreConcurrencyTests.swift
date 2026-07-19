import XCTest
@testable import DeskBar

final class AIQuotaStoreConcurrencyTests: XCTestCase {
    func testDeletedProviderCannotRestoreSnapshotAfterInFlightRefresh() async {
        let gate = FetchGate()
        let provider = GatedQuotaProvider(gate: gate)
        let store = AIQuotaStore(providers: [provider])

        let refreshTask = Task { await store.refreshAll() }
        await gate.waitUntilStarted()
        await store.unregister(providerID: provider.id)
        await gate.release()
        _ = await refreshTask.value

        let snapshot = await store.snapshot(for: provider.id)
        XCTAssertNil(snapshot)
    }
}

private struct GatedQuotaProvider: AIQuotaProvider {
    let gate: FetchGate
    let id: AIProviderID = "test.gated"
    let displayName = "Gated"

    func fetchQuota() async throws -> AIQuotaSnapshot {
        await gate.wait()
        return AIQuotaSnapshot(
            providerID: id,
            providerName: displayName,
            confidence: .verified,
            reading: .init(used: 1, limit: 10, unit: .requests),
            source: .init(label: "Test"),
            statusMessage: "Fresh"
        )
    }
}

private actor FetchGate {
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
