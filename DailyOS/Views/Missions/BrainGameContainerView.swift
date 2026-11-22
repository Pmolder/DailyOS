import SwiftUI
import AudioToolbox

/// Stage-2 Cognitive Brain Activation container (Solar-Orange & Obsidian theme).
/// Hosts all 4 mini-games (~30-60s each): Reflex Strike, Memory Grid, Math Sprint, Node Connect.
/// Includes a 15-second Anti-Fall-Back-Asleep Guard that resumes the alarm ramp if interaction stops.
struct BrainGameContainerView: View {
    let game: BrainGameMode
    let reflexThresholdMs: Int
    let isPracticeMode: Bool
    let onCompleted: (String) -> Void
    var onCancelPractice: (() -> Void)? = nil

    @ObservedObject private var audioManager = AlarmAudioManager.shared

    @State private var lastInteractionDate: Date = Date()
    @State private var inactivitySecondsRemaining: Double = 15.0
    @State private var sleepGuardPenaltyActive: Bool = false

    private let guardTickTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            SolarTheme.obsidian.ignoresSafeArea()

            VStack(spacing: 14) {
                // Top Stage-2 HUD
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: game.iconName)
                            .foregroundStyle(SolarTheme.solarBright)
                        Text(isPracticeMode ? "PRACTICE • \(game.displayName.uppercased())" : "STAGE 2 OF 2 • \(game.displayName.uppercased())")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(SolarTheme.charcoal, in: Capsule())
                    .overlay(Capsule().stroke(SolarTheme.solarCore.opacity(0.6), lineWidth: 1))

                    Spacer()

