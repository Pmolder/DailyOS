import SwiftUI
import AudioToolbox

/// Full-screen locked Wake Alarm & Challenge view (no dismiss gesture, no snooze).
/// Exact Challenge Timing Engine:
/// 1. Ringing Gate shows real-time hardware volume escalation (0-30s vib, 30-60s 1-15%, 60-90s 15-50%)
///    and a single "DO CHALLENGE" button.
/// 2. Tapping "DO CHALLENGE" immediately silences the alarm and starts a 20.0s initial grace timer
///    (from the exact tap timestamp) to complete Rep 1 / Step 1.
/// 3. Once Rep 1 / Step 1 is detected, switches to a 3.0s per-rep timer resetting on every rep/step.
/// 4. If either timer expires: immediately resumes alarm & ramps hardware volume 1% -> 50% over 15s
///    with active volume-button correction; completing the next squat/step silences it & resets 3.0s.
struct AlarmRingingView: View {
    let alarm: AlarmItem
    let onDismissAlarm: () -> Void

    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var audioManager = AlarmAudioManager.shared
    @ObservedObject private var volumeController = SystemVolumeController.shared

    @State private var currentTimeString: String = ""
    @State private var hasStartedChallenge: Bool = false

    // Exact 20s initial grace + 3.0s inter-rep timer state
    @State private var hasCompletedFirstUnit: Bool = false
    @State private var challengeStartDate: Date?
    @State private var lastUnitCompletedDate: Date?
    @State private var countdownSecondsRemaining: Double = 20.0
    @State private var inactivityPenaltyActive: Bool = false
    @State private var penaltyBannerText: String?

