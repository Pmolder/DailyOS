import SwiftUI
import SwiftData
import EventKit
import Combine

/// Tab 3: Pure Focus Tab — 100% Dedicated to Deep Work, Ambient Ring Timer, Today's Focus Blocks & Focus Bento Stats.
/// All Google/Apple Calendar OAuth onboarding lives exclusively in Settings → Connected Sources.
struct FocusTabView: View {
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared

    @State private var showingScheduleTaskSheet = false
    @State private var showingCustomDurationSheet = false

    // Inline Deep Work Ring Timer State
    @State private var selectedMinutes: Int = 45
    @State private var customMinutesDraft: Int = 35
    @State private var focusCueNote: String = ""
    @State private var isTimerRunning: Bool = false
    @State private var isTimerPaused: Bool = false
    @State private var remainingSeconds: Int = 45 * 60
    @State private var sessionFinishedBanner: String? = nil

    // Today's Bento Telemetry
    @State private var focusedMinutesToday: Int = HabitMetricsEngine.focusMinutesToday
    @State private var completedSessionsToday: Int = HabitMetricsEngine.completedFocusSessionsToday

    private let quickDurationPresets: [Int] = [15, 25, 45, 60, 90]
    private let secondTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var totalSessionSeconds: Int {
        max(60, selectedMinutes * 60)
    }

    private var elapsedSessionSeconds: Int {
        max(0, totalSessionSeconds - remainingSeconds)
    }

    private var timerRingProgress: Double {
        guard totalSessionSeconds > 0 else { return 0 }
        if !isTimerRunning && !isTimerPaused {
            return 1.0
        }
        return Double(max(0, remainingSeconds)) / Double(totalSessionSeconds)
    }

