import SwiftUI
import UIKit
import AudioToolbox

/// Full-screen Solar-Orange Max-Brightness Wake UI & 2-Stage Anti-Cheat Challenge Flow:
/// - Stage 0 (Ringing Gate): Edge-to-edge Solar-Orange sunrise luminance (#FF5500 -> #FFA200),
///   auto 100% screen brightness, pulsing glow ring, giant pitch-black clock, and massive "DO CHALLENGE" pill.
/// - Stage 1 (Physical): Squats (30s initial grace -> 5.0s per-rep + stateful resume-volume escalation),
///   Steps (custom goal + flat custom time limit), or QR / Barcode Scan (custom grace timer).
/// - Stage 2 (Cognitive): 1 of 4 interactive Brain Games with 15s Anti-Fall-Back-Asleep Guard.
/// - Stage 3 (Complete): Stops all alarms/notifications, restores screen brightness, shows "WAKE COMPLETE" + "START MY DAY".
struct AlarmRingingView: View {
    let alarm: AlarmItem
    let onDismissAlarm: () -> Void

    private enum WakeStage {
        case ringingGate
        case stage1Physical
        case stage2BrainGame
        case wakeComplete
    }

    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var audioManager = AlarmAudioManager.shared
    @ObservedObject private var volumeController = SystemVolumeController.shared

    @State private var stage: WakeStage = .ringingGate
    @State private var resolvedPhysicalMission: MissionType = .squats
    @State private var resolvedBrainGame: BrainGameMode? = .reflexStrike
    @State private var physicalCompletionSummary: String = ""
    @State private var brainCompletionSummary: String = ""

    // Screen brightness capture & restore
    @State private var savedOriginalBrightness: CGFloat = 0.5
    @State private var didCaptureBrightness: Bool = false
    @State private var didRestoreBrightness: Bool = false

    // Ringing Gate clock & glow animation
    @State private var currentTimeString: String = ""
    @State private var pulseGlow: Bool = false

    // Stage-1 Timers & Stateful Resume-Volume Penalty
    @State private var hasCompletedFirstSquat: Bool = false
    @State private var challengeStartDate: Date?
    @State private var lastSquatCompletedDate: Date?
    @State private var countdownSecondsRemaining: Double = 30.0
    @State private var inactivityPenaltyActive: Bool = false
    @State private var penaltyBannerText: String?

    private let uiTickTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var totalStageCount: Int {
        resolvedBrainGame == nil ? 1 : 2
    }

