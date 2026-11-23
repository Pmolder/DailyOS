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
        durationSeconds: Int
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // End any stale Deep Work activity first
        endAll()

        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(max(60, durationSeconds)))
        let attributes = FocusActivityAttributes(
            taskTitle: taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Deep Work" : taskTitle,
            focusCue: focusCue.trimmingCharacters(in: .whitespacesAndNewlines),
            accentHex: accentHex
        )
        let state = FocusActivityAttributes.ContentState(
            startDate: now,
            endDate: end,
            isPaused: false,
            remainingSecondsWhenPaused: max(60, durationSeconds)
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

    func update(isPaused: Bool, remainingSeconds: Int, totalDurationSeconds: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let activity = currentActivity ?? Activity<FocusActivityAttributes>.activities.first else { return }

        let now = Date()
        let clampedRem = max(0, remainingSeconds)
        let elapsed = max(0, totalDurationSeconds - clampedRem)
        let reconstructedStart = now.addingTimeInterval(TimeInterval(-elapsed))
        let newEnd = now.addingTimeInterval(TimeInterval(clampedRem))

        let state = FocusActivityAttributes.ContentState(
            startDate: reconstructedStart,
            endDate: newEnd,
            isPaused: isPaused,
            remainingSecondsWhenPaused: clampedRem
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
            remainingSecondsWhenPaused: 0
        )
        let finalContent = ActivityContent(state: finalState, staleDate: nil)

        for activity in activeList {
            Task {
                await activity.end(finalContent, dismissalPolicy: .immediate)
            }
        }
    }
}
