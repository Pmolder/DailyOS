import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// "Every habit. One glance." — Rebuilt Habits Tab matching the Midnight Obsidian & Ambient Glow design language.
struct HabitsListView: View {
    var onOpenFocusTab: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\HabitItem.sortOrder, order: .forward),
            SortDescriptor(\HabitItem.createdAt, order: .forward)
        ]
    ) private var allHabits: [HabitItem]

    @Query(sort: [SortDescriptor(\HabitLog.date, order: .reverse)])
    private var allLogs: [HabitLog]

    @Query(
        sort: [
            SortDescriptor(\RoutineChecklistItem.sortOrder, order: .forward),
            SortDescriptor(\RoutineChecklistItem.createdAt, order: .forward)
        ]
    ) private var allRoutineItems: [RoutineChecklistItem]

    @Query private var allRoutineLogs: [RoutineChecklistLog]
    @Query private var allFocusTasks: [FocusTaskItem]
    @Query private var allAlarms: [AlarmItem]

    @ObservedObject private var notificationScheduler = NotificationScheduler.shared
    @ObservedObject private var calendarCompletions = CalendarEventCompletionStore.shared
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared

    @State private var isScoreCardExpanded: Bool = true
    @State private var showingCreateSheet: Bool = false
    @State private var showingStreakSheet: Bool = false
    @State private var showingAnalyticsSheet: Bool = false
    @State private var showingNotificationStudio: Bool = false
    @State private var activeRoutineSheet: RoutineType? = nil
    @State private var quantityAdjustHabit: HabitItem?

    // Drag-and-drop, Reorder Mode & Spotlight Celebration State
    @State private var draggingHabitID: UUID? = nil
    @State private var isReorderMode: Bool = false
    @State private var primePulse: Bool = false
    @State private var spotlightShimmerTrigger: Int = 0
    @State private var routineBurstTrigger: [UUID: Int] = [:]

    private var activeHabits: [HabitItem] {
        allHabits.filter { !$0.isArchived }
    }

    private var todayKey: String {
        HabitItem.dateKey(for: Date())
    }

    private var todayCompletedRoutineIDs: Set<UUID> {
        Set(allRoutineLogs.filter { $0.dayKey == todayKey }.map(\.itemID))
    }

    private func routineItems(for type: RoutineType) -> [RoutineChecklistItem] {
        allRoutineItems.filter { $0.routineType == type }
    }

    private func routineCounts(for type: RoutineType) -> (completed: Int, total: Int) {
        let items = routineItems(for: type)
        let done = items.filter { todayCompletedRoutineIDs.contains($0.id) }.count
        return (done, items.count)
    }

    // MARK: - Time-Aware Dynamic Morning & Night Spotlight Windows

    private var isInMorningWindow: Bool {
        let hour = ISOWeekCalendar.current.component(.hour, from: Date())
        return (5..<12).contains(hour) || (HabitMetricsEngine.isWakeCompletedToday && hour < 15)
    }

    private var nextEnabledAlarm: AlarmItem? {
        let now = Date()
        return allAlarms
            .filter(\.isEnabled)
            .compactMap { alarm -> (alarm: AlarmItem, date: Date)? in
                guard let next = alarm.nextTriggerDate(after: now) else { return nil }
                return (alarm, next)
            }
            .min(by: { $0.date < $1.date })?
            .alarm
    }

    private var nightBedtimeTargetLabel: String? {
        guard let alarm = nextEnabledAlarm else { return nil }
        let bed = alarm.bedtimeSchedule()
        return "Lights out \(bed.lightsOutText) • \(alarm.sleepCycleCount) cycles"
    }

    private var isInNightWindow: Bool {
        let cal = ISOWeekCalendar.current
        let now = Date()
        let nowMins = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)

        if let alarm = nextEnabledAlarm {
            let bed = alarm.bedtimeSchedule()
            let windDownMins = bed.windDownHour * 60 + bed.windDownMinute
            let triggerStart = (windDownMins - 45 + 1440) % 1440
            // Active from 45m before wind-down through 03:00 AM
            if triggerStart >= 180 {
                return nowMins >= triggerStart || nowMins < 180
            } else {
                return nowMins >= triggerStart && nowMins < 180
            }
        }
        // Fallback window when no alarm is enabled: 20:30 – 03:00
        return nowMins >= (20 * 60 + 30) || nowMins < 180
    }

    private var isMorningSpotlightActive: Bool {
        let counts = routineCounts(for: .morning)
        return isInMorningWindow && counts.total > 0 && counts.completed < counts.total
    }

    private var isNightSpotlightActive: Bool {
        let counts = routineCounts(for: .night)
        return isInNightWindow && counts.total > 0 && counts.completed < counts.total
    }

    private func spotlightAccent(for habit: HabitItem, logMap: [String: HabitLog]) -> Color? {
        guard !HabitMetricsEngine.isDayComplete(for: habit, on: Date(), logMap: logMap) else {
            return nil
        }
        if habit.timeOfDay == .morning && isInMorningWindow {
            return DailyOSTheme.solarAccent
        }
        if habit.timeOfDay == .night && isInNightWindow {
            return DailyOSTheme.indigoGlow
        }
        return nil
    }

    private var displayedHabits: [HabitItem] {
        if isReorderMode { return activeHabits }
        return activeHabits.sorted { lhs, rhs in
            let lMap = HabitMetricsEngine.logsByDayKey(for: lhs.id, allLogs: allLogs)
            let rMap = HabitMetricsEngine.logsByDayKey(for: rhs.id, allLogs: allLogs)
            let lSpot = spotlightAccent(for: lhs, logMap: lMap) != nil
            let rSpot = spotlightAccent(for: rhs, logMap: rMap) != nil
            if lSpot != rSpot { return lSpot }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var todayScore: TodayScoreSummary {
        let _ = calendarCompletions.revision
        let todaysTasks = allFocusTasks.filter { $0.dayKey == todayKey }
        let linkedIDs = Set(allFocusTasks.compactMap(\.googleCalendarEventID).filter { !$0.isEmpty })
        let todayCalBlocks = focusManager.upcomingBlocks.filter { block in
            guard block.dayKey == todayKey else { return false }
            if let rID = block.remoteEventID, linkedIDs.contains(rID) { return false }
            return true
        }
        let calCompleted = todayCalBlocks.filter { calendarCompletions.isCompleted($0) }.count
        return HabitMetricsEngine.todayScoreSummary(
            habits: activeHabits,
            allLogs: allLogs,
            todayTasks: todaysTasks,
            completedCalendarEventsCount: calCompleted,
            totalCalendarEventsCount: todayCalBlocks.count
        )
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
                        HStack(alignment: .center, spacing: 7) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Habits")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(formattedTodaySubtitle)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.eyebrow)
                            }

                            Spacer(minLength: 4)

                            // Analytics / Stats Circular Button
                            if !activeHabits.isEmpty {
                                FrostedCircleButton(icon: "chart.xyaxis.line", size: 34) {
                                    showingAnalyticsSheet = true
                                }
                            }

                            // Reorder Mode Fallback Button (when 2+ habits exist)
                            if activeHabits.count > 1 {
                                FrostedCircleButton(
                                    icon: isReorderMode ? "checkmark" : "arrow.up.arrow.down",
                                    size: 34,
                                    tint: isReorderMode ? DailyOSTheme.skyGlow : Color.white
                                ) {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                        isReorderMode.toggle()
                                    }
                                }
                            }

                            // Daily Notification Studio Circular Bell Button
                            FrostedCircleButton(icon: "bell.badge", size: 34) {
                                showingNotificationStudio = true
                            }

                            // Streak Flame Pill
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showingStreakSheet = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "flame.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .symbolEffect(.bounce, value: globalStreak.currentStreak)
                                        .foregroundStyle(Color(hex: "#FF8C42"))
                                    Text("\(globalStreak.currentStreak)")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                        .animation(ProMotionSpring.pop, value: globalStreak.currentStreak)
                                        .foregroundStyle(.white)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .background(DailyOSTheme.buttonSurface, in: Capsule())
                                .overlay(Capsule().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            // Add Habit Circular Button
                            FrostedCircleButton(icon: "plus", size: 34) {
                                showingCreateSheet = true
                            }
                        }
                        .padding(.top, 6)

                        // 2. Collapsible Dual-Ring "Today's Overview" Hero Card (Pure Habits + Separate To-Do Ring)
                        TodayScoreHeroCard(
                            summary: todayScore,
                            isExpanded: $isScoreCardExpanded,
                            onTapTodoRing: onOpenFocusTab
                        )

                        // 2b. Time-Aware Dynamic Morning / Night Spotlight Hero Card + Compact Sun/Moon Bar
                        dynamicRoutinesSection

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
                                ForEach(Array(displayedHabits.enumerated()), id: \.element.id) { index, habit in
                                    let logMap = HabitMetricsEngine.logsByDayKey(for: habit.id, allLogs: allLogs)
                                    let isBeingDragged = draggingHabitID == habit.id
                                    let spotColor = spotlightAccent(for: habit, logMap: logMap)

                                    HStack(spacing: 10) {
                                        if isReorderMode {
                                            VStack(spacing: 6) {
                                                Button {
                                                    moveHabit(at: index, direction: -1)
                                                } label: {
                                                    Image(systemName: "chevron.up")
                                                        .font(.system(size: 12, weight: .bold))
                                                        .foregroundStyle(index == 0 ? DailyOSTheme.eyebrow.opacity(0.35) : Color.white)
                                                        .frame(width: 30, height: 30)
                                                        .background(DailyOSTheme.buttonSurface, in: Circle())
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(index == 0)

                                                Image(systemName: "line.3.horizontal")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(DailyOSTheme.eyebrow)

                                                Button {
                                                    moveHabit(at: index, direction: 1)
                                                } label: {
                                                    Image(systemName: "chevron.down")
                                                        .font(.system(size: 12, weight: .bold))
                                                        .foregroundStyle(index == displayedHabits.count - 1 ? DailyOSTheme.eyebrow.opacity(0.35) : Color.white)
                                                        .frame(width: 30, height: 30)
                                                        .background(DailyOSTheme.buttonSurface, in: Circle())
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(index == displayedHabits.count - 1)
                                            }
                                        }

                                        NavigationLink {
                                            HabitDetailView(habit: habit, allHabits: activeHabits, allLogs: allLogs)
                                        } label: {
                                            HabitFeedCardView(
                                                habit: habit,
                                                logMap: logMap,
                                                spotlightAccent: spotColor,
                                                onQuickCheckIn: {
                                                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                                        handleQuickCheckIn(habit, logMap: logMap)
                                                    }
                                                },
                                                onLongPressQuantity: {
                                                    quantityAdjustHabit = habit
                                                }
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isReorderMode)
                                    }
                                    .opacity(isBeingDragged ? 0.55 : 1.0)
                                    .scaleEffect(isBeingDragged ? 0.98 : 1.0)
                                    .staggeredEntrance(index: index)
                                    .onDrag {
                                        draggingHabitID = habit.id
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        return NSItemProvider(object: habit.id.uuidString as NSString)
                                    }
                                    .onDrop(
                                        of: [UTType.text],
                                        delegate: HabitReorderDropDelegate(
                                            targetHabit: habit,
                                            habits: activeHabits,
                                            draggingHabitID: $draggingHabitID,
                                            onReorder: { reordered in
                                                persistHabitOrder(reordered)
                                            }
                                        )
                                    )
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
            .sheet(item: $activeRoutineSheet) { routineType in
                RoutineChecklistSheet(routineType: routineType)
            }
            .onAppear {
                RoutineChecklistSeeder.seedDefaultsIfNeeded(in: modelContext)
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    primePulse = true
                }
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

    // MARK: - Time-Aware Dynamic Morning / Night Spotlight Hero + Compact Sun & Moon Bar

    private var dynamicRoutinesSection: some View {
        VStack(spacing: 12) {
            if isMorningSpotlightActive {
                routineSpotlightHeroCard(type: .morning, bedtimeTarget: nil)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94).combined(with: .opacity),
                        removal: .scale(scale: 0.90).combined(with: .opacity)
                    ))
            } else if isNightSpotlightActive {
                routineSpotlightHeroCard(type: .night, bedtimeTarget: nightBedtimeTargetLabel)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94).combined(with: .opacity),
                        removal: .scale(scale: 0.90).combined(with: .opacity)
                    ))
            }

            HStack(spacing: 12) {
                if !isMorningSpotlightActive {
                    routineRingPill(type: .morning)
                }
                if !isNightSpotlightActive {
                    routineRingPill(type: .night)
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: isMorningSpotlightActive)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: isNightSpotlightActive)
    }

    private func routineSpotlightHeroCard(type: RoutineType, bedtimeTarget: String?) -> some View {
        let items = routineItems(for: type)
        let counts = routineCounts(for: type)
        let remainingItems = items.filter { !todayCompletedRoutineIDs.contains($0.id) }
        let ratio = counts.total > 0 ? Double(counts.completed) / Double(counts.total) : 0.0
        let accent = type.accentColor

        return VStack(alignment: .leading, spacing: 14) {
            // Header (tap to open full RoutineChecklistSheet)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                activeRoutineSheet = type
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        OrganicBreathingAura(color: accent, diameter: 62)
                        Circle()
                            .fill(accent.opacity(0.20))
                            .frame(width: 48, height: 48)
                            .overlay(Circle().stroke(accent.opacity(0.55), lineWidth: 1.5))
                        Image(systemName: type.iconName)
                            .font(.system(size: 21, weight: .bold))
                            .symbolEffect(.bounce, value: counts.completed)
                            .foregroundStyle(accent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(type == .morning ? "MORNING SPOTLIGHT" : "NIGHT SPOTLIGHT")
                                .font(.system(size: 10, weight: .black, design: .rounded))
                                .tracking(1.1)
                                .foregroundStyle(accent)

                            if let bedtimeTarget {
                                Text("• \(bedtimeTarget)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white.opacity(0.75))
                                    .lineLimit(1)
                            }
                        }

                        Text("\(type.title) • \(counts.completed) / \(counts.total)")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(Color.white)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 28, height: 28)
                        .background(accent.opacity(0.14), in: Circle())
                }
            }
            .buttonStyle(.plain)

            // Live Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 6)
                    Capsule()
                        .fill(accent)
                        .frame(width: max(8, geo.size.width * ratio), height: 6)
                        .shadow(color: accent.opacity(0.55), radius: 6)
                        .animation(ProMotionSpring.ringFill, value: ratio)
                }
            }
            .frame(height: 6)

            // Inline 1-Tap Checkable Preview Rows for Remaining Steps
            VStack(spacing: 8) {
                ForEach(remainingItems.prefix(4)) { item in
                    let burst = routineBurstTrigger[item.id] ?? 0
                    let isChargerStep = type == .night && (item.title.lowercased().contains("charger") || item.title.lowercased().contains("phone"))

                    HStack(spacing: 11) {
                        Button {
                            routineBurstTrigger[item.id] = burst + 1
                            let becameDone = SharedModelContainer.shared.toggleRoutineLog(itemID: item.id, dayKey: todayKey)
                            if becameDone {
                                let newCounts = routineCounts(for: type)
                                if newCounts.completed >= newCounts.total {
                                    spotlightShimmerTrigger += 1
                                }
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            } else {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        } label: {
                            ZStack {
                                CompletionBurstView(trigger: burst, color: accent, size: 42)
                                Circle()
                                    .stroke(accent.opacity(0.75), lineWidth: 2)
                                    .frame(width: 24, height: 24)
                            }
                        }
                        .buttonStyle(MidnightPressButtonStyle())

                        Text(item.title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if isChargerStep {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                activeRoutineSheet = .night
                            } label: {
                                Label("Dock", systemImage: "camera.fill")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(accent.opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(MidnightPressButtonStyle())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(DailyOSTheme.canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(accent.opacity(0.22), lineWidth: 1))
                }
            }
        }
        .padding(16)
        .ambientCard(accent: accent, cornerRadius: 24, washOpacity: 0.16)
        .midnightShimmer(trigger: spotlightShimmerTrigger, color: accent)
    }

    private func routineRingPill(type: RoutineType) -> some View {
        let counts = routineCounts(for: type)
        let ratio = counts.total > 0 ? Double(counts.completed) / Double(counts.total) : 0.0
        let isComplete = counts.total > 0 && counts.completed == counts.total
        let accent = type.accentColor
        let shouldPulse = type.isCurrentlyPrimeWindow && !isComplete && counts.total > 0

        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            activeRoutineSheet = type
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    // Circular Obsidian Button + 2.5pt Progress Ring
                    ZStack {
                        Circle()
                            .fill(DailyOSTheme.card)
                            .frame(width: 46, height: 46)

                        Circle()
                            .stroke(accent.opacity(shouldPulse ? (primePulse ? 0.30 : 0.14) : 0.16), lineWidth: 2.5)
                            .frame(width: 46, height: 46)

                        if ratio > 0 {
                            Circle()
                                .trim(from: 0, to: ratio)
                                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 46, height: 46)
                                .shadow(color: accent.opacity(isComplete ? 0.65 : 0.35), radius: isComplete ? 7 : 4)
                                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: ratio)
                        }

                        Image(systemName: type.iconName)
                            .font(.system(size: 18, weight: .semibold))
                            .symbolEffect(.bounce, value: counts.completed)
                            .foregroundStyle(accent)
                    }

                    if isComplete {
                        Circle()
                            .fill(accent)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8.5, weight: .black))
                                    .foregroundStyle(DailyOSTheme.canvas)
                            )
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.shortLabel)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text("\(counts.completed)/\(counts.total) done")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(ProMotionSpring.pop, value: counts.completed)
                        .foregroundStyle(isComplete ? accent : DailyOSTheme.eyebrow)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .ambientCard(
                accent: (isComplete || shouldPulse) ? accent : nil,
                cornerRadius: 20,
                washOpacity: isComplete ? 0.12 : (shouldPulse ? 0.08 : 0.0)
            )
        }
        .buttonStyle(MidnightPressButtonStyle())
    }

    // MARK: - Habit Reordering Persistence & Widget Sync

    private func moveHabit(at index: Int, direction: Int) {
        let target = index + direction
        guard activeHabits.indices.contains(index), activeHabits.indices.contains(target) else { return }
        var reordered = activeHabits
        let moved = reordered.remove(at: index)
        reordered.insert(moved, at: target)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            persistHabitOrder(reordered)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func persistHabitOrder(_ orderedHabits: [HabitItem]) {
        for (idx, habit) in orderedHabits.enumerated() {
            habit.sortOrder = idx
        }
        try? modelContext.save()
        SharedModelContainer.shared.save() // Triggers WidgetSyncCoordinator + WidgetCenter.reloadAllTimelines()
    }
}

