import SwiftUI

// MARK: - Selective Midnight Obsidian Motion & Tactile Button Style

/// Tactile press button style for primary pill CTAs, circular icon buttons, and quick chips.
struct MidnightPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .brightness(configuration.isPressed ? 0.06 : 0.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

extension AnyTransition {
    /// Clean subtle reveal transition for Day/Week switching, Today's Score collapse, and Active Focus banner.
    static var midnightReveal: AnyTransition {
        .opacity
            .combined(with: .scale(scale: 0.96))
            .combined(with: .offset(y: 6))
    }
}

/// Low-GPU 6-second smooth breathing radial aura reserved exclusively for
/// Today's Score Ring, Streak Flame, and Deep Work Timer Ring.
struct AmbientBreathingGlow: View {
    let color: Color
    var diameter: CGFloat = 220

    @State private var breathe: Bool = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(breathe ? 0.20 : 0.09), color.opacity(0.0)],
                    center: .center,
                    startRadius: diameter * 0.08,
                    endRadius: diameter * 0.52
                )
            )
            .frame(width: diameter, height: diameter)
            .scaleEffect(breathe ? 1.05 : 0.95)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 6.0).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}
