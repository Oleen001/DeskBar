import Foundation
import SwiftUI

enum DeskBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case allDisplays
    case mainDisplay
    case pointerDisplay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allDisplays: "All displays"
        case .mainDisplay: "Main display"
        case .pointerDisplay: "Pointer display"
        }
    }
}

enum DeskBarDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var spacing: CGFloat {
        switch self {
        case .compact: 8
        case .comfortable: 12
        case .spacious: 16
        }
    }

    var outerPadding: CGFloat {
        switch self {
        case .compact: 10
        case .comfortable: 14
        case .spacious: 18
        }
    }

    var cardHeight: CGFloat {
        switch self {
        case .compact: 140
        case .comfortable: 160
        case .spacious: 184
        }
    }
}

enum DeskBarAccent: String, CaseIterable, Identifiable, Sendable {
    case cyan
    case blue
    case indigo
    case purple
    case mint
    case neutral

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .mint: .mint
        case .neutral: .gray
        }
    }
}

enum DeskBarShortcutPreset: String, CaseIterable, Identifiable, Sendable {
    case controlOptionCommandD
    case commandShiftD
    case optionCommandD

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .controlOptionCommandD: "⌃⌥⌘D"
        case .commandShiftD: "⇧⌘D"
        case .optionCommandD: "⌥⌘D"
        }
    }

    var shortcut: GlobalHotKeyMonitor.Shortcut {
        switch self {
        case .controlOptionCommandD:
            .init(keyCode: GlobalHotKeyMonitor.Shortcut.deskBarDefault.keyCode,
                  modifiers: [.control, .option, .command])
        case .commandShiftD:
            .init(keyCode: GlobalHotKeyMonitor.Shortcut.deskBarDefault.keyCode,
                  modifiers: [.command, .shift])
        case .optionCommandD:
            .init(keyCode: GlobalHotKeyMonitor.Shortcut.deskBarDefault.keyCode,
                  modifiers: [.option, .command])
        }
    }
}

enum DeskBarRefreshRate: String, CaseIterable, Identifiable, Sendable {
    case efficient
    case balanced
    case live

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    var systemIntervalScale: Double {
        switch self {
        case .efficient: 2
        case .balanced: 1
        case .live: 0.5
        }
    }

    var aiRefreshInterval: TimeInterval {
        switch self {
        case .efficient: 30 * 60
        case .balanced: 15 * 60
        case .live: 5 * 60
        }
    }
}

@MainActor
final class DeskBarPreferences: ObservableObject {
    @Published var displayMode: DeskBarDisplayMode { didSet { persist(displayMode.rawValue, key: Keys.displayMode) } }
    @Published var density: DeskBarDensity { didSet { persist(density.rawValue, key: Keys.density) } }
    @Published var accent: DeskBarAccent { didSet { persist(accent.rawValue, key: Keys.accent) } }
    @Published var shortcutPreset: DeskBarShortcutPreset { didSet { persist(shortcutPreset.rawValue, key: Keys.shortcut) } }
    @Published var refreshRate: DeskBarRefreshRate { didSet { persist(refreshRate.rawValue, key: Keys.refreshRate) } }

    @Published var showLauncher: Bool { didSet { persist(showLauncher, key: Keys.showLauncher) } }
    @Published var showClock: Bool { didSet { persist(showClock, key: Keys.showClock) } }
    @Published var showSystemMonitor: Bool { didSet { persist(showSystemMonitor, key: Keys.showSystemMonitor) } }
    @Published var showAILimits: Bool { didSet { persist(showAILimits, key: Keys.showAILimits) } }
    @Published var showCPU: Bool { didSet { persist(showCPU, key: Keys.showCPU) } }
    @Published var showRAM: Bool { didSet { persist(showRAM, key: Keys.showRAM) } }
    @Published var showNetwork: Bool { didSet { persist(showNetwork, key: Keys.showNetwork) } }
    @Published var codexPlanLabel: String {
        didSet {
            let normalized = normalizedPlanLabel(codexPlanLabel)
            guard normalized == codexPlanLabel else { codexPlanLabel = normalized; return }
            persist(normalized, key: Keys.codexPlanLabel)
        }
    }
    @Published var claudePlanLabel: String {
        didSet {
            let normalized = normalizedPlanLabel(claudePlanLabel)
            guard normalized == claudePlanLabel else { claudePlanLabel = normalized; return }
            persist(normalized, key: Keys.claudePlanLabel)
        }
    }

