import SwiftUI
import AudioToolbox

/// Full-screen locked nuclear wake cover (no dismiss gesture, no snooze, hides alarm controls).
/// Flow:
/// 1. Ringing Gate showing live 90s escalation phase + volume curve + "START MISSION".
/// 2. Active Mission immediately mutes siren, starts a 20s countdown & 3s inactivity watchdog.
///    If 20s expires or >3s passes without progress, blasts 100% nuclear siren until resumed/completed.
/// 3. Completion triggers Good Morning chime + AVSpeechSynthesizer and unlocks UI.
struct AlarmRingingView: View {
    let alarm: AlarmItem
    let onDismissAlarm: () -> Void

    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var audioManager = AlarmAudioManager.shared

    @State private var currentTimeString: String = ""
    @State private var hasStartedMission: Bool = false

    // 20-second mission countdown & 3-second inactivity watchdog
    @State private var missionSecondsRemaining: Double = 20.0
    @State private var secondsSinceLastProgress: Double = 0.0
    @State private var watchdogPenaltyReason: String?

    private let uiTickTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: audioManager.isPenaltyBlastActive
                    ? [Color(red: 0.42, green: 0.02, blue: 0.04), Color(red: 0.18, green: 0.01, blue: 0.02), .black]
                    : [Color(red: 0.08, green: 0.04, blue: 0.12), Color(red: 0.14, green: 0.03, blue: 0.06), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                if !hasStartedMission {
                    ringingGateView
                } else {
                    activeMissionContainerView
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .onAppear {
            updateClockText()
        }
        .onReceive(uiTickTimer) { _ in
            updateClockText()
            if hasStartedMission {
                tickMissionWatchdog()
            }
        }
    }

    // MARK: - Stage 1: Escalating Ringing Gate

    private var ringingGateView: some View {
        VStack(spacing: 22) {
            // Escalation Phase Badge
            HStack(spacing: 8) {
                Image(systemName: audioManager.currentVolumeFraction > 0 ? "speaker.wave.3.fill" : "iphone.radiowaves.left.and.right")
                    .foregroundStyle(audioManager.currentVolumeFraction > 0.3 ? .red : .orange)
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

                Text(alarm.label.uppercased())
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.orange)

                Label(alarm.missionSummary, systemImage: alarm.missionType.iconName)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .foregroundStyle(.white)
            }

            // Live 90-Second Escalation Telemetry
            VStack(spacing: 10) {
                HStack {
                    Text("SIREN VOLUME")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(round(audioManager.currentVolumeFraction * 100)))%")
                        .font(.headline.weight(.black).monospacedDigit())
                        .foregroundStyle(audioManager.currentVolumeFraction >= 0.99 ? .red : .orange)
                }

                ProgressView(value: Double(audioManager.currentVolumeFraction), total: 1.0)
                    .tint(audioManager.currentVolumeFraction >= 0.3 ? .red : .orange)

                HStack {
                    Text("Elapsed: \(formatSeconds(audioManager.wakeElapsedSeconds))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("Max Siren at 01:30")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

            Spacer()

            // No Snooze Notice
            Text("NO SNOOZE • MUTE SWITCH OVERRIDDEN • 20s MISSION WINDOW")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            // Start Mission CTA
            Button {
                startMissionFlow()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: alarm.missionType.iconName)
                        .font(.title2.weight(.bold))
                    Text("START MISSION")
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

    // MARK: - Stage 2: Active Locked Mission + Watchdog

    private var activeMissionContainerView: some View {
        VStack(spacing: 12) {
            // Countdown & Watchdog HUD
            HStack(spacing: 10) {
                // 20-Second Mission Timer Pill
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                    Text(String(format: "%.1fs", max(0, missionSecondsRemaining)))
                        .monospacedDigit()
                }
                .font(.headline.weight(.black))
                .foregroundStyle(missionSecondsRemaining <= 5 ? .red : .green)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    (missionSecondsRemaining <= 5 ? Color.red : Color.green).opacity(0.2),
                    in: Capsule()
                )

                Spacer()

                // 3-Second Inactivity Watchdog Pill
                HStack(spacing: 6) {
                    Image(systemName: audioManager.isPenaltyBlastActive ? "speaker.wave.3.fill" : "bolt.heart.fill")
                    Text(audioManager.isPenaltyBlastActive
                         ? "100% PENALTY"
                         : String(format: "IDLE %.1f/3s", min(3.0, secondsSinceLastProgress)))
                        .monospacedDigit()
                }
                .font(.caption.weight(.black))
                .foregroundStyle(audioManager.isPenaltyBlastActive ? .white : .cyan)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    audioManager.isPenaltyBlastActive ? Color.red : Color.cyan.opacity(0.2),
                    in: Capsule()
                )
            }

            if let penalty = watchdogPenaltyReason {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(penalty)
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            }

            // Mission View Switcher
            Group {
                switch alarm.missionType {
                case .pushups:
                    VisionExerciseMissionSubView(
                        mode: .pushups,
                        repGoal: max(3, alarm.repGoal),
                        onProgress: registerMissionProgress,
                        onComplete: completeMission
                    )
                case .squats:
                    VisionExerciseMissionSubView(
                        mode: .squats,
                        repGoal: max(3, alarm.repGoal),
                        onProgress: registerMissionProgress,
                        onComplete: completeMission
                    )
                case .qrBarcode:
                    BarcodeScannerMissionSubView(
                        targetCode: resolvedTargetBarcode,
                        targetLabel: SharedModelContainer.shared.registeredBarcodeLabel,
                        onProgress: registerMissionProgress,
                        onComplete: completeMission
                    )
                case .steps:
                    StepCounterMissionSubView(
                        stepGoal: max(5, alarm.stepGoal),
                        onProgress: registerMissionProgress,
                        onComplete: completeMission
                    )
                case .math:
                    MathChallengeMissionSubView(
                        difficulty: alarm.mathDifficulty,
                        problemCount: max(1, alarm.mathProblemCount),
                        onProgress: registerMissionProgress,
                        onComplete: completeMission
                    )
                case .none:
                    VisionExerciseMissionSubView(
                        mode: .pushups,
                        repGoal: max(3, alarm.repGoal),
                        onProgress: registerMissionProgress,
                        onComplete: completeMission
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Watchdog Logic

    private func startMissionFlow() {
        hasStartedMission = true
        missionSecondsRemaining = 20.0
        secondsSinceLastProgress = 0.0
        watchdogPenaltyReason = nil
        alarmEngine.pauseSirenForMission()
    }

    private func registerMissionProgress() {
        secondsSinceLastProgress = 0.0
        // If inactivity penalty was firing while time still remains, mute siren again as user resumed!
        if missionSecondsRemaining > 0 && audioManager.isPenaltyBlastActive {
            watchdogPenaltyReason = nil
            alarmEngine.pauseSirenForMission()
        }
    }

    private func tickMissionWatchdog() {
        if missionSecondsRemaining > 0 {
            missionSecondsRemaining = max(0, missionSecondsRemaining - 0.1)
        }
        secondsSinceLastProgress += 0.1

        if missionSecondsRemaining <= 0 {
            watchdogPenaltyReason = "20s WINDOW EXPIRED — 100% SIREN ACTIVE UNTIL COMPLETED!"
            if !audioManager.isPenaltyBlastActive {
                alarmEngine.triggerPenaltyBlast()
            }
        } else if secondsSinceLastProgress > 3.0 {
            watchdogPenaltyReason = "NO PROGRESS FOR >3s — MOVE NOW TO MUTE 100% SIREN!"
            if !audioManager.isPenaltyBlastActive {
                alarmEngine.triggerPenaltyBlast()
            }
        }
    }

    private var resolvedTargetBarcode: String {
        let trimmedCustom = alarm.customTargetBarcode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            return trimmedCustom
        }
        return SharedModelContainer.shared.registeredBarcode
    }

    private func updateClockText() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        currentTimeString = formatter.string(from: Date())
    }

    private func formatSeconds(_ total: TimeInterval) -> String {
        let secs = Int(max(0, total))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    private func completeMission() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        onDismissAlarm()
    }
}

// MARK: - 1. AI Camera Pushups / Squats Vision Mission

private struct VisionExerciseMissionSubView: View {
    let mode: VisionExerciseMode
    let repGoal: Int
    let onProgress: () -> Void
    let onComplete: () -> Void

    @StateObject private var detector = VisionPoseDetector()
    @State private var didComplete = false

    var body: some View {
        VStack(spacing: 12) {
            // Header & Live Rep Counter
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.orange)
                    Text("Phase: \(detector.phase.rawValue) • Angle: \(Int(detector.overlayState.activeAngleDegrees))°")
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

            // Live Front Camera + Neon Skeleton Overlay
            ZStack {
                BarcodeScannerCameraPreview(session: detector.captureSession)
                PoseSkeletonOverlayView(state: detector.overlayState)

                // Top Status Tag inside Camera
                VStack {
                    HStack {
                        Label("ON-DEVICE VISION", systemImage: "eye.fill")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())

                        Spacer()

                        if mode == .pushups {
                            Text(detector.overlayState.torsoAligned ? "TORSO OK" : "ALIGN TORSO")
                                .font(.caption2.weight(.black))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    (detector.overlayState.torsoAligned ? Color.green : Color.orange).opacity(0.85),
                                    in: Capsule()
                                )
                                .foregroundStyle(.black)
                        }
                    }
                    .padding(10)

                    Spacer()

                    Text(detector.overlayState.postureHint)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.72))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(detector.overlayState.torsoAligned ? Color.green.opacity(0.75) : Color.orange, lineWidth: 2)
            )

            // Progress Bar
            ProgressView(value: Double(min(detector.repCount, repGoal)), total: Double(max(1, repGoal)))
                .tint(.green)
        }
        .onAppear {
            detector.onProgressDetected = {
                onProgress()
            }
            detector.start(mode: mode)
        }
        .onDisappear {
            detector.stop()
        }
        .onChange(of: detector.repCount) { _, newCount in
            if newCount >= repGoal && !didComplete {
                didComplete = true
                detector.stop()
                onComplete()
            }
        }
    }
}

