import SwiftUI
import AudioToolbox

struct AlarmRingingView: View {
    let alarm: AlarmItem
    let onDismissAlarm: () -> Void

    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @State private var currentTimeString: String = ""
    private let clockTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.05, blue: 0.16),
                    Color(red: 0.18, green: 0.04, blue: 0.10),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                // Header Status Pill
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    Text(alarmEngine.isUsingSynthEngineFallback
                         ? "RINGING • AVAudioEngine Synth Override"
                         : "RINGING • Mute Switch Bypassed")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.28), in: Capsule())
                .overlay(Capsule().stroke(Color.red.opacity(0.6), lineWidth: 1))
                .padding(.top, 8)

                // Clock & Label
                VStack(spacing: 4) {
                    Text(currentTimeString.isEmpty ? alarm.formattedTime : currentTimeString)
                        .font(.system(size: 54, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)

                    Text(alarm.label)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }

                Divider()
                    .overlay(Color.white.opacity(0.2))
                    .padding(.horizontal, 24)

                // Active Mission Content
                Group {
                    switch alarm.missionType {
                    case .none:
                        StandardDismissMissionView(onComplete: completeMission)
                    case .steps:
                        StepCounterMissionSubView(
                            stepGoal: max(5, alarm.stepGoal),
                            onComplete: completeMission
                        )
                    case .qrBarcode:
                        BarcodeScannerMissionSubView(
                            targetCode: resolvedTargetBarcode,
                            targetLabel: SharedModelContainer.shared.registeredBarcodeLabel,
                            onComplete: completeMission
                        )
                    case .math:
                        MathChallengeMissionSubView(
                            difficulty: alarm.mathDifficulty,
                            problemCount: max(1, alarm.mathProblemCount),
                            onComplete: completeMission
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .interactiveDismissDisabled(true)
        .onAppear {
            updateClockText()
        }
        .onReceive(clockTimer) { _ in
            updateClockText()
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

    private func completeMission() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        onDismissAlarm()
    }
}

// MARK: - 0. Standard Instant Dismissal View

private struct StandardDismissMissionView: View {
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "alarm.waves.left.and.right.fill")
                .font(.system(size: 72))
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .repeating)

            Text("Tap below to stop the alarm and start your day.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            Spacer()

            Button(action: onComplete) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                    Text("DISMISS ALARM")
                        .font(.headline.weight(.bold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.green, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

// MARK: - 1. Step Counter Dismissal Mission (CoreMotion CMPedometer)

private struct StepCounterMissionSubView: View {
    let stepGoal: Int
    let onComplete: () -> Void

    @StateObject private var stepManager = StepCounterManager()
    @State private var didComplete = false

    private var progress: Double {
        guard stepGoal > 0 else { return 1.0 }
        return min(1.0, Double(stepManager.currentSteps) / Double(stepGoal))
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Label("STEP COUNTER MISSION", systemImage: "figure.walk.motion")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.cyan)

                Text("Walk \(stepGoal) steps to shut off the alarm")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            // Circular Step Progress Ring
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 18)
                    .frame(width: 210, height: 210)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            colors: [.cyan, .green, .mint],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 210, height: 210)
                    .animation(.easeOut(duration: 0.25), value: stepManager.currentSteps)

                VStack(spacing: 4) {
                    Image(systemName: "shoeprints.fill")
                        .font(.title2)
                        .foregroundStyle(.mint)

                    Text("\(stepManager.currentSteps)")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)

                    Text("of \(stepGoal) steps")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text(String(format: "%.1f m", stepManager.distanceMeters))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                    Text("Distance")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }

                VStack(spacing: 2) {
                    Text("\(max(0, stepGoal - stepManager.currentSteps))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.orange)
                    Text("Remaining")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 24)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            Text(stepManager.statusMessage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .onAppear {
            stepManager.startTracking()
        }
        .onDisappear {
            stepManager.stopTracking()
        }
        .onChange(of: stepManager.currentSteps) { _, newValue in
            if newValue >= stepGoal && !didComplete {
                didComplete = true
                stepManager.stopTracking()
                onComplete()
            }
        }
    }
}

// MARK: - 2. QR / Barcode Scanner Dismissal Mission (AVFoundation)

private struct BarcodeScannerMissionSubView: View {
    let targetCode: String
    let targetLabel: String
    let onComplete: () -> Void

    @StateObject private var scannerVM = BarcodeScannerViewModel()
    @State private var mismatchFeedback: String?
    @State private var didComplete = false

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Label("QR / BARCODE MISSION", systemImage: "qrcode.viewfinder")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.yellow)

                Text("Scan target: \(targetLabel)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)

                Text("Expected Code: \(targetCode)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
            }

            // Live Camera Viewport
            ZStack {
                BarcodeScannerCameraPreview(session: scannerVM.captureSession)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.yellow.opacity(0.7), lineWidth: 2)
                    )

                // Viewfinder Reticle
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                    .foregroundStyle(.yellow)
                    .frame(width: 210, height: 150)

                VStack {
                    HStack {
                        Spacer()
                        Button {
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
            .frame(maxHeight: 300)

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

            Spacer(minLength: 0)
        }
        .onAppear {
            scannerVM.onCodeDetected = { scannedValue, _ in
                guard !didComplete else { return }
                let expected = targetCode.trimmingCharacters(in: .whitespacesAndNewlines)
                if expected.isEmpty || scannedValue == expected {
                    didComplete = true
                    scannerVM.stopSession()
                    onComplete()
                } else {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    mismatchFeedback = "Scanned '\(scannedValue)' — does not match target '\(expected)'"
                }
            }
            scannerVM.checkPermissionAndStart()
        }
        .onDisappear {
            scannerVM.stopSession()
        }
    }
}

// MARK: - 3. Math Challenge Dismissal Mission

private struct MathProblem {
    let expressionText: String
    let correctAnswer: Int

    static func generate(difficulty: MathDifficulty) -> MathProblem {
        switch difficulty {
        case .easy:
            let a = Int.random(in: 3...9)
            let b = Int.random(in: 3...9)
            let c = Int.random(in: 10...35)
            return MathProblem(
                expressionText: "(\(a) × \(b)) + \(c)",
                correctAnswer: (a * b) + c
            )
        case .medium:
            let a = Int.random(in: 11...19)
            let b = Int.random(in: 4...9)
            let c = Int.random(in: 15...65)
            return MathProblem(
                expressionText: "(\(a) × \(b)) + \(c)",
                correctAnswer: (a * b) + c
            )
        case .hard:
            let a = Int.random(in: 13...28)
            let b = Int.random(in: 11...19)
            let c = Int.random(in: 45...180)
            return MathProblem(
                expressionText: "(\(a) × \(b)) + \(c)",
                correctAnswer: (a * b) + c
            )
        }
    }
}

private struct MathChallengeMissionSubView: View {
    let difficulty: MathDifficulty
    let problemCount: Int
    let onComplete: () -> Void

    @State private var currentProblemIndex: Int = 0
    @State private var currentProblem: MathProblem = MathProblem(expressionText: "(7 × 8) + 14", correctAnswer: 70)
    @State private var userInput: String = ""
    @State private var errorFeedback: Bool = false

    private let keypadRows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["CLR", "0", "⌫"]
    ]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("MATH MISSION", systemImage: "function")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)

                Spacer()

                Text("Problem \(currentProblemIndex + 1) of \(problemCount)")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.25), in: Capsule())
                    .foregroundStyle(.orange)
            }

            // Problem Expression Display
            VStack(spacing: 10) {
                Text(currentProblem.expressionText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                HStack {
                    Text(userInput.isEmpty ? "?" : userInput)
                        .font(.system(size: 32, weight: .heavy, design: .monospaced))
                        .foregroundStyle(errorFeedback ? .red : .cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(errorFeedback ? Color.red : Color.cyan.opacity(0.5), lineWidth: 1.5)
                                )
                        )
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

            // Numeric Keypad
            VStack(spacing: 8) {
                ForEach(keypadRows, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { key in
                            Button {
                                handleKeyTap(key)
                            } label: {
                                Text(key)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }

                Button(action: submitAnswer) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("SUBMIT ANSWER")
                            .font(.headline.weight(.bold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 2)
            }
        }
        .onAppear {
            currentProblem = MathProblem.generate(difficulty: difficulty)
        }
    }

    private func handleKeyTap(_ key: String) {
        errorFeedback = false
        switch key {
        case "CLR":
            userInput = ""
        case "⌫":
            if !userInput.isEmpty {
                userInput.removeLast()
            }
        default:
            if userInput.count < 7 {
                userInput.append(key)
            }
        }
    }

    private func submitAnswer() {
        guard let numeric = Int(userInput) else {
            errorFeedback = true
            return
        }

        if numeric == currentProblem.correctAnswer {
            userInput = ""
            errorFeedback = false
            if currentProblemIndex + 1 >= problemCount {
                onComplete()
            } else {
                currentProblemIndex += 1
                currentProblem = MathProblem.generate(difficulty: difficulty)
            }
        } else {
            errorFeedback = true
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            userInput = ""
        }
    }
}
