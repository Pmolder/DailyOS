import SwiftUI
import UIKit

/// Multi-slide Midnight Obsidian "Weekly Winter Arc" Recap with 1-Tap 9:16 (1080×1920) Story Card export via ImageRenderer.
struct WeeklyRecapSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var summary: WeeklyRecapSummary = WeeklyRecapEngine.buildCurrentWeekRecap()
    @State private var currentPage: Int = 0
    @State private var renderedStoryImage: UIImage? = nil
    @State private var showingShareSheet: Bool = false

    private let weekdayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 36) { dismiss() }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("WEEKLY ARC")
                            .eyebrowStyle()
                        Text(summary.dateRangeLabel)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                    }
                    Spacer()
                    Text("\(currentPage + 1)/4")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DailyOSTheme.eyebrow)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 8)

                TabView(selection: $currentPage) {
                    slide1WeeklyScore.tag(0)
                    slide2HabitsConsistency.tag(1)
                    slide3DeepWorkAndMornings.tag(2)
                    slide4StoryCardExport.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            summary = WeeklyRecapEngine.buildCurrentWeekRecap()
        }
        .sheet(isPresented: $showingShareSheet) {
            if let image = renderedStoryImage {
                ActivityShareSheet(items: [image])
            }
        }
    }

    // MARK: - Slide 1: Weekly Score

    private var slide1WeeklyScore: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("WEEKLY SCORE")
                .eyebrowStyle()

            ZStack {
                AmbientBreathingGlow(color: DailyOSTheme.skyGlow, diameter: 250)
                AmbientBloomRing(
                    progress: Double(summary.avgWeeklyScore) / 100.0,
                    color: DailyOSTheme.skyGlow,
                    lineWidth: 16,
                    diameter: 216
                )
                VStack(spacing: 4) {
                    Text("\(summary.avgWeeklyScore)")
                        .font(.system(size: 60, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                    Text("AVG SCORE")
                        .eyebrowStyle()
                }
            }

            Text(summary.scoreHeadline)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)

            // Mon-Sun 7-day bar strip
            HStack(spacing: 10) {
                ForEach(0..<7, id: \.self) { idx in
                    let sc = idx < summary.dailyScores.count ? summary.dailyScores[idx] : 0
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            Capsule()
                                .fill(DailyOSTheme.inputSurface)
                                .frame(width: 10, height: 52)
                            Capsule()
                                .fill(sc >= 70 ? DailyOSTheme.skyGlow : DailyOSTheme.indigoGlow.opacity(0.65))
                                .frame(width: 10, height: max(4, CGFloat(sc) * 0.52))
                        }
                        Text(weekdayLabels[idx])
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .ambientCard(cornerRadius: 20)
            .padding(.horizontal, 22)

            Spacer()
        }
    }

    // MARK: - Slide 2: Habits & Consistency

    private var slide2HabitsConsistency: some View {
        let topAccent = Color(hex: summary.topHabitColorHex)
        return VStack(spacing: 20) {
            Spacer()

            Text("HABITS & CONSISTENCY")
                .eyebrowStyle()

            Text("\(summary.habitConsistencyPercent)%")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DailyOSTheme.emerald)

            Text("Weekly Habit Completion Rate")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.85))

            // Top Habit Highlight Card with Mini-Heatmap
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: summary.topHabitIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(topAccent)
                        .frame(width: 44, height: 44)
                        .background(topAccent.opacity(0.18), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("TOP HABIT")
                            .eyebrowStyle()
                        Text(summary.topHabitName)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                    }

                    Spacer()

                    Text("\(summary.topHabitCompletedDays)/7d")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(topAccent)
                }

                HStack(spacing: 8) {
                    ForEach(0..<7, id: \.self) { idx in
                        let ratio = idx < summary.topHabitWeekRatios.count ? summary.topHabitWeekRatios[idx] : 0.0
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ratio >= 1.0 ? topAccent : (ratio > 0 ? topAccent.opacity(0.42) : DailyOSTheme.emptyCell))
                                .frame(height: 28)
                            Text(weekdayLabels[idx])
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(DailyOSTheme.eyebrow)
                        }
                    }
                }
            }
            .padding(18)
            .ambientCard(accent: topAccent, cornerRadius: 22, washOpacity: 0.10)
            .padding(.horizontal, 22)

            // Best Active Streak Pill
            HStack(spacing: 10) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(hex: "#FF8C42"))
                Text("Best Active Streak: \(summary.bestActiveStreak) days")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .ambientCard(accent: Color(hex: "#FF8C42"), cornerRadius: 18, washOpacity: 0.10)

            Spacer()
        }
    }

    // MARK: - Slide 3: Deep Work & Mornings

    private var slide3DeepWorkAndMornings: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("DEEP WORK & MORNINGS")
                .eyebrowStyle()

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                recapTile(icon: "timer", color: DailyOSTheme.skyGlow, value: summary.formattedFocusTime, label: "DEEP WORK")
                recapTile(icon: "checkmark.circle.fill", color: DailyOSTheme.emerald, value: "\(summary.completedFocusTasks)", label: "TASKS CLEARED")
                recapTile(icon: "camera.fill", color: DailyOSTheme.indigoGlow, value: "\(summary.verifiedPhotoProofs)", label: "PROOFS VERIFIED")
                recapTile(icon: "sun.max.fill", color: Color(hex: "#FFB020"), value: "\(summary.morningsConquered)", label: "MORNINGS WON")
            }
            .padding(.horizontal, 22)

            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(hex: "#FFB020"))
                    .frame(width: 40, height: 40)
                    .background(Color(hex: "#FFB020").opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("AVG REFLEX STRIKE SPEED")
                        .eyebrowStyle()
                    Text(summary.formattedReactionSpeed)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                }
                Spacer()
            }
            .padding(16)
            .ambientCard(accent: Color(hex: "#FFB020"), cornerRadius: 20, washOpacity: 0.08)
            .padding(.horizontal, 22)

            Spacer()
        }
    }

    // MARK: - Slide 4: Final Shareable 9:16 Story Card + ImageRenderer Export

    private var slide4StoryCardExport: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 4)

            // Live 9:16 Story Card Preview
            WeeklyArcStoryCardView(summary: summary)
                .frame(width: 252, height: 448)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: DailyOSTheme.skyGlow.opacity(0.22), radius: 20)

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                exportStoryCard()
            } label: {
                Label("Save / Share Story Card", systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(DailyOSTheme.skyGlow, in: Capsule())
            }
            .buttonStyle(MidnightPressStyle())
            .padding(.horizontal, 28)

            Spacer(minLength: 26)
        }
    }

    private func recapTile(icon: String, color: Color, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white)

            Text(label)
                .eyebrowStyle()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ambientCard(accent: color, cornerRadius: 20, washOpacity: 0.07)
    }

    /// Renders a crisp 1080×1920 (360×640 @ 3x) 9:16 Midnight Obsidian Story Card via SwiftUI ImageRenderer.
    @MainActor
    private func exportStoryCard() {
        let cardView = WeeklyArcStoryCardView(summary: summary)
            .frame(width: 360, height: 640)
        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 3.0
        if let uiImage = renderer.uiImage {
            renderedStoryImage = uiImage
            showingShareSheet = true
        }
    }
}