    @Published var maximumApps: Int {
        didSet {
            let normalized = min(max(maximumApps, 3), 12)
            guard normalized == maximumApps else { maximumApps = normalized; return }
            persist(maximumApps, key: Keys.maximumApps)
        }
    }
    @Published var maximumPanelWidth: Double {
        didSet {
            let normalized = min(max(maximumPanelWidth, 760), 1_400)
            guard normalized == maximumPanelWidth else { maximumPanelWidth = normalized; return }
            persist(maximumPanelWidth, key: Keys.maximumPanelWidth)
        }
    }
    @Published var bottomInset: Double {
        didSet {
            let normalized = min(max(bottomInset, 8), 80)
            guard normalized == bottomInset else { bottomInset = normalized; return }
            persist(bottomInset, key: Keys.bottomInset)
        }
    }
    @Published var glassIntensity: Double {
        didSet {
            let normalized = min(max(glassIntensity, 0.5), 1.35)
            guard normalized == glassIntensity else { glassIntensity = normalized; return }
            persist(glassIntensity, key: Keys.glassIntensity)
        }
    }
    @Published var cpuAlertThreshold: Int {
        didSet {
            let normalized = min(max(cpuAlertThreshold, 50), 95)
            guard normalized == cpuAlertThreshold else { cpuAlertThreshold = normalized; return }
            persist(cpuAlertThreshold, key: Keys.cpuAlertThreshold)
        }
    }
    @Published var ramAlertThreshold: Int {
        didSet {
            let normalized = min(max(ramAlertThreshold, 70), 98)
            guard normalized == ramAlertThreshold else { ramAlertThreshold = normalized; return }
            persist(ramAlertThreshold, key: Keys.ramAlertThreshold)
        }
    }
    @Published var aiAlertThreshold: Int {
        didSet {
            let normalized = min(max(aiAlertThreshold, 50), 95)
            guard normalized == aiAlertThreshold else { aiAlertThreshold = normalized; return }
            persist(aiAlertThreshold, key: Keys.aiAlertThreshold)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayMode = Self.enumValue(defaults, key: Keys.displayMode) ?? .allDisplays
        density = Self.enumValue(defaults, key: Keys.density) ?? .comfortable
        accent = Self.enumValue(defaults, key: Keys.accent) ?? .cyan
        shortcutPreset = Self.enumValue(defaults, key: Keys.shortcut) ?? .controlOptionCommandD
        refreshRate = Self.enumValue(defaults, key: Keys.refreshRate) ?? .balanced
        showLauncher = Self.bool(defaults, key: Keys.showLauncher, fallback: true)
        showClock = Self.bool(defaults, key: Keys.showClock, fallback: true)
        showSystemMonitor = Self.bool(defaults, key: Keys.showSystemMonitor, fallback: true)
        showAILimits = Self.bool(defaults, key: Keys.showAILimits, fallback: true)
        showCPU = Self.bool(defaults, key: Keys.showCPU, fallback: true)
        showRAM = Self.bool(defaults, key: Keys.showRAM, fallback: true)
        showNetwork = Self.bool(defaults, key: Keys.showNetwork, fallback: true)
        codexPlanLabel = defaults.string(forKey: Keys.codexPlanLabel) ?? "Pro 5x"
        claudePlanLabel = defaults.string(forKey: Keys.claudePlanLabel) ?? "Pro"
        maximumApps = min(max(defaults.object(forKey: Keys.maximumApps) as? Int ?? 9, 3), 12)
        maximumPanelWidth = min(max(defaults.object(forKey: Keys.maximumPanelWidth) as? Double ?? 1_200, 760), 1_400)
        bottomInset = min(max(defaults.object(forKey: Keys.bottomInset) as? Double ?? 18, 8), 80)
        glassIntensity = min(max(defaults.object(forKey: Keys.glassIntensity) as? Double ?? 1, 0.5), 1.35)
        cpuAlertThreshold = min(max(defaults.object(forKey: Keys.cpuAlertThreshold) as? Int ?? 80, 50), 95)
        ramAlertThreshold = min(max(defaults.object(forKey: Keys.ramAlertThreshold) as? Int ?? 97, 70), 98)
        aiAlertThreshold = min(max(defaults.object(forKey: Keys.aiAlertThreshold) as? Int ?? 80, 50), 95)
    }

    var hasVisibleSystemMetric: Bool {
        showSystemMonitor && (showCPU || showRAM || showNetwork)
    }

    func planOverride(for providerName: String) -> String? {
        let value: String
        if providerName.localizedCaseInsensitiveContains("claude") {
            value = claudePlanLabel
        } else if providerName.localizedCaseInsensitiveContains("codex") || providerName.localizedCaseInsensitiveContains("openai") {
            value = codexPlanLabel
        } else {
            return nil
        }
        let normalized = normalizedPlanLabel(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedPlanLabel(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(28))
    }

    func panelHeight(isCompact: Bool) -> CGFloat {
        let dashboardCount = (hasVisibleSystemMetric ? 1 : 0) + (showAILimits ? 1 : 0)
        let baseline: CGFloat
        if dashboardCount == 0 {
            baseline = 92
        } else if isCompact && dashboardCount == 2 {
            baseline = 436
        } else {
            baseline = 276
        }

        switch density {
        case .compact: return max(84, baseline - 32)
        case .comfortable: return baseline
        case .spacious: return baseline + (dashboardCount == 2 && isCompact ? 56 : 32)
        }
    }

    func reset() {
        displayMode = .allDisplays
        density = .comfortable
        accent = .cyan
        shortcutPreset = .controlOptionCommandD
        refreshRate = .balanced
        showLauncher = true
        showClock = true
        showSystemMonitor = true
        showAILimits = true
        showCPU = true
        showRAM = true
        showNetwork = true
        codexPlanLabel = "Pro 5x"
        claudePlanLabel = "Pro"
        maximumApps = 9
        maximumPanelWidth = 1_200
        bottomInset = 18
        glassIntensity = 1
        cpuAlertThreshold = 80
        ramAlertThreshold = 97
        aiAlertThreshold = 80
    }

    private func persist(_ value: Any, key: String) {
        defaults.set(value, forKey: key)
    }

    private static func bool(_ defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private static func enumValue<T: RawRepresentable>(
        _ defaults: UserDefaults,
        key: String
    ) -> T? where T.RawValue == String {
        guard let rawValue = defaults.string(forKey: key) else { return nil }
        return T(rawValue: rawValue)
    }

    private enum Keys {
        static let displayMode = "DeskBar.preferences.displayMode"
        static let density = "DeskBar.preferences.density"
        static let accent = "DeskBar.preferences.accent"
        static let shortcut = "DeskBar.preferences.shortcut"
        static let refreshRate = "DeskBar.preferences.refreshRate"
        static let showLauncher = "DeskBar.preferences.showLauncher"
        static let showClock = "DeskBar.preferences.showClock"
        static let showSystemMonitor = "DeskBar.preferences.showSystemMonitor"
        static let showAILimits = "DeskBar.preferences.showAILimits"
        static let showCPU = "DeskBar.preferences.showCPU"
        static let showRAM = "DeskBar.preferences.showRAM"
        static let showNetwork = "DeskBar.preferences.showNetwork"
        static let codexPlanLabel = "DeskBar.preferences.codexPlanLabel"
        static let claudePlanLabel = "DeskBar.preferences.claudePlanLabel"
        static let maximumApps = "DeskBar.preferences.maximumApps"
        static let maximumPanelWidth = "DeskBar.preferences.maximumPanelWidth"
        static let bottomInset = "DeskBar.preferences.bottomInset"
        static let glassIntensity = "DeskBar.preferences.glassIntensity"
        static let cpuAlertThreshold = "DeskBar.preferences.cpuAlertThreshold"
        static let ramAlertThreshold = "DeskBar.preferences.ramAlertThreshold"
        static let aiAlertThreshold = "DeskBar.preferences.aiAlertThreshold"
    }
}