                    if isPracticeMode, let onCancelPractice {
                        Button("Close") {
                            onCancelPractice()
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SolarTheme.solarBright)
                    } else {
                        // 15-Second Anti-Fall-Back-Asleep Guard Pill
                        HStack(spacing: 5) {
                            Image(systemName: sleepGuardPenaltyActive ? "speaker.wave.3.fill" : "eye.fill")
                            Text(sleepGuardPenaltyActive
                                 ? "WAKE UP!"
                                 : String(format: "%.0fs", ceil(max(0, inactivitySecondsRemaining))))
                                .monospacedDigit()
                        }
                        .font(.caption.weight(.black))
                        .foregroundStyle(sleepGuardPenaltyActive ? Color.white : (inactivitySecondsRemaining <= 4 ? Color.red : SolarTheme.solarBright))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            sleepGuardPenaltyActive ? Color.red : SolarTheme.charcoal,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                sleepGuardPenaltyActive ? Color.red : SolarTheme.hairline,
                                lineWidth: 1
                            )
                        )
                    }
                }

                if sleepGuardPenaltyActive && !isPracticeMode {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("15s INACTIVITY DETECTED — ALARM RESUMED! TAP GAME TO SILENCE!")
                            .font(.caption2.weight(.black))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
                }

                // Active Mini-Game Content
                Group {
                    switch game {
                    case .reflexStrike, .random, .off:
                        ReflexStrikeGameView(
                            thresholdMs: reflexThresholdMs,
                            onInteraction: registerInteraction,
                            onWin: { summary in
                                finishGame(summary: summary)
                            }
                        )
                    case .memoryGrid:
                        MemoryGridGameView(
                            onInteraction: registerInteraction,
                            onWin: { summary in
                                finishGame(summary: summary)
                            }
                        )
                    case .mathSprint:
                        MathSprintGameView(
                            onInteraction: registerInteraction,
                            onWin: { summary in
                                finishGame(summary: summary)
                            }
                        )
                    case .nodeConnect:
                        NodeConnectGameView(
                            onInteraction: registerInteraction,
                            onWin: { summary in
                                finishGame(summary: summary)
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            lastInteractionDate = Date()
            inactivitySecondsRemaining = 15.0
            sleepGuardPenaltyActive = false
        }
        .onReceive(guardTickTimer) { _ in
            guard !isPracticeMode else { return }
            let elapsed = Date().timeIntervalSince(lastInteractionDate)
            inactivitySecondsRemaining = max(0.0, 15.0 - elapsed)

            if inactivitySecondsRemaining <= 0.0 && !sleepGuardPenaltyActive {
                sleepGuardPenaltyActive = true
                audioManager.startOrResumeChallengePenaltyRamp()
            }
        }
    }

    private func registerInteraction() {
        lastInteractionDate = Date()
        inactivitySecondsRemaining = 15.0
        if sleepGuardPenaltyActive && !isPracticeMode {
            sleepGuardPenaltyActive = false
            _ = audioManager.pauseChallengePenaltyAndSaveProgress()
        }
    }

    private func finishGame(summary: String) {
        registerInteraction()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCompleted(summary)
    }
}

// MARK: - Game 1: Reflex Strike (3 Valid Strikes Under Configurable Threshold)

private struct ReflexStrikeGameView: View {
    let thresholdMs: Int
    let onInteraction: () -> Void
    let onWin: (String) -> Void

    private enum PadState {
        case waiting
        case goOrange
        case falseStart
        case tooSlow(Int)
        case goodHit(Int)
    }

    @State private var padState: PadState = .waiting
    @State private var validStrikeTimesMs: [Int] = []
    @State private var goTimestamp: CFAbsoluteTime = 0
    @State private var scheduledWorkItem: DispatchWorkItem?
    @State private var lastResultCaption: String = "Tap only the instant the pad flashes Solar Orange."

    private let requiredStrikes = 3
    private let impact = UIImpactFeedbackGenerator(style: .heavy)

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("REFLEX STRIKE")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
                Text("Land \(requiredStrikes) strikes under \(thresholdMs) ms")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SolarTheme.solarBright)
            }

            // Strike Progress Pills
            HStack(spacing: 10) {
                ForEach(0..<requiredStrikes, id: \.self) { idx in
                    let achieved = idx < validStrikeTimesMs.count
                    VStack(spacing: 2) {
                        Image(systemName: achieved ? "bolt.fill" : "bolt")
                            .foregroundStyle(achieved ? Color.black : Color.secondary)
                        Text(achieved ? "\(validStrikeTimesMs[idx]) ms" : "Strike \(idx + 1)")
                            .font(.caption2.weight(.black).monospacedDigit())
                            .foregroundStyle(achieved ? Color.black : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        achieved ? SolarTheme.solarBright : SolarTheme.charcoal,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(achieved ? SolarTheme.solarGold : SolarTheme.hairline, lineWidth: 1)
                    )
                }
            }

            // Massive Target Pad
            Button {
                handlePadTap()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(padBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28)
                                .stroke(padBorderColor, lineWidth: 3)
                        )

                    VStack(spacing: 14) {
                        Image(systemName: padIconName)
                            .font(.system(size: 56, weight: .black))
                            .foregroundStyle(padForeground)

                        Text(padHeadline)
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .foregroundStyle(padForeground)
                            .multilineTextAlignment(.center)

                        Text(lastResultCaption)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(padForeground.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            scheduleNextFlash()
        }
        .onDisappear {
            scheduledWorkItem?.cancel()
        }
    }

    private var padBackground: AnyShapeStyle {
        switch padState {
        case .goOrange:
            return AnyShapeStyle(SolarTheme.sunriseGradient)
        case .falseStart, .tooSlow:
            return AnyShapeStyle(Color.red.opacity(0.85))
        case .goodHit:
            return AnyShapeStyle(Color.green.opacity(0.85))
        case .waiting:
            return AnyShapeStyle(SolarTheme.charcoal)
        }
    }

    private var padBorderColor: Color {
        switch padState {
        case .goOrange: return .white
        case .falseStart, .tooSlow: return .red
        case .goodHit: return .green
        case .waiting: return SolarTheme.solarCore.opacity(0.45)
        }
    }

    private var padForeground: Color {
        switch padState {
        case .goOrange, .goodHit: return SolarTheme.obsidian
        case .waiting, .falseStart, .tooSlow: return .white
        }
    }

    private var padIconName: String {
        switch padState {
        case .waiting: return "hand.raised.fill"
        case .goOrange: return "bolt.fill"
        case .falseStart: return "xmark.octagon.fill"
        case .tooSlow: return "tortoise.fill"
        case .goodHit: return "checkmark.seal.fill"
        }
    }

    private var padHeadline: String {
        switch padState {
        case .waiting: return "WAIT FOR ORANGE..."
        case .goOrange: return "TAP NOW!"
        case .falseStart: return "TOO EARLY!"
        case .tooSlow(let ms): return "\(ms) ms"
        case .goodHit(let ms): return "\(ms) ms!"
        }
    }

    private func scheduleNextFlash() {
        scheduledWorkItem?.cancel()
        padState = .waiting
        let delay = Double.random(in: 1.5...3.8)
        let work = DispatchWorkItem {
            goTimestamp = CFAbsoluteTimeGetCurrent()
            padState = .goOrange
            lastResultCaption = "STRIKE NOW (< \(thresholdMs) ms)!"
            impact.impactOccurred(intensity: 1.0)
        }
        scheduledWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handlePadTap() {
        onInteraction()

        switch padState {
        case .waiting:
            // False start! Restart attempt
            scheduledWorkItem?.cancel()
            padState = .falseStart
            lastResultCaption = "False start — wait until the pad flashes Solar Orange!"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            queueNextAttempt(after: 1.0)

        case .goOrange:
            let elapsedMs = max(1, Int(round((CFAbsoluteTimeGetCurrent() - goTimestamp) * 1000.0)))
            if elapsedMs <= thresholdMs {
                validStrikeTimesMs.append(elapsedMs)
                padState = .goodHit(elapsedMs)
                lastResultCaption = "Locked in \(elapsedMs) ms! (\(validStrikeTimesMs.count)/\(requiredStrikes))"
                UINotificationFeedbackGenerator().notificationOccurred(.success)

                if validStrikeTimesMs.count >= requiredStrikes {
                    let avg = validStrikeTimesMs.reduce(0, +) / validStrikeTimesMs.count
                    scheduledWorkItem?.cancel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        onWin("Reflex Strike • Avg \(avg) ms")
                    }
                } else {
                    queueNextAttempt(after: 0.9)
                }
            } else {
                padState = .tooSlow(elapsedMs)
                lastResultCaption = "Too slow (\(elapsedMs) ms > \(thresholdMs) ms). Stay sharp!"
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                queueNextAttempt(after: 1.0)
            }

        case .falseStart, .tooSlow, .goodHit:
            break
        }
    }

    private func queueNextAttempt(after seconds: Double) {
        scheduledWorkItem?.cancel()
        let work = DispatchWorkItem {
            lastResultCaption = "Hold steady… wait for Solar Orange."
            scheduleNextFlash()
        }
        scheduledWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - Game 2: Memory Grid (4x4 Pattern Recall, 3 Escalating Rounds: 4 -> 5 -> 6 Tiles)

private struct MemoryGridGameView: View {
    let onInteraction: () -> Void
    let onWin: (String) -> Void

    @State private var currentRound: Int = 1 // 1..3
    @State private var targetTiles: Set<Int> = []
    @State private var selectedTiles: Set<Int> = []
    @State private var wrongTileIndex: Int?
    @State private var isShowingPattern: Bool = true
    @State private var statusText: String = "Memorize the glowing Solar-Orange tiles…"
    @State private var mistakes: Int = 0
    @State private var hideWorkItem: DispatchWorkItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private var tileCountForCurrentRound: Int {
        switch currentRound {
        case 1: return 4
        case 2: return 5
        default: return 6
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("MEMORY GRID")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
                Text("Round \(currentRound) of 3 • Recall \(tileCountForCurrentRound) tiles")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SolarTheme.solarBright)
            }

            HStack(spacing: 8) {
                ForEach(1...3, id: \.self) { round in
                    Capsule()
                        .fill(round < currentRound ? Color.green : (round == currentRound ? SolarTheme.solarBright : SolarTheme.elevated))
                        .frame(height: 6)
                }
            }

            Text(statusText)
                .font(.caption.weight(.bold))
                .foregroundStyle(wrongTileIndex != nil ? Color.red : Color.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(minHeight: 34)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(0..<16, id: \.self) { index in
                    let isTargetVisible = isShowingPattern && targetTiles.contains(index)
                    let isMatched = !isShowingPattern && selectedTiles.contains(index)
                    let isWrong = wrongTileIndex == index

                    Button {
                        handleTileTap(index)
                    } label: {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(tileFill(visible: isTargetVisible, matched: isMatched, wrong: isWrong))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(tileBorder(visible: isTargetVisible, matched: isMatched, wrong: isWrong), lineWidth: 2)
                            )
                            .shadow(
                                color: (isTargetVisible || isMatched) ? SolarTheme.solarCore.opacity(0.45) : Color.clear,
                                radius: 8
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isShowingPattern || wrongTileIndex != nil)
                }
            }
            .padding(14)
            .solarCard(cornerRadius: 20)

            Spacer()
        }
        .onAppear {
            startRound(currentRound)
        }
        .onDisappear {
            hideWorkItem?.cancel()
        }
    }

    private func tileFill(visible: Bool, matched: Bool, wrong: Bool) -> Color {
        if wrong { return .red }
        if visible || matched { return SolarTheme.solarCore }
        return SolarTheme.elevated
    }

    private func tileBorder(visible: Bool, matched: Bool, wrong: Bool) -> Color {
        if wrong { return .white }
        if visible || matched { return SolarTheme.solarGold }
        return SolarTheme.hairline
    }

    private func startRound(_ round: Int) {
        hideWorkItem?.cancel()
        currentRound = round
        selectedTiles = []
        wrongTileIndex = nil
        isShowingPattern = true
        statusText = "Memorize \(tileCountForCurrentRound) glowing tiles…"

        let shuffled = Array(0..<16).shuffled()
        targetTiles = Set(shuffled.prefix(tileCountForCurrentRound))

        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingPattern = false
                statusText = "Tap the \(tileCountForCurrentRound) tiles you saw (\(selectedTiles.count)/\(tileCountForCurrentRound))"
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func handleTileTap(_ index: Int) {
        onInteraction()
        guard !isShowingPattern, wrongTileIndex == nil else { return }
        guard !selectedTiles.contains(index) else { return }

        if targetTiles.contains(index) {
            selectedTiles.insert(index)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            statusText = "Matched \(selectedTiles.count) of \(tileCountForCurrentRound)"

            if selectedTiles.count == targetTiles.count {
                if currentRound >= 3 {
                    onWin("Memory Grid • 3/3 rounds (\(mistakes) err)")
                } else {
                    statusText = "Round \(currentRound) cleared! Next round…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        startRound(currentRound + 1)
                    }
                }
            }
        } else {
            mistakes += 1
            wrongTileIndex = index
            statusText = "Wrong tile! Replaying fresh Round \(currentRound) pattern…"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                startRound(currentRound)
            }
        }
    }
}