// MARK: - 9:16 Aesthetic Midnight Obsidian Story Graphic

private struct WeeklyArcStoryCardView: View {
    let summary: WeeklyRecapSummary

    var body: some View {
        ZStack {
            Color(hex: "#09090D")

            // Subtle Midnight Obsidian Ambient Glow Mesh
            RadialGradient(
                colors: [DailyOSTheme.skyGlow.opacity(0.22), Color.clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 340
            )
            RadialGradient(
                colors: [DailyOSTheme.indigoGlow.opacity(0.18), Color.clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 320
            )

            VStack(spacing: 18) {
                // Brand Header
                VStack(spacing: 4) {
                    Text("DAILYOS • WEEKLY ARC")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(DailyOSTheme.eyebrow)
                    Text(summary.dateRangeLabel)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                }
                .padding(.top, 26)

                Spacer(minLength: 4)

                // Hero Score Ring
                ZStack {
                    AmbientBloomRing(
                        progress: Double(summary.avgWeeklyScore) / 100.0,
                        color: DailyOSTheme.skyGlow,
                        lineWidth: 11,
                        diameter: 148
                    )
                    VStack(spacing: 2) {
                        Text("\(summary.avgWeeklyScore)")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                        Text(summary.scoreHeadline)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(DailyOSTheme.skyGlow)
                    }
                }

                // 2x2 Bento Stat Tiles
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    storyBento(label: "CONSISTENCY", value: "\(summary.habitConsistencyPercent)%", color: DailyOSTheme.emerald)
                    storyBento(label: "DEEP WORK", value: summary.formattedFocusTime, color: DailyOSTheme.skyGlow)
                    storyBento(label: "TASKS DONE", value: "\(summary.completedFocusTasks)", color: DailyOSTheme.indigoGlow)
                    storyBento(label: "REFLEX AVG", value: summary.formattedReactionSpeed, color: Color(hex: "#FFB020"))
                }
                .padding(.horizontal, 20)

                // Bottom Streak Flame Pill
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: "#FF8C42"))
                    Text("\(summary.bestActiveStreak)-Day Best Streak")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(hex: "#141419"), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))

                Spacer(minLength: 10)
            }
            .padding(.bottom, 18)
        }
    }

    private func storyBento(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(DailyOSTheme.eyebrow)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(hex: "#141419"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        )
    }
}

// MARK: - Native UIActivityViewController Wrapper (Zero Extra Photo Library Permissions)

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