// MARK: - 2. QR / Barcode Scanner Dismissal Mission

private struct BarcodeScannerMissionSubView: View {
    let targetCode: String
    let targetLabel: String
    let onProgress: () -> Void
    let onComplete: () -> Void

    @StateObject private var scannerVM = BarcodeScannerViewModel()
    @State private var mismatchFeedback: String?
    @State private var didComplete = false

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Label("QR / BARCODE MISSION", systemImage: "qrcode.viewfinder")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.yellow)

                Text("Scan: \(targetLabel)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Expected: \(targetCode)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
            }

            ZStack {
                BarcodeScannerCameraPreview(session: scannerVM.captureSession)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.yellow.opacity(0.75), lineWidth: 2)
                    )

                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                    .foregroundStyle(.yellow)
                    .frame(width: 220, height: 150)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            onProgress()
                            scannerVM.toggleTorch()
                        } label: {
                            Label(
                                scannerVM.isTorchOn ? "Light ON" : "Light",
                                systemImage: scannerVM.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill"
                            )
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(12)
                    }
                    Spacer()
                }
            }

            if let mismatchFeedback {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(mismatchFeedback)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text(scannerVM.statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear {
            scannerVM.onCodeDetected = { scannedValue, _ in
                guard !didComplete else { return }
                onProgress()
                let expected = targetCode.trimmingCharacters(in: .whitespacesAndNewlines)
                if expected.isEmpty || scannedValue == expected {
                    didComplete = true
                    scannerVM.stopSession()
                    onComplete()
                } else {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    mismatchFeedback = "Scanned '\(scannedValue)' — expected '\(expected)'"
                }
            }
            scannerVM.checkPermissionAndStart()
        }
        .onDisappear {
            scannerVM.stopSession()
        }
    }
}

