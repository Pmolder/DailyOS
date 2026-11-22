import SwiftUI
import SwiftData
import EventKit
import Combine

struct FocusTabView: View {
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared
    @ObservedObject private var googleAuth = GoogleAuthService.shared
    @ObservedObject private var audioManager = AlarmAudioManager.shared

    @Query(sort: [SortDescriptor(\FocusCheckInLog.timestamp, order: .reverse)])
    private var checkInLogs: [FocusCheckInLog]

    var onOpenSettings: () -> Void = {}

    @State private var showingScheduleTaskSheet = false
    @State private var showingAppleCalendarFilterSheet = false
    @State private var selectedFilterDateKey: String? = nil // nil = All Upcoming

    // Deep Work Ring Timer Setup & Presentation
    @State private var selectedDeepWorkMinutes: Int = 25
    @State private var deepWorkCueNote: String = ""
    @State private var showingDeepWorkTimer: Bool = false
    @State private var loggedFocusMinutesToday: Int = HabitMetricsEngine.focusMinutesToday

    private let deepWorkPresets: [Int] = [25, 45, 60, 90]

    /// Next 14 days aligned cleanly starting from this week's Monday (ISO-8601).
    private var mondayStripDates: [Date] {
        let cal = ISOWeekCalendar.current
        let monday = ISOWeekCalendar.startOfMondayWeek(for: Date())
        return (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
    }

    private var filteredBlocks: [FocusBlockDisplayItem] {
        guard let selectedKey = selectedFilterDateKey else {
            return focusManager.upcomingBlocks
        }
        return focusManager.upcomingBlocks.filter { $0.dayKey == selectedKey }
    }

    private var groupedDays: [(dayKey: String, date: Date, blocks: [FocusBlockDisplayItem])] {
        let dict = Dictionary(grouping: filteredBlocks, by: \.dayKey)
        return dict.compactMap { key, items in
            guard let date = HabitItem.date(from: key) else { return nil }
            return (dayKey: key, date: date, blocks: items.sorted { $0.startDate < $1.startDate })
        }.sorted { $0.date < $1.date }
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
                        // 1. Top Header
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Focus")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white)
                                Text(formattedTodaySubtitle)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.eyebrow)
                            }

                            Spacer()

                            if loggedFocusMinutesToday > 0 {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(DailyOSTheme.skyGlow)
                                        .frame(width: 6, height: 6)
                                    Text("\(loggedFocusMinutesToday)m")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(Color.white)
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 38)
                                .background(DailyOSTheme.buttonSurface, in: Capsule())
                                .overlay(Capsule().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                            }

                            FrostedCircleButton(icon: "timer", size: 38, tint: DailyOSTheme.skyGlow) {
                                showingDeepWorkTimer = true
                            }

