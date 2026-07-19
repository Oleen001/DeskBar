import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DeskBarSettingsSection: String, CaseIterable, Identifiable {
    case layout
    case widgets
    case apps
    case ai
    case alerts
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .layout: "Layout"
        case .widgets: "Widgets"
        case .apps: "Apps"
        case .ai: "AI Connections"
        case .alerts: "Alerts"
        case .appearance: "Appearance"
        }
    }

    var icon: String {
        switch self {
        case .layout: "rectangle.3.group"
        case .widgets: "square.grid.2x2"
        case .apps: "app.dashed"
        case .ai: "sparkles"
        case .alerts: "bell.badge"
        case .appearance: "paintpalette"
        }
    }
}

@MainActor
final class DeskBarSettingsNavigation: ObservableObject {
    @Published var selection: DeskBarSettingsSection = .layout
}

struct DeskBarSettingsView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var applications: ApplicationsModel
    @ObservedObject var hotKey: GlobalHotKeyMonitor
    @ObservedObject var aiQuota: AIQuotaViewModel
    @ObservedObject var claudeBridge: ClaudeStatusLineBridgeInstaller
    @ObservedObject var alerts: SmartAlertCenter
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var preferences: DeskBarPreferences
    @ObservedObject var navigation: DeskBarSettingsNavigation

    @State private var providerName = ""
    @State private var windowLabel = ""
    @State private var used = ""
    @State private var limit = ""
    @State private var unit = AIQuotaUnit.messages
    @State private var hasResetDate = true
    @State private var resetDate = Date().addingTimeInterval(7 * 24 * 60 * 60)
    @State private var quotaError: String?

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(accent: preferences.accent.color)

            HStack(spacing: 0) {
                settingsSidebar
                Divider().opacity(0.45)
                settingsDetail
            }
        }
        .environment(\.deskBarGlassIntensity, preferences.glassIntensity)
        .frame(width: 780, height: 680)
        .onAppear {
            launchAtLogin.refresh()
            claudeBridge.refresh()
        }
        .alert("DeskBar Settings", isPresented: errorIsPresented) {
            Button("OK") {
                quotaError = nil
                launchAtLogin.clearError()
                claudeBridge.clearError()
            }
        } message: {
            Text(quotaError ?? launchAtLogin.lastError ?? claudeBridge.lastError ?? "Unknown error")
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("DeskBar", systemImage: "rectangle.bottomthird.inset.filled")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            ForEach(DeskBarSettingsSection.allCases) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { navigation.selection = section }
                } label: {
                    Label(section.title, systemImage: section.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(navigation.selection == section ? 0.12 : 0))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(navigation.selection == section ? .isSelected : [])
            }

            Spacer()
            Text("Changes apply instantly")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
        }
        .padding(14)
        .frame(width: 188)
    }

    private var settingsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(navigation.selection.title)
                        .font(.title2.weight(.bold))
                    Text(sectionSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                switch navigation.selection {
                case .layout: layoutSettings
                case .widgets: widgetSettings
                case .apps: appSettings
                case .ai: aiSettings
                case .alerts:
                    glassSection("Smart alerts", icon: "bell.badge", tint: .orange) {
                        smartAlertControls
                    }
                case .appearance: appearanceSettings
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var sectionSubtitle: String {
        switch navigation.selection {
        case .layout: "Choose where DeskBar lives and how much Desktop space it uses."
        case .widgets: "Show only the information you want during the day."
        case .apps: "Choose and arrange the apps in your launcher."
        case .ai: "Manage verified connections and optional estimated limits."
        case .alerts: "Control warnings without turning DeskBar into a distraction."
        case .appearance: "Tune the Liquid Glass surface to match your Desktop."
        }
    }

    private var layoutSettings: some View {
        VStack(spacing: 14) {
            glassSection("Desktop placement", icon: "display.2", tint: .cyan) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Show on", selection: $preferences.displayMode) {
                        ForEach(DeskBarDisplayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Density", selection: $preferences.density) {
                        ForEach(DeskBarDensity.allCases) { density in
                            Text(density.displayName).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)

                    valueSlider(
                        "Maximum width",
                        value: $preferences.maximumPanelWidth,
                        range: 760...1_400,
                        step: 20,
                        valueText: "\(Int(preferences.maximumPanelWidth)) pt"
                    )
                    valueSlider(
                        "Distance from bottom",
                        value: $preferences.bottomInset,
                        range: 8...80,
                        step: 2,
                        valueText: "\(Int(preferences.bottomInset)) pt"
                    )
                }
            }

            glassSection("Interaction", icon: "keyboard", tint: .blue) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Command shortcut", selection: $preferences.shortcutPreset) {
                        ForEach(DeskBarShortcutPreset.allCases) { shortcut in
                            Text(shortcut.displayName).tag(shortcut)
                        }
                    }
                    Picker("Refresh cadence", selection: $preferences.refreshRate) {
                        ForEach(DeskBarRefreshRate.allCases) { rate in
                            Text(rate.displayName).tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(refreshRateDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    LabeledContent("Shortcut status", value: hotKeyStatus)
                    Text("Press the shortcut to temporarily bring DeskBar above other apps. Hover and press animations stay at 120 ms or faster.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Divider().opacity(0.45)
                    launchAtLoginControls
                }
            }
        }
    }

    private var widgetSettings: some View {
        VStack(spacing: 14) {
            glassSection("Visible widgets", icon: "square.grid.2x2", tint: .mint) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("App launcher", isOn: $preferences.showLauncher)
                    if preferences.showLauncher {
                        Stepper(
                            "Maximum apps: \(preferences.maximumApps)",
                            value: $preferences.maximumApps,
                            in: 3...12
                        )
                        .padding(.leading, 22)
                    }
                    Toggle("Clock and date", isOn: $preferences.showClock)
                    Toggle("System monitor", isOn: $preferences.showSystemMonitor)
                    if preferences.showSystemMonitor {
                        HStack(spacing: 16) {
                            Toggle("CPU", isOn: $preferences.showCPU)
                            Toggle("RAM", isOn: $preferences.showRAM)
                            Toggle("NET", isOn: $preferences.showNetwork)
                        }
                        .padding(.leading, 22)
                    }
                    Toggle("AI limit bars", isOn: $preferences.showAILimits)
                    Text("The Settings gear remains available even when other widgets are hidden.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            glassSection("Live preview", icon: "waveform.path.ecg", tint: .blue) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145), spacing: 8)],
                    spacing: 8
                ) {
                    if preferences.showCPU { metricTile("CPU", monitor.cpuUsageText, icon: "cpu") }
                    if preferences.showRAM { metricTile("RAM", monitor.memoryActiveUsageText, icon: "memorychip") }
                    if preferences.showNetwork { metricTile("NET", monitor.networkRate, icon: "arrow.up.arrow.down") }
                    metricTile("Disk", monitor.diskCapacity, icon: "internaldrive")
                    metricTile("Battery", monitor.batteryStatus, icon: "battery.100")
                    metricTile("Thermal", monitor.thermalStatus, icon: "thermometer.medium")
                }
            }
        }
    }

    private var appSettings: some View {
        glassSection("Pinned apps", icon: "pin", tint: .indigo) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(applications.pinnedApps.bundleIdentifiers.count) pinned")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Application…", systemImage: "plus") { chooseApplication() }
                        .buttonStyle(.borderedProminent)
                }

                if applications.pinnedApps.bundleIdentifiers.isEmpty {
                    ContentUnavailableView(
                        "No pinned apps",
                        systemImage: "app.dashed",
                        description: Text("Add an application here or right-click a running app on DeskBar.")
                    )
                    .frame(minHeight: 180)
                } else {
                    ForEach(Array(applications.pinnedApps.bundleIdentifiers.enumerated()), id: \.element) { index, identifier in
                        pinnedApplicationRow(identifier: identifier, index: index)
                        if index < applications.pinnedApps.bundleIdentifiers.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
    }

    private var aiSettings: some View {
        glassSection("AI limits", icon: "chart.bar.xaxis", tint: .purple) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("OpenAI/Codex uses your local Codex sign-in. Gemini and Antigravity quota are hidden because their CLI panels do not provide a supported machine-readable export. Add a manual estimate below when you want a visible limit bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("Refresh") { Task { await aiQuota.refresh() } }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Plan badges")
                        .font(.callout.weight(.medium))
                    HStack(spacing: 8) {
                        TextField("Codex plan (auto if blank)", text: $preferences.codexPlanLabel)
                        TextField("Claude plan", text: $preferences.claudePlanLabel)
                    }
                    Text("These labels are display-only. Codex uses the signed-in plan when the local app-server reports it; a typed value overrides that label.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                quotaList
                Divider().opacity(0.45)
                claudeBridgeControls
                Divider().opacity(0.45)
                estimatedQuotaEditor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appearanceSettings: some View {
        VStack(spacing: 14) {
            glassSection("Liquid Glass", icon: "drop.halffull", tint: preferences.accent.color) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Accent")
                        .font(.callout.weight(.medium))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        ForEach(DeskBarAccent.allCases) { accent in
                            Button {
                                withAnimation(.easeOut(duration: 0.12)) { preferences.accent = accent }
                            } label: {
                                HStack(spacing: 7) {
                                    Circle().fill(accent.color).frame(width: 12, height: 12)
                                    Text(accent.displayName).font(.caption)
                                    Spacer(minLength: 0)
                                    if preferences.accent == accent {
                                        Image(systemName: "checkmark").font(.caption2.weight(.bold))
                                    }
                                }
                                .padding(8)
                                .background {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.white.opacity(preferences.accent == accent ? 0.12 : 0.04))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    valueSlider(
                        "Glass intensity",
                        value: $preferences.glassIntensity,
                        range: 0.5...1.35,
                        step: 0.05,
                        valueText: "\(Int(preferences.glassIntensity * 100))%"
                    )
                    Text("Reduce Transparency in macOS Accessibility settings still takes priority.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Restore Defaults", role: .destructive) { preferences.reset() }
            }
        }
    }

    private var claudeBridgeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code connection")
                        .font(.callout.weight(.medium))
                    Text(claudeBridgeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                switch claudeBridge.state {
                case .installed:
                    Button("Disconnect") {
                        claudeBridge.uninstall()
                        Task { await aiQuota.refresh() }
                    }
                case .notInstalled:
                    Button("Connect Claude") {
                        claudeBridge.install()
                        Task { await aiQuota.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                case .needsRecovery:
                    Button("Clean up") {
                        claudeBridge.uninstall()
                        Task { await aiQuota.refresh() }
                    }
                case .unavailable:
                    Button("Check again") { claudeBridge.refresh() }
                }
            }

            Text("DeskBar caches only Claude's documented 5-hour and 7-day percentages and reset times. Credentials, prompts, and account details stay with Claude Code.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var claudeBridgeStatus: String {
        switch claudeBridge.state {
        case .notInstalled:
            "Not connected"
        case .installed:
            "Connected · use Claude Code once to update the bars"
        case let .needsRecovery(message), let .unavailable(message):
            message
        }
    }

    private var smartAlertControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("System warnings", isOn: $alerts.systemAlertsEnabled)
            Text("CPU and RAM require three high samples. Network spikes and thermal pressure alert immediately.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if alerts.systemAlertsEnabled {
                percentageSlider(
                    "CPU warning",
                    value: $preferences.cpuAlertThreshold,
                    range: 50...95,
                    criticalOffset: 10
                )
                percentageSlider(
                    "RAM warning",
                    value: $preferences.ramAlertThreshold,
                    range: 70...98,
                    criticalOffset: 2
                )
            }

            Toggle("AI limit warnings", isOn: $alerts.aiAlertsEnabled)
            Text("Choose when verified, fresh AI usage should trigger a warning.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if alerts.aiAlertsEnabled {
                percentageSlider(
                    "AI usage warning",
                    value: $preferences.aiAlertThreshold,
                    range: 50...95,
                    criticalOffset: 10
                )
            }

            HStack {
                Toggle(
                    "macOS notifications",
                    isOn: Binding(
                        get: { alerts.notificationState == .enabled },
                        set: { enabled in
                            Task { await alerts.setNotificationsEnabled(enabled) }
                        }
                    )
                )
                Spacer()
                Text(alerts.notificationState.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if alerts.activeAlerts.isEmpty {
                Label("All clear", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Divider().opacity(0.45)
                ForEach(alerts.activeAlerts.prefix(4)) { alert in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: alert.severity == .critical ? "exclamationmark.triangle.fill" : "bell.badge.fill")
                            .foregroundStyle(alert.severity == .critical ? Color.red : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title).font(.caption.weight(.semibold))
                            Text(alert.message).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricTile(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.monospacedDigit().weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 13, style: .continuous),
            tint: .blue
        )
        .accessibilityElement(children: .combine)
    }

    private func glassSection<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 20, style: .continuous),
            tint: tint,
            depth: .raised
        )
    }

    @ViewBuilder
    private var launchAtLoginControls: some View {
        Toggle("Launch DeskBar at login", isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { enabled in Task { await launchAtLogin.setEnabled(enabled) } }
        ))
        .disabled(launchAtLogin.isUpdating || !launchAtLogin.state.canChangeRegistration)

        if case .requiresApproval = launchAtLogin.state {
            Button("Open Login Items Settings") {
                launchAtLogin.openLoginItemsSettings()
            }
        } else if case let .unavailable(message) = launchAtLogin.state {
            Text(message).font(.caption).foregroundStyle(.secondary)
        } else if case .notFound = launchAtLogin.state {
            VStack(alignment: .leading, spacing: 6) {
                Text("macOS could not register this local build automatically. You can still add DeskBar under Open at Login in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Login Items Settings") {
                    launchAtLogin.openLoginItemsSettings()
                }
            }
        }
    }

    @ViewBuilder
    private var quotaList: some View {
        if aiQuota.snapshots.isEmpty {
            ProgressView("Checking supported quota sources…")
        } else {
            ForEach(aiQuota.snapshots.filter { $0.confidence != .estimated }) { snapshot in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(snapshot.providerName).fontWeight(.medium)
                        Spacer()
                        Text(snapshot.confidence.rawValue.capitalized)
                            .foregroundStyle(.secondary)
                    }
                    AIQuotaBar(
                        fraction: snapshot.reading?.fractionUsed,
                        tint: quotaTint(snapshot)
                    )
                    Text(snapshot.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(quotaMetadata(snapshot))
                        .font(.caption2)
                        .foregroundStyle(snapshot.isStale ? Color.orange : Color.secondary)
                }
                .padding(10)
                .liquidGlass(
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                    tint: quotaTint(snapshot)
                )
            }
        }

        if let warning = aiQuota.estimatedStore.loadWarning {
            VStack(alignment: .leading, spacing: 6) {
                Text(warning).font(.caption).foregroundStyle(.orange)
                Button("Reset unreadable saved limits", role: .destructive) {
                    aiQuota.estimatedStore.discardUnreadableData()
                }
            }
        }

        ForEach(aiQuota.estimatedStore.configurations) { configuration in
            EstimatedQuotaRow(configuration: configuration, store: aiQuota.estimatedStore)
        }
    }

    private var estimatedQuotaEditor: some View {
        DisclosureGroup("Add estimated limit") {
            TextField("AI service", text: $providerName)
            TextField("Window, e.g. 5 hours or Weekly", text: $windowLabel)
            if providerName.localizedCaseInsensitiveContains("claude") {
                HStack {
                    Text("Claude windows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("5 hours") { windowLabel = "5 hours" }
                    Button("Weekly") { windowLabel = "Weekly" }
                }
                Text("Add Claude twice with the same service name—once for each limit window. DeskBar will group both bars in one card.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Used", text: $used)
                TextField("Limit", text: $limit)
            }
            Picker("Unit", selection: $unit) {
                ForEach(AIQuotaUnit.allCases) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            Toggle("Has reset date", isOn: $hasResetDate)
            if hasResetDate {
                DatePicker("Resets", selection: $resetDate)
            }
            Button("Add limit") { addEstimatedQuota() }
                .disabled(providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }

    private func percentageSlider(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        criticalOffset: Int
    ) -> some View {
        let doubleBinding = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Int($0.rounded()) }
        )
        let critical = min(100, value.wrappedValue + criticalOffset)

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)% · critical \(critical)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: doubleBinding,
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .accessibilityLabel(title)
            .accessibilityValue("\(value.wrappedValue) percent")
        }
        .padding(.leading, 22)
    }

    private func pinnedApplicationRow(identifier: String, index: Int) -> some View {
        let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        let name = applicationURL?.deletingPathExtension().lastPathComponent ?? identifier
        let icon = applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }

        return HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.fill").resizable().scaledToFit().padding(6)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(identifier).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()

            Button {
                applications.pinnedApps.move(
                    fromOffsets: IndexSet(integer: index),
                    toOffset: index - 1
                )
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .accessibilityLabel("Move \(name) earlier")

            Button {
                applications.pinnedApps.move(
                    fromOffsets: IndexSet(integer: index),
                    toOffset: index + 2
                )
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == applications.pinnedApps.bundleIdentifiers.count - 1)
            .accessibilityLabel("Move \(name) later")

            Button(role: .destructive) {
                applications.pinnedApps.unpin(identifier)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(name) from DeskBar")
        }
        .padding(.vertical, 3)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Add Application to DeskBar"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK, let applicationURL = panel.url else { return }
        if !applications.pinApplication(at: applicationURL) {
            quotaError = "DeskBar could not identify that application."
        }
    }

    private var hotKeyStatus: String {
        switch hotKey.state {
        case .inactive: "Inactive"
        case .registered: "Ready"
        case .registeredWithEventMonitor: "Ready with Accessibility permission"
        case let .permissionRequired(message): message
        case let .unavailable(message): message
        }
    }

    private var refreshRateDescription: String {
        switch preferences.refreshRate {
        case .efficient: "System graphs update less often; AI limits refresh every 30 minutes."
        case .balanced: "Balanced system sampling; AI limits refresh every 15 minutes."
        case .live: "System graphs update faster; AI limits refresh every 5 minutes."
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: {
                quotaError != nil || launchAtLogin.lastError != nil || claudeBridge.lastError != nil
            },
            set: {
                if !$0 {
                    quotaError = nil
                    launchAtLogin.clearError()
                    claudeBridge.clearError()
                }
            }
        )
    }

    private func addEstimatedQuota() {
        guard let usedValue = Double(used), let limitValue = Double(limit) else {
            quotaError = "Used and limit must be numbers."
            return
        }
        do {
            try aiQuota.estimatedStore.add(
                providerName: providerName,
                windowLabel: windowLabel,
                used: usedValue,
                limit: limitValue,
                unit: unit,
                resetDate: hasResetDate ? resetDate : nil
            )
            providerName = ""
            windowLabel = ""
            used = ""
            limit = ""
            hasResetDate = true
        } catch {
            quotaError = error.localizedDescription
        }
    }

    private func quotaMetadata(_ snapshot: AIQuotaSnapshot) -> String {
        var parts = [snapshot.source.label]
        if snapshot.isStale { parts.append("Stale") }
        parts.append("Fetched \(snapshot.timing.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
        if let resetsAt = snapshot.timing.resetsAt {
            parts.append("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func quotaTint(_ snapshot: AIQuotaSnapshot) -> Color {
        if snapshot.isStale { return .orange }
        guard let fraction = snapshot.reading?.fractionUsed else { return .gray }
        if fraction >= 0.9 { return .red }
        if fraction >= 0.75 { return .orange }
        return .green
    }
}

private struct EstimatedQuotaRow: View {
    let configuration: EstimatedQuotaConfiguration
    @ObservedObject var store: EstimatedQuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(configuration.providerName).fontWeight(.medium)
                    if let windowLabel = configuration.windowLabel {
                        Text(windowLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(configuration.used.formatted()) / \(configuration.limit.formatted()) \(configuration.unit.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int((fractionUsed * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(quotaTint)
                Stepper("Usage", value: usageBinding, in: 0...configuration.limit, step: usageStep)
                    .labelsHidden()
                    .accessibilityLabel("Adjust \(configuration.providerName) usage")
                Button(role: .destructive) {
                    try? store.delete(id: configuration.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(configuration.providerName) estimated limit")
            }

            AIQuotaBar(fraction: fractionUsed, tint: quotaTint)

            if let resetDate = configuration.resetDate {
                Text("Estimated · resets \(resetDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(resetDate <= .now ? .orange : .secondary)
            } else {
                Text("Estimated · user-entered")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            tint: quotaTint
        )
    }

    private var fractionUsed: Double {
        min(max(configuration.used / configuration.limit, 0), 1)
    }

    private var quotaTint: Color {
        if fractionUsed >= 0.9 { return .red }
        if fractionUsed >= 0.75 { return .orange }
        return .green
    }

    private var usageBinding: Binding<Double> {
        Binding(
            get: { configuration.used },
            set: { newValue in
                guard let updated = try? EstimatedQuotaConfiguration(
                    id: configuration.id,
                    providerName: configuration.providerName,
                    windowLabel: configuration.windowLabel,
                    used: newValue,
                    limit: configuration.limit,
                    unit: configuration.unit,
                    currencyCode: configuration.currencyCode,
                    resetDate: configuration.resetDate
                ) else { return }
                try? store.update(updated)
            }
        )
    }

    private var usageStep: Double {
        switch configuration.unit {
        case .requests, .messages: 1
        case .tokens: max(1, configuration.limit / 100)
        case .currency, .credits: max(0.01, configuration.limit / 100)
        }
    }
}

private extension AIQuotaUnit {
    var displayName: String {
        switch self {
        case .requests: "Requests"
        case .tokens: "Tokens"
        case .currency: "Currency"
        case .credits: "Credits"
        case .messages: "Messages"
        }
    }
}
