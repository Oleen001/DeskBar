import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: LaunchAtLoginServicing {}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    enum State: Equatable {
        case unavailable(String)
        case disabled
        case enabled
        case requiresApproval
        case notFound

        var isEnabled: Bool {
            self == .enabled
        }

        var canChangeRegistration: Bool {
            switch self {
            case .disabled, .enabled, .requiresApproval:
                true
            case .unavailable, .notFound:
                false
            }
        }
    }

    @Published private(set) var state: State
    @Published private(set) var isUpdating = false
    @Published private(set) var lastError: String?

    var isEnabled: Bool {
        state.isEnabled
    }

    private let service: (any LaunchAtLoginServicing)?

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        service: (any LaunchAtLoginServicing)? = nil
    ) {
        guard Self.isValidApplicationBundle(
            at: bundleURL,
            bundleIdentifier: bundleIdentifier
        ) else {
            self.service = nil
            state = .unavailable(
                "Launch at Login is available after DeskBar is installed as a signed .app."
            )
            return
        }

        let resolvedService = service ?? SMAppService.mainApp
        self.service = resolvedService
        state = Self.state(for: resolvedService.status)
    }

    func refresh() {
        guard let service else { return }
        state = Self.state(for: service.status)
    }

    func setEnabled(_ shouldEnable: Bool) async {
        guard let service, !isUpdating else { return }

        lastError = nil
        refresh()

        if shouldEnable, service.status == .enabled { return }
        if !shouldEnable, service.status == .notRegistered { return }

        if shouldEnable, service.status == .requiresApproval {
            state = .requiresApproval
            return
        }

        isUpdating = true
        defer {
            isUpdating = false
            refresh()
        }

        do {
            if shouldEnable {
                try service.register()
            } else {
                try await service.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearError() {
        lastError = nil
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func isValidApplicationBundle(
        at bundleURL: URL,
        bundleIdentifier: String?
    ) -> Bool {
        guard bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return false
        }
        return bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .unavailable("This macOS version returned an unknown Login Item status.")
        }
    }
}
