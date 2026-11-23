import SwiftUI
import SwiftData
import EventKit
import Combine

// MARK: - Live Shared Deep Work Timer Controller (Persists When Minimized to Focus Pill Banner)

@MainActor
final class DeepWorkTimerController: ObservableObject {
    static let shared = DeepWorkTimerController()

    @Published var isRunning: Bool = false
    @Published var isPaused: Bool = false
    @Published var sessionTitle: String = "DEEP WORK"
    @Published var cueSubtitle: String = ""
    @Published var totalMinutes: Int = 45
    @Published var remainingSeconds: Int = 45 * 60
    @Published var activeTaskID: UUID? = nil

    private var timerCancellable: AnyCancellable?

    private init() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    var totalSeconds: Int { max(60, totalMinutes * 60) }
    var elapsedSeconds: Int { max(0, totalSeconds - remainingSeconds) }
    var isActive: Bool { isRunning || isPaused }

    var progressFraction: Double {
        guard totalSeconds > 0 else { return 1.0 }
        if !isActive { return 1.0 }
        return Double(max(0, remainingSeconds)) / Double(totalSeconds)
    }

    var formattedCountdown: String {
        let clamped = max(0, remainingSeconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    func prepare(title: String = "DEEP WORK", minutes: Int = 45, cue: String = "", taskID: UUID? = nil, autoStart: Bool = false) {
        let clamped = max(5, min(240, minutes))
        sessionTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "DEEP WORK" : title
        totalMinutes = clamped
        remainingSeconds = clamped * 60
        if !cue.isEmpty { cueSubtitle = cue }
        activeTaskID = taskID
        isRunning = autoStart
        isPaused = false
        if autoStart {
            FocusLiveActivityManager.shared.start(
                taskTitle: sessionTitle,
                focusCue: cueSubtitle,
                durationSeconds: remainingSeconds
            )
        } else {
            FocusLiveActivityManager.shared.endAll()
        }
    }

    func start() {
        if remainingSeconds <= 0 {
            remainingSeconds = totalMinutes * 60
        }
        isRunning = true
        isPaused = false
        FocusLiveActivityManager.shared.start(
            taskTitle: sessionTitle,
            focusCue: cueSubtitle,
            durationSeconds: remainingSeconds
        )
    }

    func togglePause() {
        guard isActive else {
            start()
            return
        }
        isPaused.toggle()
        isRunning = !isPaused
        FocusLiveActivityManager.shared.update(
            isPaused: isPaused,
            remainingSeconds: remainingSeconds,
            totalDurationSeconds: totalSeconds
        )
    }

    @discardableResult
    func finishAndLog() -> Int {
        let logged = elapsedSeconds >= 60 ? max(1, elapsedSeconds / 60) : 0
        isRunning = false
        isPaused = false
        remainingSeconds = totalMinutes * 60
        FocusLiveActivityManager.shared.endAll()

        if logged > 0 {
            HabitMetricsEngine.addFocusMinutesToday(logged)
            HabitMetricsEngine.incrementFocusSessionsToday()
            WidgetSyncCoordinator.syncSnapshotFromStore()
            Task { await DailyNotificationManager.shared.refreshScheduledNotifications() }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        return logged
    }

    private func tick() {
        guard isRunning && !isPaused else { return }
        if remainingSeconds > 1 {
            remainingSeconds -= 1
        } else {
            remainingSeconds = 0
            let mins = totalMinutes
            isRunning = false
            isPaused = false
            FocusLiveActivityManager.shared.endAll()
            HabitMetricsEngine.addFocusMinutesToday(mins)
            HabitMetricsEngine.incrementFocusSessionsToday()
            WidgetSyncCoordinator.syncSnapshotFromStore()
            Task { await DailyNotificationManager.shared.refreshScheduledNotifications() }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

// MARK: - Tab 3: Task-First Day Slider & Week Overview Focus Hub

struct FocusTabView: View {
    private enum FocusViewMode: String, CaseIterable {
        case day = "Day"
        case week = "Week"
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\FocusTaskItem.createdAt, order: .forward)])
    private var allTasks: [FocusTaskItem]

    @ObservedObject private var focusManager = FocusAccountabilityManager.shared
    @ObservedObject private var timerController = DeepWorkTimerController.shared
    @ObservedObject private var photoProofScheduler = PhotoProofScheduler.shared
    @ObservedObject private var calendarCompletions = CalendarEventCompletionStore.shared

    @State private var viewMode: FocusViewMode = .day
    @State private var selectedDate: Date = ISOWeekCalendar.current.startOfDay(for: Date())
    @State private var weekAnchorDate: Date = ISOWeekCalendar.startOfMondayWeek(for: Date())

    // Sheets
    @State private var showingNewTaskSheet: Bool = false
    @State private var newTaskInitialDate: Date = Date()
    @State private var editingTask: FocusTaskItem? = nil
    @State private var showingDeepWorkSheet: Bool = false

    private var cal: Calendar { ISOWeekCalendar.current }

    private var selectedDayKey: String {
        HabitItem.dateKey(for: selectedDate)
    }

    private var isViewingToday: Bool {
        cal.isDateInToday(selectedDate)
    }

    private var currentWeekDates: [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekAnchorDate) }
    }

    private var weekRangeLabel: String {
        guard let first = currentWeekDates.first, let last = currentWeekDates.last else { return "" }
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone.current
        f.dateFormat = "d MMM"
        return "\(f.string(from: first)) – \(f.string(from: last))"
    }

    private func tasks(for date: Date) -> [FocusTaskItem] {
        let key = HabitItem.dateKey(for: date)
        return allTasks
            .filter { $0.dayKey == key }
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted {
                    return !lhs.isCompleted // Pending first, completed below
                }
                if lhs.sortMinutesOfDay != rhs.sortMinutesOfDay {
                    return lhs.sortMinutesOfDay < rhs.sortMinutesOfDay
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private func syncedBlocks(for date: Date) -> [FocusBlockDisplayItem] {
        let _ = calendarCompletions.revision
        let key = HabitItem.dateKey(for: date)
        let linkedIDs = Set(allTasks.compactMap(\.googleCalendarEventID).filter { !$0.isEmpty })
        return focusManager.upcomingBlocks
            .filter { block in
                guard block.dayKey == key else { return false }
                if let remoteID = block.remoteEventID, linkedIDs.contains(remoteID) {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                let lDone = calendarCompletions.isCompleted(lhs)
                let rDone = calendarCompletions.isCompleted(rhs)
                if lDone != rDone { return !lDone }
                return lhs.startDate < rhs.startDate
            }
    }

    private func scheduledMinutes(for date: Date) -> Int {
        let taskMins = tasks(for: date).reduce(0) { $0 + $1.durationMinutes }
        let syncedMins = syncedBlocks(for: date).reduce(0) { $0 + Int(round($1.durationMinutes)) }
        return taskMins + syncedMins
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DailyOSTheme.canvas.ignoresSafeArea()

                VStack(spacing: 12) {
                    // 1. Top Header: Focus + Day|Week Switcher + Timer + Add
                    topHeaderBar
                        .padding(.horizontal, 18)
                        .padding(.top, 6)

                    // 2. Pinned Active Deep Work Focus Pill Banner (only when timer is running/paused)
                    if timerController.isActive {
                        activeTimerPillBanner
                            .padding(.horizontal, 18)
                            .transition(.midnightReveal)
                    }

                    // 3. Main Content: Day View vs Week Overview
                    if viewMode == .day {
                        dayModeContent
                            .transition(.midnightReveal)
                    } else {
                        weekModeContent
                            .transition(.midnightReveal)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                Task { await focusManager.syncAllSources() }
            }
            .sheet(isPresented: $showingNewTaskSheet) {
                FocusTaskEditorSheet(existingTask: nil, initialDate: newTaskInitialDate)
            }
            .sheet(item: $editingTask) { task in
                FocusTaskEditorSheet(existingTask: task, initialDate: HabitItem.date(from: task.dayKey) ?? selectedDate)
            }
            .fullScreenCover(isPresented: $showingDeepWorkSheet) {
                DeepWorkRingFullScreenView(timerController: timerController)
            }
        }
    }

    // MARK: - Top Bar: Focus + Day|Week Switcher + Timer + Add

    private var topHeaderBar: some View {
        HStack(spacing: 10) {
            Text("Focus")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)

            Spacer(minLength: 4)

            // Compact Day | Week Segmented Pill
            HStack(spacing: 2) {
                ForEach(FocusViewMode.allCases, id: \.self) { mode in
                    let active = viewMode == mode
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            viewMode = mode
                        }
                        Task { await focusManager.syncAllSources() }
                    } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(active ? Color.black : DailyOSTheme.eyebrow)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(active ? Color.white : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(DailyOSTheme.buttonSurface, in: Capsule())
            .overlay(Capsule().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))

            // Quick-Launch Deep Work Timer Button
            FrostedCircleButton(
                icon: "timer",
                size: 36,
                tint: timerController.isActive ? DailyOSTheme.emerald : DailyOSTheme.skyGlow
            ) {
                showingDeepWorkSheet = true
            }

            // Quick Add Task Button
            FrostedCircleButton(icon: "plus", size: 36) {
                newTaskInitialDate = selectedDate
                showingNewTaskSheet = true
            }
        }
    }

    // MARK: - Pinned Active Deep Work Banner

    private var activeTimerPillBanner: some View {
        Button {
            showingDeepWorkSheet = true
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(timerController.isPaused ? DailyOSTheme.solarAccent : DailyOSTheme.skyGlow)
                    .frame(width: 9, height: 9)
                    .shadow(color: DailyOSTheme.skyGlow.opacity(0.75), radius: 5)

                VStack(alignment: .leading, spacing: 1) {
                    Text(timerController.sessionTitle.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.0)
                        .foregroundStyle(DailyOSTheme.eyebrow)
                        .lineLimit(1)
                    Text(timerController.isPaused ? "Paused • Tap to expand" : "Deep Work Active • Tap to expand")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.88))
                }

                Spacer()

                Text(timerController.formattedCountdown)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DailyOSTheme.skyGlow)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    timerController.togglePause()
                } label: {
                    Image(systemName: timerController.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: 30, height: 30)
                        .background(DailyOSTheme.skyGlow, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .ambientCard(accent: DailyOSTheme.skyGlow, cornerRadius: 18, washOpacity: 0.14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - DAY VIEW (Monday-First 7-Day Slider + Priority Tasks List)

    private var dayModeContent: some View {
        let dayTasks = tasks(for: selectedDate)
        let daySynced = syncedBlocks(for: selectedDate)

        return VStack(spacing: 12) {
            // 1. Monday-First 7-Day ISO-8601 Week Slider
            weekSliderCard
                .padding(.horizontal, 18)

            // 2. Active Calendar Accountability Banner (if live right now)
            if let active = focusManager.activeFocusBlock {
                activeAccountabilityBanner(active)
                    .padding(.horizontal, 18)
            }

            // 3. Priority To-Do Tasks & Time Blocks (List with native Swipe Actions & Pull-to-Refresh)
            if dayTasks.isEmpty && daySynced.isEmpty {
                ScrollView(showsIndicators: false) {
                    emptyDayCard
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                }
                .refreshable {
                    await focusManager.syncAllSources()
                }
            } else {
                List {
                    if !dayTasks.isEmpty {
                        Section {
                            ForEach(dayTasks) { task in
                                let _ = photoProofScheduler.logRevision
                                FocusTaskCardRow(
                                    task: task,
                                    proofRecord: PhotoProofLogStore.record(for: task.id.uuidString),
                                    onToggleComplete: {
                                        toggleTaskCompletion(task)
                                    },
                                    onTapEdit: {
                                        editingTask = task
                                    },
                                    onTogglePhotoProof: {
                                        togglePhotoProof(for: task)
                                    },
                                    onPlayTimer: {
                                        launchTimer(for: task)
                                    }
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        moveTaskToTomorrow(task)
                                    } label: {
                                        Label("Tomorrow", systemImage: "arrow.right.circle")
                                    }
                                    .tint(DailyOSTheme.skyGlow)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteTask(task)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(dayHeaderTitle(for: selectedDate))
                                    .eyebrowStyle()
                                Spacer()
                                let mins = scheduledMinutes(for: selectedDate)
                                if mins > 0 {
                                    Text(formatScheduledHours(mins))
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(DailyOSTheme.skyGlow)
                                }
                            }
                            .textCase(nil)
                            .padding(.horizontal, 2)
                        }
                    }

                    if !daySynced.isEmpty {
                        Section {
                            ForEach(daySynced) { block in
                                let _ = photoProofScheduler.logRevision
                                let _ = calendarCompletions.revision
                                let calKey = CalendarPhotoProofStore.stableKey(for: block)
                                let completionKey = CalendarEventCompletionStore.eventKey(for: block)
                                let isOptedIn = CalendarPhotoProofStore.isEnabled(forKey: calKey)
                                let isDone = calendarCompletions.isCompleted(eventKey: completionKey)
                                SyncedFocusBlockRow(
                                    block: block,
                                    isCurrent: focusManager.activeFocusBlock?.id == block.id,
                                    isCompleted: isDone,
                                    isPhotoProofEnabled: isOptedIn,
                                    proofRecord: PhotoProofLogStore.record(for: calKey),
                                    onToggleComplete: {
                                        let nowDone = calendarCompletions.toggle(eventKey: completionKey, dayKey: block.dayKey)
                                        if nowDone {
                                            PhotoProofScheduler.shared.cancelProofs(for: calKey)
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        } else {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        }
                                    },
                                    onTogglePhotoProof: {
                                        toggleCalendarPhotoProof(for: block, key: calKey, currentlyEnabled: isOptedIn)
                                    },
                                    onPlayTimer: {
                                        let mins = max(15, Int(round(block.durationMinutes)))
                                        timerController.prepare(
                                            title: block.title,
                                            minutes: mins,
                                            cue: block.trimmedLocation.isEmpty ? block.notes : "at \(block.trimmedLocation)",
                                            autoStart: true
                                        )
                                        if isOptedIn {
                                            PhotoProofScheduler.shared.scheduleProofs(
                                                taskID: calKey,
                                                taskTitle: block.title,
                                                taskNotes: block.notes,
                                                taskStart: Date(),
                                                durationMinutes: mins,
                                                triggerInitialImmediatelyIfNow: true
                                            )
                                        }
                                        showingDeepWorkSheet = true
                                    }
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if let manualID = block.manualBlockID {
                                        Button(role: .destructive) {
                                            focusManager.deleteScheduledTask(id: manualID)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("CALENDAR & SYNCED BLOCKS")
                                .eyebrowStyle()
                                .textCase(nil)
                                .padding(.horizontal, 2)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await focusManager.syncAllSources()
                }
            }
        }
    }

    // MARK: - Interactive Monday-First Week Slider Card

    private var weekSliderCard: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    shiftWeek(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(DailyOSTheme.inputSurface, in: Circle())
                }
                .buttonStyle(.plain)

                Text(weekRangeLabel)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.leading, 4)

                Spacer()

                if !isViewingToday {
                    Button("Today") {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let today = cal.startOfDay(for: Date())
                        selectedDate = today
                        weekAnchorDate = ISOWeekCalendar.startOfMondayWeek(for: today)
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(DailyOSTheme.skyGlow, in: Capsule())
                    .buttonStyle(.plain)
                }

                Button {
                    shiftWeek(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(DailyOSTheme.inputSurface, in: Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                ForEach(currentWeekDates, id: \.self) { day in
                    let isSelected = cal.isDate(day, inSameDayAs: selectedDate)
                    let isToday = cal.isDateInToday(day)
                    let dayTasks = tasks(for: day)
                    let daySynced = syncedBlocks(for: day)
                    let totalCount = dayTasks.count + daySynced.count
                    let allTasksDone = dayTasks.allSatisfy(\.isCompleted)
                    let allSyncedDone = daySynced.allSatisfy { calendarCompletions.isCompleted($0) }
                    let allDone = totalCount > 0 && allTasksDone && allSyncedDone

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectedDate = day
                        Task { await focusManager.syncAllSources() }
                    } label: {
                        VStack(spacing: 4) {
                            Text(shortWeekdayLabel(day))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(isSelected ? DailyOSTheme.skyGlow : DailyOSTheme.eyebrow)

                            Text(dayNumberLabel(day))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? Color.white : (isToday ? DailyOSTheme.skyGlow : Color.white.opacity(0.85)))

                            HStack(spacing: 3) {
                                if totalCount > 0 {
                                    let dots = min(3, totalCount)
                                    ForEach(0..<dots, id: \.self) { _ in
                                        Circle()
                                            .fill(allDone ? DailyOSTheme.emerald : DailyOSTheme.skyGlow)
                                            .frame(width: 4.5, height: 4.5)
                                    }
                                } else {
                                    Circle()
                                        .fill(Color.clear)
                                        .frame(width: 4.5, height: 4.5)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            isSelected ? DailyOSTheme.inputSurface : Color.clear,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(
                                    isSelected ? DailyOSTheme.skyGlow : (isToday ? DailyOSTheme.skyGlow.opacity(0.32) : Color.clear),
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .ambientCard(cornerRadius: 22)
    }

    // MARK: - WEEK OVERVIEW MODE (Mon–Sun Open Day Scanner)

    private var weekModeContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                // Week Navigation Header
                HStack {
                    Button { shiftWeek(by: -1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 34, height: 34)
                            .background(DailyOSTheme.buttonSurface, in: Circle())
                            .overlay(Circle().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    VStack(spacing: 2) {
                        Text(weekRangeLabel)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                        Text("Tap a day to focus • Tap + to drop a task")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }

                    Spacer()

                    Button { shiftWeek(by: 1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 34, height: 34)
                            .background(DailyOSTheme.buttonSurface, in: Circle())
                            .overlay(Circle().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)

                // 7-Day Monday-to-Sunday Overview Cards
                VStack(spacing: 10) {
                    ForEach(currentWeekDates, id: \.self) { day in
                        weekDayOverviewCard(for: day)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 32)
            }
        }
        .refreshable {
            await focusManager.syncAllSources()
        }
    }

    private func weekDayOverviewCard(for day: Date) -> some View {
        let dayTasks = tasks(for: day)
        let daySynced = syncedBlocks(for: day)
        let mins = scheduledMinutes(for: day)
        let isToday = cal.isDateInToday(day)
        let isOpenDay = dayTasks.isEmpty && daySynced.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedDate = day
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        viewMode = .day
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(weekDayCardHeader(day))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(isToday ? DailyOSTheme.skyGlow : Color.white)

                        if isToday {
                            Text("TODAY")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DailyOSTheme.skyGlow, in: Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // Scheduled Hours or "Open" Badge
                Text(isOpenDay ? "Open" : "\(formatScheduledHours(mins)) scheduled")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isOpenDay ? DailyOSTheme.emerald : DailyOSTheme.skyGlow)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        (isOpenDay ? DailyOSTheme.emerald : DailyOSTheme.skyGlow).opacity(0.14),
                        in: Capsule()
                    )

                // Inline + Button to Drop a Task Straight onto This Day
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedDate = day
                    newTaskInitialDate = day
                    showingNewTaskSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 28, height: 28)
                        .background(DailyOSTheme.buttonSurface, in: Circle())
                        .overlay(Circle().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            // Compact 1-Line Task & Block Previews
            if !isOpenDay {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dayTasks) { task in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(task.isCompleted ? DailyOSTheme.emerald : DailyOSTheme.skyGlow)
                                .frame(width: 6, height: 6)
                            Text(task.formattedCompactPrefix)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(DailyOSTheme.eyebrow)
                            Text("— \(task.title)\(task.trimmedLocation.isEmpty ? "" : " · \(task.trimmedLocation)")")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .strikethrough(task.isCompleted, color: DailyOSTheme.eyebrow)
                                .foregroundStyle(task.isCompleted ? DailyOSTheme.eyebrow : Color.white.opacity(0.9))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }

                    ForEach(daySynced) { block in
                        let isBlockDone = calendarCompletions.isCompleted(block)
                        HStack(spacing: 8) {
                            Circle()
                                .fill(isBlockDone ? DailyOSTheme.emerald : DailyOSTheme.indigoGlow)
                                .frame(width: 6, height: 6)
                            Text(block.formattedTimeAndDuration)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(DailyOSTheme.eyebrow)
                            Text("— \(block.title)\(block.trimmedLocation.isEmpty ? "" : " · \(block.trimmedLocation)")")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .strikethrough(isBlockDone, color: DailyOSTheme.eyebrow)
                                .foregroundStyle(isBlockDone ? DailyOSTheme.eyebrow : Color.white.opacity(0.88))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(14)
        .ambientCard(accent: isToday ? DailyOSTheme.skyGlow : nil, cornerRadius: 18, washOpacity: 0.08)
    }

    // MARK: - Empty Day Card & Active Accountability Banner

    private var emptyDayCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(DailyOSTheme.skyGlow)
                .frame(width: 56, height: 56)
                .background(DailyOSTheme.skyGlow.opacity(0.14), in: Circle())

            Text("Clear Schedule for \(dayShortTitle(for: selectedDate))")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)

            Text("Add a task with duration & place, or tap the timer icon to launch a Deep Work session.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DailyOSTheme.eyebrow)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)

            HStack(spacing: 10) {
                Button {
                    newTaskInitialDate = selectedDate
                    showingNewTaskSheet = true
                } label: {
                    Label("Add Task", systemImage: "plus")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(DailyOSTheme.skyGlow, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    showingDeepWorkSheet = true
                } label: {
                    Label("Deep Work", systemImage: "timer")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(DailyOSTheme.buttonSurface, in: Capsule())
                        .overlay(Capsule().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .ambientCard(accent: DailyOSTheme.skyGlow, cornerRadius: 22, washOpacity: 0.06)
    }

    private func activeAccountabilityBanner(_ block: FocusBlockDisplayItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(focusManager.checkInPhaseLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(focusManager.isCurrentBlockCleared ? DailyOSTheme.emerald : DailyOSTheme.solarAccent)
            }
            Spacer()
            if !focusManager.isCurrentBlockCleared {
                Button {
                    focusManager.openVoluntaryProofCapture(for: block)
                } label: {
                    Label("Proof", systemImage: "camera.fill")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(DailyOSTheme.solarAccent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .ambientCard(
            accent: focusManager.isCurrentBlockCleared ? DailyOSTheme.emerald : DailyOSTheme.solarAccent,
            cornerRadius: 16,
            washOpacity: 0.10
        )
    }

    // MARK: - Task Actions

    private func toggleTaskCompletion(_ task: FocusTaskItem) {
        task.isCompleted.toggle()
        if task.isCompleted {
            PhotoProofScheduler.shared.cancelProofs(for: task.id.uuidString)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        try? modelContext.save()
        SharedModelContainer.shared.save()
    }

    private func togglePhotoProof(for task: FocusTaskItem) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        task.requiresPhotoProof.toggle()
        try? modelContext.save()
        SharedModelContainer.shared.save()

        let taskID = task.id.uuidString
        if task.requiresPhotoProof {
            if let scheduledStart = task.startTime {
                PhotoProofScheduler.shared.scheduleProofs(
                    taskID: taskID,
                    taskTitle: task.title,
                    taskNotes: task.notes,
                    taskStart: scheduledStart,
                    durationMinutes: task.durationMinutes
                )
            } else {
                PhotoProofLogStore.markArmed(taskID: taskID)
                photoProofScheduler.logRevision += 1
            }
        } else {
            PhotoProofScheduler.shared.cancelProofs(for: taskID)
            PhotoProofLogStore.clearRecord(for: taskID)
            photoProofScheduler.logRevision += 1
        }
    }

    private func toggleCalendarPhotoProof(for block: FocusBlockDisplayItem, key: String, currentlyEnabled: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let next = !currentlyEnabled
        CalendarPhotoProofStore.setEnabled(next, forKey: key)
        if next {
            PhotoProofScheduler.shared.scheduleProofs(
                taskID: key,
                taskTitle: block.title,
                taskNotes: block.notes,
                taskStart: block.startDate,
                durationMinutes: max(5, Int(round(block.durationMinutes)))
            )
        } else {
            PhotoProofScheduler.shared.cancelProofs(for: key)
            PhotoProofLogStore.clearRecord(for: key)
            photoProofScheduler.logRevision += 1
        }
    }

    private func moveTaskToTomorrow(_ task: FocusTaskItem) {
        let base = HabitItem.date(from: task.dayKey) ?? selectedDate
        if let nextDay = cal.date(byAdding: .day, value: 1, to: base) {
            task.dayKey = HabitItem.dateKey(for: nextDay)
            if let oldStart = task.startTime,
               let shiftedStart = cal.date(byAdding: .day, value: 1, to: oldStart) {
                task.startTime = shiftedStart
                if task.requiresPhotoProof {
                    PhotoProofScheduler.shared.scheduleProofs(
                        taskID: task.id.uuidString,
                        taskTitle: task.title,
                        taskNotes: task.notes,
                        taskStart: shiftedStart,
                        durationMinutes: task.durationMinutes
                    )
                }
            }
            try? modelContext.save()
            SharedModelContainer.shared.save()
            if task.syncToGoogleCalendar {
                Task { await GoogleCalendarService.pushTask(task) }
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func deleteTask(_ task: FocusTaskItem) {
        let linkedEventID = task.googleCalendarEventID
        PhotoProofScheduler.shared.cancelProofs(for: task.id.uuidString)
        PhotoProofLogStore.clearRecord(for: task.id.uuidString)
        modelContext.delete(task)
        try? modelContext.save()
        SharedModelContainer.shared.save()
        if let linkedEventID {
            Task { await GoogleCalendarService.deleteLinkedEvent(eventID: linkedEventID) }
        }
    }

    private func launchTimer(for task: FocusTaskItem) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let cue = task.trimmedLocation.isEmpty ? task.trimmedNotes : "at \(task.trimmedLocation)"
        timerController.prepare(
            title: task.title,
            minutes: task.durationMinutes,
            cue: cue,
            taskID: task.id,
            autoStart: true
        )
        if task.requiresPhotoProof {
            PhotoProofScheduler.shared.scheduleProofs(
                taskID: task.id.uuidString,
                taskTitle: task.title,
                taskNotes: task.notes,
                taskStart: Date(),
                durationMinutes: task.durationMinutes,
                triggerInitialImmediatelyIfNow: true
            )
        }
        showingDeepWorkSheet = true
    }

    private func shiftWeek(by weeks: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let shiftedAnchor = cal.date(byAdding: .day, value: weeks * 7, to: weekAnchorDate) {
            weekAnchorDate = shiftedAnchor
        }
        if let shiftedDay = cal.date(byAdding: .day, value: weeks * 7, to: selectedDate) {
            selectedDate = shiftedDay
        }
        Task { await focusManager.syncAllSources() }
    }

    // MARK: - Formatting Helpers (ISO-8601)

    private func shortWeekdayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func dayNumberLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone.current
        f.dateFormat = "d"
        return f.string(from: date)
    }

    private func dayHeaderTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone.current
        f.dateFormat = "EEEE, d MMM"
        if cal.isDateInToday(date) { return "TODAY • \(f.string(from: date).uppercased())" }
        if cal.isDateInTomorrow(date) { return "TOMORROW • \(f.string(from: date).uppercased())" }
        return f.string(from: date).uppercased()
    }

    private func dayShortTitle(for date: Date) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE, d MMM"
        return f.string(from: date)
    }

    private func weekDayCardHeader(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE d"
        return f.string(from: date)
    }

    private func formatScheduledHours(_ mins: Int) -> String {
        if mins < 60 { return "\(mins)m" }
        let hours = Double(mins) / 60.0
        if mins % 60 == 0 {
            return "\(mins / 60)h"
        }
        return String(format: "%.1fh", hours)
    }
}

// MARK: - Glanceable Focus Task Card Row

private struct FocusTaskCardRow: View {
    let task: FocusTaskItem
    let proofRecord: PhotoProofTaskRecord?
    let onToggleComplete: () -> Void
    let onTapEdit: () -> Void
    let onTogglePhotoProof: () -> Void
    let onPlayTimer: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            // Left: One-Tap Completion Check Circle
            Button(action: onToggleComplete) {
                ZStack {
                    Circle()
                        .fill(task.isCompleted ? DailyOSTheme.emerald : Color.clear)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(task.isCompleted ? DailyOSTheme.emerald : Color.white.opacity(0.28), lineWidth: 2)
                        )
                    if task.isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(DailyOSTheme.canvas)
                    }
                }
            }
            .buttonStyle(MidnightPressStyle())

            // Center: Bold Title + Time/Duration Pill + Place Pill + Proof Status Chip
            Button(action: onTapEdit) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .strikethrough(task.isCompleted, color: DailyOSTheme.eyebrow)
                        .foregroundStyle(task.isCompleted ? DailyOSTheme.eyebrow : Color.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: task.startTime != nil ? "clock" : "hourglass")
                                .font(.system(size: 10, weight: .bold))
                            Text(task.formattedTimeRangeAndDuration)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundStyle(task.isCompleted ? DailyOSTheme.eyebrow : DailyOSTheme.skyGlow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            (task.isCompleted ? DailyOSTheme.eyebrow : DailyOSTheme.skyGlow).opacity(0.14),
                            in: Capsule()
                        )

                        if !task.trimmedLocation.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.system(size: 10, weight: .bold))
                                Text(task.trimmedLocation)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color.white.opacity(task.isCompleted ? 0.45 : 0.82))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(DailyOSTheme.inputSurface, in: Capsule())
                            .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))
                        }

                        if task.requiresPhotoProof {
                            PhotoProofStatusBadge(record: proofRecord)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Right: 1-Tap Camera Proof Toggle Pill + Compact Circular Play Button
            HStack(spacing: 7) {
                Button(action: onTogglePhotoProof) {
                    Image(systemName: task.requiresPhotoProof ? "camera.fill" : "camera")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(task.requiresPhotoProof ? DailyOSTheme.emerald : DailyOSTheme.eyebrow)
                        .frame(width: 32, height: 32)
                        .background(
                            task.requiresPhotoProof ? DailyOSTheme.emerald.opacity(0.16) : DailyOSTheme.inputSurface,
                            in: Circle()
                        )
                        .overlay(
                            Circle().stroke(
                                task.requiresPhotoProof ? DailyOSTheme.emerald.opacity(0.45) : DailyOSTheme.hairline,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(MidnightPressStyle())
                .accessibilityLabel(task.requiresPhotoProof ? "Disable Photo Proof" : "Enable Photo Proof")

                Button(action: onPlayTimer) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(task.isCompleted ? DailyOSTheme.eyebrow : DailyOSTheme.skyGlow)
                        .frame(width: 34, height: 34)
                        .background(
                            (task.isCompleted ? DailyOSTheme.inputSurface : DailyOSTheme.skyGlow.opacity(0.16)),
                            in: Circle()
                        )
                        .overlay(Circle().stroke(task.isCompleted ? DailyOSTheme.hairline : DailyOSTheme.skyGlow.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(MidnightPressStyle())
            }
        }
        .padding(14)
        .ambientCard(
            accent: task.isCompleted ? DailyOSTheme.emerald : (task.requiresPhotoProof ? DailyOSTheme.skyGlow : nil),
            cornerRadius: 18,
            washOpacity: 0.06
        )
    }
}

private struct PhotoProofStatusBadge: View {
    let record: PhotoProofTaskRecord?

    var body: some View {
        let status = record?.lastStatus ?? .armed
        let label: String = {
            switch status {
            case .verified: return "Verified ✓"
            case .missed: return "Missed ✕"
            case .armed: return "Proof Armed"
            }
        }()
        let tint: Color = {
            switch status {
            case .verified: return DailyOSTheme.emerald
            case .missed: return Color(hex: "#FF6B6B")
            case .armed: return DailyOSTheme.indigoGlow
            }
        }()

        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Native Checkable Synced Calendar / Google Tasks Row

private struct SyncedFocusBlockRow: View {
    let block: FocusBlockDisplayItem
    let isCurrent: Bool
    let isCompleted: Bool
    let isPhotoProofEnabled: Bool
    let proofRecord: PhotoProofTaskRecord?
    let onToggleComplete: () -> Void
    let onTogglePhotoProof: () -> Void
    let onPlayTimer: () -> Void

    private var sourceColor: Color {
        switch block.source {
        case .googleCalendar: return DailyOSTheme.skyGlow
        case .googleTasks: return DailyOSTheme.indigoGlow
        case .appleCalendar: return DailyOSTheme.periwinkle
        case .local: return Color(hex: "#2DD4BF")
        }
    }

    private var compactSourceTag: String {
        switch block.source {
        case .googleCalendar: return "Google Cal"
        case .googleTasks: return "Google Tasks"
        case .appleCalendar: return "Apple Cal"
        case .local: return "Focus"
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            // Left: 1-Tap Circular Completion Checkbox (matches FocusTaskCardRow)
            Button(action: onToggleComplete) {
                ZStack {
                    Circle()
                        .fill(isCompleted ? DailyOSTheme.emerald : Color.clear)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(isCompleted ? DailyOSTheme.emerald : Color.white.opacity(0.28), lineWidth: 2)
                        )
                    if isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(DailyOSTheme.canvas)
                    }
                }
            }
            .buttonStyle(MidnightPressStyle())

            // Center: Bold Event Title + Time/Duration Pill + Optional Location Pill + Muted Source Badge
            VStack(alignment: .leading, spacing: 6) {
                Text(block.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .strikethrough(isCompleted, color: DailyOSTheme.eyebrow)
                    .foregroundStyle(isCompleted ? DailyOSTheme.eyebrow : Color.white)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    // Time & Duration Pill
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10, weight: .bold))
                        Text(block.formattedTimeAndDuration)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(isCompleted ? DailyOSTheme.eyebrow : sourceColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (isCompleted ? DailyOSTheme.eyebrow : sourceColor).opacity(0.14),
                        in: Capsule()
                    )

                    // Optional Location Pill
                    if !block.trimmedLocation.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 10, weight: .bold))
                            Text(block.trimmedLocation)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color.white.opacity(isCompleted ? 0.45 : 0.82))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DailyOSTheme.inputSurface, in: Capsule())
                        .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))
                    }

                    // Subtle Muted Source Tag
                    Text(compactSourceTag)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DailyOSTheme.inputSurface, in: Capsule())
                        .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))

                    if isPhotoProofEnabled {
                        PhotoProofStatusBadge(record: proofRecord)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: Inline Camera Photo-Proof Toggle + Play Deep Work Timer Button
            HStack(spacing: 7) {
                Button(action: onTogglePhotoProof) {
                    Image(systemName: isPhotoProofEnabled ? "camera.fill" : "camera")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isPhotoProofEnabled ? DailyOSTheme.emerald : DailyOSTheme.eyebrow)
                        .frame(width: 32, height: 32)
                        .background(
                            isPhotoProofEnabled ? DailyOSTheme.emerald.opacity(0.16) : DailyOSTheme.inputSurface,
                            in: Circle()
                        )
                        .overlay(
                            Circle().stroke(
                                isPhotoProofEnabled ? DailyOSTheme.emerald.opacity(0.45) : DailyOSTheme.hairline,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(MidnightPressStyle())

                Button(action: onPlayTimer) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isCompleted ? DailyOSTheme.eyebrow : sourceColor)
                        .frame(width: 34, height: 34)
                        .background(
                            (isCompleted ? DailyOSTheme.inputSurface : sourceColor.opacity(0.15)),
                            in: Circle()
                        )
                }
                .buttonStyle(MidnightPressStyle())
            }
        }
        .padding(14)
        .ambientCard(
            accent: isCompleted ? DailyOSTheme.emerald : (isCurrent ? DailyOSTheme.emerald : (isPhotoProofEnabled ? DailyOSTheme.skyGlow : nil)),
            cornerRadius: 18,
            washOpacity: 0.08
        )
    }
}

// MARK: - Full-Screen Midnight Obsidian Glowing Deep Work Timer View

private struct DeepWorkRingFullScreenView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var timerController: DeepWorkTimerController
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared

    @State private var loggedBanner: String? = nil
    private let presets: [Int] = [15, 25, 45, 60, 90]

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            RadialGradient(
                colors: [DailyOSTheme.skyGlow.opacity(0.11), Color.clear],
                center: .center,
                startRadius: 40,
                endRadius: 270
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Bar (Minimize back to Focus Tab without stopping timer!)
                HStack {
                    FrostedCircleButton(icon: "chevron.down", size: 40) {
                        dismiss()
                    }
                    Spacer()
                    Text(timerController.isActive ? "Minimize anytime" : "Deep Work Timer")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                Spacer()

                // Iconic Glowing Ring + Countdown + Editable Cue
                ZStack {
                    AmbientBreathingGlow(
                        color: timerController.isPaused ? Color(hex: "#FFB020") : DailyOSTheme.skyGlow,
                        diameter: 310
                    )
                    AmbientBloomRing(
                        progress: timerController.progressFraction,
                        color: timerController.isPaused ? Color(hex: "#FFB020") : DailyOSTheme.skyGlow,
                        lineWidth: 14,
                        diameter: 264
                    )

                    VStack(spacing: 8) {
                        Text(timerController.sessionTitle.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(1.6)
                            .foregroundStyle(DailyOSTheme.eyebrow)
                            .lineLimit(1)
                            .frame(maxWidth: 185)

                        Text(timerController.formattedCountdown)
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .contentTransition(.numericText())

                        TextField(
                            "",
                            text: $timerController.cueSubtitle,
                            prompt: Text("phone in another room").foregroundStyle(Color.white.opacity(0.32))
                        )
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 180)
                    }
                }

                // Quick Duration Presets (when idle)
                if !timerController.isActive {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { mins in
                            let selected = timerController.totalMinutes == mins
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                timerController.prepare(
                                    title: timerController.sessionTitle,
                                    minutes: mins,
                                    cue: timerController.cueSubtitle,
                                    autoStart: false
                                )
                            } label: {
                                Text("\(mins)m")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.84))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(selected ? DailyOSTheme.skyGlow : DailyOSTheme.buttonSurface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 26)
                }

                if let loggedBanner {
                    Text(loggedBanner)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.emerald)
                        .padding(.top, 14)
                }

                Spacer()

                // Bottom Controls: Finish / Play-Pause / Optional Gemini Photo Proof
                HStack(spacing: 28) {
                    VStack(spacing: 8) {
                        FrostedCircleButton(icon: "checkmark", size: 54, tint: DailyOSTheme.emerald) {
                            let logged = timerController.finishAndLog()
                            if logged > 0 {
                                loggedBanner = "Logged \(logged)m Deep Work"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    dismiss()
                                }
                            } else {
                                dismiss()
                            }
                        }
                        Text("Finish")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }

                    VStack(spacing: 8) {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            timerController.togglePause()
                        } label: {
                            Image(systemName: (timerController.isRunning && !timerController.isPaused) ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Color.black)
                                .frame(width: 68, height: 68)
                                .background(DailyOSTheme.skyGlow, in: Circle())
                                .shadow(color: DailyOSTheme.skyGlow.opacity(0.35), radius: 14)
                        }
                        .buttonStyle(.plain)
                        Text((timerController.isRunning && !timerController.isPaused) ? "Pause" : (timerController.isPaused ? "Resume" : "Start"))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.8))
                    }

                    VStack(spacing: 8) {
                        FrostedCircleButton(icon: "camera.fill", size: 54, tint: DailyOSTheme.solarAccent) {
                            let title = timerController.sessionTitle
                            let cue = timerController.cueSubtitle
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                if let active = focusManager.activeFocusBlock {
                                    focusManager.openVoluntaryProofCapture(for: active)
                                } else {
                                    focusManager.activateFocusTaskAlarm(
                                        taskID: "deep_work_proof_\(Int(Date().timeIntervalSince1970))",
                                        taskTitle: title,
                                        taskNotes: cue.isEmpty ? "Deep work photo proof" : cue,
                                        taskSource: "Deep Work",
                                        evasionPenalty: false
                                    )
                                }
                            }
                        }
                        Text("Proof")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Non-Dismissible Full-Screen Task Check-In Alarm + Live Photo Proof Modal

struct FocusTaskAlarmFullScreenView: View {
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared
    @ObservedObject private var audioManager = AlarmAudioManager.shared
    @ObservedObject private var volumeController = SystemVolumeController.shared
    @StateObject private var cameraVM = LivePhotoCaptureViewModel()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: focusManager.isEvasionPenaltyActive
                    ? [Color(red: 0.40, green: 0.02, blue: 0.05), Color(red: 0.16, green: 0.01, blue: 0.02), DailyOSTheme.canvas]
                    : [Color(red: 0.12, green: 0.05, blue: 0.02), Color(red: 0.08, green: 0.04, blue: 0.12), DailyOSTheme.canvas],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if !focusManager.isCapturingPhotoProof {
                alarmRingingStageView
            } else {
                liveCameraProofStageView
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .onAppear {
            volumeController.ensureMountedInKeyWindow()
        }
    }

    private var alarmRingingStageView: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                Image(systemName: focusManager.isEvasionPenaltyActive ? "exclamationmark.shield.fill" : "speaker.wave.3.fill")
                    .foregroundStyle(focusManager.isEvasionPenaltyActive ? Color.red : Color.orange)
                Text(focusManager.isEvasionPenaltyActive
                     ? "EVASION PENALTY • 0% → 22% IN 10s"
                     : "TASK CHECK-IN ALARM • 1% → 22% IN 2m")
                    .font(.caption.weight(.black))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background((focusManager.isEvasionPenaltyActive ? Color.red : Color.orange).opacity(0.28), in: Capsule())
            .overlay(Capsule().stroke(focusManager.isEvasionPenaltyActive ? Color.red : Color.orange, lineWidth: 1.5))
            .padding(.top, 16)

            Spacer()

            VStack(spacing: 8) {
                Text(focusManager.activeAlarmSource.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DailyOSTheme.skyGlow)

                Text(focusManager.activeAlarmTitle.isEmpty ? "Scheduled Focus Task" : focusManager.activeAlarmTitle)
                    .font(.title.weight(.black))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white)

                if !focusManager.activeAlarmNotes.isEmpty {
                    Text(focusManager.activeAlarmNotes)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal)

            VStack(spacing: 10) {
                HStack {
                    Text("SYSTEM VOLUME (MAX 22%)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                    Spacer()
                    Text("\(Int(round(audioManager.focusWarningVolumeFraction * 100)))% (HW: \(Int(round(volumeController.currentHardwareVolume * 100)))%)")
                        .font(.subheadline.weight(.black).monospacedDigit())
                        .foregroundStyle(Color.red)
                }

                ProgressView(value: Double(min(0.22, audioManager.focusWarningVolumeFraction)), total: 0.22)
                    .tint(.red)

                Text("Hardware Volume-Down Lock Active • Submit live photo proof to stop alarm")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .ambientCard(cornerRadius: 18)
            .padding(.horizontal)

            if let feedback = focusManager.lastVerificationFeedback {
                Text(feedback)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            Button {
                focusManager.beginPhotoProofCaptureFromAlarm()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.title3)
                    Text("TAKE PROOF PHOTO (20s GRACE)")
                        .font(.headline.weight(.black))
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(DailyOSTheme.solarAccent, in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    private var liveCameraProofStageView: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                        Text("GRACE: \(focusManager.photoGraceSecondsRemaining)s")
                            .monospacedDigit()
                    }
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(focusManager.photoGraceSecondsRemaining <= 5 ? Color.red : DailyOSTheme.emerald)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        (focusManager.photoGraceSecondsRemaining <= 5 ? Color.red : DailyOSTheme.emerald).opacity(0.2),
                        in: Capsule()
                    )

                    Spacer()

                    if audioManager.isFocusWarningActive && !audioManager.isFocusWarningPaused {
                        Label("ALARM RINGING", systemImage: "speaker.wave.3.fill")
                            .font(.caption.weight(.black))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red, in: Capsule())
                    } else {
                        Label("ALARM PAUSED", systemImage: "speaker.slash.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DailyOSTheme.skyGlow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(DailyOSTheme.skyGlow.opacity(0.18), in: Capsule())
                    }
                }
                .padding(.horizontal)

                VStack(spacing: 2) {
                    Text(focusManager.activeAlarmTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                    Text("Live camera only — photo library disabled. Gemini 2.5 Flash verifies your task.")
                        .font(.caption)
                        .foregroundStyle(DailyOSTheme.eyebrow)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                if let feedback = focusManager.lastVerificationFeedback {
                    HStack(spacing: 8) {
                        if focusManager.isSubmittingToGemini {
                            ProgressView()
                                .tint(DailyOSTheme.skyGlow)
                        } else {
                            Image(systemName: focusManager.lastVerificationWasRejected ? "xmark.octagon.fill" : "checkmark.seal.fill")
                                .foregroundStyle(focusManager.lastVerificationWasRejected ? Color.red : DailyOSTheme.emerald)
                        }
                        Text(feedback)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(focusManager.lastVerificationWasRejected ? Color.red : Color.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        (focusManager.lastVerificationWasRejected ? Color.red : DailyOSTheme.skyGlow).opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .padding(.horizontal)
                }

                ZStack {
                    if let captured = cameraVM.capturedImage {
                        Image(uiImage: captured)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 380)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(DailyOSTheme.solarAccent, lineWidth: 2)
                            )
                    } else {
                        CameraPreviewView(session: cameraVM.captureSession)
                            .frame(maxWidth: .infinity, maxHeight: 380)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(DailyOSTheme.skyGlow.opacity(0.65), lineWidth: 2)
                            )
                    }
                }
                .padding(.horizontal)

                Spacer(minLength: 0)

                if let captured = cameraVM.capturedImage {
                    HStack(spacing: 12) {
                        Button {
                            cameraVM.retakePhoto()
                        } label: {
                            Label("Retake", systemImage: "arrow.counterclockwise")
                                .font(.headline)
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(DailyOSTheme.buttonSurface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(focusManager.isSubmittingToGemini)

                        Button {
                            Task {
                                await focusManager.submitLiveProofPhoto(captured)
                                if focusManager.lastVerificationWasRejected {
                                    cameraVM.retakePhoto()
                                }
                            }
                        } label: {
                            HStack {
                                if focusManager.isSubmittingToGemini {
                                    ProgressView()
                                        .tint(.black)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(focusManager.isSubmittingToGemini ? "Verifying..." : "Submit Proof")
                                    .font(.headline.weight(.bold))
                            }
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(DailyOSTheme.emerald, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(focusManager.isSubmittingToGemini)
                    }
                    .padding(.horizontal)
                } else {
                    HStack(spacing: 36) {
                        Color.clear.frame(width: 48, height: 48)

                        Button {
                            cameraVM.takeLivePhoto()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(Color.white, lineWidth: 4)
                                    .frame(width: 74, height: 74)
                                Circle()
                                    .fill(DailyOSTheme.solarAccent)
                                    .frame(width: 60, height: 60)
                                Image(systemName: "camera.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.black)
                            }
                        }
                        .disabled(cameraVM.isCapturing)

                        Button {
                            cameraVM.switchCamera()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.title3)
                                .foregroundStyle(Color.white)
                                .frame(width: 48, height: 48)
                                .background(DailyOSTheme.buttonSurface, in: Circle())
                        }
                    }
                }
            }
            .padding(.vertical)
            .background(DailyOSTheme.canvas.ignoresSafeArea())
            .navigationTitle("Live Task Proof")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        cameraVM.stopSession()
                        focusManager.returnFromCameraWithoutSubmitting()
                    }
                    .disabled(focusManager.isSubmittingToGemini)
                }
            }
            .onAppear {
                cameraVM.checkPermissionAndStart()
            }
            .onDisappear {
                cameraVM.stopSession()
            }
        }
    }
}

// MARK: - Optional Apple Calendar Filter Sheet (Opened from Settings → Connected Sources)

struct AppleCalendarFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Select Apple Calendars to Track") {
                    ForEach(focusManager.availableAppleCalendars) { cal in
                        let isSelected = focusManager.trackedAppleCalendarIDs.contains(cal.id)
                        Button {
                            focusManager.toggleAppleCalendarTracking(cal.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cal.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.white)
                                    Text(cal.sourceTitle)
                                        .font(.caption2)
                                        .foregroundStyle(DailyOSTheme.eyebrow)
                                }
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? DailyOSTheme.emerald : DailyOSTheme.eyebrow)
                            }
                        }
                        .listRowBackground(DailyOSTheme.card)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DailyOSTheme.canvas)
            .navigationTitle("Apple Calendars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
