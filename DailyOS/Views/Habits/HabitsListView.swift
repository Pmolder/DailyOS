import SwiftUI
import SwiftData

/// "Every habit. One glance." — Rebuilt Habits Tab matching the Midnight Obsidian & Ambient Glow design language.
struct HabitsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\HabitItem.sortOrder, order: .forward),
            SortDescriptor(\HabitItem.createdAt, order: .forward)
        ]
    ) private var allHabits: [HabitItem]

    @Query(sort: [SortDescriptor(\HabitLog.date, order: .reverse)])
    private var allLogs: [HabitLog]

    @ObservedObject private var notificationScheduler = NotificationScheduler.shared

    @State private var isScoreCardExpanded: Bool = true
    @State private var showingCreateSheet: Bool = false
    @State private var showingStreakSheet: Bool = false
    @State private var showingAnalyticsSheet: Bool = false
    @State private var showingNotificationStudio: Bool = false
    @State private var quantityAdjustHabit: HabitItem?

    private var activeHabits: [HabitItem] {
        allHabits.filter { !$0.isArchived }
    }

    private var todayScore: TodayScoreSummary {
        HabitMetricsEngine.todayScoreSummary(habits: activeHabits, allLogs: allLogs)
    }

    private var globalStreak: GlobalStreakSummary {
        HabitMetricsEngine.globalStreakSummary(habits: activeHabits, allLogs: allLogs)
    }

    private var formattedTodaySubtitle: String {
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "EEEE, d MMM"
        return f.string(from: Date())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DailyOSTheme.canvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 1. Top Header Bar
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Habits")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(formattedTodaySubtitle)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.eyebrow)
                            }

                            Spacer()

                            // Analytics / Stats Circular Button
                            if !activeHabits.isEmpty {
                                FrostedCircleButton(icon: "chart.xyaxis.line", size: 38) {
                                    showingAnalyticsSheet = true
                                }
                            }

                            // Daily Notification Studio Circular Bell Button
                            FrostedCircleButton(icon: "bell.badge", size: 38) {
                                showingNotificationStudio = true
                            }

                            // Streak Flame Pill
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showingStreakSheet = true
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "flame.fill")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color(hex: "#FF8C42"))
                                    Text("\(globalStreak.currentStreak)")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(.white)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 38)
                                .background(DailyOSTheme.buttonSurface, in: Capsule())
                                .overlay(Capsule().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            // Add Habit Circular Button
                            FrostedCircleButton(icon: "plus", size: 38) {
                                showingCreateSheet = true
                            }
                        }
                        .padding(.top, 6)

                        // 2. Collapsible "Today's Score" Hero Card
                        TodayScoreHeroCard(
                            summary: todayScore,
                            isExpanded: $isScoreCardExpanded
                        )

                        // 3. Scrollable Habit Cards Feed (Clean Empty State on Fresh Install)
                        if activeHabits.isEmpty {
                            VStack(spacing: 14) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 34))
                                    .foregroundStyle(DailyOSTheme.skyGlow)
                                Text("No Habits Yet")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("Tap + to build a daily routine or track a quit streak with glowing heatmaps, notes, and analytics.")
                                    .font(.system(size: 13, weight: .regular, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.eyebrow)
                                    .multilineTextAlignment(.center)

                                Button {
                                    showingCreateSheet = true
                                } label: {
                                    Label("Create First Habit", systemImage: "plus")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(DailyOSTheme.canvas)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 12)
                                        .background(DailyOSTheme.skyGlow, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 4)
                            }
                            .padding(28)
                            .frame(maxWidth: .infinity)
                            .ambientCard(accent: DailyOSTheme.skyGlow, cornerRadius: 22, washOpacity: 0.06)
                        } else {
                            LazyVStack(spacing: 14) {
                                ForEach(activeHabits) { habit in
                                    let logMap = HabitMetricsEngine.logsByDayKey(for: habit.id, allLogs: allLogs)
                                    NavigationLink {
                                        HabitDetailView(habit: habit, allHabits: activeHabits, allLogs: allLogs)
                                    } label: {
                                        HabitFeedCardView(
                                            habit: habit,
                                            logMap: logMap,
                                            onQuickCheckIn: {
                                                handleQuickCheckIn(habit, logMap: logMap)
                                            },
                                            onLongPressQuantity: {
                                                quantityAdjustHabit = habit
                                            }
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingCreateSheet) {
                HabitEditorView(habitToEdit: nil)
            }
            .sheet(isPresented: $showingStreakSheet) {
                StreakFreezeSheetView(summary: globalStreak)
            }
            .sheet(isPresented: $showingNotificationStudio) {
                NotificationStudioView()
            }
            .sheet(isPresented: $showingAnalyticsSheet) {
                if let first = activeHabits.first {
                    HabitAnalyticsSheetView(habits: activeHabits, allLogs: allLogs, selectedHabitID: first.id)
                }
            }
            .sheet(item: $quantityAdjustHabit) { habit in
                let map = HabitMetricsEngine.logsByDayKey(for: habit.id, allLogs: allLogs)
                HabitQuantityAdjustSheet(
                    habit: habit,
                    date: Date(),
                    initialValue: HabitMetricsEngine.loggedValue(for: habit, on: Date(), logMap: map)
                )
            }
        }
    }

    private func handleQuickCheckIn(_ habit: HabitItem, logMap: [String: HabitLog]) {
        let today = Date()
        if habit.trackingMode == .quantity {
            let current = HabitMetricsEngine.loggedValue(for: habit, on: today, logMap: logMap)
            let next = current + 1.0
            SharedModelContainer.shared.setHabitLog(for: habit, on: today, value: next)
            if next >= habit.effectiveDailyTarget && current < habit.effectiveDailyTarget {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } else if habit.kind == .quit {
            let currentlyClean = HabitMetricsEngine.isDayComplete(for: habit, on: today, logMap: logMap)
            SharedModelContainer.shared.setHabitLog(for: habit, on: today, value: currentlyClean ? -1.0 : 1.0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            let currentlyDone = HabitMetricsEngine.isDayComplete(for: habit, on: today, logMap: logMap)
            SharedModelContainer.shared.setHabitLog(for: habit, on: today, value: currentlyDone ? 0.0 : 1.0)
            if !currentlyDone {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }

        Task { await notificationScheduler.rescheduleAll() }
    }
}

// MARK: - Collapsible "Today's Score" Hero Card

private struct TodayScoreHeroCard: View {
    let summary: TodayScoreSummary
    @Binding var isExpanded: Bool

    private var ringColor: Color {
        switch summary.score {
        case 75...100: return DailyOSTheme.skyGlow
        case 45..<75: return Color(hex: "#38BDF8")
        default: return Color(hex: "#818CF8")
        }
    }

    var body: some View {
        VStack(spacing: isExpanded ? 16 : 0) {
            HStack {
                if !isExpanded {
                    HStack(spacing: 10) {
                        ZStack {
                            AmbientBloomRing(
                                progress: Double(summary.score) / 100.0,
                                color: ringColor,
                                lineWidth: 4,
                                diameter: 34
                            )
                            Text("\(summary.score)")
                                .font(.system(size: 12, weight: .black, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("TODAY'S SCORE").eyebrowStyle()
                            Text(summary.headline)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                } else {
                    Spacer()
                    Text("TODAY'S SCORE").eyebrowStyle()
                    Spacer()
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                        .frame(width: 28, height: 28)
                        .background(DailyOSTheme.inputSurface, in: Circle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                ZStack {
                    AmbientBloomRing(
                        progress: Double(summary.score) / 100.0,
                        color: ringColor,
                        lineWidth: 14,
                        diameter: 170
                    )

                    VStack(spacing: 2) {
                        Text("\(summary.score)")
                            .font(.system(size: 56, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("/ 100")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                }
                .padding(.vertical, 2)

                Text(summary.headline)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                // 2 x 2 Bento Micro-Tiles
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    scoreBentoTile(title: "HABITS", value: "\(summary.habitsCompleted) / \(summary.habitsTotal)")
                    scoreBentoTile(title: "FOCUS", value: "\(summary.focusMinutesToday) min")
                    scoreBentoTile(title: "STREAK", value: summary.globalStreak == 1 ? "1 day" : "\(summary.globalStreak) days")
                    scoreBentoTile(title: "WAKE", value: summary.wakeCompletedToday ? "Done" : "Pending")
                }
            }
        }
        .padding(16)
        .ambientCard(accent: ringColor, cornerRadius: 24, washOpacity: 0.08)
    }

    private func scoreBentoTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).eyebrowStyle()
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(DailyOSTheme.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
    }
}

// MARK: - Lush Ambient Habit Feed Card with Expanding Radial Particle Burst

private struct HabitFeedCardView: View {
    let habit: HabitItem
    let logMap: [String: HabitLog]
    let onQuickCheckIn: () -> Void
    let onLongPressQuantity: () -> Void

    @State private var burstTrigger: Int = 0

    private var accent: Color { habit.accentColor }

    private var todayRatio: Double {
        HabitMetricsEngine.progressRatio(for: habit, on: Date(), logMap: logMap)
    }

    private var todayValue: Double {
        HabitMetricsEngine.loggedValue(for: habit, on: Date(), logMap: logMap)
    }

    private var isCompleteToday: Bool {
        todayRatio >= 1.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Card Header Row
            HStack(spacing: 12) {
                // 38x38 Tinted Rounded-Square Icon Badge
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(accent.opacity(0.18))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: habit.iconName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accent)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(habit.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(HabitMetricsEngine.streakSubtitle(for: habit, logMap: logMap))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                }

                Spacer(minLength: 8)

                // Interactive One-Tap Check-In Control
                ZStack {
                    ParticleBurstOverlay(accent: accent, trigger: burstTrigger)

                    if habit.trackingMode == .quantity {
                        // Quantity Habit: Circular mini progress ring with integer inside
                        ZStack {
                            Circle()
                                .stroke(accent.opacity(0.22), lineWidth: 3.5)
                                .frame(width: 36, height: 36)
                            Circle()
                                .trim(from: 0, to: todayRatio)
                                .stroke(accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 36, height: 36)
                                .animation(.spring(response: 0.3), value: todayRatio)

                            Text("\(Int(todayValue))")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(isCompleteToday ? accent : Color.white)
                        }
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                        .onTapGesture {
                            burstTrigger += 1
                            onQuickCheckIn()
                        }
                        .onLongPressGesture(minimumDuration: 0.4) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onLongPressQuantity()
                        }
                    } else if habit.kind == .quit {
                        // Quit Habit: Warm circular hand/shield badge
                        Button {
                            burstTrigger += 1
                            onQuickCheckIn()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(isCompleteToday ? accent : DailyOSTheme.inputSurface)
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Circle().stroke(isCompleteToday ? accent : accent.opacity(0.45), lineWidth: 1.5)
                                    )
                                Image(systemName: isCompleteToday ? "hand.raised.fill" : "shield.slash")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(isCompleteToday ? DailyOSTheme.canvas : accent)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Binary Build Habit: Circular check button with radial burst
                        Button {
                            if !isCompleteToday {
                                burstTrigger += 1
                            }
                            onQuickCheckIn()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(isCompleteToday ? accent : DailyOSTheme.inputSurface)
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Circle().stroke(isCompleteToday ? accent : accent.opacity(0.4), lineWidth: 1.5)
                                    )
                                    .shadow(color: isCompleteToday ? accent.opacity(0.45) : .clear, radius: 6)

                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(isCompleteToday ? DailyOSTheme.canvas : Color.white.opacity(0.35))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Full-Width Compact Contribution Heatmap Grid (7 rows x 28 weeks)
            HabitHeatmapGridView(
                habit: habit,
                logMap: logMap,
                weeksCount: 28,
                showAxes: false
            )
        }
        .padding(16)
        .ambientCard(accent: accent, cornerRadius: 22, washOpacity: 0.09)
    }
}

// MARK: - Subtle Expanding Radial Ring & Particle Burst Animation

private struct ParticleBurstOverlay: View {
    let accent: Color
    let trigger: Int

    @State private var animate: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(animate ? 0.0 : 0.75), lineWidth: animate ? 0.5 : 2.5)
                .frame(width: animate ? 88 : 34, height: animate ? 88 : 34)

            ForEach(0..<8, id: \.self) { idx in
                let angle = Double(idx) * (Double.pi / 4.0)
                Circle()
                    .fill(accent)
                    .frame(width: animate ? 2 : 5, height: animate ? 2 : 5)
                    .opacity(animate ? 0.0 : 0.95)
                    .offset(
                        x: animate ? CGFloat(cos(angle) * 42) : 0,
                        y: animate ? CGFloat(sin(angle) * 42) : 0
                    )
            }
        }
        .allowsHitTesting(false)
        .opacity(trigger == 0 ? 0 : 1)
        .onChange(of: trigger) { _, _ in
            animate = false
            withAnimation(.easeOut(duration: 0.52)) {
                animate = true
            }
        }
    }
}
