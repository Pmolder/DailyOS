import ActivityKit
import WidgetKit
import SwiftUI

/// iPhone 13 Pro–first Midnight Obsidian Lock Screen Live Activity for Deep Work
/// (plus Dynamic Island closures for forward compatibility).
struct FocusLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            // Lock Screen / StandBy Banner
            FocusLockScreenBannerView(context: context)
                .activityBackgroundTint(Color.dailyHex("#09090D"))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            let accent = Color.dailyHex(context.attributes.accentHex)
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
                    if context.state.isPaused {
                        Text(formatClock(context.state.remainingSecondsWhenPaused))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.dailyHex("#FFB020"))
                    } else {
                        Text(timerInterval: context.state.startDate...context.state.endDate, countsDown: true)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: 72, alignment: .trailing)
                    }
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
                if context.state.isPaused {
                    Text(formatClock(context.state.remainingSecondsWhenPaused))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.dailyHex("#FFB020"))
                } else {
                    Text(timerInterval: context.state.startDate...context.state.endDate, countsDown: true)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: 46, alignment: .trailing)
                }
            } minimal: {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }

    private func formatClock(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
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

    private var pausedProgress: Double {
        min(1.0, max(0.0, Double(context.state.remainingSecondsWhenPaused) / totalSeconds))
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

            HStack(spacing: 14) {
                // Left: Compact Glowing Circular Progress Gauge (42x42pt)
                ZStack {
                    Circle()
                        .fill(Color.dailyHex("#141419"))
                        .frame(width: 42, height: 42)

                    if context.state.isPaused {
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 3)
                            .frame(width: 42, height: 42)
                        Circle()
                            .trim(from: 0, to: pausedProgress)
                            .stroke(Color.dailyHex("#FFB020"), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 42, height: 42)
                    } else {
                        ProgressView(
                            timerInterval: context.state.startDate...context.state.endDate,
                            countsDown: true
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

                // Right: Live Ticking Tabular Countdown OR Paused Badge
                VStack(alignment: .trailing, spacing: 3) {
                    if context.state.isPaused {
                        Text(formatClock(context.state.remainingSecondsWhenPaused))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)

                        Text("PAUSED")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(Color.dailyHex("#FFB020"))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.dailyHex("#FFB020").opacity(0.16), in: Capsule())
                    } else {
                        Text(timerInterval: context.state.startDate...context.state.endDate, countsDown: true)
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Color.white)
                            .frame(minWidth: 74, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func formatClock(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