    private var formattedTimerClock: String {
        let clamped = max(0, remainingSeconds)
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var todayBlocks: [FocusBlockDisplayItem] {
        let todayKey = HabitItem.dateKey(for: Date())
        return focusManager.upcomingBlocks
            .filter { $0.dayKey == todayKey }
            .sorted { $0.startDate < $1.startDate }
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
                    VStack(spacing: 18) {
                        // 1. Clean Top Header
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

                            FrostedCircleButton(icon: "plus", size: 38) {
                                showingScheduleTaskSheet = true
                            }
                        }
                        .padding(.top, 6)

                        // 2. Glowing Deep Work Timer Hero Card
                        deepWorkHeroCard

                        // 3. Focus Bento Stats (2-Column Dark Cards)
                        focusBentoStatsRow

                        // 4. Active Scheduled Accountability Block (only when live)
                        if let active = focusManager.activeFocusBlock {
                            activeScheduledBlockCard(active)
                        }

                        // 5. Today's Focus Blocks (Manual + Synced only if already connected in Settings)
                        todaysFocusBlocksSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 34)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                focusedMinutesToday = HabitMetricsEngine.focusMinutesToday
                completedSessionsToday = HabitMetricsEngine.completedFocusSessionsToday
                if !isTimerRunning && !isTimerPaused {
                    remainingSeconds = selectedMinutes * 60
                }
                Task { await focusManager.syncAllSources() }
            }
            .onReceive(secondTick) { _ in
                guard isTimerRunning && !isTimerPaused else { return }
                if remainingSeconds > 1 {
                    remainingSeconds -= 1
                } else {
                    completeDeepWorkSession(loggedMinutes: selectedMinutes)
                }
            }
            .sheet(isPresented: $showingScheduleTaskSheet) {
                AddScheduledTaskSheet()
            }
            .sheet(isPresented: $showingCustomDurationSheet) {
                CustomFocusDurationSheet(minutes: $customMinutesDraft) { chosen in
                    applyDurationSelection(chosen)
                }
            }
        }
    }

    // MARK: - 1. Glowing Deep Work Timer Hero Card

    private var deepWorkHeroCard: some View {
        VStack(spacing: 18) {
            // Glowing Circular Progress Ring
            ZStack {
                AmbientBloomRing(
                    progress: timerRingProgress,
                    color: isTimerRunning && !isTimerPaused ? DailyOSTheme.skyGlow : Color(hex: "#818CF8"),
                    lineWidth: 13,
                    diameter: 224
                )

                VStack(spacing: 6) {
                    Text(focusManager.activeFocusBlock?.title.uppercased() ?? "DEEP WORK")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(DailyOSTheme.eyebrow)
                        .lineLimit(1)
                        .frame(maxWidth: 165)

                    Text(formattedTimerClock)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .contentTransition(.numericText())

                    // Inline Editable Cue Subtitle
                    TextField(
                        "",
                        text: $focusCueNote,
                        prompt: Text("phone in another room").foregroundStyle(Color.white.opacity(0.30))
                    )
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 168)
                }
            }
            .padding(.top, 6)

            // Quick Duration Pills (15m, 25m, 45m, 60m, 90m, Custom)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickDurationPresets, id: \.self) { mins in
                        let selected = selectedMinutes == mins
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            applyDurationSelection(mins)
                        } label: {
                            Text("\(mins)m")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.82))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(
                                    selected ? DailyOSTheme.skyGlow : DailyOSTheme.inputSurface,
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().stroke(selected ? DailyOSTheme.skyGlow : DailyOSTheme.hairline, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isTimerRunning)
                        .opacity(isTimerRunning ? 0.55 : 1.0)
                    }

                    let isCustomSelected = !quickDurationPresets.contains(selectedMinutes)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        customMinutesDraft = selectedMinutes
                        showingCustomDurationSheet = true
                    } label: {
                        Text(isCustomSelected ? "\(selectedMinutes)m" : "Custom")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(isCustomSelected ? Color.black : Color.white.opacity(0.82))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(
                                isCustomSelected ? DailyOSTheme.skyGlow : DailyOSTheme.inputSurface,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().stroke(isCustomSelected ? DailyOSTheme.skyGlow : DailyOSTheme.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isTimerRunning)
                    .opacity(isTimerRunning ? 0.55 : 1.0)
                }
            }

            // Start / Pause / Finish / Optional Photo Proof Controls
            HStack(spacing: 12) {
                if isTimerRunning || isTimerPaused {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        isTimerPaused.toggle()
                    } label: {
                        Label(isTimerPaused ? "Resume" : "Pause", systemImage: isTimerPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(DailyOSTheme.skyGlow, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        let logged = max(1, elapsedSessionSeconds / 60)
                        completeDeepWorkSession(loggedMinutes: elapsedSessionSeconds >= 60 ? logged : 0)
                    } label: {
                        Label("Finish", systemImage: "checkmark")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(DailyOSTheme.buttonSurface, in: Capsule())
                            .overlay(Capsule().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        sessionFinishedBanner = nil
                        remainingSeconds = selectedMinutes * 60
                        isTimerRunning = true
                        isTimerPaused = false
                    } label: {
                        Label("Start Deep Work", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(DailyOSTheme.skyGlow, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // Optional Gemini Camera Photo Proof Button
                FrostedCircleButton(icon: "camera.fill", size: 46, tint: DailyOSTheme.solarAccent) {
                    if let active = focusManager.activeFocusBlock {
                        focusManager.openVoluntaryProofCapture(for: active)
                    } else {
                        focusManager.activateFocusTaskAlarm(
                            taskID: "deep_work_proof_\(Int(Date().timeIntervalSince1970))",
                            taskTitle: focusCueNote.isEmpty ? "Deep Work Session" : focusCueNote,
                            taskNotes: "Optional photo proof for \(selectedMinutes)m Deep Work block",
                            taskSource: "Deep Work",
                            evasionPenalty: false
                        )
                    }
                }
            }

            if let banner = sessionFinishedBanner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(DailyOSTheme.emerald)
                    Text(banner)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.emerald)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DailyOSTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(20)
        .ambientCard(accent: DailyOSTheme.skyGlow, cornerRadius: 26, washOpacity: 0.11)
    }

    // MARK: - 2. Focus Bento Stats (2-Column Dark Cards)

    private var focusBentoStatsRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "timer")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DailyOSTheme.skyGlow)
                        .frame(width: 30, height: 30)
                        .background(DailyOSTheme.skyGlow.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Spacer()
                }

                Text("\(focusedMinutesToday) min")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)

                Text("FOCUSED TODAY")
                    .eyebrowStyle()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ambientCard(accent: DailyOSTheme.skyGlow, cornerRadius: 20, washOpacity: 0.06)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DailyOSTheme.emerald)
                        .frame(width: 30, height: 30)
                        .background(DailyOSTheme.emerald.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Spacer()
                }

                Text("\(completedSessionsToday)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)

                Text("COMPLETED SESSIONS")
                    .eyebrowStyle()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ambientCard(accent: DailyOSTheme.emerald, cornerRadius: 20, washOpacity: 0.06)
        }
    }

    // MARK: - 3. Active Scheduled Block Card

    private func activeScheduledBlockCard(_ block: FocusBlockDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(focusManager.isCurrentBlockCleared ? DailyOSTheme.emerald : DailyOSTheme.solarAccent)
                        .frame(width: 7, height: 7)
                    Text("ACTIVE BLOCK • \(block.source.badgeTitle)")
                        .eyebrowStyle()
                }
                Spacer()
                Text(block.timeRangeText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DailyOSTheme.eyebrow)
            }

            Text(block.title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)

            if !focusManager.isCurrentBlockCleared {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(focusManager.completedCheckInsForCurrentBlock == 0
                             ? "INITIAL PROOF WINDOW (5M)"
                             : "NEXT 30M CHECK-IN")
                            .eyebrowStyle()
                        Text(formatCountdown(focusManager.secondsUntilCheckInDeadline))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(focusManager.secondsUntilCheckInDeadline <= 60 ? Color(hex: "#FF6B6B") : DailyOSTheme.emerald)
                    }
                    Spacer()
                    Button {
                        focusManager.openVoluntaryProofCapture(for: block)
                    } label: {
                        Label("Photo Proof", systemImage: "camera.fill")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(DailyOSTheme.solarAccent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(focusManager.checkInPhaseLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DailyOSTheme.emerald)
            }
        }
        .padding(16)
        .ambientCard(
            accent: focusManager.isCurrentBlockCleared ? DailyOSTheme.emerald : DailyOSTheme.solarAccent,
            cornerRadius: 20,
            washOpacity: 0.09
        )
    }

    // MARK: - 4. Today's Focus Blocks Section

    private var todaysFocusBlocksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TODAY'S FOCUS BLOCKS")
                    .eyebrowStyle()
                Spacer()
                Button {
                    showingScheduleTaskSheet = true
                } label: {
                    Label("Add Focus Block", systemImage: "plus")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.skyGlow)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)

            if todayBlocks.isEmpty {
                VStack(spacing: 10) {
                    Text("No Focus Blocks Today")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text("Start the Deep Work timer above or schedule a timed focus block with optional AI photo proof.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 18)
                .ambientCard(cornerRadius: 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(todayBlocks) { block in
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

    // MARK: - Timer Helpers

    private func applyDurationSelection(_ mins: Int) {
        let clamped = max(5, min(180, mins))
        selectedMinutes = clamped
        remainingSeconds = clamped * 60
        isTimerRunning = false
        isTimerPaused = false
        sessionFinishedBanner = nil
    }

    private func completeDeepWorkSession(loggedMinutes: Int) {
        isTimerRunning = false
        isTimerPaused = false
        remainingSeconds = selectedMinutes * 60

        if loggedMinutes > 0 {
            HabitMetricsEngine.addFocusMinutesToday(loggedMinutes)
            HabitMetricsEngine.incrementFocusSessionsToday()
            focusedMinutesToday = HabitMetricsEngine.focusMinutesToday
            completedSessionsToday = HabitMetricsEngine.completedFocusSessionsToday
            sessionFinishedBanner = "Logged \(loggedMinutes) min Deep Work session — Today's Score updated."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            WidgetSyncCoordinator.syncSnapshotFromStore()
            Task { await DailyNotificationManager.shared.refreshScheduledNotifications() }
        }
    }

    private func formatCountdown(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Custom Duration Sheet

private struct CustomFocusDurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var minutes: Int
    let onApply: (Int) -> Void

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 36) { dismiss() }
                    Spacer()
                    Text("Custom Duration")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }

                Text("\(minutes) min")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DailyOSTheme.skyGlow)

                Stepper("Focus Minutes", value: $minutes, in: 5...180, step: 5)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(16)
                    .ambientCard(cornerRadius: 18)

                Spacer()

                Button {
                    onApply(minutes)
                    dismiss()
                } label: {
                    Text("Set \(minutes) Minutes")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(DailyOSTheme.skyGlow, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .presentationDetents([.height(300)])
        .preferredColorScheme(.dark)
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
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 38) {
                        dismiss()
                    }
                    Spacer()
                    Text("Add Focus Block")
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
                        VStack(alignment: .leading, spacing: 10) {
                            Text("BLOCK DETAILS")
                                .eyebrowStyle()

                            TextField("Focus Block Title", text: $title)
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
                                     ? "≤ 35 min: Initial photo proof required in the first 5 minutes."
                                     : "> 35 min: Initial photo proof required in the first 5 minutes, then every 30 minutes.")
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
