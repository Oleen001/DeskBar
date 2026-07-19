import AppKit
import SwiftUI

struct DeskBarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var applications: ApplicationsModel
    @ObservedObject var aiQuota: AIQuotaViewModel
    @ObservedObject var alerts: SmartAlertCenter
    @ObservedObject var preferences: DeskBarPreferences
    @ObservedObject var settingsNavigation: DeskBarSettingsNavigation
    @State private var isClockHovered = false
    @State private var isSettingsHovered = false
    let onApplicationActivated: () -> Void

    private var quotaGroups: [AIQuotaDisplayGroup] {
        AIQuotaDisplayGroup.grouping(aiQuota.snapshots)
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 1080
            let contentHeight = max(1, proxy.size.height - WhiteDogView.stripHeight)

            ZStack(alignment: .top) {
                VStack(spacing: preferences.density.spacing) {
                    launcherRow(
                        maximumApps: min(preferences.maximumApps, isCompact ? 5 : 12),
                        showsTitle: !isCompact
                    )

                    if preferences.hasVisibleSystemMetric || preferences.showAILimits {
                        if isCompact {
                            VStack(spacing: preferences.density.spacing) {
                                if preferences.hasVisibleSystemMetric { metricDashboard }
                                if preferences.showAILimits { quotaDashboard }
                            }
                        } else {
                            HStack(alignment: .top, spacing: preferences.density.spacing) {
                                if preferences.hasVisibleSystemMetric {
                                    metricDashboard
                                        .frame(maxWidth: 540)
                                }
                                if preferences.showAILimits { quotaDashboard }
                            }
                        }
                    }
                }
                .padding(preferences.density.outerPadding)
                .frame(
                    width: proxy.size.width,
                    height: contentHeight,
                    alignment: .top
                )
                .liquidGlass(
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                    tint: preferences.accent.color
                )
                .offset(y: WhiteDogView.stripHeight)

                WhiteDogView()
                    .frame(height: WhiteDogView.stripHeight, alignment: .top)
                    .padding(.horizontal, 18)
                    .zIndex(2)
            }
        }
        .environment(\.deskBarGlassIntensity, preferences.glassIntensity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("DeskBar desktop companion")
    }

    private func launcherRow(maximumApps: Int, showsTitle: Bool) -> some View {
        HStack(spacing: 10) {
            if showsTitle || !preferences.showLauncher {
                Label("DeskBar", systemImage: "sparkles.rectangle.stack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Divider()
                    .frame(height: 30)
                    .opacity(0.45)
            }

            if preferences.showLauncher {
                HStack(spacing: 6) {
                    ForEach(applications.apps.prefix(maximumApps)) { app in
                        LauncherAppButton(
                            app: app,
                            activate: {
                                applications.activate(app)
                                onApplicationActivated()
                            },
                            togglePin: { applications.togglePin(app) }
                        )
                    }
                }
            }

            Spacer(minLength: 12)
            if !alerts.activeAlerts.isEmpty {
                AlertSummaryButton(
                    alerts: alerts.activeAlerts,
                    showsTitle: showsTitle,
                    onSettingsOpened: { presentSettings(.alerts) }
                )
            }
            if preferences.showClock { clock }
            settingsButton
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private var metricDashboard: some View {
        HStack(spacing: 10) {
            if preferences.showCPU {
                MetricGraphCard(
                    title: "CPU", value: monitor.cpuUsageText, icon: "cpu",
                    history: monitor.cpuHistory, fixedRange: 0...100, tint: .cyan,
                    minimumHeight: preferences.density.cardHeight
                )
            }
            if preferences.showRAM {
                MetricGraphCard(
                    title: "RAM", value: monitor.memoryActiveUsageText, icon: "memorychip",
                    history: monitor.memoryActiveHistory, fixedRange: 0...100, tint: .blue,
                    primaryLegend: "Active + wired",
                    minimumHeight: preferences.density.cardHeight
                )
            }
            if preferences.showNetwork {
                MetricGraphCard(
                    title: "NET", value: monitor.networkRate, icon: "arrow.up.arrow.down",
                    history: monitor.networkHistory, fixedRange: nil, tint: .mint,
                    minimumHeight: preferences.density.cardHeight
                )
            }
        }
    }

    @ViewBuilder
    private var quotaDashboard: some View {
        if quotaGroups.isEmpty {
            HStack {
                Spacer()
                ProgressView("Checking AI limits…")
                    .controlSize(.small)
                Spacer()
            }
            .frame(minHeight: preferences.density.cardHeight)
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                tint: .purple
            )
        } else {
            HStack(spacing: 10) {
                ForEach(Array(quotaGroups.prefix(3))) { group in
                    AIQuotaGroupCard(
                        group: group,
                        planOverride: preferences.planOverride(for: group.providerName),
                        minimumHeight: preferences.density.cardHeight,
                        onSettingsOpened: { presentSettings(.ai) }
                    )
                }
            }
        }
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .trailing, spacing: 1) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(Color.primary.opacity(isClockHovered ? 1 : 0.88))
            .brightness(isClockHovered ? 0.10 : 0)
            .shadow(color: .white.opacity(isClockHovered ? 0.14 : 0), radius: 6)
            .scaleEffect(isClockHovered ? 1.04 : 1)
            .offset(y: isClockHovered ? -1 : 0)
            .alwaysActiveHover { hovering in
                setHover(hovering, state: $isClockHovered)
            }
        }
        .accessibilityLabel("Current date and time")
    }

    private var settingsButton: some View {
        Button {
            presentSettings(.layout)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary.opacity(isSettingsHovered ? 1 : 0.72))
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(.white.opacity(isSettingsHovered ? 0.13 : 0.05))
                }
                .rotationEffect(.degrees(isSettingsHovered && !reduceMotion ? 18 : 0))
        }
        .buttonStyle(PressScaleButtonStyle())
        .alwaysActiveHover { hovering in
            setHover(hovering, state: $isSettingsHovered)
        }
        .help("Open DeskBar Settings")
        .accessibilityLabel("Open DeskBar Settings")
    }

    private func presentSettings(_ section: DeskBarSettingsSection) {
        settingsNavigation.selection = section
        onApplicationActivated()
        openSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func setHover(_ hovering: Bool, state: Binding<Bool>) {
        if reduceMotion {
            state.wrappedValue = hovering
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                state.wrappedValue = hovering
            }
        }
    }
}