// MARK: - 3. Legacy Step Counter & Math Fallbacks

private struct StepCounterMissionSubView: View {
    let stepGoal: Int
    let onProgress: () -> Void
    let onComplete: () -> Void

    @StateObject private var stepManager = StepCounterManager()
    @State private var didComplete = false

    var body: some View {
        VStack(spacing: 20) {
            Label("STEP COUNTER MISSION", systemImage: "figure.walk.motion")
                .font(.headline.weight(.bold))
                .foregroundStyle(.cyan)

            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 16)
                    .frame(width: 200, height: 200)
                Circle()
                    .trim(from: 0, to: min(1.0, Double(stepManager.currentSteps) / Double(max(1, stepGoal))))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 200, height: 200)

                VStack {
                    Text("\(stepManager.currentSteps)")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .monospacedDigit()
                    Text("of \(stepGoal) steps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .onAppear { stepManager.startTracking() }
        .onDisappear { stepManager.stopTracking() }
        .onChange(of: stepManager.currentSteps) { _, newValue in
            onProgress()
            if newValue >= stepGoal && !didComplete {
                didComplete = true
                stepManager.stopTracking()
                onComplete()
            }
        }
    }
}

private struct MathProblem {
    let expressionText: String
    let correctAnswer: Int

    static func generate(difficulty: MathDifficulty) -> MathProblem {
        switch difficulty {
        case .easy:
            let a = Int.random(in: 3...9), b = Int.random(in: 3...9), c = Int.random(in: 10...35)
            return MathProblem(expressionText: "(\(a) × \(b)) + \(c)", correctAnswer: (a * b) + c)
        case .medium:
            let a = Int.random(in: 11...19), b = Int.random(in: 4...9), c = Int.random(in: 15...65)
            return MathProblem(expressionText: "(\(a) × \(b)) + \(c)", correctAnswer: (a * b) + c)
        case .hard:
            let a = Int.random(in: 13...28), b = Int.random(in: 11...19), c = Int.random(in: 45...180)
            return MathProblem(expressionText: "(\(a) × \(b)) + \(c)", correctAnswer: (a * b) + c)
        }
    }
}

private struct MathChallengeMissionSubView: View {
    let difficulty: MathDifficulty
    let problemCount: Int
    let onProgress: () -> Void
    let onComplete: () -> Void