    private let uiTickTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: inactivityPenaltyActive
                    ? [Color(red: 0.42, green: 0.02, blue: 0.04), Color(red: 0.18, green: 0.01, blue: 0.02), .black]
                    : [Color(red: 0.08, green: 0.04, blue: 0.12), Color(red: 0.14, green: 0.03, blue: 0.06), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                if !hasStartedChallenge {
                    ringingGateView
                } else {
                    activeChallengeContainerView
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .onAppear {
            updateClockText()
            volumeController.ensureMountedInKeyWindow()
        }
        .onReceive(uiTickTimer) { _ in
            updateClockText()
            if hasStartedChallenge {
                tickChallengeTimers()
            }
        }
    }

    // MARK: - Stage 1: Ringing Gate

    private var ringingGateView: some View {
        VStack(spacing: 22) {
            HStack(spacing: 8) {
                Image(systemName: audioManager.currentTargetVolumeFraction > 0 ? "speaker.wave.3.fill" : "iphone.radiowaves.left.and.right")
                    .foregroundStyle(audioManager.currentTargetVolumeFraction > 0.15 ? Color.red : Color.orange)
                Text(audioManager.escalationPhaseLabel)
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.28), in: Capsule())
            .overlay(Capsule().stroke(Color.red.opacity(0.65), lineWidth: 1.5))
            .padding(.top, 12)

            Spacer()

            VStack(spacing: 8) {
                Text(currentTimeString.isEmpty ? alarm.formattedTime : currentTimeString)
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Text(alarm.displayLabel.uppercased())
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.orange)

                Label(alarm.missionSummary, systemImage: alarm.missionType.iconName)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .foregroundStyle(.white)
            }

            // Live Hardware Volume Telemetry
            VStack(spacing: 10) {
                HStack {
                    Text("SYSTEM HARDWARE VOLUME")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(round(audioManager.currentTargetVolumeFraction * 100)))% (HW: \(Int(round(volumeController.currentHardwareVolume * 100)))%)")
                        .font(.subheadline.weight(.black).monospacedDigit())
                        .foregroundStyle(audioManager.currentTargetVolumeFraction >= 0.49 ? Color.red : Color.orange)
                }

                ProgressView(value: Double(min(0.50, audioManager.currentTargetVolumeFraction)), total: 0.50)
                    .tint(audioManager.currentTargetVolumeFraction >= 0.15 ? .red : .orange)

                HStack {
                    Text("Elapsed: \(formatSeconds(audioManager.wakeElapsedSeconds))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("Cap: 50% • Vol-Down Lock Active")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

            Spacer()

            Text("NO SNOOZE • 20s FOR 1ST REP • 3s PER REP THEREAFTER")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            Button {
                startChallengeFromTap()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: alarm.missionType.iconName)
                        .font(.title2.weight(.bold))
                    Text("DO CHALLENGE")
                        .font(.title3.weight(.black))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Stage 2: Active Challenge (20s Initial Grace -> 3.0s Per-Rep Timer)

    private var activeChallengeContainerView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                // Active Countdown Pill (20s initial OR 3.0s per-rep)
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                    if !hasCompletedFirstUnit {
                        Text(String(format: "1ST REP GRACE: %.1fs", max(0, countdownSecondsRemaining)))
                            .monospacedDigit()
                    } else {
                        Text(String(format: "NEXT REP: %.1fs", max(0, countdownSecondsRemaining)))
                            .monospacedDigit()
                    }
                }
                .font(.subheadline.weight(.black))
                .foregroundStyle(countdownSecondsRemaining <= 1.5 || inactivityPenaltyActive ? Color.red : Color.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    (countdownSecondsRemaining <= 1.5 || inactivityPenaltyActive ? Color.red : Color.green).opacity(0.2),
                    in: Capsule()
                )

                Spacer()

                // Audio Status Pill
                HStack(spacing: 5) {
                    Image(systemName: inactivityPenaltyActive ? "speaker.wave.3.fill" : "speaker.slash.fill")
                    Text(inactivityPenaltyActive
                         ? "PENALTY \(Int(round(audioManager.currentTargetVolumeFraction * 100)))%"
                         : "SILENCED")
                        .monospacedDigit()
                }
                .font(.caption.weight(.black))
                .foregroundStyle(inactivityPenaltyActive ? Color.white : Color.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    inactivityPenaltyActive ? Color.red : Color.cyan.opacity(0.2),
                    in: Capsule()
                )
            }

            if let penaltyBannerText {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(penaltyBannerText)
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            }

            // Challenge Mission View (Squats or Steps ONLY)
            Group {
                switch alarm.missionType {
                case .squats:
                    SquatsMissionSubView(
                        repGoal: max(5, alarm.repGoal),
                        onRepCompleted: handleProgressUnitCompleted,
                        onComplete: completeChallenge
                    )
                case .steps:
                    StepsMissionSubView(
                        stepGoal: max(20, alarm.stepGoal),
                        onStepIncremented: handleProgressUnitCompleted,
                        onComplete: completeChallenge
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Exact 20s Initial / 3.0s Inter-Rep Timer State Machine

    private func startChallengeFromTap() {
        hasStartedChallenge = true
        hasCompletedFirstUnit = false
        inactivityPenaltyActive = false
        penaltyBannerText = nil
        // Start 20.0s grace timer strictly from the exact moment "Do Challenge" is tapped
        challengeStartDate = Date()
        lastUnitCompletedDate = nil
        countdownSecondsRemaining = 20.0
        alarmEngine.silenceForChallenge()
    }

    private func handleProgressUnitCompleted(_ newCount: Int) {
        hasCompletedFirstUnit = true
        lastUnitCompletedDate = Date()
        countdownSecondsRemaining = 3.0

        // Instant silence & reset if inactivity penalty alarm was blasting!
        if inactivityPenaltyActive {
            inactivityPenaltyActive = false
            penaltyBannerText = nil
            alarmEngine.silenceForChallenge()
        }
    }

    private func tickChallengeTimers() {
        let now = Date()

        if !hasCompletedFirstUnit {
            guard let start = challengeStartDate else { return }
            let elapsed = now.timeIntervalSince(start)
            countdownSecondsRemaining = max(0.0, 20.0 - elapsed)

            if countdownSecondsRemaining <= 0.0 && !inactivityPenaltyActive {
                triggerInactivityEscalation(
                    message: "20s INITIAL GRACE EXPIRED — RAMPING 1%→50% (15s)! COMPLETE A \(alarm.missionType == .squats ? "SQUAT" : "STEP")!"
                )
            }
        } else {
            guard let lastUnit = lastUnitCompletedDate else { return }
            let elapsed = now.timeIntervalSince(lastUnit)
            countdownSecondsRemaining = max(0.0, 3.0 - elapsed)

            if countdownSecondsRemaining <= 0.0 && !inactivityPenaltyActive {
                triggerInactivityEscalation(
                    message: "3s REP TIMER EXPIRED — RAMPING 1%→50% (15s)! COMPLETE NEXT \(alarm.missionType == .squats ? "SQUAT" : "STEP")!"
                )
            }
        }
    }

    private func triggerInactivityEscalation(message: String) {
        inactivityPenaltyActive = true
        penaltyBannerText = message
        alarmEngine.startInactivityPenalty()
    }

    private func updateClockText() {
        let formatter = DateFormatter()
        formatter.calendar = ISOWeekCalendar.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm:ss"
        currentTimeString = formatter.string(from: Date())
    }

    private func formatSeconds(_ total: TimeInterval) -> String {
        let secs = Int(max(0, total))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    private func completeChallenge() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onDismissAlarm()
    }
}

// MARK: - 1. AI Vision Squats Mission

private struct SquatsMissionSubView: View {
    let repGoal: Int
    let onRepCompleted: (Int) -> Void
    let onComplete: () -> Void

    @StateObject private var detector = VisionPoseDetector()
    @State private var didComplete = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI SQUATS")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.orange)
                    Text("Phase: \(detector.phase.rawValue) • Knee: \(Int(detector.overlayState.kneeAngleDegrees))°")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.cyan)
                }

                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(detector.repCount)")
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                    Text("/ \(repGoal)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

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
                    .stroke(Color.green.opacity(0.75), lineWidth: 2)
            )

            ProgressView(value: Double(min(detector.repCount, repGoal)), total: Double(max(1, repGoal)))
                .tint(.green)
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

// MARK: - 2. CoreMotion Steps Mission

private struct StepsMissionSubView: View {
    let stepGoal: Int
    let onStepIncremented: (Int) -> Void
    let onComplete: () -> Void

    @StateObject private var stepManager = StepCounterManager()
    @State private var didComplete = false

    private var progress: Double {
        guard stepGoal > 0 else { return 1.0 }
        return min(1.0, Double(stepManager.currentSteps) / Double(stepGoal))
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Label("STEPS MISSION (COREMOTION)", systemImage: "figure.walk")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.cyan)
                Text("Walk \(stepGoal) steps to complete the wake challenge")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 18)
                    .frame(width: 220, height: 220)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(colors: [.cyan, .green, .mint], center: .center),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 220, height: 220)
                    .animation(.easeOut(duration: 0.2), value: stepManager.currentSteps)

                VStack(spacing: 4) {
                    Image(systemName: "shoeprints.fill")
                        .font(.title2)
                        .foregroundStyle(.mint)

                    Text("\(stepManager.currentSteps)")
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)

                    Text("/ \(stepGoal) steps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            ProgressView(value: progress, total: 1.0)
                .tint(.green)
                .padding(.horizontal, 12)

            HStack(spacing: 28) {
                VStack(spacing: 2) {
                    Text(String(format: "%.1f m", stepManager.distanceMeters))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                    Text("Distance")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }

                VStack(spacing: 2) {
                    Text("\(max(0, stepGoal - stepManager.currentSteps))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.orange)
                    Text("Remaining")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 26)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

            Text(stepManager.statusMessage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .onAppear {
            stepManager.onStepIncremented = { count in
                onStepIncremented(count)
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
}