private struct AlertSummaryButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let alerts: [DeskBarSmartAlert]
    let showsTitle: Bool
    let onSettingsOpened: () -> Void

    private var leadingAlert: DeskBarSmartAlert? { alerts.first }

    var body: some View {
        Button {
            onSettingsOpened()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: leadingAlert?.severity == .critical ? "exclamationmark.triangle.fill" : "bell.badge.fill")
                Text("\(alerts.count)")
                    .monospacedDigit()
                if showsTitle, let leadingAlert {
                    Text(leadingAlert.title)
                        .lineLimit(1)
                        .frame(maxWidth: 150)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary.opacity(isHovered ? 1 : 0.78))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                Capsule(style: .continuous)
                    .fill(.white.opacity(isHovered ? 0.11 : 0.05))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(isHovered ? 0.24 : 0.10), lineWidth: 0.75)
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        .scaleEffect(isHovered ? 1.025 : 1)
        .alwaysActiveHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
        }
        .help(leadingAlert.map { "\($0.title): \($0.message)" } ?? "Smart alerts")
        .accessibilityLabel("\(alerts.count) active smart alerts")
    }
}

private struct LauncherAppButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let app: DesktopApplication
    let activate: () -> Void
    let togglePin: () -> Void

    var body: some View {
        Button(action: activate) {
            VStack(spacing: 3) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(isHovered ? 0.30 : 0.14), radius: isHovered ? 8 : 3, y: 3)
                Circle()
                    .fill(app.isRunning ? Color.primary : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .padding(5)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(isHovered ? 0.10 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(isHovered ? 0.22 : 0), lineWidth: 0.75)
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        .scaleEffect(isHovered ? 1.10 : 1)
        .offset(y: isHovered ? -3 : 0)
        .alwaysActiveHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
        }
        .help(app.name)
        .accessibilityLabel("Open \(app.name)")
        .contextMenu {
            Button(app.isPinned ? "Remove from DeskBar" : "Keep in DeskBar", action: togglePin)
        }
    }
}

