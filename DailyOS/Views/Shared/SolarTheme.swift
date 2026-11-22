import SwiftUI

/// Cohesive Obsidian & Solar-Orange visual design system for DailyOS v3.3.
enum SolarTheme {
    static let obsidian = Color(red: 0.031, green: 0.031, blue: 0.039)       // #08080A
    static let charcoal = Color(red: 0.075, green: 0.075, blue: 0.090)       // #131317
    static let elevated = Color(red: 0.110, green: 0.110, blue: 0.132)       // #1C1C22
    static let hairline = Color.white.opacity(0.08)

    static let solarDeep = Color(red: 1.000, green: 0.333, blue: 0.000)      // #FF5500
    static let solarCore = Color(red: 1.000, green: 0.420, blue: 0.000)      // #FF6B00
    static let solarMid = Color(red: 1.000, green: 0.478, blue: 0.000)       // #FF7A00
    static let solarBright = Color(red: 1.000, green: 0.533, blue: 0.000)    // #FF8800
    static let solarGold = Color(red: 1.000, green: 0.635, blue: 0.000)      // #FFA200

    static let sunriseGradient = LinearGradient(
        colors: [solarDeep, solarMid, solarGold],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let obsidianGradient = LinearGradient(
        colors: [obsidian, charcoal],
        startPoint: .top,
        endPoint: .bottom
    )
}

struct SolarCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(SolarTheme.charcoal, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(SolarTheme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func solarCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(SolarCardModifier(cornerRadius: cornerRadius))
    }
}
