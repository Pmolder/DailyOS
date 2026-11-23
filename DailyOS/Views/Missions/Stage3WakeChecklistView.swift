import SwiftUI
import Combine
import UIKit

/// Stage 3 of 3 • Morning Activation Checklist (High-Luminance Solar-Orange Max-Brightness Theme).
/// Runs immediately after Stage-2 Brain Game finishes: alarm stays silent during the countdown
/// (default 2:00) and resumes escalating if the timer expires before all activation steps are ticked.
struct Stage3WakeChecklistView: View {
    let items: [String]
    let timeLimitSeconds: Int
    let totalStages: Int
    let onDeadlineExpired: () -> Void
    let onCompleteAll: () -> Void

    @State private var checkedIndices: Set<Int> = []
    @State private var remainingSeconds: Int
    @State private var didEscalatePenalty: Bool = false
    @State private var burstTriggers: [Int: Int] = [:]
    @State private var shimmerTrigger: Int = 0

    // Optional built-in 30s mini light-exposure timer per eligible item
    @State private var activeLightTimerIndex: Int? = nil
    @State private var lightSecondsLeft: Int = 30

    private let secondTick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    init(
        items: [String],
        timeLimitSeconds: Int,
        totalStages: Int = 3,
        onDeadlineExpired: @escaping () -> Void,
        onCompleteAll: @escaping () -> Void
    ) {
        self.items = items
        self.timeLimitSeconds = max(30, timeLimitSeconds)
        self.totalStages = totalStages
        self.onDeadlineExpired = onDeadlineExpired
        self.onCompleteAll = onCompleteAll
        _remainingSeconds = State(initialValue: max(30, timeLimitSeconds))
    }

    private var allItemsChecked: Bool {
        !items.isEmpty && checkedIndices.count >= items.count
    }

    private var timerProgress: Double {
        guard timeLimitSeconds > 0 else { return 0 }
        return max(0.0, min(1.0, Double(remainingSeconds) / Double(timeLimitSeconds)))
    }

    private var completionFraction: Double {
        guard !items.isEmpty else { return 1.0 }
        return Double(checkedIndices.count) / Double(items.count)
    }

    private var formattedCountdown: String {
        let clamped = max(0, remainingSeconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    var body: some View {
        ZStack {
            SolarTheme.sunriseGradient
                .ignoresSafeArea()

            VStack(spacing: 16) {
                // Top Stage Pill
                HStack(spacing: 8) {
                    Image(systemName: "sun.max.fill")
                    Text("STAGE \(totalStages) OF \(totalStages) • WAKE ACTIVATION")
                }
                .font(.caption.weight(.black))
                .foregroundStyle(SolarTheme.solarGold)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(SolarTheme.obsidian, in: Capsule())
                .padding(.top, 14)

                // Deadline Penalty Alert Banner
                if didEscalatePenalty && !allItemsChecked {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.3.fill")
                        Text("TIME EXPIRED — ALARM RESUMED! COMPLETE ALL STEPS NOW!")
                            .font(.caption2.weight(.black))
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 18)
                }

                // Large Bold Tabular Countdown + Circular Ring
                ZStack {
                    Circle()
                        .fill(SolarTheme.obsidian.opacity(0.92))
                        .frame(width: 152, height: 152)

                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 8)
                        .frame(width: 136, height: 136)

                    Circle()
                        .trim(from: 0, to: allItemsChecked ? 1.0 : timerProgress)
                        .stroke(
                            allItemsChecked ? DailyOSTheme.emerald : (remainingSeconds <= 20 ? Color.red : SolarTheme.solarGold),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 136, height: 136)
                        .animation(ProMotionSpring.ringFill, value: timerProgress)

                    VStack(spacing: 2) {
                        Text(allItemsChecked ? "READY" : formattedCountdown)
                            .font(.system(size: allItemsChecked ? 28 : 34, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .foregroundStyle(allItemsChecked ? DailyOSTheme.emerald : Color.white)

                        Text("\(checkedIndices.count) / \(items.count) DONE")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(SolarTheme.solarGold)
                    }
                }
                .shadow(color: Color.black.opacity(0.32), radius: 14, y: 5)

                // Progress Bar Strip
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(SolarTheme.obsidian.opacity(0.42))
                            .frame(height: 7)
                        Capsule()
                            .fill(allItemsChecked ? DailyOSTheme.emerald : SolarTheme.obsidian)
                            .frame(width: max(0, geo.size.width * completionFraction), height: 7)
                            .animation(ProMotionSpring.ringFill, value: completionFraction)
                    }
                }
                .frame(height: 7)
                .padding(.horizontal, 24)

                // Interactive Pitch-Black Checklist Cards
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, title in
                            checklistCard(index: idx, title: title)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                }

                Spacer(minLength: 0)

                // Final Turn Alarm Off CTA (Unlocked When All Items Checked)
                Button {
                    guard allItemsChecked else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCompleteAll()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: allItemsChecked ? "checkmark.seal.fill" : "lock.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(allItemsChecked ? DailyOSTheme.emerald : Color.white.opacity(0.45))
                        Text(allItemsChecked ? "TURN ALARM OFF & START DAY" : "COMPLETE ALL \(items.count) STEPS FIRST")
                            .font(.headline.weight(.black))
                            .foregroundStyle(allItemsChecked ? Color.white : Color.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        allItemsChecked ? SolarTheme.obsidian : SolarTheme.obsidian.opacity(0.55),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(
                            allItemsChecked ? DailyOSTheme.emerald.opacity(0.7) : Color.white.opacity(0.14),
                            lineWidth: 1.5
                        )
                    )
                    .midnightShimmer(trigger: shimmerTrigger, color: DailyOSTheme.emerald)
                    .shadow(color: Color.black.opacity(0.38), radius: 14, y: 6)
                }
                .buttonStyle(MidnightPressButtonStyle())
                .disabled(!allItemsChecked)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
        }
        .onReceive(secondTick) { _ in
            // 1. Optional 30s bright-light mini timer
            if let lightIdx = activeLightTimerIndex {
                if lightSecondsLeft > 1 {
                    lightSecondsLeft -= 1
                } else {
                    lightSecondsLeft = 0
                    activeLightTimerIndex = nil
                    if !checkedIndices.contains(lightIdx) {
                        toggleCheck(at: lightIdx)
                    }
                }
            }

            // 2. Main Stage-3 deadline guard
            guard !allItemsChecked else { return }
            if remainingSeconds > 1 {
                remainingSeconds -= 1
            } else {
                remainingSeconds = 0
                if !didEscalatePenalty {
                    didEscalatePenalty = true
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    onDeadlineExpired()
                }
            }
        }
    }