private struct MetricGraphCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let title: String
    let value: String
    let icon: String
    let history: [Double]
    let fixedRange: ClosedRange<Double>?
    let tint: Color
    let secondaryValue: String?
    let secondaryHistory: [Double]
    let primaryLegend: String?
    let secondaryLegend: String?
    let secondaryTint: Color
    let minimumHeight: CGFloat

    init(
        title: String,
        value: String,
        icon: String,
        history: [Double],
        fixedRange: ClosedRange<Double>?,
        tint: Color,
        secondaryValue: String? = nil,
        secondaryHistory: [Double] = [],
        primaryLegend: String? = nil,
        secondaryLegend: String? = nil,
        secondaryTint: Color = .white,
        minimumHeight: CGFloat
    ) {
        self.title = title
        self.value = value
        self.icon = icon
        self.history = history
        self.fixedRange = fixedRange
        self.tint = tint
        self.secondaryValue = secondaryValue
        self.secondaryHistory = secondaryHistory
        self.primaryLegend = primaryLegend
        self.secondaryLegend = secondaryLegend
        self.secondaryTint = secondaryTint
        self.minimumHeight = minimumHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                HStack(spacing: 4) {
                    Text(value)
                        .font(.callout.monospacedDigit().weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .contentTransition(.numericText())
                    if let secondaryValue {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(secondaryValue)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(secondaryTint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .contentTransition(.numericText())
                    }
                }
            }

            MetricSparkline(
                values: history,
                fixedRange: fixedRange,
                tint: tint,
                secondaryValues: secondaryHistory,
                secondaryTint: secondaryTint,
                showsEndpoint: isHovered
            )
            .frame(height: 72)

            HStack(spacing: 6) {
                Text(history.count < 2 ? "Collecting history…" : "Recent activity")
                    .opacity(isHovered ? 0 : 1)
                    .overlay(alignment: .leading) {
                        Text("\(history.count) samples")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary.opacity(0.82))
                            .opacity(isHovered ? 1 : 0)
                    }
                if let primaryLegend {
                    Spacer(minLength: 4)
                    legendDot(tint)
                    Text(primaryLegend)
                    if let secondaryLegend {
                        legendDot(secondaryTint)
                        Text(secondaryLegend)
                    }
                }
            }
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: minimumHeight)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 20, style: .continuous),
            tint: tint,
            depth: isHovered ? .raised : .flat,
            highlighted: isHovered
        )
        .scaleEffect(isHovered ? 1.025 : 1)
        .offset(y: isHovered ? -2 : 0)
        .alwaysActiveHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var description = "\(title), \(primaryLegend ?? "Current") \(value)"
        if let secondaryValue {
            description += ", \(secondaryLegend ?? "Secondary") \(secondaryValue)"
        }
        return description + ", recent history graph"
    }

    private func legendDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
    }
}

private struct MetricSparkline: View {
    let values: [Double]
    let fixedRange: ClosedRange<Double>?
    let tint: Color
    let secondaryValues: [Double]
    let secondaryTint: Color
    let showsEndpoint: Bool