// MARK: - Long-Press Drag-and-Drop Reorder Delegate

private struct HabitReorderDropDelegate: DropDelegate {
    let targetHabit: HabitItem
    let habits: [HabitItem]
    @Binding var draggingHabitID: UUID?
    let onReorder: ([HabitItem]) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID = draggingHabitID,
              draggedID != targetHabit.id,
              let fromIndex = habits.firstIndex(where: { $0.id == draggedID }),
              let toIndex = habits.firstIndex(where: { $0.id == targetHabit.id }) else {
            return
        }

        var updated = habits
        let moved = updated.remove(at: fromIndex)
        updated.insert(moved, at: toIndex)

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            onReorder(updated)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingHabitID = nil
        return true
    }
}

// MARK: - Collapsible Dual-Ring "Today's Overview" Hero Card (Pure Habits + Separate To-Do Ring)

private struct TodayScoreHeroCard: View {
    let summary: TodayScoreSummary
    @Binding var isExpanded: Bool
    let onTapTodoRing: () -> Void
    @State private var score100Trigger: Int = 0

    private var habitsRingColor: Color {
        switch summary.habitsPercent {
        case 75...100: return DailyOSTheme.emerald
        case 45..<75: return DailyOSTheme.indigoGlow
        default: return DailyOSTheme.periwinkle
        }
    }

