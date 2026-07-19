import Combine
import Foundation
@preconcurrency import UserNotifications

enum DeskBarAlertSeverity: Int, Comparable, Sendable {
    case notice = 0
    case warning = 1
    case critical = 2

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .notice: "Notice"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

enum DeskBarAlertCategory: String, Sendable {
    case system
    case ai
}

struct DeskBarSmartAlert: Identifiable, Equatable, Sendable {
    let id: String
    let category: DeskBarAlertCategory
    let severity: DeskBarAlertSeverity
    let title: String
    let message: String
}

struct SmartAlertCandidate: Equatable, Sendable {
    let alert: DeskBarSmartAlert
    let requiredSamples: Int
}

struct SmartAlertThresholds: Equatable, Sendable {
    var cpuWarning = 80
    var cpuCritical = 90
    var memoryWarning = 97
    var memoryCritical = 99
    var aiWarning = 80
    var aiCritical = 90
}

enum SmartAlertEvaluator {
    static func systemCandidates(
        cpuUsage: Int?,
        memoryUsage: Int?,
        networkBytesPerSecond: Double?,
        networkHistory: [Double],
        thermalState: SystemThermalMetric,
        thresholds: SmartAlertThresholds = .init()
    ) -> [SmartAlertCandidate] {
        var candidates: [SmartAlertCandidate] = []

        if let cpuUsage, cpuUsage >= thresholds.cpuWarning {
            let severity: DeskBarAlertSeverity = cpuUsage >= thresholds.cpuCritical ? .critical : .warning
            candidates.append(
                candidate(
                    id: "system.cpu",
                    severity: severity,
                    title: "CPU \(cpuUsage)%",
                    message: "CPU has stayed high across recent samples.",
                    requiredSamples: 3
                )
            )
        }

        if let memoryUsage, memoryUsage >= thresholds.memoryWarning {
            let severity: DeskBarAlertSeverity = memoryUsage >= thresholds.memoryCritical ? .critical : .warning
            candidates.append(
                candidate(
                    id: "system.memory",
                    severity: severity,
                    title: "RAM \(memoryUsage)%",
                    message: "Memory usage has stayed high across recent samples.",
                    requiredSamples: 3
                )
            )
        }

        if let networkBytesPerSecond,
           isNetworkSpike(networkBytesPerSecond, history: networkHistory) {
            candidates.append(
                candidate(
                    id: "system.network",
                    severity: .warning,
                    title: "Network spike",
                    message: "Traffic is much higher than its recent baseline.",
                    requiredSamples: 1
                )
            )
        }

        switch thermalState {
        case .serious:
            candidates.append(
                candidate(
                    id: "system.thermal",
                    severity: .warning,
                    title: "Mac is running hot",
                    message: "Thermal pressure is serious. Heavy tasks may slow down.",
                    requiredSamples: 1
                )
            )
        case .critical:
            candidates.append(
                candidate(
                    id: "system.thermal",
                    severity: .critical,
                    title: "Critical thermal pressure",
                    message: "Pause heavy tasks and let the Mac cool down.",
                    requiredSamples: 1
                )
            )
        case .nominal, .fair, .unknown:
            break
        }

        return candidates
    }

    static func aiAlerts(
        snapshots: [AIQuotaSnapshot],
        now: Date = .now,
        thresholds: SmartAlertThresholds = .init()
    ) -> [DeskBarSmartAlert] {
        snapshots.compactMap { snapshot in
            guard !snapshot.timing.isStale(at: now),
                  let fraction = snapshot.reading?.fractionUsed,
                  fraction >= Double(thresholds.aiWarning) / 100 else { return nil }

            let severity: DeskBarAlertSeverity = fraction >= Double(thresholds.aiCritical) / 100 ? .critical : .warning
            let remaining = max(0, Int(((1 - fraction) * 100).rounded()))
            let window = snapshot.windowLabel.map { " · \($0)" } ?? ""
            let reset = snapshot.timing.resetsAt.map {
                " Resets \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))."
            } ?? ""

            return DeskBarSmartAlert(
                id: "ai.\(snapshot.providerID.rawValue)",
                category: .ai,
                severity: severity,
                title: "\(snapshot.providerName)\(window) is nearly used",
                message: "\(remaining)% remaining.\(reset)"
            )
        }
        .sorted(by: alertSort)
    }

