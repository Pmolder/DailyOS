import SwiftUI

// MARK: - 120Hz ProMotion Spring Presets

enum ProMotionSpring {
    static let glide = Animation.spring(response: 0.32, dampingFraction: 0.76)
    static let pop = Animation.spring(response: 0.28, dampingFraction: 0.62)
    static let checkPop = Animation.spring(response: 0.34, dampingFraction: 0.55)
    static let ringFill = Animation.spring(response: 0.75, dampingFraction: 0.78)
}

// MARK: - Tactile Specular Press Button Style

struct MidnightPressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .brightness(configuration.isPressed ? 0.08 : 0.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.70), value: configuration.isPressed)
    }
}

// MARK: - Visible Check-In Burst (28pt -> 62pt Glowing Ring + 8 Bright Sparks over 0.55s)

struct CheckInBurstEffect: View {
    let trigger: Int
    let color: Color
    var size: CGFloat = 66

    @State private var progress: CGFloat = 1.0
    @State private var isBursting: Bool = false

    private let sparkCount = 8

    var body: some View {
        ZStack {
            if isBursting {
                // Expanding translucent glowing accent ring (28pt -> 62pt)
                let ringDiameter = 28.0 + progress * 34.0
                Circle()
                    .stroke(color.opacity(Double(max(0, 1.0 - progress)) * 0.88), lineWidth: 3.0 * (1.0 - progress * 0.55))
                    .frame(width: ringDiameter, height: ringDiameter)
                    .shadow(color: color.opacity(Double(max(0, 1.0 - progress)) * 0.75), radius: 5)

                // 8 crisp bright accent sparks bursting outward
                Canvas { context, canvasSize in
                    let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    let radius = 12.0 + progress * 22.0
                    let alpha = Double(max(0, 1.0 - progress))
                    let dotSize = max(2.2, 5.4 * (1.0 - progress * 0.52))

                    for i in 0..<sparkCount {
                        let angle = (Double(i) / Double(sparkCount)) * 2.0 * Double.pi + 0.18
                        let x = center.x + CGFloat(cos(angle)) * radius
                        let y = center.y + CGFloat(sin(angle)) * radius
                        let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                    }
                }
                .frame(width: max(size, 68), height: max(size, 68))
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            isBursting = true
            progress = 0.0
            withAnimation(.easeOut(duration: 0.55)) {
                progress = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) {
                isBursting = false
            }
        }
    }
}

/// Backward-compatible alias so all existing callsites automatically use `CheckInBurstEffect`.
typealias CompletionBurstView = CheckInBurstEffect

// MARK: - Visible Checkbox Pop Bounce (0.65 -> 1.28 -> 1.0)

struct CheckPopBounceModifier: ViewModifier {
    let trigger: Int
    @State private var scale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: trigger) { _, _ in
                scale = 0.65
                withAnimation(.spring(response: 0.20, dampingFraction: 0.52)) {
                    scale = 1.28
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    withAnimation(ProMotionSpring.checkPop) {
                        scale = 1.0
                    }
                }
            }
    }
}

// MARK: - Clearly Visible 2.8s Breathing Ambient Glow Halo (Scale 1.0 <-> 1.08, Opacity 0.32 <-> 0.68)

struct OrganicBreathingAura: View {
    let color: Color
    var diameter: CGFloat = 210

    @State private var highPhase: Bool = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.55), color.opacity(0.18), color.opacity(0.0)],
                    center: .center,
                    startRadius: diameter * 0.06,
                    endRadius: diameter * 0.50
                )
            )
            .frame(width: diameter, height: diameter)
            .opacity(highPhase ? 0.68 : 0.32)
            .scaleEffect(highPhase ? 1.08 : 1.0)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                    highPhase = true
                }
            }
    }
}

// MARK: - Fast Staggered Waterfall Card Entrance

struct StaggeredEntranceModifier: ViewModifier {
    let index: Int
    @State private var appeared: Bool = false

    func body(content: Content) -> some View {
        let delay = Double(min(max(0, index), 6)) * 0.035
        content
            .opacity(appeared ? 1.0 : 0.0)
            .offset(y: appeared ? 0 : 12)
            .onAppear {
                guard !appeared else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.80).delay(delay)) {
                    appeared = true
                }
            }
    }
}

// MARK: - Visible Diagonal Glossy Light Shimmer Sweep (100% Milestone Celebration)

struct MidnightShimmerOverlay: ViewModifier {
    let trigger: Int
    let color: Color

    @State private var sweepOffset: CGFloat = -1.2
    @State private var isAnimating: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    if isAnimating {
                        LinearGradient(
                            colors: [
                                .clear,
                                color.opacity(0.35),
                                Color.white.opacity(0.45),
                                color.opacity(0.28),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.55, height: geo.size.height * 1.8)
                        .rotationEffect(.degrees(18))
                        .offset(x: sweepOffset * geo.size.width, y: -geo.size.height * 0.35)
                        .allowsHitTesting(false)
                    }
                }
                .clipped()
            )
            .onChange(of: trigger) { _, _ in
                isAnimating = true
                sweepOffset = -0.85
                withAnimation(.easeInOut(duration: 0.85)) {
                    sweepOffset = 1.45
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.90) {
                    isAnimating = false
                }
            }
    }
}

extension AnyTransition {
    static var dailyCardSpring: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .scale(scale: 0.94).combined(with: .opacity)
        )
    }
}

extension View {
    func staggeredEntrance(index: Int) -> some View {
        modifier(StaggeredEntranceModifier(index: index))
    }

    func midnightShimmer(trigger: Int, color: Color = DailyOSTheme.skyGlow) -> some View {
        modifier(MidnightShimmerOverlay(trigger: trigger, color: color))
    }

    func checkPopBounce(trigger: Int) -> some View {
        modifier(CheckPopBounceModifier(trigger: trigger))
    }
}