    private func supportsLightMiniTimer(_ text: String) -> Bool {
        let low = text.lowercased()
        return low.contains("30") || low.contains("light")
    }

    private func checklistCard(index: Int, title: String) -> some View {
        let isChecked = checkedIndices.contains(index)
        let burstCount = burstTriggers[index] ?? 0
        let hasMiniTimer = supportsLightMiniTimer(title) && !isChecked
        let isLightTimerRunning = activeLightTimerIndex == index

        return HStack(spacing: 14) {
            Button {
                toggleCheck(at: index)
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        CompletionBurstView(trigger: burstCount, color: DailyOSTheme.emerald, size: 54)

                        Circle()
                            .fill(isChecked ? DailyOSTheme.emerald : Color.clear)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle()
                                    .stroke(isChecked ? DailyOSTheme.emerald : Color.white.opacity(0.35), lineWidth: 2.2)
                            )
                            .scaleEffect(isChecked ? 1.05 : 1.0)
                            .animation(ProMotionSpring.pop, value: isChecked)

                        if isChecked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(SolarTheme.obsidian)
                        }
                    }

                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .strikethrough(isChecked, color: Color.white.opacity(0.5))
                        .foregroundStyle(isChecked ? Color.white.opacity(0.55) : Color.white)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Optional 30s Bright-Light Mini Tap-Timer Pill
            if hasMiniTimer {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if isLightTimerRunning {
                        activeLightTimerIndex = nil
                    } else {
                        lightSecondsLeft = 30
                        activeLightTimerIndex = index
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isLightTimerRunning ? "pause.fill" : "sun.max.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(isLightTimerRunning ? "\(lightSecondsLeft)s" : "30s")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .foregroundStyle(isLightTimerRunning ? SolarTheme.obsidian : SolarTheme.solarGold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        isLightTimerRunning ? SolarTheme.solarGold : SolarTheme.solarGold.opacity(0.18),
                        in: Capsule()
                    )
                }
                .buttonStyle(MidnightPressButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Color(hex: "#08080A"), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isChecked ? DailyOSTheme.emerald.opacity(0.65) : Color.white.opacity(0.14), lineWidth: 1.2)
        )
    }

    private func toggleCheck(at index: Int) {
        if checkedIndices.contains(index) {
            checkedIndices.remove(index)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            checkedIndices.insert(index)
            if activeLightTimerIndex == index {
                activeLightTimerIndex = nil
            }
            burstTriggers[index] = (burstTriggers[index] ?? 0) + 1
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

            if checkedIndices.count >= items.count {
                shimmerTrigger += 1
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}
