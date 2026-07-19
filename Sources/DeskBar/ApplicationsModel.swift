import AppKit
import Combine

struct DesktopApplication: Identifiable {
    let id: String
    let bundleIdentifier: String?
    let name: String
    let icon: NSImage
    let application: NSRunningApplication?
    let applicationURL: URL?
    let isPinned: Bool

    var isRunning: Bool {
        application != nil
    }
}

@MainActor
final class ApplicationsModel: ObservableObject {
    @Published private(set) var apps: [DesktopApplication] = []
    @Published private(set) var lastLaunchError: String?

    let pinnedApps: PinnedAppsStore

    private var observers: [NSObjectProtocol] = []
    private var pinnedAppsObserver: AnyCancellable?

    init(pinnedApps: PinnedAppsStore = PinnedAppsStore()) {
        self.pinnedApps = pinnedApps
        pinnedAppsObserver = pinnedApps.$bundleIdentifiers
            .dropFirst()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    func start() {
        guard observers.isEmpty else {
            refresh()
            return
        }

        refresh()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    func refresh() {
        let runningApplications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }

        var runningByBundleIdentifier: [String: NSRunningApplication] = [:]
        var runningWithoutBundleIdentifier: [NSRunningApplication] = []

        for application in runningApplications {
            guard let bundleIdentifier = application.bundleIdentifier else {
                runningWithoutBundleIdentifier.append(application)
                continue
            }

            if let existing = runningByBundleIdentifier[bundleIdentifier] {
                if application.isActive && !existing.isActive {
                    runningByBundleIdentifier[bundleIdentifier] = application
                }
            } else {
                runningByBundleIdentifier[bundleIdentifier] = application
            }
        }

        let pinnedItems = pinnedApps.bundleIdentifiers.map { bundleIdentifier in
            let runningApplication = runningByBundleIdentifier.removeValue(forKey: bundleIdentifier)
            return makeApplication(
                bundleIdentifier: bundleIdentifier,
                runningApplication: runningApplication,
                isPinned: true
            )
        }

        let unpinnedRunningItems = runningByBundleIdentifier
            .map { bundleIdentifier, runningApplication in
                makeApplication(
                    bundleIdentifier: bundleIdentifier,
                    runningApplication: runningApplication,
                    isPinned: false
                )
            }
            .sorted(by: applicationSort)

        let unidentifiableRunningItems = runningWithoutBundleIdentifier
            .map { runningApplication in
                makeApplication(
                    bundleIdentifier: nil,
                    runningApplication: runningApplication,
                    isPinned: false
                )
            }
            .sorted(by: applicationSort)

        apps = pinnedItems + unpinnedRunningItems + unidentifiableRunningItems
    }

    func activate(_ app: DesktopApplication) {
        lastLaunchError = nil

        if let runningApplication = app.application, !runningApplication.isTerminated {
            runningApplication.activate(options: [.activateAllWindows])
            return
        }

        guard let applicationURL = app.applicationURL else {
            lastLaunchError = "DeskBar could not find \(app.name) on this Mac."
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let applicationName = app.name
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastLaunchError = "DeskBar could not open \(applicationName): \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func pin(_ app: DesktopApplication) -> Bool {
        guard let bundleIdentifier = app.bundleIdentifier else { return false }
        return pinnedApps.pin(bundleIdentifier)
    }

    func unpin(_ app: DesktopApplication) {
        guard let bundleIdentifier = app.bundleIdentifier else { return }
        pinnedApps.unpin(bundleIdentifier)
    }

    @discardableResult
    func togglePin(_ app: DesktopApplication) -> Bool {
        guard let bundleIdentifier = app.bundleIdentifier else { return false }
        return pinnedApps.toggle(bundleIdentifier)
    }

    @discardableResult
    func pinApplication(at applicationURL: URL) -> Bool {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            return false
        }
        return pinnedApps.pin(bundleIdentifier)
    }

    func clearLastLaunchError() {
        lastLaunchError = nil
    }

    private func makeApplication(
        bundleIdentifier: String?,
        runningApplication: NSRunningApplication?,
        isPinned: Bool
    ) -> DesktopApplication {
        let installedURL = bundleIdentifier.flatMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        let applicationURL = runningApplication?.bundleURL ?? installedURL
        let name = runningApplication?.localizedName
            ?? applicationURL?.deletingPathExtension().lastPathComponent
            ?? bundleIdentifier
            ?? "Application"
        let icon = runningApplication?.icon
            ?? applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? Self.fallbackIcon

        return DesktopApplication(
            id: bundleIdentifier ?? "pid-\(runningApplication?.processIdentifier ?? 0)",
            bundleIdentifier: bundleIdentifier,
            name: name,
            icon: icon,
            application: runningApplication,
            applicationURL: applicationURL,
            isPinned: isPinned
        )
    }

    private func applicationSort(_ lhs: DesktopApplication, _ rhs: DesktopApplication) -> Bool {
        if lhs.application?.isActive != rhs.application?.isActive {
            return lhs.application?.isActive == true
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static let fallbackIcon: NSImage = {
        if let symbol = NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Application") {
            return symbol
        }
        return NSImage(size: NSSize(width: 32, height: 32))
    }()

}
