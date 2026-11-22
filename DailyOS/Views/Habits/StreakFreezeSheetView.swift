import SwiftUI

/// Modal Streak & Streak Freeze sheet matching the Midnight Obsidian & Ambient Glow reference.
struct StreakFreezeSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let summary: GlobalStreakSummary

    private let mondayFirstLetters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 28) {
                HStack {
                    Spacer()
                    FrostedCircleButton(icon: "xmark", size: 36) {
                        dismiss()
                    }
                }
                .padding(.top, 8)

                Spacer(minLength: 10)

                // Stylized Gradient Flame Behind Giant Bold Streak Number
                ZStack {
                    // Ambient orange radial bloom
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: "#FF7A00").opacity(0.32), Color.clear],
                                center: .center,
                                startRadius: 20,
                                endRadius: 120
                            )
                        )
                        .frame(width: 240, height: 240)

                    // Outer flame silhouette
                    Image(systemName: "flame.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 152, height: 176)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "#FF5E1A"), Color(hex: "#FF9F1C"), Color(hex: "#FFE066")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .offset(y: -14)

                    // Inner golden core highlight
                    Image(systemName: "flame.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 78, height: 96)
                        .foregroundStyle(Color(hex: "#FFF3B0").opacity(0.65))
                        .offset(y: 6)

                    // Giant Bold White Streak Number overlapping flame base
                    Text("\(summary.currentStreak)")
                        .font(.system(size: 86, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: Color.black.opacity(0.38), radius: 8, y: 4)
                        .offset(y: 44)
                }
                .frame(height: 210)

                Text(summary.currentStreak == 1 ? "day streak" : "day streak")
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .padding(.top, -10)

                // Monday–Sunday 7-Day Horizontal Completion Row
                HStack(spacing: 12) {
                    ForEach(0..<7, id: \.self) { idx in
                        let completed = idx < summary.mondayToSundayCompleted.count && summary.mondayToSundayCompleted[idx]
                        let isToday = idx == summary.todayMondayIndex

                        VStack(spacing: 8) {
                            ZStack {
                                if completed {
                                    Circle()
                                        .fill(DailyOSTheme.emerald)
                                        .frame(width: 36, height: 36)
                                        .shadow(color: DailyOSTheme.emerald.opacity(0.38), radius: 6)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .black))
                                        .foregroundStyle(DailyOSTheme.canvas)
                                } else if isToday {
                                    Circle()
                                        .stroke(DailyOSTheme.skyGlow, lineWidth: 2.2)
                                        .frame(width: 36, height: 36)
                                        .background(DailyOSTheme.skyGlow.opacity(0.10), in: Circle())
                                } else {
                                    Circle()
                                        .fill(DailyOSTheme.inputSurface)
                                        .frame(width: 36, height: 36)
                                        .overlay(Circle().stroke(DailyOSTheme.hairline, lineWidth: 1))
                                }
                            }

                            Text(mondayFirstLetters[idx])
                                .font(.system(size: 12, weight: isToday ? .bold : .semibold, design: .rounded))
                                .foregroundStyle(isToday ? DailyOSTheme.skyGlow : DailyOSTheme.eyebrow)
                        }
                    }
                }
                .padding(.top, 6)

                // Streak Freeze Card
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(DailyOSTheme.iceBlue.opacity(0.14))
                            .frame(width: 44, height: 44)
                            .blur(radius: 6)
                        Image(systemName: "snowflake")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(DailyOSTheme.iceBlue)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.freezesRemaining == 1
                             ? "1 streak freeze left"
                             : "\(summary.freezesRemaining) streak freezes left")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("protects your streak if you miss a day")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .ambientCard(accent: DailyOSTheme.iceBlue, cornerRadius: 18, washOpacity: 0.06)

                Spacer()
            }
            .padding(.horizontal, 22)
        }
        .preferredColorScheme(.dark)
    }
}
