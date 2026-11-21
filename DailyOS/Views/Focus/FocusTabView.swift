import SwiftUI
import SwiftData
import EventKit

struct FocusTabView: View {
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared
    @ObservedObject private var audioManager = AlarmAudioManager.shared

    @Query(sort: [SortDescriptor(\FocusCheckInLog.timestamp, order: .reverse)])
    private var checkInLogs: [FocusCheckInLog]

    let onOpenSettings: () -> Void

    @State private var showingAddManualSheet = false
    @State private var showingCalendarFilterSheet = false

    var body: some View {
        NavigationStack {
            List {
                // 1. Live Check-In Due / Active Focus Block Banner
                Section {
                    if focusManager.isCheckInDue {
                        checkInDueBanner
                    } else if let active = focusManager.activeFocusBlock {
                        activeFocusCard(active)
                    } else {
                        idleFocusCard
                    }
                }

                // 2. Accountability Loop Configuration (30-40 min + Gemini Status)
                Section("AI Accountability Loop") {
                    Stepper(
                        "Check-In Interval: \(focusManager.checkInIntervalMinutes) min",
                        value: Binding(
                            get: { focusManager.checkInIntervalMinutes },
                            set: { focusManager.updateCheckInInterval($0) }
                        ),
                        in: 30...40,
                        step: 1
                    )

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
                        focusManager.triggerCheckInDue(immediateAlarm: true)
                    } label: {
                        Label("Test Check-In + 2-Min Escalating Alarm", systemImage: "camera.badge.clock")
                            .foregroundStyle(.orange)
                    }
                }

                // 3. Apple / Google Calendar Sync (EventKit)
                Section {
                    if !focusManager.isCalendarAuthorized {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Connect your synced iOS Calendars (Apple iCloud / Google Calendar) to auto-track blocks like KOOL, Study, or Work.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                Task {
                                    await focusManager.requestCalendarAccess()
                                }
                            } label: {
                                Label("Connect iOS Calendars", systemImage: "calendar.badge.plus")
                                    .font(.subheadline.weight(.bold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.indigo)
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack {
                            Label(
                                "Tracking \(focusManager.trackedCalendarIDs.count) of \(focusManager.availableCalendars.count) calendars",
                                systemImage: "calendar.badge.checkmark"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.green)

                            Spacer()

                            Button("Filter") {
                                showingCalendarFilterSheet = true
                            }
                            .font(.caption.weight(.bold))
                        }

                        if focusManager.todayBlocks.isEmpty {
                            Text("No timed events remaining today in selected calendars. Start a manual focus block below.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(focusManager.todayBlocks) { block in
                                FocusBlockRow(
                                    block: block,
                                    isCurrent: focusManager.activeFocusBlock?.id == block.id,
                                    onEndManual: {
                                        if let id = block.manualBlockID {
                                            focusManager.endManualFocusBlock(id: id)
                                        }
                                    }
                                )
                            }
                        }
                    }

                    Button {
                        showingAddManualSheet = true
                    } label: {
                        Label("Start Manual Focus Block", systemImage: "plus.circle.fill")
                            .foregroundStyle(.cyan)
                    }
                } header: {
                    HStack {
                        Text("Today's Focus Schedule")
                        Spacer()
                        if focusManager.isCalendarAuthorized {
                            Button {
                                focusManager.refreshTodaySchedule()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption.weight(.bold))
                            }
                        }
                    }
                }

                // 4. Recent AI Proof Check-In Logs
                if !checkInLogs.isEmpty {
                    Section("Recent Photo Proof Logs") {
                        ForEach(checkInLogs.prefix(12)) { log in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: log.verified ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                        .foregroundStyle(log.verified ? .green : .red)
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
                        showingAddManualSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("Start Manual Focus Block")
                }
            }
            .onAppear {
                focusManager.refreshTodaySchedule()
            }
            .sheet(isPresented: $showingAddManualSheet) {
                AddManualFocusBlockSheet()
            }
            .sheet(isPresented: $showingCalendarFilterSheet) {
                CalendarFilterSheet()
            }
        }
    }

    // MARK: - Subviews

    private var checkInDueBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("ACCOUNTABILITY CHECK-IN DUE", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.red)
                Spacer()
                if audioManager.isFocusWarningActive {
                    Text("VOL \(Int(round(audioManager.focusWarningVolumeFraction * 100)))%")
                        .font(.caption.weight(.black).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.25), in: Capsule())
                        .foregroundStyle(.red)
                }
            }

            if let block = focusManager.activeFocusBlock {
                Text(block.title)
                    .font(.title3.weight(.bold))
                if !block.notes.isEmpty {
                    Text(block.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if audioManager.isFocusWarningActive {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(audioManager.focusWarningVolumeFraction), total: 0.5)
                        .tint(.red)
                    Text("2-min escalating warning alarm active (ramps 0% → 50%)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            if let feedback = focusManager.lastVerificationFeedback {
                Text(feedback)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(focusManager.lastVerificationWasRejected ? .red : .green)
            }

            Button {
                focusManager.beginPhotoProofCaptureWithGraceTimer()
            } label: {
                HStack {
                    Image(systemName: "camera.fill")
                    Text("TAKE PROOF PHOTO (20s GRACE)")
                        .font(.subheadline.weight(.black))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private func activeFocusCard(_ block: FocusBlockDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("ACTIVE BLOCK • \(block.calendarTitle.uppercased())", systemImage: "bolt.shield.fill")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.cyan)
                Spacer()
                Text(block.timeRangeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(block.title)
                .font(.headline.weight(.bold))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next Photo Check-In")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatCountdown(focusManager.secondsUntilNextCheckIn))
                        .font(.title2.weight(.black).monospacedDigit())
                        .foregroundStyle(.green)
                }

                Spacer()

                Button {
                    focusManager.triggerCheckInDue(immediateAlarm: false)
                    focusManager.beginPhotoProofCaptureWithGraceTimer()
                } label: {
                    Label("Submit Proof", systemImage: "camera.fill")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }

            if let feedback = focusManager.lastVerificationFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.green)
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
                Text("No Ongoing Focus Block")
                    .font(.subheadline.weight(.bold))
                Text("When a tracked calendar event or manual focus session is active, DailyOS triggers live camera check-ins every \(focusManager.checkInIntervalMinutes) minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatCountdown(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Focus Block Row

private struct FocusBlockRow: View {
    let block: FocusBlockDisplayItem
    let isCurrent: Bool
    let onEndManual: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrent ? Color.green : (block.isManual ? Color.cyan : Color.indigo))
                .frame(width: 4, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(block.title)
                        .font(.subheadline.weight(.semibold))
                    if isCurrent {
                        Text("NOW")
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
                    Text(block.calendarTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(block.isManual ? .cyan : .indigo)
                }
            }

            Spacer()

            if block.isManual && isCurrent {
                Button("End") {
                    onEndManual()
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }
}

// MARK: - Live Camera-Only AI Focus Photo Proof Modal (20s Grace Timer + Gemini 2.5 Flash)

struct FocusPhotoProofModalView: View {
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared
    @ObservedObject private var audioManager = AlarmAudioManager.shared
    @StateObject private var cameraVM = LivePhotoCaptureViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                // Grace Timer & Warning Status Header
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                        Text("GRACE: \(focusManager.photoGraceSecondsRemaining)s")
                            .monospacedDigit()
                    }
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(focusManager.photoGraceSecondsRemaining <= 5 ? .red : .green)
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

                // Active Task Context
                VStack(spacing: 2) {
                    Text("VERIFY TASK: \(focusManager.activeFocusBlock?.title ?? "Focus Session")")
                        .font(.headline.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Live camera only — photo library disabled. Gemini 2.5 Flash verifies your proof.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                // Rejection / Loading Banner
                if let feedback = focusManager.lastVerificationFeedback {
                    HStack(spacing: 8) {
                        if focusManager.isSubmittingToGemini {
                            ProgressView()
                                .tint(.cyan)
                        } else {
                            Image(systemName: focusManager.lastVerificationWasRejected ? "xmark.octagon.fill" : "checkmark.seal.fill")
                                .foregroundStyle(focusManager.lastVerificationWasRejected ? .red : .green)
                        }
                        Text(feedback)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(focusManager.lastVerificationWasRejected ? .red : .white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        (focusManager.lastVerificationWasRejected ? Color.red : Color.cyan).opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .padding(.horizontal)
                }

                // Live Camera Viewport or Captured Preview
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
                        BarcodeScannerCameraPreview(session: cameraVM.captureSession)
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

                // Capture / Verify Controls
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
            .navigationTitle("Live Accountability Proof")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        cameraVM.stopSession()
                        focusManager.cancelPhotoCaptureWithoutSubmitting()
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
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
    }
}

// MARK: - Add Manual Focus Block Sheet

private struct AddManualFocusBlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String = "Deep Work / Study"
    @State private var notes: String = ""
    @State private var durationMinutes: Int = 90

    var body: some View {
        NavigationStack {
            Form {
                Section("Manual Focus Block") {
                    TextField("Task Title (e.g., KOOL Math Study)", text: $title)
                    TextField("Description for Gemini AI (e.g., Solving calculus notes at desk)", text: $notes)
                    Stepper("Duration: \(durationMinutes) minutes", value: $durationMinutes, in: 30...240, step: 15)
                }
            }
            .navigationTitle("Start Focus Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        FocusAccountabilityManager.shared.addManualFocusBlock(
                            title: title,
                            notes: notes,
                            durationMinutes: durationMinutes
                        )
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}

// MARK: - Calendar Filter Picker Sheet

private struct CalendarFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Select Calendars to Track (e.g., KOOL, Study, Work)") {
                    ForEach(focusManager.availableCalendars) { cal in
                        let isSelected = focusManager.trackedCalendarIDs.contains(cal.id)
                        Button {
                            focusManager.toggleCalendarTracking(cal.id)
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
            .navigationTitle("Tracked Calendars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