                            FrostedCircleButton(icon: "plus", size: 38) {
                                showingScheduleTaskSheet = true
                            }
                        }
                        .padding(.top, 6)

                        // 2. Hero Card: Active Scheduled Focus Block OR Deep Work Launcher
                        if let active = focusManager.activeFocusBlock {
                            activeFocusCard(active)
                        }
                        deepWorkLauncherCard

                        // 3. Connected Sources Card
                        connectedSourcesCard

                        // 4. ISO-8601 Monday-First Multi-Day Schedule Filter
                        mondayScheduleStripCard

                        // 5. Multi-Day Grouped Scheduled Tasks
                        if groupedDays.isEmpty {
                            emptyUpcomingTasksCard
                        } else {
                            ForEach(groupedDays, id: \.dayKey) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(sectionHeaderTitle(for: group.date))
                                        .eyebrowStyle()
                                        .padding(.horizontal, 4)

                                    VStack(spacing: 10) {
                                        ForEach(group.blocks) { block in
                                            FocusBlockCardRow(
                                                block: block,
                                                isCurrent: focusManager.activeFocusBlock?.id == block.id,
                                                onDelete: block.manualBlockID.map { manualID in
                                                    { focusManager.deleteScheduledTask(id: manualID) }
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        // 6. Recent AI Proof Check-In Logs
                        if !checkInLogs.isEmpty {
                            recentProofLogsCard
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                loggedFocusMinutesToday = HabitMetricsEngine.focusMinutesToday
                Task { await focusManager.syncAllSources() }
            }
            .sheet(isPresented: $showingScheduleTaskSheet) {
                AddScheduledTaskSheet()
            }
            .sheet(isPresented: $showingAppleCalendarFilterSheet) {
                AppleCalendarFilterSheet()
            }
            .fullScreenCover(isPresented: $showingDeepWorkTimer) {
                DeepWorkTimerFullScreenView(
                    sessionLabel: focusManager.activeFocusBlock?.title ?? "DEEP WORK",
                    durationMinutes: selectedDeepWorkMinutes,
                    cueSubtitle: deepWorkCueNote,
                    activeFocusBlock: focusManager.activeFocusBlock,
                    onLoggedMinutes: { mins in
                        if mins > 0 {
                            HabitMetricsEngine.addFocusMinutesToday(mins)
                            loggedFocusMinutesToday = HabitMetricsEngine.focusMinutesToday
                        }
                    }
                )
            }
        }
    }

    // MARK: - Hero Deep Work Launcher Card

    private var deepWorkLauncherCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    AmbientBloomRing(
                        progress: min(1.0, Double(loggedFocusMinutesToday) / 60.0),
                        color: DailyOSTheme.skyGlow,
                        lineWidth: 7,
                        diameter: 66
                    )
                    Text("\(selectedDeepWorkMinutes)m")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("DEEP WORK")
                        .eyebrowStyle()
                    Text("Ambient Focus Timer")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text("Distraction-free obsidian timer that feeds Today's Score.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            // Preset Duration Pills
            HStack(spacing: 8) {
                ForEach(deepWorkPresets, id: \.self) { mins in
                    let selected = selectedDeepWorkMinutes == mins
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectedDeepWorkMinutes = mins
                    } label: {
                        Text("\(mins)m")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                selected ? DailyOSTheme.skyGlow : DailyOSTheme.inputSurface,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(selected ? DailyOSTheme.skyGlow : DailyOSTheme.hairline, lineWidth: 1)
                            )
                            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Optional Focus Cue Field (empty default, placeholder only)
            HStack(spacing: 10) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DailyOSTheme.eyebrow)
                TextField(
                    "",
                    text: $deepWorkCueNote,
                    prompt: Text("phone in another room").foregroundStyle(Color.white.opacity(0.28))
                )
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(DailyOSTheme.hairline, lineWidth: 1)
            )

            // Primary Launch Pill
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showingDeepWorkTimer = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Start \(selectedDeepWorkMinutes)-Min Deep Work")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(DailyOSTheme.skyGlow, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .ambientCard(accent: DailyOSTheme.skyGlow, cornerRadius: 24, washOpacity: 0.10)
    }

    // MARK: - Active Scheduled Focus Block Card

    private func activeFocusCard(_ block: FocusBlockDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(focusManager.isCurrentBlockCleared ? DailyOSTheme.emerald : DailyOSTheme.solarAccent)
                        .frame(width: 7, height: 7)
                    Text(block.source.badgeTitle)
                        .eyebrowStyle()
                }
                Spacer()
                Text(block.timeRangeText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DailyOSTheme.eyebrow)
            }

            Text(block.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)

            Text(focusManager.checkInPhaseLabel)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(focusManager.isCurrentBlockCleared ? DailyOSTheme.emerald : DailyOSTheme.solarAccent)

            if !focusManager.isCurrentBlockCleared {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(focusManager.completedCheckInsForCurrentBlock == 0
                             ? "1ST PROOF DEADLINE (5M)"
                             : "NEXT 30-MIN PROOF")
                            .eyebrowStyle()
                        Text(formatCountdown(focusManager.secondsUntilCheckInDeadline))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(focusManager.secondsUntilCheckInDeadline <= 60 ? Color(hex: "#FF6B6B") : DailyOSTheme.emerald)
                    }

                    Spacer()

                    Button {
                        focusManager.openVoluntaryProofCapture(for: block)
                    } label: {
                        Label("Submit Proof", systemImage: "camera.fill")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(DailyOSTheme.solarAccent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let feedback = focusManager.lastVerificationFeedback {
                Text(feedback)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(focusManager.lastVerificationWasRejected ? Color(hex: "#FF6B6B") : DailyOSTheme.emerald)
            }
        }
        .padding(18)
        .ambientCard(
            accent: focusManager.isCurrentBlockCleared ? DailyOSTheme.emerald : DailyOSTheme.solarAccent,
            cornerRadius: 22,
            washOpacity: 0.11
        )
    }

    // MARK: - Connected Sources Card

    private var connectedSourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CONNECTED SOURCES")
                .eyebrowStyle()

            VStack(spacing: 12) {
                // Google Calendar & Tasks
                HStack(spacing: 12) {
                    sourceIconBadge("g.circle.fill", color: DailyOSTheme.skyGlow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Google Calendar & Tasks")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                        if let msg = focusManager.lastGoogleSyncMessage {
                            Text(msg)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(DailyOSTheme.eyebrow)
                                .lineLimit(1)
                        } else {
                            Text(googleAuth.isConnected ? "Auto-sync active" : "OAuth 2.0 + PKCE")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(DailyOSTheme.eyebrow)
                        }
                    }
                    Spacer()
                    if googleAuth.isConnected {
                        Button {
                            Task { await focusManager.syncAllSources() }
                        } label: {
                            Group {
                                if focusManager.isSyncingGoogle {
                                    ProgressView()
                                        .tint(DailyOSTheme.skyGlow)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(DailyOSTheme.skyGlow)
                                }
                            }
                            .frame(width: 34, height: 34)
                            .background(DailyOSTheme.buttonSurface, in: Circle())
                            .overlay(Circle().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button("Connect") {
                            onOpenSettings()
                        }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.solarAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(DailyOSTheme.solarAccent.opacity(0.14), in: Capsule())
                        .buttonStyle(.plain)
                    }
                }

                Divider().overlay(DailyOSTheme.hairline)

                // Apple Calendar (Optional)
                HStack(spacing: 12) {
                    sourceIconBadge("calendar", color: Color(hex: "#A78BFA"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Calendar (Optional)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                        Text(focusManager.appleCalendarSyncEnabled && focusManager.isAppleCalendarAuthorized
                             ? "\(focusManager.trackedAppleCalendarIDs.count) tracked calendars"
                             : "Optional EventKit source")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                    Spacer()
                    if focusManager.appleCalendarSyncEnabled && focusManager.isAppleCalendarAuthorized {
                        Button("Filter") {
                            showingAppleCalendarFilterSheet = true
                        }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.skyGlow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
                        .buttonStyle(.plain)
                    } else {
                        Button("Configure") {
                            onOpenSettings()
                        }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(DailyOSTheme.buttonSurface, in: Capsule())
                        .buttonStyle(.plain)
                    }
                }

                Divider().overlay(DailyOSTheme.hairline)

                // Gemini 2.5 Flash AI Verifier
                HStack(spacing: 12) {
                    sourceIconBadge("sparkles", color: DailyOSTheme.emerald)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Photo Proof Verifier")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                        Text("Live camera check-ins")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                    Spacer()
                    if KeychainService.offlineVisionFallbackEnabled {
                        Text("Offline Mode")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(DailyOSTheme.skyGlow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
                    } else if KeychainService.hasGeminiAPIKey {
                        Text("Gemini Ready")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(DailyOSTheme.emerald)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(DailyOSTheme.emerald.opacity(0.14), in: Capsule())
                    } else {
                        Button("Add API Key") {
                            onOpenSettings()
                        }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.solarAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(DailyOSTheme.solarAccent.opacity(0.14), in: Capsule())
                        .buttonStyle(.plain)
                    }
                }

                Divider().overlay(DailyOSTheme.hairline)

                // Test Check-In Alarm Row
                Button {
                    focusManager.activateFocusTaskAlarm(
                        taskID: "test_focus_alarm",
                        taskTitle: focusManager.activeFocusBlock?.title ?? "Focus Accountability Test",
                        taskNotes: focusManager.activeFocusBlock?.notes ?? "Live workspace check-in",
                        taskSource: "Test",
                        evasionPenalty: false
                    )
                } label: {
                    HStack(spacing: 12) {
                        sourceIconBadge("camera.badge.clock", color: DailyOSTheme.solarAccent)
                        Text("Test Task Check-In Alarm (1%→22% / 2m)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(DailyOSTheme.solarAccent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .ambientCard(cornerRadius: 22)
    }

    private func sourceIconBadge(_ icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - ISO-8601 Monday-First Schedule Strip

    private var mondayScheduleStripCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SCHEDULE (MON–SUN)")
                    .eyebrowStyle()
                Spacer()
                Button(selectedFilterDateKey == nil ? "All Upcoming" : "Show All") {
                    selectedFilterDateKey = nil
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(selectedFilterDateKey == nil ? DailyOSTheme.skyGlow : DailyOSTheme.solarAccent)
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(mondayStripDates, id: \.self) { day in
                        let key = HabitItem.dateKey(for: day)
                        let isSelected = selectedFilterDateKey == key
                        let isToday = ISOWeekCalendar.current.isDateInToday(day)
                        let count = focusManager.upcomingBlocks.filter { $0.dayKey == key }.count

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectedFilterDateKey = (isSelected ? nil : key)
                        } label: {
                            VStack(spacing: 4) {
                                Text(shortWeekdayLabel(day))
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(isSelected ? Color.black : DailyOSTheme.eyebrow)
                                Text(dayNumberLabel(day))
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(isSelected ? Color.black : (isToday ? DailyOSTheme.skyGlow : Color.white))
                                Circle()
                                    .fill(count > 0 ? (isSelected ? Color.black : DailyOSTheme.skyGlow) : Color.clear)
                                    .frame(width: 5, height: 5)
                            }
                            .frame(width: 44, height: 58)
                            .background(
                                isSelected
                                    ? DailyOSTheme.skyGlow
                                    : (isToday ? DailyOSTheme.skyGlow.opacity(0.14) : DailyOSTheme.inputSurface),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(isToday && !isSelected ? DailyOSTheme.skyGlow.opacity(0.45) : DailyOSTheme.hairline, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .ambientCard(cornerRadius: 22)
    }

    // MARK: - Empty Upcoming Tasks Card

    private var emptyUpcomingTasksCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(DailyOSTheme.skyGlow)
                .frame(width: 56, height: 56)
                .background(DailyOSTheme.skyGlow.opacity(0.14), in: Circle())

            Text("No Scheduled Tasks")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)

            Text("Tap + to schedule a future focus block, or connect Google Calendar & Tasks in Settings.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DailyOSTheme.eyebrow)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .ambientCard(cornerRadius: 22)
    }

    // MARK: - Recent Photo Proof Logs

    private var recentProofLogsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECENT PHOTO PROOF LOGS")
                .eyebrowStyle()

            VStack(spacing: 10) {
                ForEach(checkInLogs.prefix(12)) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: log.verified ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(log.verified ? DailyOSTheme.emerald : Color(hex: "#FF6B6B"))
                            Text(log.taskTitle)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white)
                                .lineLimit(1)
                            Spacer()
                            Text(log.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(DailyOSTheme.eyebrow)
                        }
                        Text(log.reason)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                    .padding(12)
                    .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(18)
        .ambientCard(cornerRadius: 22)
    }

    // MARK: - Formatting Helpers (ISO-8601)

    private func shortWeekdayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE"
        return f.string(from: date).uppercased()
    }

    private func dayNumberLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "d"
        return f.string(from: date)
    }

    private func sectionHeaderTitle(for date: Date) -> String {
        let cal = ISOWeekCalendar.current
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone.current
        f.dateFormat = "EEEE, d MMM"
        let formatted = f.string(from: date)
        if cal.isDateInToday(date) {
            return "Today • \(formatted)"
        } else if cal.isDateInTomorrow(date) {
            return "Tomorrow • \(formatted)"
        }
        return formatted
    }

    private func formatCountdown(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Deep Work Glowing Ring Full-Screen Timer

private struct DeepWorkTimerFullScreenView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared

    let sessionLabel: String
    let durationMinutes: Int
    let cueSubtitle: String
    let activeFocusBlock: FocusBlockDisplayItem?
    let onLoggedMinutes: (Int) -> Void

    @State private var remainingSeconds: Int
    @State private var isPaused: Bool = false
    @State private var didFinishSession: Bool = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        sessionLabel: String,
        durationMinutes: Int,
        cueSubtitle: String,
        activeFocusBlock: FocusBlockDisplayItem?,
        onLoggedMinutes: @escaping (Int) -> Void
    ) {
        self.sessionLabel = sessionLabel
        self.durationMinutes = max(1, durationMinutes)
        self.cueSubtitle = cueSubtitle
        self.activeFocusBlock = activeFocusBlock
        self.onLoggedMinutes = onLoggedMinutes
        _remainingSeconds = State(initialValue: max(60, durationMinutes * 60))
    }

    private var totalSeconds: Int {
        max(60, durationMinutes * 60)
    }

    private var elapsedSeconds: Int {
        max(0, totalSeconds - remainingSeconds)
    }

    private var progressFraction: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(remainingSeconds) / Double(totalSeconds)
    }

    private var formattedTimerText: String {
        let clamped = max(0, remainingSeconds)
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            // Subtle ambient radial halo behind ring
            RadialGradient(
                colors: [DailyOSTheme.skyGlow.opacity(0.11), Color.clear],
                center: .center,
                startRadius: 40,
                endRadius: 260
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Bar
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 40) {
                        endAndLogSession()
                    }
                    Spacer()
                    if let block = activeFocusBlock {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(DailyOSTheme.emerald)
                                .frame(width: 7, height: 7)
                            Text(block.timeRangeText)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.white.opacity(0.75))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(DailyOSTheme.buttonSurface, in: Capsule())
                        .overlay(Capsule().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

                Spacer()

                // Center Glowing Ring + Tabular Countdown
                ZStack {
                    AmbientBloomRing(
                        progress: progressFraction,
                        color: didFinishSession ? DailyOSTheme.emerald : DailyOSTheme.skyGlow,
                        lineWidth: 14,
                        diameter: 268
                    )

                    VStack(spacing: 8) {
                        Text(sessionLabel.isEmpty ? "DEEP WORK" : sessionLabel.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(1.8)
                            .foregroundStyle(DailyOSTheme.eyebrow)
                            .lineLimit(1)
                            .frame(maxWidth: 190)

                        Text(formattedTimerText)
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .contentTransition(.numericText())

                        if !cueSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(cueSubtitle)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.45))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 185)
                        } else if didFinishSession {
                            Text("Session complete")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(DailyOSTheme.emerald)
                        } else if isPaused {
                            Text("Paused")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(DailyOSTheme.solarAccent)
                        }
                    }
                }

                Spacer()

                // Bottom Circular Controls: End / Pause-Resume / Photo Proof
                HStack(spacing: 28) {
                    VStack(spacing: 8) {
                        FrostedCircleButton(icon: "stop.fill", size: 54, tint: Color(hex: "#FF6B6B")) {
                            endAndLogSession()
                        }
                        Text("End")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }

                    VStack(spacing: 8) {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            if didFinishSession {
                                remainingSeconds = totalSeconds
                                didFinishSession = false
                                isPaused = false
                            } else {
                                isPaused.toggle()
                            }
                        } label: {
                            Image(systemName: didFinishSession ? "arrow.clockwise" : (isPaused ? "play.fill" : "pause.fill"))
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Color.black)
                                .frame(width: 68, height: 68)
                                .background(DailyOSTheme.skyGlow, in: Circle())
                                .shadow(color: DailyOSTheme.skyGlow.opacity(0.35), radius: 14)
                        }
                        .buttonStyle(.plain)
                        Text(didFinishSession ? "Restart" : (isPaused ? "Resume" : "Pause"))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.75))
                    }

                    VStack(spacing: 8) {
                        FrostedCircleButton(icon: "camera.fill", size: 54, tint: DailyOSTheme.solarAccent) {
                            let target = activeFocusBlock
                            endAndLogSession()
                            if let block = target {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    focusManager.openVoluntaryProofCapture(for: block)
                                }
                            } else {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    focusManager.activateFocusTaskAlarm(
                                        taskID: "deep_work_proof",
                                        taskTitle: sessionLabel,
                                        taskNotes: cueSubtitle.isEmpty ? "Deep work session check-in" : cueSubtitle,
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
                .padding(.bottom, 42)
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(timer) { _ in
            guard !isPaused && !didFinishSession else { return }
            if remainingSeconds > 1 {
                remainingSeconds -= 1
            } else {
                remainingSeconds = 0
                didFinishSession = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onLoggedMinutes(durationMinutes)
            }
        }
    }

    private func endAndLogSession() {
        if !didFinishSession {
            let mins = elapsedSeconds / 60
            if mins > 0 {
                onLoggedMinutes(mins)
            }
        }
        dismiss()
    }
}

// MARK: - Scheduled Focus Block Card Row

private struct FocusBlockCardRow: View {
    let block: FocusBlockDisplayItem
    let isCurrent: Bool
    let onDelete: (() -> Void)?

    private var sourceColor: Color {
        switch block.source {
        case .googleCalendar: return DailyOSTheme.skyGlow
        case .googleTasks: return Color(hex: "#A78BFA")
        case .appleCalendar: return Color(hex: "#818CF8")
        case .local: return Color(hex: "#2DD4BF")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: block.source.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isCurrent ? DailyOSTheme.emerald : sourceColor)
                .frame(width: 40, height: 40)
                .background(
                    (isCurrent ? DailyOSTheme.emerald : sourceColor).opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isCurrent ? DailyOSTheme.emerald : sourceColor)
                        .frame(width: 6, height: 6)
                    Text(block.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    if isCurrent {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DailyOSTheme.emerald, in: Capsule())
                            .foregroundStyle(Color.black)
                    }
                }

                HStack(spacing: 6) {
                    Text(block.timeRangeText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DailyOSTheme.eyebrow)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(DailyOSTheme.eyebrow)

                    Text("\(Int(round(block.durationMinutes)))m")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.75))

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(DailyOSTheme.eyebrow)

                    Text(block.source.badgeTitle)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(sourceColor)
                }

                Text(block.requiresRecurringCheckIns
                     ? "Check-ins: First 5m + every 30m"
                     : "Check-ins: First 5m only (≤ 35m)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(DailyOSTheme.eyebrow)
            }

            Spacer(minLength: 0)

            if let onDelete {
                FrostedCircleButton(icon: "trash", size: 34, tint: Color(hex: "#FF6B6B")) {
                    onDelete()
                }
            }
        }
        .padding(14)
        .ambientCard(accent: isCurrent ? DailyOSTheme.emerald : nil, cornerRadius: 18, washOpacity: 0.08)
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

    // MARK: - Stage 1: Task Check-In Alarm (Normal 2m 1%->22% OR Evasion 10s 0%->22%)

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

            // Real-Time Hardware Volume Telemetry (Capped at 22%)
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

    // MARK: - Stage 2: Live Camera-Only Capture + Gemini 2.5 Flash Verification

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

// MARK: - Native Future Task Scheduling Sheet (Midnight Obsidian Styled)

private struct AddScheduledTaskSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var taskDate: Date = Date()
    @State private var startTime: Date = Date()
    @State private var endTime: Date = Date().addingTimeInterval(60 * 60)

    private var combinedStartDate: Date {
        combine(date: taskDate, time: startTime)
    }

    private var combinedEndDate: Date {
        let candidate = combine(date: taskDate, time: endTime)
        return candidate > combinedStartDate ? candidate : combinedStartDate.addingTimeInterval(15 * 60)
    }

    private var durationMinutes: Int {
        max(15, Int(round(combinedEndDate.timeIntervalSince(combinedStartDate) / 60.0)))
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 38) {
                        dismiss()
                    }
                    Spacer()
                    Text("Schedule Task")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // Task Details
                        VStack(alignment: .leading, spacing: 10) {
                            Text("TASK DETAILS")
                                .eyebrowStyle()

                            TextField("Task Title", text: $title)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white)
                                .padding(14)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))

                            TextField("Proof Description (Optional)", text: $notes)
                                .font(.system(size: 15, weight: .regular, design: .rounded))
                                .foregroundStyle(Color.white)
                                .padding(14)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                        }

                        // Date & Time
                        VStack(alignment: .leading, spacing: 10) {
                            Text("DATE & TIME (MON–SUN)")
                                .eyebrowStyle()

                            VStack(spacing: 12) {
                                DatePicker(
                                    "Date",
                                    selection: $taskDate,
                                    in: ISOWeekCalendar.current.startOfDay(for: Date())...,
                                    displayedComponents: .date
                                )
                                .tint(DailyOSTheme.skyGlow)

                                Divider().overlay(DailyOSTheme.hairline)

                                DatePicker(
                                    "Start Time",
                                    selection: $startTime,
                                    displayedComponents: .hourAndMinute
                                )
                                .tint(DailyOSTheme.skyGlow)
                                .onChange(of: startTime) { _, newStart in
                                    if combine(date: taskDate, time: endTime) <= combine(date: taskDate, time: newStart) {
                                        endTime = newStart.addingTimeInterval(60 * 60)
                                    }
                                }

                                Divider().overlay(DailyOSTheme.hairline)

                                DatePicker(
                                    "End Time",
                                    selection: $endTime,
                                    displayedComponents: .hourAndMinute
                                )
                                .tint(DailyOSTheme.skyGlow)
                            }
                            .padding(16)
                            .ambientCard(cornerRadius: 18)
                        }

                        // Accountability Check-In Schedule
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ACCOUNTABILITY CHECK-INS")
                                .eyebrowStyle()

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Duration")
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.white)
                                    Spacer()
                                    Text("\(durationMinutes) min")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(DailyOSTheme.skyGlow)
                                }

                                Text(durationMinutes <= 35
                                     ? "≤ 35 min: Initial photo proof required in the first 5 minutes. No recurring check-ins afterward."
                                     : "> 35 min: Initial photo proof required in the first 5 minutes, then every 30 minutes until end time.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.eyebrow)
                            }
                            .padding(16)
                            .ambientCard(cornerRadius: 18)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                }

                // Sticky Full-Width Pill Save Button
                Button {
                    FocusAccountabilityManager.shared.addScheduledTask(
                        title: title,
                        notes: notes,
                        startDate: combinedStartDate,
                        endDate: combinedEndDate
                    )
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(canSave ? DailyOSTheme.skyGlow : DailyOSTheme.emptyCell, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.calendar, ISOWeekCalendar.current)
        .environment(\.locale, Locale(identifier: "en_GB"))
    }

    private func combine(date: Date, time: Date) -> Date {
        let cal = ISOWeekCalendar.current
        let d = cal.dateComponents([.year, .month, .day], from: date)
        let t = cal.dateComponents([.hour, .minute], from: time)
        var merged = DateComponents()
        merged.year = d.year
        merged.month = d.month
        merged.day = d.day
        merged.hour = t.hour
        merged.minute = t.minute
        merged.second = 0
        return cal.date(from: merged) ?? date
    }
}

// MARK: - Optional Apple Calendar Filter Sheet

private struct AppleCalendarFilterSheet: View {
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
