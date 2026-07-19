import AppKit
import SwiftUI

private struct DeskBarGlassIntensityKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var deskBarGlassIntensity: Double {
        get { self[DeskBarGlassIntensityKey.self] }
        set { self[DeskBarGlassIntensityKey.self] = min(max(newValue, 0.5), 1.35) }
    }
}

enum LiquidGlassDepth {
    case flat
    case raised
}

private struct LiquidGlassSurface<Surface: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.deskBarGlassIntensity) private var glassIntensity

    let surface: Surface
    let tint: Color
    let depth: LiquidGlassDepth
    let highlighted: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    surface
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                } else {
                    surface.fill(.ultraThinMaterial)
                    surface.fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.16 * glassIntensity),
                                tint.opacity(0.15 * glassIntensity),
                                .clear,
                                .black.opacity(0.08 * glassIntensity)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    surface.fill(.white.opacity(highlighted ? 0.10 * glassIntensity : 0))
                }
            }
            .overlay {
                surface.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(reduceTransparency ? 0.20 : (highlighted ? 0.62 : 0.48) * glassIntensity),
                            .white.opacity((highlighted ? 0.18 : 0.10) * glassIntensity),
                            tint.opacity((highlighted ? 0.12 : 0.22) * glassIntensity),
                            .black.opacity(0.16 * glassIntensity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(
                color: depth == .raised ? .black.opacity(0.22 * glassIntensity) : .clear,
                radius: depth == .raised ? 14 * glassIntensity : 0,
                y: depth == .raised ? 7 : 0
            )
            .shadow(
                color: depth == .raised ? .white.opacity((highlighted ? 0.11 : 0.04) * glassIntensity) : .clear,
                radius: depth == .raised ? 16 * glassIntensity : 0,
                y: depth == .raised ? 3 : 0
            )
    }
}

extension View {
    func liquidGlass<Surface: InsettableShape>(
        in surface: Surface,
        tint: Color = .clear,
        depth: LiquidGlassDepth = .flat,
        highlighted: Bool = false
    ) -> some View {
        modifier(
            LiquidGlassSurface(
                surface: surface,
                tint: tint,
                depth: depth,
                highlighted: highlighted
            )
        )
    }
}

struct LiquidGlassBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var accent: Color = .cyan

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !reduceTransparency {
                LinearGradient(
                    colors: [
                        accent.opacity(0.10),
                        Color.indigo.opacity(0.08),
                        Color.purple.opacity(0.07),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .ignoresSafeArea()
    }
}

struct AIQuotaBar: View {
    let fraction: Double?
    let tint: Color

    private var clampedFraction: Double {
        min(max(fraction ?? 0, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.13))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    }

                if fraction != nil {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.72), tint, .white.opacity(0.82)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(5, proxy.size.width * clampedFraction))
                        .shadow(color: tint.opacity(0.52), radius: 4)
                } else {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            Color.secondary.opacity(0.42),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
