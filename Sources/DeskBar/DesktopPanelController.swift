import AppKit
import Combine
import SwiftUI

@MainActor
final class DesktopPanelController {
    private let monitor: SystemMonitor
    private let applications: ApplicationsModel
    private let aiQuota: AIQuotaViewModel
    private let alerts: SmartAlertCenter
    private let preferences: DeskBarPreferences
    private let settingsNavigation: DeskBarSettingsNavigation
    private var panels: [NSScreen: NSPanel] = [:]
    private var notchPanels: [NSScreen: NSPanel] = [:]
    private var notchHoverStates: [NSScreen: NotchHoverState] = [:]
    private var outsideClickMonitor: Any?
    private var desktopMouseMoveMonitor: Any?
    private var preferencesObserver: AnyCancellable?
    private var exposurePanelNumber = 0
    private var exposureCheckTimestamp = -Double.infinity
    private var cachedPanelExposure = false
    private(set) var isCommandMode = false

    init(
        monitor: SystemMonitor,
        applications: ApplicationsModel,
        aiQuota: AIQuotaViewModel,
        alerts: SmartAlertCenter,
        preferences: DeskBarPreferences,
        settingsNavigation: DeskBarSettingsNavigation
    ) {
        self.monitor = monitor
        self.applications = applications
        self.aiQuota = aiQuota
        self.alerts = alerts
        self.preferences = preferences
        self.settingsNavigation = settingsNavigation
        preferencesObserver = preferences.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                self?.showOnAllDisplays()
            }
        }
    }

    func showOnAllDisplays() {
        startDesktopHoverMonitoring()
        let screens = targetScreens()

        for (screen, panel) in panels where !screens.contains(screen) {
            panel.orderOut(nil)
            panel.close()
        }
        let notchScreens = screens.filter(supportsNotchOverlay(on:))
        for (screen, panel) in notchPanels where !notchScreens.contains(screen) {
            panel.orderOut(nil)
            panel.close()
        }

        for screen in screens {
            let panel = panel(for: screen)
            position(panel, on: screen)
            panel.orderFrontRegardless()
        }

        for screen in notchScreens {
            let notchPanel = notchPanel(for: screen)
            position(notchPanel, atNotchOn: screen)
            notchPanel.orderFrontRegardless()
        }

        panels = panels.filter { screens.contains($0.key) }
        notchPanels = notchPanels.filter { notchScreens.contains($0.key) }
        notchHoverStates = notchHoverStates.filter { notchScreens.contains($0.key) }
        if isCommandMode {
            promoteCommandPanel()
        }
    }

    func showOnDesktop() {
        isCommandMode = false
        stopOutsideClickMonitoring()
        demotePanelsToDesktop()
        monitor.setPollingMode(.idle)
    }

    func toggleCommandMode() {
        if isCommandMode {
            showOnDesktop()
        } else {
            showCommandMode()
        }
    }

    private func showCommandMode() {
        isCommandMode = true
        showOnAllDisplays()
    }

    private func promoteCommandPanel() {
        for panel in panels.values {
            panel.level = Self.desktopLevel
        }

        let panel =
            screenContainingPointer().flatMap { panels[$0] }
            ?? NSScreen.main.flatMap { panels[$0] }
            ?? panels.values.first
        guard let panel else {
            showOnDesktop()
            return
        }

        panel.level = .floating
        panel.orderFrontRegardless()
        monitor.setPollingMode(.active)
        startOutsideClickMonitoring()
    }

    private func panel(for screen: NSScreen) -> NSPanel {
        if let existing = panels[screen] { return existing }

        let panel = NSPanel(
            contentRect: .init(origin: .zero, size: Self.defaultPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = false
        panel.level = Self.desktopLevel
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.contentView = NSHostingView(
            rootView: DeskBarView(
                monitor: monitor,
                applications: applications,
                aiQuota: aiQuota,
                alerts: alerts,
                preferences: preferences,
                settingsNavigation: settingsNavigation,
                onApplicationActivated: { [weak self] in self?.showOnDesktop() }
            )
        )
        panels[screen] = panel
        return panel
    }

    private func notchPanel(for screen: NSScreen) -> NSPanel {
        if let existing = notchPanels[screen] { return existing }

        let panel = NSPanel(
            contentRect: .init(
                origin: .zero,
                size: NotchQuotaLayout.size(
                    screenFrame: screen.frame,
                    safeAreaTopInset: screen.safeAreaInsets.top
                )
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        // This ribbon intentionally extends the visual language of the hardware notch, but it
        // must never intercept the menu bar or camera-housing click region.
        panel.ignoresMouseEvents = true
        let hoverState = notchHoverState(for: screen)
        panel.contentView = NSHostingView(
            rootView: NotchStatusView(
                monitor: monitor,
                aiQuota: aiQuota,
                hoverState: hoverState,
                height: NotchQuotaLayout.size(
                    screenFrame: screen.frame,
                    safeAreaTopInset: screen.safeAreaInsets.top
                ).height
            )
        )
        notchPanels[screen] = panel
        return panel
    }

    private func notchHoverState(for screen: NSScreen) -> NotchHoverState {
        if let existing = notchHoverStates[screen] { return existing }
        let state = NotchHoverState()
        notchHoverStates[screen] = state
        return state
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let preferredSize = DesktopPanelLayout.dashboardSize(
            visibleFrame: screen.visibleFrame,
            maximumWidth: CGFloat(preferences.maximumPanelWidth),
            wideHeight: preferences.panelHeight(isCompact: false) + WhiteDogView.stripHeight,
            compactHeight: preferences.panelHeight(isCompact: true) + WhiteDogView.stripHeight
        )
        panel.setFrame(
            DesktopPanelLayout.frame(
                visibleFrame: screen.visibleFrame,
                preferredSize: preferredSize,
                bottomInset: CGFloat(preferences.bottomInset)
            ),
            display: true
        )
    }

    private func position(_ panel: NSPanel, atNotchOn screen: NSScreen) {
        panel.setFrame(
            NotchQuotaLayout.frame(
                screenFrame: screen.frame,
                safeAreaTopInset: screen.safeAreaInsets.top
            ),
            display: true
        )
    }

    private func supportsNotchOverlay(on screen: NSScreen) -> Bool {
        guard screen.safeAreaInsets.top > 0,
              screen.auxiliaryTopLeftArea != nil,
              screen.auxiliaryTopRightArea != nil else {
            return false
        }
        return true
    }


    private func screenContainingPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard
            let index = DesktopPanelLayout.screenIndex(
                containing: location,
                frames: screens.map(\.frame)
            )
        else { return nil }
        return screens[index]
    }

    private func targetScreens() -> [NSScreen] {
        switch preferences.displayMode {
        case .allDisplays:
            NSScreen.screens
        case .mainDisplay:
            NSScreen.main.map { [$0] } ?? Array(NSScreen.screens.prefix(1))
        case .pointerDisplay:
            screenContainingPointer().map { [$0] }
                ?? NSScreen.main.map { [$0] }
                ?? Array(NSScreen.screens.prefix(1))
        }
    }

    func applicationActivationDidChange() {
        if isCommandMode {
            showOnDesktop()
        } else {
            demotePanelsToDesktop()
            monitor.setPollingMode(.idle)
        }
    }

    func systemDidSuspend() {
        isCommandMode = false
        stopOutsideClickMonitoring()
        demotePanelsToDesktop()
        monitor.setPollingMode(.paused)
    }

    func systemDidResume() {
        monitor.setPollingMode(isCommandMode ? .active : .idle)
    }

    func shutdown() {
        stopOutsideClickMonitoring()
        stopDesktopHoverMonitoring()
        panels.values.forEach { $0.close() }
        notchPanels.values.forEach { $0.close() }
        panels.removeAll()
        notchPanels.removeAll()
        notchHoverStates.removeAll()
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.showOnDesktop() }
        }
    }

    private func stopOutsideClickMonitoring() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private func startDesktopHoverMonitoring() {
        guard desktopMouseMoveMonitor == nil else { return }
        desktopMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.forwardDesktopMouseMoved(
                    location: NSEvent.mouseLocation,
                    timestamp: event.timestamp,
                    modifierFlags: event.modifierFlags
                )
            }
        }
    }

    private func forwardDesktopMouseMoved(
        location: CGPoint,
        timestamp: TimeInterval,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        updateNotchHover(at: location)
        guard !isCommandMode else { return }

        promotePanelUnderPointerIfDesktopIsActive(at: location)

        if preferences.displayMode == .pointerDisplay,
            let pointerScreen = screenContainingPointer(),
            panels[pointerScreen] == nil
        {
            showOnAllDisplays()
            return
        }

        for panel in panels.values {
            let localLocation = panel.convertPoint(fromScreen: location)
            guard
                let event = NSEvent.mouseEvent(
                    with: .mouseMoved,
                    location: localLocation,
                    modifierFlags: modifierFlags,
                    timestamp: timestamp,
                    windowNumber: panel.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 0,
                    pressure: 0
                )
            else { continue }
            panel.sendEvent(event)
        }
    }

    /// The top ribbon is visual-only so macOS retains ownership of menu-bar and notch clicks.
    /// Its small hover response is driven from the existing global mouse observer instead.
    private func updateNotchHover(at location: CGPoint) {
        for (screen, state) in notchHoverStates {
            let hovered = notchPanels[screen]?.frame.contains(location) ?? false
            guard state.isHovered != hovered else { continue }
            state.isHovered = hovered
        }
    }

    /// Desktop-level windows remain below normal apps by design. When the user is actually
    /// on the desktop and moves over the strip, temporarily raise only that panel so SwiftUI
    /// controls can receive native hover and click events. It is immediately demoted when the
    /// pointer leaves, or while another app / DeskBar Settings is active.
    private func promotePanelUnderPointerIfDesktopIsActive(at location: CGPoint) {
        let targetPanel = panels.values.first { $0.frame.contains(location) }
        let canPromote =
            !NSApplication.shared.isActive
            && targetPanel.map { desktopSurfaceIsExposedIfNeeded(panel: $0) } == true

        for panel in panels.values {
            let shouldPromote = canPromote && panel === targetPanel
            let desiredLevel = shouldPromote ? NSWindow.Level.floating : Self.desktopLevel
            guard panel.level != desiredLevel else { continue }
            panel.level = desiredLevel
            panel.orderFrontRegardless()
        }
    }

    private func desktopSurfaceIsExposedIfNeeded(panel: NSPanel) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if exposurePanelNumber == panel.windowNumber,
            now - exposureCheckTimestamp < 0.25
        {
            return cachedPanelExposure
        }

        exposurePanelNumber = panel.windowNumber
        exposureCheckTimestamp = now
        cachedPanelExposure = desktopSurfaceIsExposed(panel: panel)
        return cachedPanelExposure
    }

    private func desktopSurfaceIsExposed(panel: NSPanel) -> Bool {
        guard let quartzPanelRect = quartzRect(for: panel.frame),
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return false
        }

        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let deskBarOwner =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "DeskBar"

        // Desktop/Finder background layers are safe. Any normal window intersecting any part of
        // the panel must keep it behind that app rather than allowing a partial overlay.
        for window in windows {
            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                bounds.intersects(quartzPanelRect),
                (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0
            else {
                continue
            }

            if (window[kCGWindowOwnerName as String] as? String) == deskBarOwner {
                continue
            }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer > desktopIconLevel { return false }
        }

        return true
    }

    private func quartzRect(for rect: CGRect) -> CGRect? {
        guard
            let screen = NSScreen.screens.first(where: {
                $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
            }),
            let displayNumber = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        let displayBounds = CGDisplayBounds(displayNumber.uint32Value)
        return CGRect(
            x: displayBounds.minX + rect.minX - screen.frame.minX,
            y: displayBounds.minY + screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func demotePanelsToDesktop() {
        exposurePanelNumber = 0
        exposureCheckTimestamp = -Double.infinity
        cachedPanelExposure = false
        for panel in panels.values {
            guard panel.level != Self.desktopLevel else { continue }
            panel.level = Self.desktopLevel
            panel.orderFrontRegardless()
        }
    }

    private func stopDesktopHoverMonitoring() {
        guard let desktopMouseMoveMonitor else { return }
        NSEvent.removeMonitor(desktopMouseMoveMonitor)
        self.desktopMouseMoveMonitor = nil
    }

    private static let desktopLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow))
    )
    private static let defaultPanelSize = CGSize(width: 1200, height: 276)
}
