import AppKit
import Combine
import Darwin
import SwiftUI

@main
struct DeskBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("DeskBar", systemImage: "rectangle.bottomthird.inset.filled") {
            Button("Toggle command bar") {
                appDelegate.panelController.toggleCommandMode()
            }

            Button("Return to desktop") {
                appDelegate.panelController.showOnDesktop()
            }

            Button("Refresh now") {
                appDelegate.monitor.refresh()
                appDelegate.applications.refresh()
                Task { await appDelegate.aiQuota.refresh() }
            }

            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }

            Divider()

            Button("Quit DeskBar", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        }

        Settings {
            DeskBarSettingsView(
                monitor: appDelegate.monitor,
                applications: appDelegate.applications,
                hotKey: appDelegate.hotKey,
                aiQuota: appDelegate.aiQuota,
                claudeBridge: appDelegate.claudeBridge,
                alerts: appDelegate.alerts,
                launchAtLogin: appDelegate.launchAtLogin,
                preferences: appDelegate.preferences,
                navigation: appDelegate.settingsNavigation
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = SystemMonitor()
    let applications = ApplicationsModel()
    let hotKey = GlobalHotKeyMonitor()
    let aiQuota = AIQuotaViewModel()
    let claudeBridge = ClaudeStatusLineBridgeInstaller()
    let launchAtLogin = LaunchAtLoginController()
    let preferences = DeskBarPreferences()
    let settingsNavigation = DeskBarSettingsNavigation()
    lazy var alerts = SmartAlertCenter(
        monitor: monitor,
        aiQuota: aiQuota,
        preferences: preferences
    )
    lazy var panelController = DesktopPanelController(
        monitor: monitor,
        applications: applications,
        aiQuota: aiQuota,
        alerts: alerts,
        preferences: preferences,
        settingsNavigation: settingsNavigation
    )
    private var shortcutObserver: AnyCancellable?
    private var refreshRateObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var applicationActivationObserver: NSObjectProtocol?
    private var appWindowObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var suspensionReasons: Set<SuspensionReason> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        runMaintenanceCommandIfRequested()
        NSApplication.shared.setActivationPolicy(.accessory)
        panelController.showOnAllDisplays()
        applyRefreshRate()
        monitor.start(mode: .idle)
        applications.start()
        aiQuota.start()
        alerts.start()
        registerHotKey()
        shortcutObserver = preferences.$shortcutPreset
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.registerHotKey() }
        refreshRateObserver = preferences.$refreshRate
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyRefreshRate() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panelController.showOnAllDisplays()
            }
        }
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.panelController.applicationActivationDidChange()
            }
        }
        appWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panelController.showOnDesktop()
            }
        }
        installLifecycleObservers()
    }

    private func registerHotKey() {
        hotKey.register(shortcut: preferences.shortcutPreset.shortcut) { [weak self] in
            self?.panelController.toggleCommandMode()
        }
    }

    private func applyRefreshRate() {
        monitor.setPollingIntervalScale(preferences.refreshRate.systemIntervalScale)
        aiQuota.setRefreshInterval(preferences.refreshRate.aiRefreshInterval)
    }

    private func runMaintenanceCommandIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--install-claude-bridge") {
            claudeBridge.install()
            guard case .installed = claudeBridge.state else { Darwin.exit(EXIT_FAILURE) }
            Darwin.exit(EXIT_SUCCESS)
        }
        if arguments.contains("--uninstall-claude-bridge") {
            claudeBridge.uninstall()
            guard case .notInstalled = claudeBridge.state else { Darwin.exit(EXIT_FAILURE) }
            Darwin.exit(EXIT_SUCCESS)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        applications.stop()
        aiQuota.stop()
        alerts.stop()
        hotKey.unregister()
        panelController.shutdown()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let applicationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver)
        }
        if let appWindowObserver {
            NotificationCenter.default.removeObserver(appWindowObserver)
        }
        lifecycleObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        lifecycleObservers.removeAll()
    }

    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers = [
            center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(for: .session) }
            },
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(from: .session) }
            },
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(for: .screens) }
            },
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(from: .screens) }
            }
        ]
    }

    private func suspend(for reason: SuspensionReason) {
        suspensionReasons.insert(reason)
        panelController.systemDidSuspend()
    }

    private func resume(from reason: SuspensionReason) {
        suspensionReasons.remove(reason)
        if suspensionReasons.isEmpty {
            panelController.systemDidResume()
        }
    }

    private enum SuspensionReason: Hashable {
        case session
        case screens
    }
}
