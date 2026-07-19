import Darwin
import Foundation
import XCTest
@testable import DeskBar

final class OpenAIQuotaProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPrimaryAndSecondaryWindowsUseCodexBucketAndShareOneRequest() async throws {
        let transport = FakeCodexTransport(results: [.success(Self.rateLimitsResponse)])
        let bridge = CodexRateLimitBridge(
            transport: transport,
            cacheLifetime: 60,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let primary = OpenAIQuotaProvider(window: .primary, bridge: bridge)
        let secondary = OpenAIQuotaProvider(window: .secondary, bridge: bridge)

        async let primarySnapshot = primary.fetchQuota()
        async let secondarySnapshot = secondary.fetchQuota()
        let snapshots = try await [primarySnapshot, secondarySnapshot]

        XCTAssertEqual(snapshots[0].providerName, "Codex")
        XCTAssertEqual(snapshots[0].windowLabel, "5 hours")
        XCTAssertEqual(snapshots[0].reading?.used, 42)
        XCTAssertEqual(snapshots[0].reading?.limit, 100)
        XCTAssertEqual(snapshots[0].timing.resetsAt, Date(timeIntervalSince1970: 1_800_001_000))
        XCTAssertEqual(snapshots[0].planName, "Pro Lite")
        XCTAssertEqual(snapshots[0].resetCreditsAvailable, 3)
        XCTAssertEqual(snapshots[1].windowLabel, "Weekly")
        XCTAssertEqual(snapshots[1].reading?.used, 73)
        XCTAssertEqual(snapshots[1].providerID.rawValue, "openai.codex.secondary")
        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testMissingExecutableProducesExplicitUnavailableState() async throws {
        let transport = FakeCodexTransport(results: [.failure(.executableNotFound)])
        let provider = OpenAIQuotaProvider(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = try await provider.fetchQuota()

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertNil(snapshot.reading)
        XCTAssertTrue(snapshot.statusMessage.contains("Codex CLI"))
        XCTAssertFalse(snapshot.statusMessage.localizedCaseInsensitiveContains("token"))
    }

    func testNullSecondaryWindowIsUnavailableWithoutDiscardingPrimary() async throws {
        let response = Data(
            #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":18,"windowDurationMins":10080,"resetsAt":1800604800},"secondary":null},"rateLimitsByLimitId":null}}"#.utf8
        )
        let transport = FakeCodexTransport(results: [.success(response)])
        let bridge = CodexRateLimitBridge(transport: transport)
        let primary = OpenAIQuotaProvider(window: .primary, bridge: bridge)
        let secondary = OpenAIQuotaProvider(window: .secondary, bridge: bridge)

        let primarySnapshot = try await primary.fetchQuota()
        let secondarySnapshot = try await secondary.fetchQuota()

        XCTAssertEqual(primarySnapshot.confidence, .verified)
        XCTAssertEqual(primarySnapshot.windowLabel, "Weekly")
        XCTAssertEqual(primarySnapshot.reading?.used, 18)
        XCTAssertEqual(secondarySnapshot.confidence, .unavailable)
        XCTAssertNil(secondarySnapshot.reading)
        XCTAssertTrue(secondarySnapshot.statusMessage.contains("secondary"))
    }

    func testFailureAfterSuccessReturnsStaleLastKnownReading() async throws {
        let transport = FakeCodexTransport(results: [
            .success(Self.rateLimitsResponse),
            .failure(.serverRejected)
        ])
        let bridge = CodexRateLimitBridge(
            transport: transport,
            cacheLifetime: 0,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let provider = OpenAIQuotaProvider(window: .primary, bridge: bridge)

        _ = try await provider.fetchQuota()
        let stale = try await provider.fetchQuota()

        XCTAssertEqual(stale.confidence, .verified)
        XCTAssertEqual(stale.reading?.used, 42)
        XCTAssertNil(stale.resetCreditsAvailable)
        XCTAssertTrue(stale.timing.isStale(at: now))
        XCTAssertTrue(stale.statusMessage.contains("last known"))
        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testTimeoutCancelsTransportAndReturnsUnavailableState() async throws {
        let cancellation = CancellationFlag()
        let transport = HangingCodexTransport(cancellation: cancellation)
        let provider = OpenAIQuotaProvider(
            transport: transport,
            timeout: 0.02,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = try await provider.fetchQuota()

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(cancellation.value)
    }

    func testTimeoutTerminatesAndReapsUnresponsiveLocalProcess() async throws {
        let processIdentifier = ProcessIdentifierBox()
        let transport = LocalCodexAppServerTransport(
            executableURL: { URL(fileURLWithPath: "/usr/bin/perl") },
            arguments: ["-e", "$SIG{TERM}=sub{}; sleep 30"],
            processStarted: { processIdentifier.set($0) }
        )
        let provider = OpenAIQuotaProvider(transport: transport, timeout: 0.02)

        let snapshot = try await provider.fetchQuota()

        XCTAssertEqual(snapshot.confidence, .unavailable)
        let pid = try XCTUnwrap(processIdentifier.value)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testMalformedOrErrorResponsesDoNotExposeRawServerContent() async throws {
        let sensitive = Data(#"{"id":2,"error":{"code":401,"message":"secret-token-value"}}"#.utf8)
        let transport = FakeCodexTransport(results: [.success(sensitive)])
        let provider = OpenAIQuotaProvider(transport: transport)

        let snapshot = try await provider.fetchQuota()

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertFalse(snapshot.statusMessage.contains("secret-token-value"))
    }

    func testExecutableResolverUsesOnlyApprovedPathsAndResolvesSymlinks() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskBarCodexResolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let approvedSymlink = temporaryDirectory.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(
            at: approvedSymlink,
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )

        let resolved = CodexExecutableResolver.resolve(
            approvedPaths: [
                temporaryDirectory.appendingPathComponent("missing").path,
                approvedSymlink.path,
                approvedSymlink.path
            ]
        )

        XCTAssertEqual(
            resolved,
            URL(fileURLWithPath: "/bin/sh").resolvingSymlinksInPath()
        )
    }

    func testMinimalProcessEnvironmentExcludesCredentialsAndInheritedPath() {
        let environment = CodexProcessEnvironment.make(
            homeDirectory: URL(fileURLWithPath: "/Users/example"),
            temporaryDirectory: URL(fileURLWithPath: "/private/tmp/example")
        )

        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["TMPDIR"], "/private/tmp/example")
        XCTAssertEqual(environment["PATH"], CodexProcessEnvironment.safeExecutablePath)
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertNil(environment["CODEX_ACCESS_TOKEN"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(Set(environment.keys), ["HOME", "TMPDIR", "PATH", "LANG"])
    }

    private static let rateLimitsResponse = Data(
        #"{"id":2,"result":{"rateLimits":{"limitId":"legacy","primary":{"usedPercent":9,"windowDurationMins":60,"resetsAt":1800000100}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1800001000},"secondary":{"usedPercent":73,"windowDurationMins":10080,"resetsAt":1800604800}}},"rateLimitResetCredits":{"availableCount":3}}}"#.utf8
    )
}

private actor FakeCodexTransport: CodexAppServerTransport {
    private var results: [Result<Data, CodexAppServerError>]
    private(set) var callCount = 0

    init(results: [Result<Data, CodexAppServerError>]) {
        self.results = results
    }

    func readRateLimits() async throws -> Data {
        callCount += 1
        guard !results.isEmpty else { throw CodexAppServerError.invalidResponse }
        return try results.removeFirst().get()
    }
}

private struct HangingCodexTransport: CodexAppServerTransport {
    let cancellation: CancellationFlag

    func readRateLimits() async throws -> Data {
        try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(30))
            return Data()
        } onCancel: {
            cancellation.set()
        }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}

private final class ProcessIdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: pid_t?

    var value: pid_t? {
        lock.withLock { storage }
    }

    func set(_ value: pid_t) {
        lock.withLock { storage = value }
    }
}
