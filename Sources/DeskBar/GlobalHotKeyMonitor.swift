import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

@MainActor
final class GlobalHotKeyMonitor: ObservableObject {
    struct Modifiers: OptionSet, Sendable {
        let rawValue: UInt32

        static let command = Self(rawValue: UInt32(cmdKey))
        static let option = Self(rawValue: UInt32(optionKey))
        static let control = Self(rawValue: UInt32(controlKey))
        static let shift = Self(rawValue: UInt32(shiftKey))
    }

    struct Shortcut: Equatable, Sendable {
        let keyCode: UInt32
        let modifiers: Modifiers

        init(keyCode: UInt32, modifiers: Modifiers) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        static let deskBarDefault = Shortcut(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: [.command, .option, .control]
        )
    }

    enum RegistrationState: Equatable {
        case inactive
        case registered
        case registeredWithEventMonitor
        case permissionRequired(String)
        case unavailable(String)

        var isAvailable: Bool {
            switch self {
            case .registered, .registeredWithEventMonitor:
                true
            case .inactive, .permissionRequired, .unavailable:
                false
            }
        }
    }

    @Published private(set) var state: RegistrationState = .inactive
    private(set) var shortcut: Shortcut?

    private let resources = CleanupResources()
    private var action: (() -> Void)?
    private var hotKeyIdentifier: EventHotKeyID?

    @discardableResult
    func register(
        shortcut: Shortcut = .deskBarDefault,
        action: @escaping () -> Void
    ) -> Bool {
        unregister()
        self.shortcut = shortcut
        self.action = action

        if registerCarbonHotKey(shortcut) {
            state = .registered
            return true
        }

        guard AXIsProcessTrusted() else {
            self.shortcut = nil
            self.action = nil
            state = .permissionRequired(
                "Allow DeskBar in System Settings > Privacy & Security > Accessibility to use the fallback shortcut monitor."
            )
            return false
        }

        if registerEventMonitorFallback(shortcut) {
            state = .registeredWithEventMonitor
            return true
        }

        self.shortcut = nil
        self.action = nil
        state = .unavailable(
            "The shortcut is already in use or macOS did not allow global keyboard monitoring."
        )
        return false
    }

    func unregister() {
        hotKeyIdentifier = nil
        resources.cleanup()
        shortcut = nil
        action = nil
        state = .inactive
    }

    private func registerCarbonHotKey(_ shortcut: Shortcut) -> Bool {
        let hotKeyIdentifier = EventHotKeyID(
            signature: Self.signature,
            id: UInt32.random(in: 1...UInt32.max)
        )
        self.hotKeyIdentifier = hotKeyIdentifier

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.carbonEventHandler,
            1,
            &eventType,
            userData,
            &resources.eventHandlerReference
        )
        guard installStatus == noErr else {
            resources.eventHandlerReference = nil
            self.hotKeyIdentifier = nil
            return false
        }

        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers.rawValue,
            hotKeyIdentifier,
            GetApplicationEventTarget(),
            0,
            &resources.hotKeyReference
        )
        guard registrationStatus == noErr else {
            if let eventHandlerReference = resources.eventHandlerReference {
                RemoveEventHandler(eventHandlerReference)
                resources.eventHandlerReference = nil
            }
            resources.hotKeyReference = nil
            self.hotKeyIdentifier = nil
            return false
        }

        return true
    }

    private func registerEventMonitorFallback(_ shortcut: Shortcut) -> Bool {
        resources.globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.matches(event, shortcut: shortcut) else { return }
            Task { @MainActor in
                self?.action?()
            }
        }

        resources.localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.matches(event, shortcut: shortcut) else { return event }
            self?.action?()
            return nil
        }

        if resources.globalEventMonitor == nil || resources.localEventMonitor == nil {
            resources.cleanup()
            return false
        }

        return true
    }

    private func handleCarbonHotKey(identifier: EventHotKeyID) {
        guard let hotKeyIdentifier,
              identifier.signature == hotKeyIdentifier.signature,
              identifier.id == hotKeyIdentifier.id else {
            return
        }
        action?()
    }

    private static func matches(_ event: NSEvent, shortcut: Shortcut) -> Bool {
        guard UInt32(event.keyCode) == shortcut.keyCode else { return false }

        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var expectedModifiers: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { expectedModifiers.insert(.command) }
        if shortcut.modifiers.contains(.option) { expectedModifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { expectedModifiers.insert(.control) }
        if shortcut.modifiers.contains(.shift) { expectedModifiers.insert(.shift) }
        return relevantModifiers == expectedModifiers
    }

    nonisolated private static let carbonEventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr else { return status }

        let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            monitor.handleCarbonHotKey(identifier: identifier)
        }
        return noErr
    }

    nonisolated private static let signature: OSType = 0x44534B42 // DSKB

    private final class CleanupResources {
        var hotKeyReference: EventHotKeyRef?
        var eventHandlerReference: EventHandlerRef?
        var globalEventMonitor: Any?
        var localEventMonitor: Any?

        func cleanup() {
            if let hotKeyReference {
                UnregisterEventHotKey(hotKeyReference)
                self.hotKeyReference = nil
            }
            if let eventHandlerReference {
                RemoveEventHandler(eventHandlerReference)
                self.eventHandlerReference = nil
            }
            if let globalEventMonitor {
                NSEvent.removeMonitor(globalEventMonitor)
                self.globalEventMonitor = nil
            }
            if let localEventMonitor {
                NSEvent.removeMonitor(localEventMonitor)
                self.localEventMonitor = nil
            }
        }

        deinit {
            cleanup()
        }
    }
}
