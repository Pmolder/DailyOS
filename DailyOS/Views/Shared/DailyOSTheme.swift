import SwiftUI

/// Midnight Obsidian & Ambient Glow design system for DailyOS v3.4.
/// Applied across Habits, Alarms, Focus, and Settings (while active ringing wake alarms
/// preserve their high-luminance Solar-Orange max-brightness theme).
enum DailyOSTheme {
    // MARK: - Core Surfaces
    static let canvas = Color(hex: "#09090D")          // Primary deep matte midnight
    static let card = Color(hex: "#141419")            // Elevated smoked charcoal card
    static let inputSurface = Color(hex: "#1B1B22")    // Secondary / input surface
    static let buttonSurface = Color(hex: "#1D1D24")   // Frosted-dark circular button fill
    static let emptyCell = Color(hex: "#22222A")       // Unfilled heatmap cell
    static let eyebrow = Color(hex: "#7D7E8A")         // Uppercase tracked section eyebrow
    static let hairline = Color.white.opacity(0.075)
    static let buttonStroke = Color.white.opacity(0.09)

    // MARK: - Signature Accents
    static let skyGlow = Color(hex: "#60A5FA")
    static let emerald = Color(hex: "#34D399")
    static let iceBlue = Color(hex: "#7DD3FC")
    static let solarAccent = Color(hex: "#FF7A00")

    // MARK: - Curated 21-Color Swatch Palette (3 x 7 Grid)
    static let habitPaletteHex: [String] = [
        // Row 1: Coral -> Solar -> Amber -> Gold -> Lime -> Emerald -> Mint
        "#FF6B6B", "#FF8C42", "#FFB830", "#FACC15", "#A3E635", "#34D399", "#2DD4BF",
        // Row 2: Teal -> Cyan -> Sky -> Cobalt -> Periwinkle -> Lavender -> Violet
        "#14B8A6", "#22D3EE", "#38BDF8", "#60A5FA", "#818CF8", "#A78BFA", "#C084FC",
        // Row 3: Magenta -> Pink -> Rose -> 4 Sleek Slate / Stone Neutrals
        "#E879F9", "#F472B6", "#FB7185", "#94A3B8", "#9CA3AF", "#A1A1AA", "#A8A29E"
    ]
}

// MARK: - Color Hex Helpers

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: Double
        switch cleaned.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 0.376; g = 0.647; b = 0.980
        }
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Ambient Wash Card Modifier

struct AmbientCardModifier: ViewModifier {
    var accent: Color?
    var cornerRadius: CGFloat = 22
    var washOpacity: Double = 0.085

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DailyOSTheme.card)
                    if let accent {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [accent.opacity(washOpacity), accent.opacity(0.0)],
                                    center: .topLeading,
                                    startRadius: 10,
                                    endRadius: 260
                                )
                            )
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        accent.map { $0.opacity(0.18) } ?? DailyOSTheme.hairline,
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    func ambientCard(accent: Color? = nil, cornerRadius: CGFloat = 22, washOpacity: Double = 0.085) -> some View {
        modifier(AmbientCardModifier(accent: accent, cornerRadius: cornerRadius, washOpacity: washOpacity))
    }

    func eyebrowStyle() -> some View {
        self
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(DailyOSTheme.eyebrow)
    }
}

// MARK: - Circular Frosted-Dark Icon Button (36-40pt)

struct FrostedCircleButton: View {
    let icon: String
    var size: CGFloat = 38
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size * 0.40, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(DailyOSTheme.buttonSurface, in: Circle())
                .overlay(Circle().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Ambient Bloom Circular Progress Ring

struct AmbientBloomRing: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 14
    var diameter: CGFloat = 176

    private var clamped: Double {
        max(0.0, min(1.0, progress))
    }

    var body: some View {
        ZStack {
            // Subtle dark track
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
                .frame(width: diameter, height: diameter)

            // Duplicated blurred ambient bloom layer underneath
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
                .blur(radius: 10)
                .opacity(0.45)

            // Crisp foreground neon-glass ring
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
                .animation(.spring(response: 0.45, dampingFraction: 0.82), value: clamped)
        }
    }
}