// MARK: - Game 3: Math Sprint (5 Problems, Custom Black & Solar-Orange Numeric Keypad)

private struct SprintMathEquation {
    let prompt: String
    let answer: Int

    static func generate() -> SprintMathEquation {
        let variant = Int.random(in: 0...3)
        switch variant {
        case 0:
            let a = Int.random(in: 14...49)
            let b = Int.random(in: 13...48)
            return SprintMathEquation(prompt: "\(a) + \(b)", answer: a + b)
        case 1:
            let a = Int.random(in: 42...95)
            let b = Int.random(in: 13...38)
            return SprintMathEquation(prompt: "\(a) − \(b)", answer: a - b)
        case 2:
            let a = Int.random(in: 6...12)
            let b = Int.random(in: 4...9)
            let c = Int.random(in: 5...19)
            return SprintMathEquation(prompt: "\(a) × \(b) + \(c)", answer: (a * b) + c)
        default:
            let a = Int.random(in: 7...14)
            let b = Int.random(in: 4...9)
            return SprintMathEquation(prompt: "\(a) × \(b)", answer: a * b)
        }
    }
}

private struct MathSprintGameView: View {
    let onInteraction: () -> Void
    let onWin: (String) -> Void

    @State private var solvedCount: Int = 0
    @State private var equation: SprintMathEquation = SprintMathEquation.generate()
    @State private var input: String = ""
    @State private var shakeOffset: CGFloat = 0
    @State private var showErrorFlash: Bool = false
    @State private var startTimestamp: Date = Date()

