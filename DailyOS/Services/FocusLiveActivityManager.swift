import Foundation
import ActivityKit

/// Safe ActivityKit lifecycle manager for the Deep Work Lock Screen Live Activity.
/// Uses native `startDate...endDate` + `pausedAt` so iOS ticks the Lock Screen clock and circular gauge
/// live in real time even while the app is suspended in the background.
@MainActor
final class FocusLiveActivityManager {
    static let shared = FocusLiveActivityManager()

    private var currentActivity: Activity<FocusActivityAttributes>?

    private init() {}

    func start(
        taskTitle: String,
        focusCue: String,
        accentHex: String = "#60A5FA",
        timeWindowLabel: String = "FOCUS SESSION",
        durationSeconds: Int,
        elapsedSeconds: Int = 0,
        isPaused: Bool = false
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        endAll()

        let now = Date()
        let safeTotal = max(60, durationSeconds)
        let safeElapsed = max(0, min(safeTotal, elapsedSeconds))
        let start = now.addingTimeInterval(TimeInterval(-safeElapsed))
        let end = start.addingTimeInterval(TimeInterval(safeTotal))
        let rem = max(0, safeTotal - safeElapsed)
        let totalMins = max(1, Int(round(Double(safeTotal) / 60.0)))

        let cleanTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Deep Work" : taskTitle
        let cleanWindow = timeWindowLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "FOCUS SESSION" : timeWindowLabel

        let attributes = FocusActivityAttributes(
            taskTitle: cleanTitle,
            focusCue: focusCue.trimmingCharacters(in: .whitespacesAndNewlines),
            accentHex: accentHex,
            timeWindowLabel: cleanWindow
        )
        let state = FocusActivityAttributes.ContentState(
            startDate: start,
            endDate: end,
            isPaused: isPaused,
            remainingSecondsWhenPaused: rem,
            totalDurationMinutes: totalMins,
            pausedAt: isPaused ? now : nil
        )

        do {
            let content = ActivityContent(state: state, staleDate: end)
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            print("[FocusLiveActivityManager] Live Activity request failed: \(error.localizedDescription)")
        }
    }

    func update(
        isPaused: Bool,
        remainingSeconds: Int,
        totalDurationSeconds: Int
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let activity = currentActivity ?? Activity<FocusActivityAttributes>.activities.first else { return }

        let now = Date()
        let safeTotal = max(60, totalDurationSeconds)
        let clampedRem = max(0, min(safeTotal, remainingSeconds))
        let elapsed = max(0, safeTotal - clampedRem)
        let reconstructedStart = now.addingTimeInterval(TimeInterval(-elapsed))
        let newEnd = now.addingTimeInterval(TimeInterval(clampedRem))
        let totalMins = max(1, Int(round(Double(safeTotal) / 60.0)))

        let state = FocusActivityAttributes.ContentState(
            startDate: reconstructedStart,
            endDate: newEnd,
            isPaused: isPaused,
            remainingSecondsWhenPaused: clampedRem,
            totalDurationMinutes: totalMins,
            pausedAt: isPaused ? now : nil
        )
        let content = ActivityContent(state: state, staleDate: newEnd)

        Task {
            await activity.update(content)
        }
    }

    func endStaleActivitiesIfNeeded() {
        let now = Date()
        for activity in Activity<FocusActivityAttributes>.activities {
            if !activity.content.state.isPaused && activity.content.state.endDate <= now {
                let finalState = FocusActivityAttributes.ContentState(
                    startDate: activity.content.state.startDate,
                    endDate: now,
                    isPaused: false,
                    remainingSecondsWhenPaused: 0,
                    totalDurationMinutes: activity.content.state.totalDurationMinutes,
                    pausedAt: nil
                )
                let finalContent = ActivityContent(state: finalState, staleDate: nil)
                Task {
                    await activity.end(finalContent, dismissalPolicy: .immediate)
                }
            }
        }
    }

    func endAll() {
        let activeList = Activity<FocusActivityAttributes>.activities
        currentActivity = nil
        guard !activeList.isEmpty else { return }

        let finalState = FocusActivityAttributes.ContentState(
            startDate: Date(),
            endDate: Date(),
            isPaused: false,
            remainingSecondsWhenPaused: 0,
            totalDurationMinutes: 1,
            pausedAt: nil
        )
        let finalContent = ActivityContent(state: finalState, staleDate: nil)

        for activity in activeList {
            Task {
                await activity.end(finalContent, dismissalPolicy: .immediate)
            }
        }
    }
}
