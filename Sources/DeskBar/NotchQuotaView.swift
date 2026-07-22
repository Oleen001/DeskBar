import AppKit
import SwiftUI

/// A single, compact status ribbon that visually extends the hardware notch.
struct NotchStatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var aiQuota: AIQuotaViewModel
    @ObservedObject var hoverState: NotchHoverState
    let height: CGFloat

    private var summaries: [AIQuotaNotchSummary] {
        AIQuotaNotchSummary.summaries(from: aiQuota.snapshots)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                NotchMetricStatus(title: "CPU", value: monitor.cpuUsageText, tint: .cyan)
                Divider().frame(height: 18).opacity(0.28)
                NotchMetricStatus(title: "RAM", value: monitor.memoryActiveUsageText, tint: .blue)
            }

            Spacer(minLength: 118)

            HStack(spacing: 0) {
                ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                    if index > 0 {
                        Divider().frame(height: 18).opacity(0.28)
                    }
                    NotchQuotaStatus(summary: summary)
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(width: NotchQuotaLayout.width, height: height)
        .background(ribbonSurface)
        .shadow(
            color: .black.opacity(hoverState.isHovered ? 0.32 : 0.16),
            radius: hoverState.isHovered ? 9 : 4,
            y: 2
        )
        .scaleEffect(hoverState.isHovered ? 1.006 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoverState.isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CPU, active RAM, Claude, and Codex status at the display notch")
        .accessibilityHint("Brightens slightly when the pointer is over the status ribbon")
    }

    private var ribbonSurface: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 15,
            bottomTrailingRadius: 15,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(.black.opacity(hoverState.isHovered ? 0.91 : 0.97))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(hoverState.isHovered ? 0.20 : 0.08))
                .frame(height: 0.5)
        }
    }
}

@MainActor
final class NotchHoverState: ObservableObject {
    @Published var isHovered = false
}

private struct NotchMetricStatus: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(tint.opacity(0.92))
            Text(value)
                .font(.system(size: 8, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(minWidth: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct NotchQuotaStatus: View {
    let summary: AIQuotaNotchSummary

    var body: some View {
        VStack(spacing: 1) {
            NotchProviderMark(provider: summary.provider)
                .frame(width: 13, height: 13)
            Text(summary.remainingPercentage.map { "\($0)%" } ?? "—")
                .font(.system(size: 8, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(summary.remainingPercentage == nil ? Color.secondary : .white)
        }
        .frame(minWidth: 25)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let percentage = summary.remainingPercentage.map { "\($0) percent remaining" } ?? "limit unavailable"
        let window = summary.windowLabel.map { ", \($0) window" } ?? ""
        return "\(summary.provider.displayName), \(percentage)\(window)"
    }
}

private struct NotchProviderMark: View {
    let provider: AIQuotaNotchSummary.Provider

    @ViewBuilder
    var body: some View {
        switch provider {
        case .claude:
            Image(nsImage: NotchBrandAssets.claudeIcon)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .codex:
            Image(nsImage: NotchBrandAssets.codexIcon)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

private enum NotchBrandAssets {
    /// Uses current local official app artwork instead of bundling third-party marks in DeskBar.
    static var claudeIcon: NSImage {
        appIcon(bundleIdentifier: "com.anthropic.claudefordesktop", fallbackPath: "/Applications/Claude.app")
    }

    static var codexIcon: NSImage {
        let officialCodexAsset = "/Applications/ChatGPT.app/Contents/Resources/icon-codex-dark-color.png"
        if let image = NSImage(contentsOfFile: officialCodexAsset) {
            return image
        }
        return appIcon(bundleIdentifier: "com.openai.codex", fallbackPath: "/Applications/ChatGPT.app")
    }

    private static func appIcon(bundleIdentifier: String, fallbackPath: String) -> NSImage {
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.path
            ?? fallbackPath
        return NSWorkspace.shared.icon(forFile: path)
    }
}

enum NotchQuotaLayout {
    static let width: CGFloat = 300

    static func size(screenFrame: CGRect, safeAreaTopInset: CGFloat) -> CGSize {
        CGSize(
            width: min(width, screenFrame.width),
            height: min(max(safeAreaTopInset, 28), screenFrame.height)
        )
    }

    /// Pins the ribbon to the top edge and makes it exactly as tall as the display's notch safe
    /// inset. It is only created for displays reporting left and right auxiliary notch areas.
    static func frame(screenFrame: CGRect, safeAreaTopInset: CGFloat) -> CGRect {
        let size = size(screenFrame: screenFrame, safeAreaTopInset: safeAreaTopInset)
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
