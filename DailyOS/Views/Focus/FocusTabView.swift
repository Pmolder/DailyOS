import SwiftUI
import SwiftData
import EventKit

struct FocusTabView: View {
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared
    @ObservedObject private var googleAuth = GoogleAuthService.shared
    @ObservedObject private var audioManager = AlarmAudioManager.shared

    @Query(sort: [SortDescriptor(\FocusCheckInLog.timestamp, order: .reverse)])
    private var checkInLogs: [FocusCheckInLog]

    let onOpenSettings: () -> Void

    @State private var showingScheduleTaskSheet = false
    @State private var showingAppleCalendarFilterSheet = false
    @State private var selectedFilterDateKey: String? = nil // nil = All Upcoming

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

    var body: some View {
        NavigationStack {
            List {
                // 1. Live Active Focus Session Status
                Section {
                    if let active = focusManager.activeFocusBlock {
                        activeFocusCard(active)
                    } else {
                        idleFocusCard
                    }
                }

                // 2. Sync Sources Status (Google Calendar & Tasks + Optional Apple Calendar)
                Section("Connected Sources") {
                    HStack {
                        Label("Google Calendar & Tasks", systemImage: "g.circle.fill")
                            .foregroundStyle(.white)
                        Spacer()
                        if googleAuth.isConnected {
                            Button {
                                Task { await focusManager.syncAllSources() }
                            } label: {
                                if focusManager.isSyncingGoogle {
                                    ProgressView()
                                } else {
                                    Label("Sync", systemImage: "arrow.clockwise")
                                        .font(.caption.weight(.bold))
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.cyan)
                        } else {
                            Button("Connect") {
                                onOpenSettings()
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                        }
                    }

                    if let msg = focusManager.lastGoogleSyncMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Apple Calendar (Optional)", systemImage: "calendar")
                        Spacer()
                        if focusManager.appleCalendarSyncEnabled && focusManager.isAppleCalendarAuthorized {
                            Button("Filter (\(focusManager.trackedAppleCalendarIDs.count))") {
                                showingAppleCalendarFilterSheet = true
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.cyan)
                        } else {
                            Button("Configure") {
                                onOpenSettings()
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Label("AI Verifier", systemImage: "sparkles")
                        Spacer()
                        if KeychainService.offlineVisionFallbackEnabled {
                            Text("Offline Test Mode")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.cyan)
                        } else if KeychainService.hasGeminiAPIKey {
                            Text("gemini-2.5-flash Ready")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.green)
                        } else {
                            Button("Add API Key") {
                                onOpenSettings()
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                        }
                    }

                    Button {
                        focusManager.activateFocusTaskAlarm(
                            taskID: "test_focus_alarm",
                            taskTitle: focusManager.activeFocusBlock?.title ?? "Focus Accountability Test",
                            taskNotes: focusManager.activeFocusBlock?.notes ?? "Live workspace check-in",
                            taskSource: "Test",
                            evasionPenalty: false
                        )
                    } label: {
                        Label("Test Task Check-In Alarm (1%→22% / 2m)", systemImage: "camera.badge.clock")
                            .foregroundStyle(.orange)
                    }
                }

                // 3. ISO-8601 Monday-First Multi-Day Schedule Filter
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Schedule (Mon–Sun)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(selectedFilterDateKey == nil ? "Showing All Upcoming" : "Show All") {
                                selectedFilterDateKey = nil
                            }
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(selectedFilterDateKey == nil ? Color.cyan : Color.orange)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(mondayStripDates, id: \.self) { day in
                                    let key = HabitItem.dateKey(for: day)
                                    let isSelected = selectedFilterDateKey == key
                                    let isToday = ISOWeekCalendar.current.isDateInToday(day)
                                    let count = focusManager.upcomingBlocks.filter { $0.dayKey == key }.count

                                    Button {
                                        selectedFilterDateKey = (isSelected ? nil : key)
                                    } label: {
                                        VStack(spacing: 3) {
                                            Text(shortWeekdayLabel(day))
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(isSelected ? Color.black : Color.secondary)
                                            Text(dayNumberLabel(day))
                                                .font(.subheadline.weight(.black).monospacedDigit())
                                                .foregroundStyle(isSelected ? Color.black : (isToday ? Color.orange : Color.white))
                                            Circle()
                                                .fill(count > 0 ? (isSelected ? Color.black : Color.cyan) : Color.clear)
                                                .frame(width: 5, height: 5)
                                        }
                                        .frame(width: 44, height: 56)
                                        .background(
                                            isSelected
                                                ? Color.orange
                                                : (isToday ? Color.orange.opacity(0.16) : Color.white.opacity(0.06)),
                                            in: RoundedRectangle(cornerRadius: 10)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // 4. Multi-Day Grouped Scheduled Tasks
                if groupedDays.isEmpty {
                    Section("Upcoming Tasks") {
                        ContentUnavailableView(
                            "No Scheduled Tasks",
                            systemImage: "calendar.badge.plus",
                            description: Text("Tap + to schedule a future focus task for any date & time, or connect Google Calendar & Tasks in Settings.")
                        )
                    }
                } else {
                    ForEach(groupedDays, id: \.dayKey) { group in
                        Section(sectionHeaderTitle(for: group.date)) {
                            ForEach(group.blocks) { block in
                                FocusBlockRow(
                                    block: block,
                                    isCurrent: focusManager.activeFocusBlock?.id == block.id
                                )
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
                        }
                    }
                }

                // 5. Recent AI Proof Check-In Logs
                if !checkInLogs.isEmpty {
                    Section("Recent Photo Proof Logs") {
                        ForEach(checkInLogs.prefix(12)) { log in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: log.verified ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                        .foregroundStyle(log.verified ? Color.green : Color.red)
                                    Text(log.taskTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(log.timestamp.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(log.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Focus")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings and Backup")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingScheduleTaskSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("Schedule Future Task")
                }
            }
            .onAppear {
                Task { await focusManager.syncAllSources() }
            }
            .sheet(isPresented: $showingScheduleTaskSheet) {
                AddScheduledTaskSheet()
            }
            .sheet(isPresented: $showingAppleCalendarFilterSheet) {
                AppleCalendarFilterSheet()
            }
        }
    }

    // MARK: - Active / Idle Focus Cards

    private func activeFocusCard(_ block: FocusBlockDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(block.source.badgeTitle.uppercased(), systemImage: block.source.iconName)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.cyan)
                Spacer()
                Text(block.timeRangeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(block.title)
                .font(.headline.weight(.bold))

            Text(focusManager.checkInPhaseLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(focusManager.isCurrentBlockCleared ? Color.green : Color.orange)

            if !focusManager.isCurrentBlockCleared {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(focusManager.completedCheckInsForCurrentBlock == 0
                             ? "1st Proof Deadline (5m Window)"
                             : "Next 30-Min Proof Deadline")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(formatCountdown(focusManager.secondsUntilCheckInDeadline))
                            .font(.title2.weight(.black).monospacedDigit())
                            .foregroundStyle(focusManager.secondsUntilCheckInDeadline <= 60 ? Color.red : Color.green)
                    }

                    Spacer()

                    Button {
                        focusManager.openVoluntaryProofCapture(for: block)
                    } label: {
                        Label("Submit Proof", systemImage: "camera.fill")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }

            if let feedback = focusManager.lastVerificationFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(focusManager.lastVerificationWasRejected ? Color.red : Color.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var idleFocusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Ongoing Focus Task")
                    .font(.subheadline.weight(.bold))
                Text("Initial photo proof is due in the first 5 min. Tasks > 35 min require recurring proofs every 30 min.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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

// MARK: - Scheduled Focus Block Row

private struct FocusBlockRow: View {
    let block: FocusBlockDisplayItem
    let isCurrent: Bool

    private var sourceColor: Color {
        switch block.source {
        case .googleCalendar: return .blue
        case .googleTasks: return .purple
        case .appleCalendar: return .indigo
        case .local: return .cyan
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrent ? Color.green : sourceColor)
                .frame(width: 4, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(block.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if isCurrent {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .black))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }

                HStack(spacing: 6) {
                    Text(block.timeRangeText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("\(Int(round(block.durationMinutes)))m")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Label(block.source.badgeTitle, systemImage: block.source.iconName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(sourceColor)
                }

                Text(block.requiresRecurringCheckIns
                     ? "Check-ins: First 5m + every 30m"
                     : "Check-ins: First 5m only (≤ 35m)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
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
                    ? [Color(red: 0.40, green: 0.02, blue: 0.05), Color(red: 0.16, green: 0.01, blue: 0.02), .black]
                    : [Color(red: 0.12, green: 0.05, blue: 0.02), Color(red: 0.08, green: 0.04, blue: 0.12), .black],
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
                    .foregroundStyle(.white)
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
                    .foregroundStyle(.cyan)

                Text(focusManager.activeAlarmTitle.isEmpty ? "Scheduled Focus Task" : focusManager.activeAlarmTitle)
                    .font(.title.weight(.black))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                if !focusManager.activeAlarmNotes.isEmpty {
                    Text(focusManager.activeAlarmNotes)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal)

            // Real-Time Hardware Volume Telemetry (Capped at 22%)
            VStack(spacing: 10) {
                HStack {
                    Text("SYSTEM VOLUME (MAX 22%)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(round(audioManager.focusWarningVolumeFraction * 100)))% (HW: \(Int(round(volumeController.currentHardwareVolume * 100)))%)")
                        .font(.subheadline.weight(.black).monospacedDigit())
                        .foregroundStyle(.red)
                }

                ProgressView(value: Double(min(0.22, audioManager.focusWarningVolumeFraction)), total: 0.22)
                    .tint(.red)

                Text("Hardware Volume-Down Lock Active • Submit live photo proof to stop alarm")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            if let feedback = focusManager.lastVerificationFeedback {
                Text(feedback)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
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
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 16))
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
                    .foregroundStyle(focusManager.photoGraceSecondsRemaining <= 5 ? Color.red : Color.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        (focusManager.photoGraceSecondsRemaining <= 5 ? Color.red : Color.green).opacity(0.2),
                        in: Capsule()
                    )

                    Spacer()

                    if audioManager.isFocusWarningActive && !audioManager.isFocusWarningPaused {
                        Label("ALARM RINGING", systemImage: "speaker.wave.3.fill")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red, in: Capsule())
                    } else {
                        Label("ALARM PAUSED", systemImage: "speaker.slash.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.cyan.opacity(0.18), in: Capsule())
                    }
                }
                .padding(.horizontal)

                VStack(spacing: 2) {
                    Text(focusManager.activeAlarmTitle)
                        .font(.headline.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Live camera only — photo library disabled. Gemini 2.5 Flash verifies your task.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                if let feedback = focusManager.lastVerificationFeedback {
                    HStack(spacing: 8) {
                        if focusManager.isSubmittingToGemini {
                            ProgressView()
                                .tint(.cyan)
                        } else {
                            Image(systemName: focusManager.lastVerificationWasRejected ? "xmark.octagon.fill" : "checkmark.seal.fill")
                                .foregroundStyle(focusManager.lastVerificationWasRejected ? Color.red : Color.green)
                        }
                        Text(feedback)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(focusManager.lastVerificationWasRejected ? Color.red : Color.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        (focusManager.lastVerificationWasRejected ? Color.red : Color.cyan).opacity(0.16),
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
                                    .stroke(Color.orange, lineWidth: 2)
                            )
                    } else {
                        CameraPreviewView(session: cameraVM.captureSession)
                            .frame(maxWidth: .infinity, maxHeight: 380)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.cyan.opacity(0.65), lineWidth: 2)
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
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
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
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: 12))
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
                                    .fill(Color.orange)
                                    .frame(width: 60, height: 60)
                                Image(systemName: "camera.fill")
                                    .font(.title2)
                                    .foregroundStyle(.black)
                            }
                        }
                        .disabled(cameraVM.isCapturing)

                        Button {
                            cameraVM.switchCamera()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.title3)
                                .frame(width: 48, height: 48)
                                .background(Color.white.opacity(0.14), in: Circle())
                        }
                    }
                }
            }
            .padding(.vertical)
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

// MARK: - Native Future Task Scheduling Sheet (Any Future Date & Time, Empty Defaults)

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

    var body: some View {
        NavigationStack {
            Form {
                Section("Task Details") {
                    TextField("Task Title", text: $title)
                    TextField("Proof Description (Optional)", text: $notes)
                }

                Section("Date & Time (ISO-8601 Mon–Sun)") {
                    DatePicker(
                        "Date",
                        selection: $taskDate,
                        in: ISOWeekCalendar.current.startOfDay(for: Date())...,
                        displayedComponents: .date
                    )

                    DatePicker(
                        "Start Time",
                        selection: $startTime,
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: startTime) { _, newStart in
                        if combine(date: taskDate, time: endTime) <= combine(date: taskDate, time: newStart) {
                            endTime = newStart.addingTimeInterval(60 * 60)
                        }
                    }

                    DatePicker(
                        "End Time",
                        selection: $endTime,
                        displayedComponents: .hourAndMinute
                    )
                }

                Section("Accountability Check-In Schedule") {
                    HStack {
                        Text("Duration")
                        Spacer()
                        Text("\(durationMinutes) min")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.cyan)
                    }

                    Text(durationMinutes <= 35
                         ? "≤ 35 min: Initial photo proof required in the first 5 minutes. No recurring check-ins afterward."
                         : "> 35 min: Initial photo proof required in the first 5 minutes, then every 30 minutes until end time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Schedule Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        FocusAccountabilityManager.shared.addScheduledTask(
                            title: title,
                            notes: notes,
                            startDate: combinedStartDate,
                            endDate: combinedEndDate
                        )
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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
                                        .foregroundStyle(.white)
                                    Text(cal.sourceTitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.green : Color.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Apple Calendars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
