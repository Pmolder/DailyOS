import Foundation
import ActivityKit

/// Safe ActivityKit lifecycle manager for the Deep Work Lock Screen Live Activity.
/// Guards all calls with `ActivityAuthorizationInfo().areActivitiesEnabled` and `do/catch`
/// so it never crashes on Simulator or when Live Activities are disabled in iOS Settings.
@MainActor
final class FocusLiveActivityManager {
    static let shared = FocusLiveActivityManager()

    private var currentActivity: Activity<FocusActivityAttributes>?

    private init() {}

    func start(
        taskTitle: String,
        focusCue: String,
        accentHex: String = "#60A5FA",
        durationSeconds: Int,
        elapsedSeconds: Int = 0
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // End any stale Deep Work activity first
        endAll()

        let now = Date()
        let safeTotal = max(60, durationSeconds)
        let safeElapsed = max(0, min(safeTotal, elapsedSeconds))
        let start = now.addingTimeInterval(TimeInterval(-safeElapsed))
        let end = start.addingTimeInterval(TimeInterval(safeTotal))
        let rem = max(0, safeTotal - safeElapsed)
        let label = FocusElapsedTimeFormatter.formatElapsedOfTotal(elapsedSeconds: safeElapsed, totalSeconds: safeTotal)

        let attributes = FocusActivityAttributes(
            taskTitle: taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Deep Work" : taskTitle,
            focusCue: focusCue.trimmingCharacters(in: .whitespacesAndNewlines),
            accentHex: accentHex
        )
        let state = FocusActivityAttributes.ContentState(
            startDate: start,
            endDate: end,
            isPaused: false,
            remainingSecondsWhenPaused: rem,
            elapsedOfTotalText: label
        )

        do {
            let content = ActivityContent(state: state, staleDate: end.addingTimeInterval(60))
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
        totalDurationSeconds: Int,
        elapsedOfTotalText: String? = nil
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let activity = currentActivity ?? Activity<FocusActivityAttributes>.activities.first else { return }

        let now = Date()
        let safeTotal = max(60, totalDurationSeconds)
        let clampedRem = max(0, min(safeTotal, remainingSeconds))
        let elapsed = max(0, safeTotal - clampedRem)
        let reconstructedStart = now.addingTimeInterval(TimeInterval(-elapsed))
        let newEnd = now.addingTimeInterval(TimeInterval(clampedRem))
        let label = elapsedOfTotalText ?? FocusElapsedTimeFormatter.formatElapsedOfTotal(
            elapsedSeconds: elapsed,
            totalSeconds: safeTotal
        )

        let state = FocusActivityAttributes.ContentState(
            startDate: reconstructedStart,
            endDate: newEnd,
            isPaused: isPaused,
            remainingSecondsWhenPaused: clampedRem,
            elapsedOfTotalText: label
        )
        let content = ActivityContent(state: state, staleDate: newEnd.addingTimeInterval(60))

        Task {
            await activity.update(content)
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
            elapsedOfTotalText: nil
        )
        let finalContent = ActivityContent(state: finalState, staleDate: nil)

        for activity in activeList {
            Task {
                await activity.end(finalContent, dismissalPolicy: .immediate)
            }
        }
    }
}