    private var todoRingColor: Color {
        DailyOSTheme.skyGlow
    }

    var body: some View {
        VStack(spacing: isExpanded ? 16 : 0) {
            HStack {
                if !isExpanded {
                    HStack(spacing: 12) {
                        HStack(spacing: 7) {
                            ZStack {
                                AmbientBloomRing(
                                    progress: Double(summary.habitsPercent) / 100.0,
                                    color: habitsRingColor,
                                    lineWidth: 3.5,
                                    diameter: 32
                                )
                                Text("\(summary.habitsPercent)")
                                    .font(.system(size: 10, weight: .black, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(ProMotionSpring.ringFill, value: summary.habitsPercent)
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text("HABITS").eyebrowStyle()
                                Text("\(summary.habitsCompleted)/\(summary.habitsTotal)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                            }
                        }

                        Button(action: onTapTodoRing) {
                            HStack(spacing: 7) {
                                ZStack {
                                    AmbientBloomRing(
                                        progress: Double(summary.todoPercent) / 100.0,
                                        color: todoRingColor,
                                        lineWidth: 3.5,
                                        diameter: 32
                                    )
                                    Text("\(summary.todoPercent)")
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                        .animation(ProMotionSpring.ringFill, value: summary.todoPercent)
                                        .foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("TO-DO").eyebrowStyle()
                                    Text("\(summary.todoCompleted)/\(summary.todoTotal)")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(todoRingColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Spacer()
                    Text("TODAY'S OVERVIEW").eyebrowStyle()
                    Spacer()
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(ProMotionSpring.glide) {
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
                // Dual Side-by-Side Glowing Progress Rings: Pure HABITS (Left) + Pure TO-DO (Right, taps to Focus)
                HStack(spacing: 14) {
                    // Left Primary Ring: Pure Habits-Only %
                    VStack(spacing: 6) {
                        ZStack {
                            OrganicBreathingAura(color: habitsRingColor, diameter: 158)
                            AmbientBloomRing(
                                progress: Double(summary.habitsPercent) / 100.0,
                                color: habitsRingColor,
                                lineWidth: 12,
                                diameter: 128
                            )

                            VStack(spacing: 1) {
                                Text("\(summary.habitsPercent)%")
                                    .font(.system(size: 32, weight: .black, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(ProMotionSpring.ringFill, value: summary.habitsPercent)
                                    .foregroundStyle(.white)
                                Text("\(summary.habitsCompleted) / \(summary.habitsTotal)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(habitsRingColor)
                            }
                        }
                        Text("HABITS")
                            .font(.system(size: 10.5, weight: .black, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                    .frame(maxWidth: .infinity)

                    // Right Companion Ring: Pure To-Do / Calendar % (tapping jumps straight to Focus tab!)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onTapTodoRing()
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                OrganicBreathingAura(color: todoRingColor, diameter: 144)
                                AmbientBloomRing(
                                    progress: Double(summary.todoPercent) / 100.0,
                                    color: todoRingColor,
                                    lineWidth: 11,
                                    diameter: 120
                                )

                                VStack(spacing: 1) {
                                    Text("\(summary.todoPercent)%")
                                        .font(.system(size: 30, weight: .black, design: .rounded))
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                        .animation(ProMotionSpring.ringFill, value: summary.todoPercent)
                                        .foregroundStyle(.white)
                                    Text("\(summary.todoCompleted) / \(summary.todoTotal)")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(todoRingColor)
                                }
                            }
                            HStack(spacing: 3) {
                                Text("TO-DO")
                                    .font(.system(size: 10.5, weight: .black, design: .rounded))
                                    .tracking(1.2)
                                    .foregroundStyle(todoRingColor)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8.5, weight: .black))
                                    .foregroundStyle(todoRingColor.opacity(0.85))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MidnightPressButtonStyle())
                }
                .padding(.vertical, 2)
                .transition(.midnightReveal)

                Text(summary.headline)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                // 2 x 2 Bento Micro-Tiles (HABITS | TO-DO | STREAK | FOCUSED)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    scoreBentoTile(title: "HABITS", value: "\(summary.habitsCompleted) / \(summary.habitsTotal)")
                    scoreBentoTile(title: "TO-DO", value: "\(summary.todoCompleted) / \(summary.todoTotal)")
                    scoreBentoTile(title: "STREAK", value: summary.globalStreak == 1 ? "1 day" : "\(summary.globalStreak) days")
                    scoreBentoTile(title: "FOCUSED", value: "\(summary.focusMinutesToday) min")
                }
            }
        }
        .padding(16)
        .ambientCard(accent: habitsRingColor, cornerRadius: 24, washOpacity: 0.08)
        .midnightShimmer(trigger: score100Trigger, color: habitsRingColor)
        .onChange(of: summary.habitsPercent) { oldVal, newVal in
            if newVal == 100 && oldVal < 100 {
                score100Trigger += 1
            }
        }
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
    var spotlightAccent: Color? = nil
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
                    HStack(spacing: 6) {
                        Text(habit.title)
                            .font(.system(size: spotlightAccent != nil ? 17 : 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let spot = spotlightAccent {
                            Text(habit.timeOfDay == .morning ? "☀️ NOW" : "🌙 TONIGHT")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(spot)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(spot.opacity(0.18), in: Capsule())
                        }
                    }

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
        .padding(spotlightAccent != nil ? 18 : 16)
        .ambientCard(
            accent: spotlightAccent ?? accent,
            cornerRadius: 22,
            washOpacity: spotlightAccent != nil ? 0.15 : 0.09
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(spotlightAccent?.opacity(0.60) ?? Color.clear, lineWidth: spotlightAccent != nil ? 1.5 : 0)
        )
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: spotlightAccent != nil)
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