    @State private var currentProblemIndex: Int = 0
    @State private var currentProblem: MathProblem = MathProblem(expressionText: "(7 × 8) + 14", correctAnswer: 70)
    @State private var userInput: String = ""
    @State private var errorFeedback: Bool = false

    private let keypadRows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["CLR", "0", "⌫"]]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("MATH MISSION", systemImage: "function")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                Text("Problem \(currentProblemIndex + 1) / \(problemCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }

            Text(currentProblem.expressionText)
                .font(.system(size: 32, weight: .bold, design: .rounded))

            Text(userInput.isEmpty ? "?" : userInput)
                .font(.system(size: 30, weight: .heavy, design: .monospaced))
                .foregroundStyle(errorFeedback ? .red : .cyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 8) {
                ForEach(keypadRows, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { key in
                            Button {
                                onProgress()
                                errorFeedback = false
                                switch key {
                                case "CLR": userInput = ""
                                case "⌫": if !userInput.isEmpty { userInput.removeLast() }
                                default: if userInput.count < 7 { userInput.append(key) }
                                }
                            } label: {
                                Text(key)
                                    .font(.title3.weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 46)
                                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }

                Button {
                    onProgress()
                    if let val = Int(userInput), val == currentProblem.correctAnswer {
                        userInput = ""
                        if currentProblemIndex + 1 >= problemCount {
                            onComplete()
                        } else {
                            currentProblemIndex += 1
                            currentProblem = MathProblem.generate(difficulty: difficulty)
                        }
                    } else {
                        errorFeedback = true
                        userInput = ""
                    }
                } label: {
                    Text("SUBMIT")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onAppear {
            currentProblem = MathProblem.generate(difficulty: difficulty)
        }
    }
}
