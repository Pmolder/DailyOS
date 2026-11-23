import ActivityKit
import WidgetKit
import SwiftUI

/// iPhone 13 Pro–first Midnight Obsidian Lock Screen Live Activity for Deep Work
/// displaying calm Smart Elapsed-of-Total Time (`35m / 45m`) and `0% → 100%` progress.
struct FocusLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            // Lock Screen / StandBy Banner
            FocusLockScreenBannerView(context: context)
                .activityBackgroundTint(Color.dailyHex("#09090D"))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            let accent = Color.dailyHex(context.attributes.accentHex)
            let displayText = resolvedElapsedOfTotal(for: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.18))
                            .frame(width: 36, height: 36)
                        Image(systemName: context.state.isPaused ? "pause.fill" : "timer")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(accent)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(displayText)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(context.state.isPaused ? Color.dailyHex("#FFB020") : Color.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DEEP WORK")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(Color.dailyHex("#7D7E8A"))
                        Text(context.attributes.taskTitle)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.attributes.focusCue.isEmpty {
                        Text(context.attributes.focusCue)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "timer")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(displayText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(context.state.isPaused ? Color.dailyHex("#FFB020") : Color.white)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }

    private func resolvedElapsedOfTotal(for state: FocusActivityAttributes.ContentState) -> String {
        if let provided = state.elapsedOfTotalText, !provided.isEmpty {
            return provided
        }
        let total = max(60, Int(round(state.endDate.timeIntervalSince(state.startDate))))
        let elapsed = max(0, total - state.remainingSecondsWhenPaused)
        return FocusElapsedTimeFormatter.formatElapsedOfTotal(elapsedSeconds: elapsed, totalSeconds: total)
    }
}

// MARK: - iPhone 13 Pro Centerpiece Lock Screen Banner

private struct FocusLockScreenBannerView: View {
    let context: ActivityViewContext<FocusActivityAttributes>

    private var accent: Color {
        Color.dailyHex(context.attributes.accentHex)
    }

    private var totalSeconds: Double {
        max(60.0, context.state.endDate.timeIntervalSince(context.state.startDate))
    }

    private var elapsedProgress: Double {
        let elapsed = max(0.0, totalSeconds - Double(context.state.remainingSecondsWhenPaused))
        return min(1.0, max(0.0, elapsed / totalSeconds))
    }

    private var elapsedOfTotalLabel: String {
        if let provided = context.state.elapsedOfTotalText, !provided.isEmpty {
            return provided
        }
        let total = Int(round(totalSeconds))
        let elapsed = max(0, total - context.state.remainingSecondsWhenPaused)
        return FocusElapsedTimeFormatter.formatElapsedOfTotal(elapsedSeconds: elapsed, totalSeconds: total)
    }

    var body: some View {
        ZStack {
            // Deep Matte Obsidian Base + Subtle Left Radial Accent Glow Wash
            Color.dailyHex("#09090D")
            RadialGradient(
                colors: [accent.opacity(0.22), accent.opacity(0.0)],
                center: .leading,
                startRadius: 4,
                endRadius: 170
            )

            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    // Left: Compact Glowing Circular Progress Gauge (0% -> 100%)
                    ZStack {
                        Circle()
                            .fill(Color.dailyHex("#141419"))
                            .frame(width: 42, height: 42)

                        if context.state.isPaused {
                            Circle()
                                .stroke(Color.white.opacity(0.10), lineWidth: 3)
                                .frame(width: 42, height: 42)
                            Circle()
                                .trim(from: 0, to: elapsedProgress)
                                .stroke(Color.dailyHex("#FFB020"), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 42, height: 42)
                        } else {
                            ProgressView(
                                timerInterval: context.state.startDate...context.state.endDate,
                                countsDown: false
                            ) {
                                EmptyView()
                            } currentValueLabel: {
                                EmptyView()
                            }
                            .progressViewStyle(.circular)
                            .tint(accent)
                            .frame(width: 42, height: 42)
                        }

                        Image(systemName: context.state.isPaused ? "pause.fill" : "timer")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(context.state.isPaused ? Color.dailyHex("#FFB020") : accent)
                    }

                    // Center: DEEP WORK Eyebrow + Bold Task Title + Muted Cue Subtitle
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DEEP WORK")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(1.3)
                            .foregroundStyle(Color.dailyHex("#7D7E8A"))

                        Text(context.attributes.taskTitle)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)

                        if !context.attributes.focusCue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(context.attributes.focusCue)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.58))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 6)

                    // Right: Calm Elapsed-of-Total Display (`35m / 45m`) + Status Pill
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(elapsedOfTotalLabel)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .lineLimit(1)

                        Text(context.state.isPaused ? "PAUSED" : "ACTIVE")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(context.state.isPaused ? Color.dailyHex("#FFB020") : Color.dailyHex("#34D399"))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                (context.state.isPaused ? Color.dailyHex("#FFB020") : Color.dailyHex("#34D399")).opacity(0.16),
                                in: Capsule()
                            )
                    }
                }

                // Sleek Horizontal Micro-Progress Bar (0% -> 100%)
                if context.state.isPaused {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10))
                            Capsule()
                                .fill(Color.dailyHex("#FFB020"))
                                .frame(width: max(4, geo.size.width * elapsedProgress))
                        }
                    }
                    .frame(height: 3.5)
                } else {
                    ProgressView(
                        timerInterval: context.state.startDate...context.state.endDate,
                        countsDown: false
                    ) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.linear)
                    .tint(accent)
                    .frame(height: 3.5)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }
}
