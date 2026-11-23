import ActivityKit
import WidgetKit
import SwiftUI

/// iPhone 13 Pro–first Midnight Obsidian Lock Screen Live Activity for Focus Sessions:
/// - ONE progress indicator only (46×46pt live circular gauge on the left — zero duplicate horizontal bar)
/// - Native iOS live-updating `Text(timerInterval:pauseTime:countsDown: false)` so it ticks smoothly on Lock Screen
/// - Zero duplicate `"DEEP WORK"` eyebrow/title text
struct FocusLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            FocusLockScreenBannerView(context: context)
                .activityBackgroundTint(Color.dailyHex("#09090D"))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            let accent = Color.dailyHex(context.attributes.accentHex)
            let eyebrow = resolvedEyebrow(for: context.attributes)
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
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(
                            timerInterval: context.state.startDate...context.state.endDate,
                            pauseTime: context.state.isPaused ? (context.state.pausedAt ?? Date()) : nil,
                            countsDown: false
                        )
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(context.state.isPaused ? Color.dailyHex("#FFB020") : Color.white)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 64, alignment: .trailing)

                        Text("/ \(FocusElapsedTimeFormatter.formatTotalDuration(minutes: context.state.totalDurationMinutes))")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.dailyHex("#7D7E8A"))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(eyebrow)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(Color.dailyHex("#7D7E8A"))
                            .lineLimit(1)
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
                Text(
                    timerInterval: context.state.startDate...context.state.endDate,
                    pauseTime: context.state.isPaused ? (context.state.pausedAt ?? Date()) : nil,
                    countsDown: false
                )
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(context.state.isPaused ? Color.dailyHex("#FFB020") : Color.white)
                .frame(maxWidth: 46, alignment: .trailing)
            } minimal: {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }

    private func resolvedEyebrow(for attributes: FocusActivityAttributes) -> String {
        let trimmedWindow = attributes.timeWindowLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if attributes.taskTitle.caseInsensitiveCompare("Deep Work") == .orderedSame {
            return trimmedWindow.isEmpty ? "FOCUS SESSION" : trimmedWindow.uppercased()
        }
        return trimmedWindow.isEmpty ? "FOCUS SESSION" : trimmedWindow.uppercased()
    }
}

// MARK: - iPhone 13 Pro Centerpiece Lock Screen Banner (Single Circular Gauge + Native Live Clock)

private struct FocusLockScreenBannerView: View {
    let context: ActivityViewContext<FocusActivityAttributes>

    private var accent: Color {
        Color.dailyHex(context.attributes.accentHex)
    }

    private var totalSeconds: Double {
        max(60.0, context.state.endDate.timeIntervalSince(context.state.startDate))
    }

    private var elapsedProgressWhenPaused: Double {
        let elapsed = max(0.0, totalSeconds - Double(context.state.remainingSecondsWhenPaused))
        return min(1.0, max(0.0, elapsed / totalSeconds))
    }

    private var eyebrowText: String {
        let trimmedWindow = context.attributes.timeWindowLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if context.attributes.taskTitle.caseInsensitiveCompare("Deep Work") == .orderedSame {
            return trimmedWindow.isEmpty ? "FOCUS SESSION" : trimmedWindow.uppercased()
        }
        return trimmedWindow.isEmpty ? "FOCUS SESSION" : trimmedWindow.uppercased()
    }

    private var totalDurationText: String {
        FocusElapsedTimeFormatter.formatTotalDuration(minutes: context.state.totalDurationMinutes)
    }

    var body: some View {
        ZStack {
            // Deep Matte Obsidian Base + Subtle Left Radial Accent Glow Wash
            Color.dailyHex("#09090D")
            RadialGradient(
                colors: [accent.opacity(0.20), accent.opacity(0.0)],
                center: .leading,
                startRadius: 4,
                endRadius: 170
            )

            HStack(spacing: 14) {
                // Left: Single Sleek 46x46pt Glowing Circular Progress Ring (No Duplicate Bottom Bar)
                ZStack {
                    Circle()
                        .fill(Color.dailyHex("#141419"))
                        .frame(width: 46, height: 46)

                    if context.state.isPaused {
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 3.5)
                            .frame(width: 46, height: 46)
                        Circle()
                            .trim(from: 0, to: elapsedProgressWhenPaused)
                            .stroke(Color.dailyHex("#FFB020"), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 46, height: 46)
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
                        .frame(width: 46, height: 46)
                    }

                    Image(systemName: context.state.isPaused ? "pause.fill" : "timer")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(context.state.isPaused ? Color.dailyHex("#FFB020") : accent)
                }

                // Center: Unique Eyebrow (Never Duplicates Title) + Bold Task Title + Optional Cue
                VStack(alignment: .leading, spacing: 2) {
                    Text(eyebrowText)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(Color.dailyHex("#7D7E8A"))
                        .lineLimit(1)

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

                Spacer(minLength: 8)

                // Right: Native Live-Updating Elapsed Clock + Muted `/ 45m` Total + Status Micro-Pill
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(
                            timerInterval: context.state.startDate...context.state.endDate,
                            pauseTime: context.state.isPaused ? (context.state.pausedAt ?? Date()) : nil,
                            countsDown: false
                        )
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 46, alignment: .trailing)

                        Text("/ \(totalDurationText)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.dailyHex("#7D7E8A"))
                    }

                    Text(context.state.isPaused ? "PAUSED" : "ACTIVE")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(context.state.isPaused ? Color.dailyHex("#FFB020") : Color.dailyHex("#34D399"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            (context.state.isPaused ? Color.dailyHex("#FFB020") : Color.dailyHex("#34D399")).opacity(0.16),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}