    private static func candidate(
        id: String,
        severity: DeskBarAlertSeverity,
        title: String,
        message: String,
        requiredSamples: Int
    ) -> SmartAlertCandidate {
        SmartAlertCandidate(
            alert: DeskBarSmartAlert(
                id: id,
                category: .system,
                severity: severity,
                title: title,
                message: message
            ),
            requiredSamples: requiredSamples
        )
    }

    private static func isNetworkSpike(_ current: Double, history: [Double]) -> Bool {
        guard current.isFinite,
              current >= 5 * 1_024 * 1_024,
              history.count >= 8 else { return false }

        let baselineValues = Array(history.dropLast()).filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !baselineValues.isEmpty else { return false }
        let middle = baselineValues.count / 2
        let median: Double
        if baselineValues.count.isMultiple(of: 2) {
            median = (baselineValues[middle - 1] + baselineValues[middle]) / 2
        } else {
            median = baselineValues[middle]
        }
        return current >= max(5 * 1_024 * 1_024, median * 4)
    }

    static func alertSort(_ lhs: DeskBarSmartAlert, _ rhs: DeskBarSmartAlert) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

enum SmartNotificationState: Equatable {
    case off
    case checking
    case enabled
    case denied

    var statusText: String {
        switch self {
        case .off: "Off"
        case .checking: "Checking…"
        case .enabled: "On"
        case .denied: "Blocked in System Settings"
        }
    }
}

@MainActor
final class SmartAlertCenter: ObservableObject {
    @Published private(set) var activeAlerts: [DeskBarSmartAlert] = []
    @Published private(set) var notificationState: SmartNotificationState = .checking
    @Published var systemAlertsEnabled: Bool {
        didSet {
            defaults.set(systemAlertsEnabled, forKey: Keys.systemAlertsEnabled)
            evaluateSystemAlerts()
        }
    }
    @Published var aiAlertsEnabled: Bool {
        didSet {
            defaults.set(aiAlertsEnabled, forKey: Keys.aiAlertsEnabled)
            evaluateAIAlerts()
        }
    }

    private let monitor: SystemMonitor
    private let aiQuota: AIQuotaViewModel
    private weak var preferences: DeskBarPreferences?
    private let defaults: UserDefaults
    private let notificationCenter = UNUserNotificationCenter.current()
    private var subscriptions: Set<AnyCancellable> = []
    private var preferencesSubscription: AnyCancellable?
    private var systemAlerts: [String: DeskBarSmartAlert] = [:]
    private var aiAlerts: [String: DeskBarSmartAlert] = [:]
    private var sustainedSampleCounts: [String: Int] = [:]
    private var lastDeliveredSeverities: [String: DeskBarAlertSeverity] = [:]
    private var notificationsEnabled: Bool

    init(
        monitor: SystemMonitor,
        aiQuota: AIQuotaViewModel,
        preferences: DeskBarPreferences? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.monitor = monitor
        self.aiQuota = aiQuota
        self.preferences = preferences
        self.defaults = defaults
        systemAlertsEnabled = defaults.object(forKey: Keys.systemAlertsEnabled) as? Bool ?? true
        aiAlertsEnabled = defaults.object(forKey: Keys.aiAlertsEnabled) as? Bool ?? true
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        let thresholdChanges = preferences.map {
            Publishers.Merge3(
                $0.$cpuAlertThreshold.dropFirst().map { _ in () },
                $0.$ramAlertThreshold.dropFirst().map { _ in () },
                $0.$aiAlertThreshold.dropFirst().map { _ in () }
            )
        }
        preferencesSubscription = thresholdChanges?.sink { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                self?.evaluateSystemAlerts(advancingSampleCounts: false)
                self?.evaluateAIAlerts()
            }
        }
    }

    func start() {
        guard subscriptions.isEmpty else { return }

        monitor.$sampleGeneration
            .dropFirst()
            .sink { [weak self] _ in self?.evaluateSystemAlerts() }
            .store(in: &subscriptions)

        aiQuota.$snapshots
            .sink { [weak self] _ in self?.evaluateAIAlerts() }
            .store(in: &subscriptions)

        evaluateSystemAlerts()
        evaluateAIAlerts()
        Task { await refreshNotificationState() }
    }

    func stop() {
        subscriptions.removeAll()
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        if !enabled {
            notificationsEnabled = false
            defaults.set(false, forKey: Keys.notificationsEnabled)
            notificationState = .off
            return
        }

        do {
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            notificationsEnabled = granted
            defaults.set(granted, forKey: Keys.notificationsEnabled)
            notificationState = granted ? .enabled : .denied
            if granted { deliverNotificationsIfNeeded() }
        } catch {
            notificationsEnabled = false
            defaults.set(false, forKey: Keys.notificationsEnabled)
            notificationState = .denied
        }
    }