    var body: some View {
        ZStack {
            switch stage {
            case .ringingGate:
                solarRingingGateView
            case .stage1Physical:
                stage1PhysicalContainerView
            case .stage2BrainGame:
                if let game = resolvedBrainGame {
                    BrainGameContainerView(
                        game: game,
                        reflexThresholdMs: alarm.reflexThresholdMs,
                        isPracticeMode: false,
                        onCompleted: { summary in
                            brainCompletionSummary = summary
                            enterWakeCompleteSummary()
                        }
                    )
                }
            case .wakeComplete:
                wakeCompleteSummaryView
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .onAppear {
            configureWakeSessionOnAppear()
        }
        .onDisappear {
            restoreScreenBrightnessIfNeeded()
        }
        .onReceive(uiTickTimer) { _ in
            updateClockText()
            if stage == .stage1Physical {
                tickStage1Timers()
            }
        }
    }

    // MARK: - Session Initialization & Brightness Management

    private func configureWakeSessionOnAppear() {
        updateClockText()
        volumeController.ensureMountedInKeyWindow()

        // Capture current screen brightness and push to 100% solar luminance
        if !didCaptureBrightness {
            savedOriginalBrightness = UIScreen.main.brightness
            didCaptureBrightness = true
            didRestoreBrightness = false
        }
        UIScreen.main.brightness = 1.0
        UIApplication.shared.isIdleTimerDisabled = true

        // Resolve Daily Random rolls once when alarm opens
        resolvedPhysicalMission = alarm.missionType.resolvedForTrigger()
        resolvedBrainGame = alarm.brainGameMode.resolvedForTrigger()

        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            pulseGlow = true
        }
    }

    private func restoreScreenBrightnessIfNeeded() {
        guard didCaptureBrightness && !didRestoreBrightness else { return }
        didRestoreBrightness = true
        UIScreen.main.brightness = savedOriginalBrightness
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Stage 0: Full-Screen Solar-Orange Max-Brightness Ringing Gate

    private var solarRingingGateView: some View {
        ZStack {
            SolarTheme.sunriseGradient
                .ignoresSafeArea()

            // Subtle animated pulsing luminance glow ring behind the time
            Circle()
                .fill(Color.white.opacity(pulseGlow ? 0.24 : 0.08))
                .frame(width: pulseGlow ? 330 : 250, height: pulseGlow ? 330 : 250)
                .blur(radius: 26)
                .offset(y: -45)

            VStack(spacing: 20) {
                // Top Stage Pill
                HStack(spacing: 8) {
                    Image(systemName: "sun.max.fill")
                    Text("STAGE 1 OF \(totalStageCount) • PHYSICAL")
                }
                .font(.caption.weight(.black))
                .foregroundStyle(SolarTheme.solarGold)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(SolarTheme.obsidian, in: Capsule())
                .padding(.top, 14)

                Spacer()

                // Pitch-Black High-Contrast Clock & Rolled Challenge Badge
                VStack(spacing: 10) {
                    Text(currentTimeString.isEmpty ? alarm.formattedTime : currentTimeString)
                        .font(.system(size: 68, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(SolarTheme.obsidian)

                    Text(alarm.displayLabel.uppercased())
                        .font(.title3.weight(.black))
                        .foregroundStyle(SolarTheme.obsidian.opacity(0.85))

                    // Rolled Challenge Pill
                    HStack(spacing: 8) {
                        Image(systemName: resolvedPhysicalMission.iconName)
                            .font(.subheadline.weight(.bold))
                        Text("TODAY'S CHALLENGE: \(resolvedPhysicalMission.shortBadge.uppercased())")
                            .font(.caption.weight(.black))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(SolarTheme.obsidian.opacity(0.92), in: Capsule())

                    if let brain = resolvedBrainGame {
                        Label("Then Stage 2: \(brain.displayName)", systemImage: brain.iconName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(SolarTheme.obsidian.opacity(0.8))
                    }
                }

                // Live Escalation Readout Card
                VStack(spacing: 8) {
                    HStack {
                        Text(audioManager.escalationPhaseLabel)
                            .font(.caption2.weight(.black))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(Int(round(audioManager.currentTargetVolumeFraction * 100)))%")
                            .font(.subheadline.weight(.black).monospacedDigit())
                            .foregroundStyle(SolarTheme.solarGold)
                    }

                    ProgressView(value: Double(min(0.50, audioManager.currentTargetVolumeFraction)), total: 0.50)
                        .tint(SolarTheme.solarBright)

                    HStack {
                        Text("Elapsed \(formatClock(Int(audioManager.wakeElapsedSeconds)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text("HW: \(Int(round(volumeController.currentHardwareVolume * 100)))% • 100% Brightness")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(14)
                .background(SolarTheme.obsidian.opacity(0.86), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 6)

                Spacer()

                // Massive Pitch-Black "DO CHALLENGE" Capsule CTA
                Button {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    beginStage1PhysicalChallenge()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: resolvedPhysicalMission.iconName)
                            .font(.title2.weight(.black))
                            .foregroundStyle(SolarTheme.solarBright)
                        Text("DO CHALLENGE")
                            .font(.title2.weight(.black))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(SolarTheme.obsidian, in: Capsule())
                    .shadow(color: Color.black.opacity(0.42), radius: 14, y: 6)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Tap Do Challenge to silence alarm")
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Stage 1: Physical Challenge Container

    private var stage1PhysicalContainerView: some View {
        ZStack {
            (inactivityPenaltyActive
             ? LinearGradient(colors: [Color(red: 0.40, green: 0.03, blue: 0.04), SolarTheme.obsidian], startPoint: .top, endPoint: .bottom)
             : LinearGradient(colors: [SolarTheme.solarDeep.opacity(0.28), SolarTheme.obsidian], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()

            VStack(spacing: 12) {
                // Top Countdown & Penalty HUD
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                        Text(stage1TimerLabel)
                            .monospacedDigit()
                    }
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(isStage1TimerCritical ? Color.red : SolarTheme.solarGold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        (isStage1TimerCritical ? Color.red : SolarTheme.solarCore).opacity(0.22),
                        in: Capsule()
                    )

                    Spacer()

                    // Stateful Penalty Volume Indicator
                    HStack(spacing: 5) {
                        Image(systemName: inactivityPenaltyActive ? "speaker.wave.3.fill" : "speaker.slash.fill")
                        if inactivityPenaltyActive {
                            Text("PENALTY \(Int(round(audioManager.currentTargetVolumeFraction * 100)))%")
                                .monospacedDigit()
                        } else if audioManager.savedRampProgress > 0.01 && resolvedPhysicalMission == .squats {
                            Text("ARMED \(Int(round(audioManager.savedRampProgress * 100)))%")
                                .monospacedDigit()
                        } else {
                            Text("SILENCED")
                        }
                    }
                    .font(.caption.weight(.black))
                    .foregroundStyle(inactivityPenaltyActive ? Color.white : (audioManager.savedRampProgress > 0.01 ? SolarTheme.solarBright : Color.green))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        inactivityPenaltyActive ? Color.red : SolarTheme.charcoal,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(
                            inactivityPenaltyActive ? Color.red : SolarTheme.hairline,
                            lineWidth: 1
                        )
                    )
                }

                if let penaltyBannerText {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(penaltyBannerText)
                            .font(.caption2.weight(.black))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                }

                // Active Physical Mission View
                Group {
                    switch resolvedPhysicalMission {
                    case .squats, .random:
                        SquatsMissionSubView(
                            repGoal: max(5, alarm.repGoal),
                            savedPenaltyFraction: audioManager.savedRampProgress,
                            onRepCompleted: handleSquatRepCompleted,
                            onComplete: {
                                finishStage1(summary: "\(alarm.repGoal) Squats Completed")
                            }
                        )
                    case .steps:
                        StepsMissionSubView(
                            stepGoal: max(50, alarm.stepGoal),
                            timeRemainingSeconds: Int(ceil(max(0, countdownSecondsRemaining))),
                            totalTimeSeconds: max(30, alarm.stepsTimeLimitSeconds),
                            onComplete: {
                                finishStage1(summary: "\(alarm.stepGoal) Steps Completed")
                            }
                        )
                    case .qrBarcode:
                        QRMissionScannerSubView(
                            expectedCode: WakeQRStorage.registeredCode,
                            onComplete: { msg in
                                finishStage1(summary: msg)
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Stage 3: WAKE COMPLETE Summary Card

    private var wakeCompleteSummaryView: some View {
        ZStack {
            SolarTheme.obsidian.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(SolarTheme.sunriseGradient)
                        .frame(width: 112, height: 112)
                        .shadow(color: SolarTheme.solarCore.opacity(0.5), radius: 22)
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 52, weight: .black))
                        .foregroundStyle(SolarTheme.obsidian)
                }

                VStack(spacing: 6) {
                    Text("WAKE COMPLETE")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("All alarms stopped • Brightness restored")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                // Completed Stage Summary Card
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: resolvedPhysicalMission.iconName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(SolarTheme.solarBright)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("STAGE 1 • PHYSICAL")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text(physicalCompletionSummary)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    if !brainCompletionSummary.isEmpty {
                        Divider()
                        HStack(spacing: 12) {
                            Image(systemName: resolvedBrainGame?.iconName ?? "brain.head.profile")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(SolarTheme.solarGold)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("STAGE 2 • COGNITIVE")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Text(brainCompletionSummary)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .padding(18)
                .solarCard(cornerRadius: 18)
                .padding(.horizontal, 4)

                Spacer()

                // Pitch-Black "START MY DAY" Button with Solar Border
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onDismissAlarm()
                } label: {
                    Text("START MY DAY")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(SolarTheme.obsidian, in: Capsule())
                        .overlay(Capsule().stroke(SolarTheme.solarBright, lineWidth: 2.5))
                        .shadow(color: SolarTheme.solarCore.opacity(0.35), radius: 14)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 22)
        }
    }

    // MARK: - Stage-1 Exact Timing & Stateful Resume-Volume Logic

    private var stage1TimerLabel: String {
        switch resolvedPhysicalMission {
        case .squats, .random:
            if !hasCompletedFirstSquat {
                return String(format: "REP 1 GRACE: %.1fs", max(0, countdownSecondsRemaining))
            } else {
                return String(format: "NEXT REP: %.1fs", max(0, countdownSecondsRemaining))
            }
        case .steps:
            return "TIME LEFT: \(formatClock(Int(ceil(max(0, countdownSecondsRemaining)))))"
        case .qrBarcode:
            return "QR GRACE: \(formatClock(Int(ceil(max(0, countdownSecondsRemaining)))))"
        }
    }

    private var isStage1TimerCritical: Bool {
        if inactivityPenaltyActive { return true }
        switch resolvedPhysicalMission {
        case .squats, .random:
            return hasCompletedFirstSquat ? countdownSecondsRemaining <= 2.0 : countdownSecondsRemaining <= 5.0
        case .steps, .qrBarcode:
            return countdownSecondsRemaining <= 10.0
        }
    }

    private func beginStage1PhysicalChallenge() {
        stage = .stage1Physical
        hasCompletedFirstSquat = false
        inactivityPenaltyActive = false
        penaltyBannerText = nil
        challengeStartDate = Date()
        lastSquatCompletedDate = nil

        switch resolvedPhysicalMission {
        case .squats, .random:
            countdownSecondsRemaining = 30.0
        case .steps:
            countdownSecondsRemaining = Double(max(30, alarm.stepsTimeLimitSeconds))
        case .qrBarcode:
            countdownSecondsRemaining = Double(max(20, alarm.qrGraceSeconds))
        }

        _ = alarmEngine.silenceForChallenge()
    }

    private func handleSquatRepCompleted(_ newCount: Int) {
        hasCompletedFirstSquat = true
        lastSquatCompletedDate = Date()
        countdownSecondsRemaining = 5.0

        // Immediately silence alarm & save current ramp progress into savedRampProgress!
        if inactivityPenaltyActive {
            inactivityPenaltyActive = false
            penaltyBannerText = nil
            _ = alarmEngine.silenceForChallenge()
        }
    }

    private func tickStage1Timers() {
        let now = Date()

        switch resolvedPhysicalMission {
        case .squats, .random:
            if !hasCompletedFirstSquat {
                guard let start = challengeStartDate else { return }
                let elapsed = now.timeIntervalSince(start)
                countdownSecondsRemaining = max(0.0, 30.0 - elapsed)

                if countdownSecondsRemaining <= 0.0 && !inactivityPenaltyActive {
                    inactivityPenaltyActive = true
                    let resumePct = Int(round(audioManager.savedRampProgress * 100))
                    penaltyBannerText = resumePct > 0
                        ? "30s GRACE EXPIRED — RESUMING PENALTY FROM \(resumePct)%! COMPLETE REP 1!"
                        : "30s GRACE EXPIRED — RAMPING 1%→50% (15s)! COMPLETE REP 1!"
                    alarmEngine.startOrResumeInactivityPenalty()
                }
            } else {
                guard let lastRep = lastSquatCompletedDate else { return }
                let elapsed = now.timeIntervalSince(lastRep)
                countdownSecondsRemaining = max(0.0, 5.0 - elapsed)

                if countdownSecondsRemaining <= 0.0 && !inactivityPenaltyActive {
                    inactivityPenaltyActive = true
                    let resumePct = Int(round(audioManager.savedRampProgress * 100))
                    penaltyBannerText = resumePct > 0
                        ? "5s REP TIMER EXPIRED — RESUMING PENALTY FROM \(resumePct)%! KEEP SQUATTING!"
                        : "5s REP TIMER EXPIRED — RAMPING 1%→50% (15s)! COMPLETE NEXT SQUAT!"
                    alarmEngine.startOrResumeInactivityPenalty()
                }
            }

        case .steps:
            guard let start = challengeStartDate else { return }
            let limit = Double(max(30, alarm.stepsTimeLimitSeconds))
            let elapsed = now.timeIntervalSince(start)
            countdownSecondsRemaining = max(0.0, limit - elapsed)

            if countdownSecondsRemaining <= 0.0 && !inactivityPenaltyActive {
                inactivityPenaltyActive = true
                penaltyBannerText = "TIME LIMIT REACHED — RAMPING 1%→50% (15s) UNTIL STEPS COMPLETE!"
                alarmEngine.startOrResumeInactivityPenalty()
            }

        case .qrBarcode:
            guard let start = challengeStartDate else { return }
            let limit = Double(max(20, alarm.qrGraceSeconds))
            let elapsed = now.timeIntervalSince(start)
            countdownSecondsRemaining = max(0.0, limit - elapsed)

            if countdownSecondsRemaining <= 0.0 && !inactivityPenaltyActive {
                inactivityPenaltyActive = true
                penaltyBannerText = "QR GRACE EXPIRED — RAMPING 1%→50% (15s)! SCAN YOUR QR CODE!"
                alarmEngine.startOrResumeInactivityPenalty()
            }
        }
    }

    private func finishStage1(summary: String) {
        physicalCompletionSummary = summary
        inactivityPenaltyActive = false
        penaltyBannerText = nil
        _ = alarmEngine.silenceForChallenge()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        if resolvedBrainGame != nil {
            withAnimation(.spring(response: 0.35)) {
                stage = .stage2BrainGame
            }
        } else {
            enterWakeCompleteSummary()
        }
    }

    private func enterWakeCompleteSummary() {
        alarmEngine.finalizeWakeAudioAndNotifications()
        restoreScreenBrightnessIfNeeded()
        withAnimation(.spring(response: 0.35)) {
            stage = .wakeComplete
        }
    }

    // MARK: - Formatting Helpers

    private func updateClockText() {
        let formatter = DateFormatter()
        formatter.calendar = ISOWeekCalendar.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm:ss"
        currentTimeString = formatter.string(from: Date())
    }

    private func formatClock(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

// MARK: - Stage-1 SubView: AI Vision Squats

private struct SquatsMissionSubView: View {
    let repGoal: Int
    let savedPenaltyFraction: Double
    let onRepCompleted: (Int) -> Void
    let onComplete: () -> Void

    @StateObject private var detector = VisionPoseDetector()
    @State private var didComplete = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI SQUATS")
                        .font(.headline.weight(.black))
                        .foregroundStyle(SolarTheme.solarBright)
                    Text("Phase: \(detector.phase.rawValue) • Knee: \(Int(detector.overlayState.kneeAngleDegrees))°")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.cyan)
                    if savedPenaltyFraction > 0.01 {
                        Text("Resume-Penalty Level: \(Int(round(savedPenaltyFraction * 100)))%")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(detector.repCount)")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(SolarTheme.solarGold)
                    Text("/ \(repGoal)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .solarCard(cornerRadius: 14)

            ZStack {
                CameraPreviewView(session: detector.captureSession)
                PoseSkeletonOverlayView(state: detector.overlayState)

                VStack {
                    HStack {
                        Label("ON-DEVICE VISION SQUATS", systemImage: "eye.fill")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    .padding(10)

                    Spacer()

                    Text(detector.overlayState.postureHint)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.75))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(SolarTheme.solarCore.opacity(0.85), lineWidth: 2)
            )

            ProgressView(value: Double(min(detector.repCount, repGoal)), total: Double(max(1, repGoal)))
                .tint(SolarTheme.solarBright)
        }
        .onAppear {
            detector.onRepCompleted = { count in
                onRepCompleted(count)
                if count >= repGoal && !didComplete {
                    didComplete = true
                    detector.stop()
                    onComplete()
                }
            }
            detector.startSquatDetection()
        }
        .onDisappear {
            detector.stop()
        }
    }
}

// MARK: - Stage-1 SubView: CoreMotion Steps (Custom Step Target + Custom Time Limit)

private struct StepsMissionSubView: View {
    let stepGoal: Int
    let timeRemainingSeconds: Int
    let totalTimeSeconds: Int
    let onComplete: () -> Void

    @StateObject private var stepManager = StepCounterManager()
    @State private var didComplete = false

    private var progress: Double {
        guard stepGoal > 0 else { return 1.0 }
        return min(1.0, Double(stepManager.currentSteps) / Double(stepGoal))
    }

    private var elapsedSeconds: Int {
        max(0, totalTimeSeconds - timeRemainingSeconds)
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Label("STEPS MISSION", systemImage: "figure.walk")
                    .font(.headline.weight(.black))
                    .foregroundStyle(SolarTheme.solarBright)
                Text("Complete \(stepGoal) steps before the countdown reaches 00:00")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 18)
                    .frame(width: 224, height: 224)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(colors: [SolarTheme.solarDeep, SolarTheme.solarBright, SolarTheme.solarGold], center: .center),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 224, height: 224)
                    .animation(.easeOut(duration: 0.2), value: stepManager.currentSteps)

                VStack(spacing: 4) {
                    Image(systemName: "shoeprints.fill")
                        .font(.title2)
                        .foregroundStyle(SolarTheme.solarGold)

                    Text("\(stepManager.currentSteps)")
                        .font(.system(size: 50, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)

                    Text("/ \(stepGoal) steps")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            HStack(spacing: 16) {
                metricBox(title: "REMAINING", value: "\(max(0, stepGoal - stepManager.currentSteps))", accent: SolarTheme.solarBright)
                metricBox(title: "ELAPSED", value: formatMMSS(elapsedSeconds), accent: .cyan)
                metricBox(title: "TIME LEFT", value: formatMMSS(timeRemainingSeconds), accent: timeRemainingSeconds <= 30 ? .red : .green)
            }

            Text(stepManager.statusMessage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .onAppear {
            stepManager.onStepIncremented = { count in
                if count >= stepGoal && !didComplete {
                    didComplete = true
                    stepManager.stopTracking()
                    onComplete()
                }
            }
            stepManager.startTracking()
        }
        .onDisappear {
            stepManager.stopTracking()
        }
    }

    private func metricBox(title: String, value: String, accent: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline.weight(.black).monospacedDigit())
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .solarCard(cornerRadius: 12)
    }

    private func formatMMSS(_ secs: Int) -> String {
        let clamped = max(0, secs)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
