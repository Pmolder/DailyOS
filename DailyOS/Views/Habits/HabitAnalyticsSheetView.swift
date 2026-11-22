import SwiftUI
import Charts

/// "Your progress, in numbers." — Full Habit Analytics Sheet with horizontal habit switcher,
/// year selector, full-year heatmap, 2x2 bento stats grid, and Swift Charts smooth area chart.
struct HabitAnalyticsSheetView: View {
    @Environment(\.dismiss) private var dismiss

    let habits: [HabitItem]
    let allLogs: [HabitLog]
    @State var selectedHabitID: UUID
    @State private var selectedYear: Int = ISOWeekCalendar.current.component(.year, from: Date())

    private var activeHabit: HabitItem? {
        habits.first(where: { $0.id == selectedHabitID }) ?? habits.first
    }

    private var activeLogMap: [String: HabitLog] {
        guard let habit = activeHabit else { return [:] }
        return HabitMetricsEngine.logsByDayKey(for: habit.id, allLogs: allLogs)
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            if let habit = activeHabit {
                let accent = habit.accentColor
                let map = activeLogMap
                let totalText = HabitMetricsEngine.totalFormatted(for: habit, inYear: selectedYear, logMap: map)
                let ratePct = HabitMetricsEngine.completionRatePercent(for: habit, inYear: selectedYear, logMap: map)
                let curStreak = HabitMetricsEngine.currentStreak(for: habit, logMap: map)
                let bestStrk = HabitMetricsEngine.bestStreak(for: habit, logMap: map)
                let monthlyPoints = HabitMetricsEngine.monthlyCompletions(for: habit, inYear: selectedYear, logMap: map)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        // Top Horizontal Habit Switcher + Accent "Done" Pill
                        HStack(spacing: 12) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(habits) { item in
                                        let isSelected = item.id == habit.id
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            withAnimation(.spring(response: 0.28)) {
                                                selectedHabitID = item.id
                                            }
                                        } label: {
                                            ZStack {
                                                Circle()
                                                    .fill(isSelected ? item.accentColor.opacity(0.24) : DailyOSTheme.buttonSurface)
                                                    .frame(width: 42, height: 42)
                                                if isSelected {
                                                    Circle()
                                                        .stroke(item.accentColor, lineWidth: 2)
                                                        .frame(width: 46, height: 46)
                                                        .shadow(color: item.accentColor.opacity(0.45), radius: 6)
                                                } else {
                                                    Circle()
                                                        .stroke(DailyOSTheme.buttonStroke, lineWidth: 1)
                                                        .frame(width: 42, height: 42)
                                                }
                                                Image(systemName: item.iconName)
                                                    .font(.system(size: 16, weight: .semibold))
                                                    .foregroundStyle(isSelected ? item.accentColor : Color.white.opacity(0.75))
                                            }
                                            .padding(3)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            Button {
                                dismiss()
                            } label: {
                                Text("Done")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.canvas)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        // Habit Context Strip
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(accent.opacity(0.18))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Image(systemName: habit.iconName)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(accent)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(habit.title)
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                if !habit.subtitle.isEmpty {
                                    Text(habit.subtitle)
                                        .font(.system(size: 12, weight: .regular, design: .rounded))
                                        .foregroundStyle(DailyOSTheme.eyebrow)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(14)
                        .ambientCard(accent: accent, cornerRadius: 18, washOpacity: 0.06)

                        // Year Switcher Pill
                        HStack {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                selectedYear -= 1
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .frame(width: 36, height: 32)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Text("\(selectedYear)")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)

                            Spacer()

                            let currentYear = ISOWeekCalendar.current.component(.year, from: Date())
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if selectedYear < currentYear {
                                    selectedYear += 1
                                }
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(selectedYear < currentYear ? Color.white.opacity(0.8) : Color.white.opacity(0.25))
                                    .frame(width: 36, height: 32)
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedYear >= currentYear)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .ambientCard(cornerRadius: 16)

                        // Full-Year Heatmap Card
                        VStack(alignment: .leading, spacing: 8) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HabitHeatmapGridView(
                                    habit: habit,
                                    logMap: map,
                                    yearFilter: selectedYear,
                                    showAxes: true
                                )
                                .frame(width: 455)
                            }
                        }
                        .padding(14)
                        .ambientCard(accent: accent, cornerRadius: 20, washOpacity: 0.06)

                        // 2 x 2 Bento Stats Grid
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            analyticsBentoTile(
                                value: totalText,
                                label: "Completions",
                                badgeIcon: "number",
                                accent: accent
                            )
                            analyticsBentoTile(
                                value: "\(ratePct)%",
                                label: "Completion Rate",
                                badgeIcon: "percent",
                                accent: accent
                            )
                            analyticsBentoTile(
                                value: curStreak == 1 ? "1 day" : "\(curStreak) days",
                                label: habit.kind == .quit ? "Days Free" : "Current Streak",
                                badgeIcon: "flame.fill",
                                accent: accent
                            )
                            analyticsBentoTile(
                                value: bestStrk == 1 ? "1 day" : "\(bestStrk) days",
                                label: "Best Streak",
                                badgeIcon: "trophy.fill",
                                accent: accent
                            )
                        }

                        // Completions / Month Smooth Area Chart (Swift Charts)
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Completions / Month")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Spacer()
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(accent.opacity(0.18))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Image(systemName: "chart.xyaxis.line")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(accent)
                                    )
                            }

                            Chart(monthlyPoints) { point in
                                AreaMark(
                                    x: .value("Month", point.monthShort),
                                    y: .value("Completions", point.count)
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [accent.opacity(0.45), accent.opacity(0.0)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("Month", point.monthShort),
                                    y: .value("Completions", point.count)
                                )
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .foregroundStyle(accent)
                            }
                            .chartYAxis(.hidden)
                            .chartXAxis {
                                AxisMarks(values: .automatic) { _ in
                                    AxisValueLabel()
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(DailyOSTheme.eyebrow)
                                }
                            }
                            .frame(height: 150)
                        }
                        .padding(16)
                        .ambientCard(accent: accent, cornerRadius: 20, washOpacity: 0.05)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
            } else {
                VStack(spacing: 16) {
                    Text("No Habits to Analyze Yet")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func analyticsBentoTile(value: String, label: String, badgeIcon: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent.opacity(0.18))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: badgeIcon)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accent)
                    )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DailyOSTheme.eyebrow)
            }
        }
        .padding(14)
        .ambientCard(accent: accent, cornerRadius: 18, washOpacity: 0.05)
    }
}