    private func refreshNotificationState() async {
        guard notificationsEnabled else {
            notificationState = .off
            return
        }
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationState = .enabled
        case .denied:
            notificationState = .denied
        case .notDetermined:
            notificationState = .off
        @unknown default:
            notificationState = .off
        }
    }

    private func evaluateSystemAlerts(advancingSampleCounts: Bool = true) {
        guard systemAlertsEnabled else {
            for id in systemAlerts.keys {
                lastDeliveredSeverities.removeValue(forKey: id)
            }
            systemAlerts.removeAll()
            sustainedSampleCounts.removeAll()
            rebuildAlerts()
            return
        }

        let candidates = SmartAlertEvaluator.systemCandidates(
            cpuUsage: monitor.cpuUsage,
            // Keep alerts on the broader total-used signal, which still includes compressed
            // memory and catches pressure that the Active + wired visual intentionally omits.
            memoryUsage: monitor.memoryUsage,
            networkBytesPerSecond: monitor.networkBytesPerSecond,
            networkHistory: monitor.networkHistory,
            thermalState: monitor.thermalState,
            thresholds: alertThresholds
        )
        let candidateIDs = Set(candidates.map(\.alert.id))

        for id in Set(systemAlerts.keys).subtracting(candidateIDs) {
            systemAlerts.removeValue(forKey: id)
        }
        for id in Set(sustainedSampleCounts.keys).subtracting(candidateIDs) {
            sustainedSampleCounts.removeValue(forKey: id)
            lastDeliveredSeverities.removeValue(forKey: id)
        }

        for candidate in candidates {
            let currentCount = sustainedSampleCounts[candidate.alert.id, default: 0]
            let nextCount = currentCount + (advancingSampleCounts ? 1 : 0)
            sustainedSampleCounts[candidate.alert.id] = nextCount
            if nextCount >= candidate.requiredSamples {
                systemAlerts[candidate.alert.id] = candidate.alert
            }
        }
        rebuildAlerts()
    }

    private func evaluateAIAlerts() {
        guard aiAlertsEnabled else {
            for id in aiAlerts.keys {
                lastDeliveredSeverities.removeValue(forKey: id)
            }
            aiAlerts.removeAll()
            rebuildAlerts()
            return
        }
        let evaluated = SmartAlertEvaluator.aiAlerts(
            snapshots: aiQuota.snapshots,
            thresholds: alertThresholds
        )
        let evaluatedIDs = Set(evaluated.map(\.id))
        for id in Set(aiAlerts.keys).subtracting(evaluatedIDs) {
            lastDeliveredSeverities.removeValue(forKey: id)
        }
        aiAlerts = Dictionary(uniqueKeysWithValues: evaluated.map { ($0.id, $0) })
        rebuildAlerts()
    }

    private var alertThresholds: SmartAlertThresholds {
        guard let preferences else { return .init() }
        return SmartAlertThresholds(
            cpuWarning: preferences.cpuAlertThreshold,
            cpuCritical: min(100, preferences.cpuAlertThreshold + 10),
            memoryWarning: preferences.ramAlertThreshold,
            memoryCritical: min(100, preferences.ramAlertThreshold + 2),
            aiWarning: preferences.aiAlertThreshold,
            aiCritical: min(100, preferences.aiAlertThreshold + 10)
        )
    }

    private func rebuildAlerts() {
        activeAlerts = Array(systemAlerts.values) + Array(aiAlerts.values)
        activeAlerts.sort(by: SmartAlertEvaluator.alertSort)
        deliverNotificationsIfNeeded()
    }

    private func deliverNotificationsIfNeeded() {
        guard notificationsEnabled, notificationState == .enabled else { return }

        for alert in activeAlerts {
            if let delivered = lastDeliveredSeverities[alert.id], delivered >= alert.severity {
                continue
            }
            lastDeliveredSeverities[alert.id] = alert.severity

            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.message
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "deskbar.\(alert.id).\(alert.severity.rawValue)",
                content: content,
                trigger: nil
            )
            Task { try? await notificationCenter.add(request) }
        }
    }

    private enum Keys {
        static let systemAlertsEnabled = "DeskBar.smartAlerts.systemEnabled"
        static let aiAlertsEnabled = "DeskBar.smartAlerts.aiEnabled"
        static let notificationsEnabled = "DeskBar.smartAlerts.notificationsEnabled"
    }
}