    private let totalProblems = 5
    private let keypadRows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["CLR", "0", "⌫"]
    ]

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("MATH SPRINT")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)

                // Live Progress Dots (1/5 .. 5/5)
                HStack(spacing: 10) {
                    ForEach(0..<totalProblems, id: \.self) { idx in
                        Circle()
                            .fill(idx < solvedCount ? Color.green : (idx == solvedCount ? SolarTheme.solarBright : SolarTheme.elevated))
                            .frame(width: 12, height: 12)
                    }
                    Text("\(min(solvedCount + 1, totalProblems))/\(totalProblems)")
                        .font(.caption.weight(.black).monospacedDigit())
                        .foregroundStyle(SolarTheme.solarBright)
                }
            }

            // Equation & Input Display
            VStack(spacing: 12) {
                Text(equation.prompt)
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text(input.isEmpty ? "—" : input)
                    .font(.system(size: 34, weight: .black, design: .monospaced))
                    .foregroundStyle(showErrorFlash ? Color.red : SolarTheme.solarGold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(SolarTheme.obsidian, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(showErrorFlash ? Color.red : SolarTheme.solarCore.opacity(0.6), lineWidth: 2)
                    )
                    .offset(x: shakeOffset)
            }
            .padding(16)
            .solarCard(cornerRadius: 18)

            // High-Contrast In-App Numeric Keypad
            VStack(spacing: 9) {
                ForEach(keypadRows, id: \.self) { row in
                    HStack(spacing: 9) {
                        ForEach(row, id: \.self) { key in
                            Button {
                                handleKey(key)
                            } label: {
                                Text(key)
                                    .font(.title2.weight(.black))
                                    .foregroundStyle(key == "CLR" || key == "⌫" ? SolarTheme.solarBright : Color.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                                    .background(SolarTheme.charcoal, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(SolarTheme.hairline, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button(action: submitAnswer) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("SUBMIT")
                            .font(.headline.weight(.black))
                    }
                    .foregroundStyle(SolarTheme.obsidian)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(SolarTheme.sunriseGradient, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            startTimestamp = Date()
            equation = SprintMathEquation.generate()
        }
    }

    private func handleKey(_ key: String) {
        onInteraction()
        showErrorFlash = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch key {
        case "CLR":
            input = ""
        case "⌫":
            if !input.isEmpty { input.removeLast() }
        default:
            if input.count < 5 { input.append(key) }
        }
    }

    private func submitAnswer() {
        onInteraction()
        guard let numeric = Int(input), numeric == equation.answer else {
            showErrorFlash = true
            input = ""
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            triggerShake()
            return
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        input = ""
        solvedCount += 1

        if solvedCount >= totalProblems {
            let elapsed = max(1, Int(round(Date().timeIntervalSince(startTimestamp))))
            onWin("Math Sprint • 5/5 in \(elapsed)s")
        } else {
            equation = SprintMathEquation.generate()
        }
    }

    private func triggerShake() {
        withAnimation(.linear(duration: 0.06)) { shakeOffset = -12 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.linear(duration: 0.06)) { shakeOffset = 12 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.linear(duration: 0.06)) { shakeOffset = -8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.2)) { shakeOffset = 0 }
        }
    }
}

// MARK: - Game 4: Node Connect (2 Rounds: 1..8 then Alternating 1->A->2->B->3->C->4->D)

private struct ConnectNode: Identifiable {
    let id: Int // Order index 0...7
    let label: String
    let normalizedPosition: CGPoint // (0.14...0.86, 0.14...0.86)
}

private struct NodeConnectGameView: View {
    let onInteraction: () -> Void
    let onWin: (String) -> Void

    @State private var currentRound: Int = 1 // 1 or 2
    @State private var nodes: [ConnectNode] = []
    @State private var nextExpectedOrderIndex: Int = 0
    @State private var shakingNodeID: Int?
    @State private var startTimestamp: Date = Date()

    private let round1Labels = ["1", "2", "3", "4", "5", "6", "7", "8"]
    private let round2Labels = ["1", "A", "2", "B", "3", "C", "4", "D"]

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("NODE CONNECT")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
                Text(currentRound == 1
                     ? "Round 1/2 • Link 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8"
                     : "Round 2/2 • Alternate 1 → A → 2 → B → 3 → C → 4 → D")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SolarTheme.solarBright)
                    .multilineTextAlignment(.center)
            }

            // Interactive Dark Canvas with Live Solar-Orange Connecting Lines
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                ZStack {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(SolarTheme.charcoal)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22)
                                .stroke(SolarTheme.hairline, lineWidth: 1)
                        )

                    // Live Solar-Orange path linking completed nodes
                    if nextExpectedOrderIndex >= 2 {
                        Path { path in
                            let connected = nodes
                                .filter { $0.id < nextExpectedOrderIndex }
                                .sorted { $0.id < $1.id }
                            for (i, node) in connected.enumerated() {
                                let pt = CGPoint(x: node.normalizedPosition.x * w, y: node.normalizedPosition.y * h)
                                if i == 0 {
                                    path.move(to: pt)
                                } else {
                                    path.addLine(to: pt)
                                }
                            }
                        }
                        .stroke(
                            SolarTheme.solarBright,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                        )
                    }

                    // 8 Non-Overlapping Circular Nodes
                    ForEach(nodes) { node in
                        let isDone = node.id < nextExpectedOrderIndex
                        let isShaking = shakingNodeID == node.id

                        Button {
                            handleNodeTap(node)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(isDone ? SolarTheme.solarCore : (isShaking ? Color.red : SolarTheme.elevated))
                                    .frame(width: 56, height: 56)
                                    .overlay(
                                        Circle()
                                            .stroke(isDone ? SolarTheme.solarGold : SolarTheme.solarCore.opacity(0.65), lineWidth: 2.5)
                                    )
                                    .shadow(color: isDone ? SolarTheme.solarCore.opacity(0.5) : .clear, radius: 8)

                                Text(node.label)
                                    .font(.title3.weight(.black))
                                    .foregroundStyle(isDone ? SolarTheme.obsidian : Color.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .offset(x: isShaking ? 8 : 0)
                        .position(
                            x: node.normalizedPosition.x * w,
                            y: node.normalizedPosition.y * h
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            startTimestamp = Date()
            buildRound(1)
        }
    }

    private func buildRound(_ round: Int) {
        currentRound = round
        nextExpectedOrderIndex = 0
        shakingNodeID = nil

        let labels = round == 1 ? round1Labels : round2Labels
        let positions = generateNonOverlappingPositions(count: labels.count)

        nodes = labels.enumerated().map { idx, text in
            ConnectNode(id: idx, label: text, normalizedPosition: positions[idx])
        }
    }

    /// Generates 8 guaranteed non-overlapping normalized positions inside (0.14...0.86).
    private func generateNonOverlappingPositions(count: Int) -> [CGPoint] {
        var placed: [CGPoint] = []
        let minDistance: CGFloat = 0.22

        for _ in 0..<count {
            var candidate = CGPoint(x: 0.5, y: 0.5)
            var found = false
            for _ in 0..<250 {
                let x = CGFloat.random(in: 0.14...0.86)
                let y = CGFloat.random(in: 0.14...0.86)
                let pt = CGPoint(x: x, y: y)
                if placed.allSatisfy({ hypot($0.x - pt.x, $0.y - pt.y) >= minDistance }) {
                    candidate = pt
                    found = true
                    break
                }
            }
            if !found {
                // Deterministic fallback grid slot if random packing gets tight
                let fallbackSlots: [CGPoint] = [
                    CGPoint(x: 0.22, y: 0.18), CGPoint(x: 0.78, y: 0.18),
                    CGPoint(x: 0.48, y: 0.34), CGPoint(x: 0.20, y: 0.50),
                    CGPoint(x: 0.80, y: 0.50), CGPoint(x: 0.50, y: 0.66),
                    CGPoint(x: 0.24, y: 0.82), CGPoint(x: 0.76, y: 0.82)
                ]
                candidate = fallbackSlots[placed.count % fallbackSlots.count]
            }
            placed.append(candidate)
        }
        return placed
    }

    private func handleNodeTap(_ node: ConnectNode) {
        onInteraction()
        guard node.id >= nextExpectedOrderIndex else { return }

        if node.id == nextExpectedOrderIndex {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.22)) {
                nextExpectedOrderIndex += 1
            }

            if nextExpectedOrderIndex >= nodes.count {
                if currentRound == 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        buildRound(2)
                    }
                } else {
                    let elapsed = max(1, Int(round(Date().timeIntervalSince(startTimestamp))))
                    onWin("Node Connect • 2/2 rounds in \(elapsed)s")
                }
            }
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            withAnimation(.linear(duration: 0.07)) {
                shakingNodeID = node.id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.spring(response: 0.2)) {
                    shakingNodeID = nil
                }
            }
        }
    }
}