    var body: some View {
        GeometryReader { proxy in
            let points = graphPoints(in: proxy.size)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.10))

                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.36), tint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(
                        LinearGradient(
                            colors: [tint.opacity(0.72), tint, .white.opacity(0.86)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: tint.opacity(0.55), radius: 4)

                    let secondaryPoints = graphPoints(in: proxy.size, values: secondaryValues)
                    if secondaryPoints.count > 1 {
                        Path { path in
                            path.move(to: secondaryPoints[0])
                            secondaryPoints.dropFirst().forEach { path.addLine(to: $0) }
                        }
                        .stroke(
                            secondaryTint,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(color: secondaryTint.opacity(0.35), radius: 3)
                    }

                    if showsEndpoint, let last = points.last {
                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                            .shadow(color: tint, radius: 5)
                            .position(last)
                    }
                } else {
                    Capsule()
                        .fill(.white.opacity(0.12))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func graphPoints(in size: CGSize) -> [CGPoint] {
        graphPoints(in: size, values: values)
    }

    private func graphPoints(in size: CGSize, values: [Double]) -> [CGPoint] {
        guard values.count > 1, size.width > 0, size.height > 0 else { return [] }

        let displayValues = fixedRange == nil ? values.map { log10($0 + 1) } : values
        let lower = fixedRange?.lowerBound ?? 0
        let upper = fixedRange?.upperBound ?? max(displayValues.max() ?? 1, 1)
        let span = max(upper - lower, 0.000_1)
        let horizontalStep = size.width / CGFloat(displayValues.count - 1)

        return displayValues.enumerated().map { index, value in
            let fraction = min(max((value - lower) / span, 0), 1)
            return CGPoint(
                x: CGFloat(index) * horizontalStep,
                y: size.height - CGFloat(fraction) * size.height
            )
        }
    }
}

private struct AIQuotaGroupCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let group: AIQuotaDisplayGroup
    let planOverride: String?
    let minimumHeight: CGFloat
    let onSettingsOpened: () -> Void

    var body: some View {
        Button {
            onSettingsOpened()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(group.providerName)
                        .font(.callout.weight(.bold))
                        .lineLimit(1)
                    if let planName = planOverride ?? group.planName {
                        Text(planName)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(planTint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(planTint.opacity(0.14), in: Capsule())
                            .lineLimit(1)
                    }
                    if let resetCreditsAvailable = group.resetCreditsAvailable {
                        Text("\(resetCreditsAvailable) reset available")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.12), in: Capsule())
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isHovered ? "slider.horizontal.3" : "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(displaySnapshots.prefix(2).enumerated()), id: \.element.id) { index, snapshot in
                    quotaWindow(snapshot, index: index)
                }

                if displaySnapshots.count > 2 {
                    Text("+\(displaySnapshots.count - 2) more limits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                tint: groupTint,
                depth: isHovered ? .raised : .flat,
                highlighted: isHovered
            )
        }
        .buttonStyle(PressScaleButtonStyle())
        .scaleEffect(isHovered ? 1.025 : 1)
        .offset(y: isHovered ? -2 : 0)
        .alwaysActiveHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
        }
        .help("Open \(group.providerName) limit settings")
        .accessibilityLabel(accessibilityLabel)
    }

    private func quotaWindow(_ snapshot: AIQuotaSnapshot, index: Int) -> some View {
        let tint = quotaTint(snapshot)
        let percentage = snapshot.reading?.fractionUsed.map { Int(($0 * 100).rounded()) }

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(windowLabel(snapshot, index: index))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(percentage.map { "\($0)%" } ?? "N/A")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(percentage == nil ? Color.secondary : tint)
            }
            AIQuotaBar(fraction: snapshot.reading?.fractionUsed, tint: tint)
            Text(resetLabel(snapshot))
                .font(.caption2)
                .foregroundStyle(snapshot.isStale ? Color.orange : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func windowLabel(_ snapshot: AIQuotaSnapshot, index: Int) -> String {
        if let label = snapshot.windowLabel { return label }
        if displaySnapshots.count > 1 { return "Limit \(index + 1)" }
        return snapshot.confidence.rawValue.capitalized
    }

    private var displaySnapshots: [AIQuotaSnapshot] {
        let readable = group.snapshots.filter { $0.reading != nil }
        return readable.isEmpty ? group.snapshots : readable
    }

    private func resetLabel(_ snapshot: AIQuotaSnapshot) -> String {
        guard let resetsAt = snapshot.timing.resetsAt else {
            return snapshot.confidence == .unavailable ? "Reset unavailable" : "Reset date not set"
        }
        let formatted = resetsAt.formatted(
            .dateTime
                .weekday(.abbreviated)
                .day()
                .month(.abbreviated)
                .hour()
                .minute()
        )
        return "Resets \(formatted)"
    }

    private func quotaTint(_ snapshot: AIQuotaSnapshot) -> Color {
        if snapshot.isStale { return .orange }
        guard let fraction = snapshot.reading?.fractionUsed else { return .gray }
        if fraction >= 0.9 { return .red }
        if fraction >= 0.75 { return .orange }
        return .green
    }

    private var groupTint: Color {
        group.snapshots.first.map(quotaTint) ?? .purple
    }

    private var planTint: Color {
        if group.providerName.localizedCaseInsensitiveContains("claude") { return .orange }
        if group.providerName.localizedCaseInsensitiveContains("codex") || group.providerName.localizedCaseInsensitiveContains("openai") {
            return .blue
        }
        return .purple
    }

    private var accessibilityLabel: String {
        var providerDescription = group.providerName
        if let planName = planOverride ?? group.planName {
            providerDescription += ", plan \(planName)"
        }
        if let resetCreditsAvailable = group.resetCreditsAvailable {
            providerDescription += ", \(resetCreditsAvailable) reset available"
        }
        let limits = displaySnapshots.prefix(2).enumerated().map { index, snapshot in
            let usage = snapshot.reading?.fractionUsed
                .map { "\(Int(($0 * 100).rounded())) percent used" }
                ?? "usage unavailable"
            return "\(windowLabel(snapshot, index: index)), \(usage), \(resetLabel(snapshot))"
        }
        return ([providerDescription] + limits).joined(separator: ", ")
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
