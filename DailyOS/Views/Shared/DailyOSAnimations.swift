import SwiftUI

// MARK: - 120Hz ProMotion Spring Presets

enum ProMotionSpring {
    static let glide = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let pop = Animation.spring(response: 0.26, dampingFraction: 0.68)
    static let ringFill = Animation.spring(response: 0.48, dampingFraction: 0.76)
}

// MARK: - Tactile Specular Press Button Style

struct MidnightPressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .brightness(configuration.isPressed ? 0.06 : 0.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

// MARK: - Habit / Task Check-In Shockwave + 8-Spark Celebration Burst (0.45s)

struct CompletionBurstView: View {
    let trigger: Int
    let color: Color
    var size: CGFloat = 58

    @State private var progress: CGFloat = 1.0
    @State private var isBursting: Bool = false

    private let sparkCount = 8

    var body: some View {
        ZStack {
            if isBursting {
                // Expanding translucent accent shockwave ring
                Circle()
                    .stroke(color.opacity(Double(max(0, 1.0 - progress)) * 0.78), lineWidth: 2.2 * (1.0 - progress * 0.5))
                    .frame(width: size * (0.42 + progress * 0.72), height: size * (0.42 + progress * 0.72))

                // 8 crisp glowing sparks bursting outward
                Canvas { context, canvasSize in
                    let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    let maxRadius = min(canvasSize.width, canvasSize.height) * 0.48
                    let radius = maxRadius * (0.28 + progress * 0.72)
                    let alpha = Double(max(0, 1.0 - progress))
                    let dotSize = max(1.5, 4.2 * (1.0 - progress * 0.65))

                    for i in 0..<sparkCount {
                        let angle = (Double(i) / Double(sparkCount)) * 2.0 * Double.pi + 0.2
                        let x = center.x + CGFloat(cos(angle)) * radius
                        let y = center.y + CGFloat(sin(angle)) * radius
                        let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            isBursting = true
            progress = 0.0
            withAnimation(.easeOut(duration: 0.45)) {
                progress = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
                isBursting = false
            }
        }
    }
}

// MARK: - Organic 3.2s Breathing Ambient Glow

struct OrganicBreathingAura: View {
    let color: Color
    var diameter: CGFloat = 210

    @State private var highPhase: Bool = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.45), color.opacity(0.0)],
                    center: .center,
                    startRadius: diameter * 0.08,
                    endRadius: diameter * 0.50
                )
            )
            .frame(width: diameter, height: diameter)
            .opacity(highPhase ? 0.62 : 0.35)
            .scaleEffect(highPhase ? 1.04 : 0.96)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                    highPhase = true
                }
            }
    }
}

// MARK: - Fast Staggered Waterfall Card Entrance (0.035s stagger capped at 6 cards)

struct StaggeredEntranceModifier: ViewModifier {
    let index: Int
    @State private var appeared: Bool = false

    func body(content: Content) -> some View {
        let delay = Double(min(max(0, index), 6)) * 0.035
        content
            .opacity(appeared ? 1.0 : 0.0)
            .offset(y: appeared ? 0 : 8)
            .onAppear {
                guard !appeared else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84).delay(delay)) {
                    appeared = true
                }
            }
    }
}

// MARK: - Midnight Obsidian Milestone Shimmer Sweep (100% Score / Routine / Stage-3)

struct MidnightShimmerSweepModifier: ViewModifier {
    let trigger: Int
    let color: Color

    @State private var sweepOffset: CGFloat = -1.4
    @State private var isAnimating: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    if isAnimating {
                        LinearGradient(
                            colors: [.clear, color.opacity(0.32), Color.white.opacity(0.28), color.opacity(0.18), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: sweepOffset * geo.size.width)
                        .allowsHitTesting(false)
                    }
                }
                .clipped()
            )
            .onChange(of: trigger) { _, _ in
                isAnimating = true
                sweepOffset = -0.8
                withAnimation(.easeInOut(duration: 0.85)) {
                    sweepOffset = 1.4
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    isAnimating = false
                }
            }
    }
}

extension View {
    func staggeredEntrance(index: Int) -> some View {
        modifier(StaggeredEntranceModifier(index: index))
    }

    func midnightShimmer(trigger: Int, color: Color = DailyOSTheme.skyGlow) -> some View {
        modifier(MidnightShimmerSweepModifier(trigger: trigger, color: color))
    }
}
