import Foundation
import Combine
import UIKit

/// Real-Time Wall-Clock Auto-Start Focus Engine + Active Deep Work Tracker:
/// - Automatically starts any scheduled timed `FocusTaskItem` or Google/Apple Calendar block at `startDate <= now < endDate`
/// - Scheduled countdown (`endDate - now`) ALWAYS ticks in real wall-clock time (never freezes when paused)
/// - Play / Pause toggles `isTrackingDeepWork` to count genuine `activeDeepWorkSeconds` into Focused Today, Today's Score, and Weekly Recap
/// - Drives Lock Screen Live Activity (`FocusLiveActivityManager`) + Floating PiP Top Pill (`FocusPiPManager`) at 1 fps
@MainActor
final class FocusAutoSessionEngine: ObservableObject {
    static let shared = FocusAutoSessionEngine()

    struct LiveSession: Equatable {
        let id: String
        let title: String
        let cue: String
        let startDate: Date
        let endDate: Date
        let isScheduledWallClock: Bool
        let requiresPhotoProof: Bool
        let taskNotes: String
    }

    @Published private(set) var activeSession: LiveSession? = nil
    @Published private(set) var isTrackingDeepWork: Bool = false
    @Published private(set) var remainingSeconds: Int = 45 * 60
    @Published private(set) var activeDeepWorkSeconds: Int = 0
    @Published var editableCue: String = ""
    @Published var adHocDurationMinutes: Int = 45
    @Published var shouldPresentTimerSheet: Bool = false

    private var tickCancellable: AnyCancellable?
    private var unloggedActiveSecondsRemainder: Int = 0
    private var dismissedScheduledIDs: Set<String> = []
    private var lastAutoEvaluatedMinuteKey: String = ""

    private init() {
        tickCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.handleSecondTick()
            }
    }

    // MARK: - Derived Display Values

    var hasLiveSession: Bool {
        activeSession != nil
    }

    var sessionTitle: String {
        activeSession?.title ?? "DEEP WORK"
    }

    var totalBlockSeconds: Int {
        guard let s = activeSession else { return max(60, adHocDurationMinutes * 60) }
        return max(60, Int(ceil(s.endDate.timeIntervalSince(s.startDate))))
    }

    var progressFraction: Double {
        guard totalBlockSeconds > 0 else { return 1.0 }
        guard activeSession != nil else { return 1.0 }
        return max(0.0, min(1.0, Double(remainingSeconds) / Double(totalBlockSeconds)))
    }

    var formattedRemainingClock: String {
        let clamped = max(0, remainingSeconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    var activeMinutesLoggedForSession: Int {
        activeDeepWorkSeconds / 60
    }

    // MARK: - Explicit Controls (Play/Pause Active Deep Work, Ad-Hoc Start, Scheduled Focus)

    func focusOnScheduledBlock(
        taskID: String,
        title: String,
        cue: String = "",
        taskNotes: String = "",
        startDate: Date,
        endDate: Date,
        requiresPhotoProof: Bool = false,
        autoStartTracking: Bool = false,
        openTimerSheet: Bool = true
    ) {
        dismissedScheduledIDs.remove(taskID)
        FocusNudgeScheduler.shared.acknowledgeAndClear(taskID: taskID)

        let isSame = activeSession?.id == taskID
        if !isSame {
            activeSession = LiveSession(
                id: taskID,
                title: title,
                cue: cue,
                startDate: startDate,
                endDate: endDate,
                isScheduledWallClock: true,
                requiresPhotoProof: requiresPhotoProof,
                taskNotes: taskNotes
            )
            editableCue = cue
            activeDeepWorkSeconds = 0
            unloggedActiveSecondsRemainder = 0
        }

        remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSinceNow)))

        if autoStartTracking {
            setDeepWorkTracking(true)
        } else {
            syncLiveActivityAndPiP()
        }

        if openTimerSheet {
            shouldPresentTimerSheet = true
        }
    }

    func startAdHocSession(
        title: String = "DEEP WORK",
        minutes: Int? = nil,
        cue: String = "",
        taskID: String? = nil,
        requiresPhotoProof: Bool = false,
        taskNotes: String = ""
    ) {
        let mins = max(5, min(240, minutes ?? adHocDurationMinutes))
        adHocDurationMinutes = mins
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(mins * 60))
        let id = taskID ?? "adhoc_\(Int(now.timeIntervalSince1970))"

        FocusNudgeScheduler.shared.acknowledgeAndClear(taskID: id)

        activeSession = LiveSession(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "DEEP WORK" : title,
            cue: cue,
            startDate: now,
            endDate: end,
            isScheduledWallClock: false,
            requiresPhotoProof: requiresPhotoProof,
            taskNotes: taskNotes
        )
        editableCue = cue
        remainingSeconds = mins * 60
        activeDeepWorkSeconds = 0
        unloggedActiveSecondsRemainder = 0
        setDeepWorkTracking(true)
    }

    func setDeepWorkTracking(_ active: Bool) {
        if activeSession == nil && active {
            startAdHocSession(minutes: adHocDurationMinutes, cue: editableCue)
            return
        }

        let wasTracking = isTrackingDeepWork
        isTrackingDeepWork = active

        if let session = activeSession {
            FocusNudgeScheduler.shared.acknowledgeAndClear(taskID: session.id)

            if active && !wasTracking && session.requiresPhotoProof {
                let minsLeft = max(5, remainingSeconds / 60)
                PhotoProofScheduler.shared.scheduleProofs(
                    taskID: session.id,
                    taskTitle: session.title,
                    taskNotes: session.taskNotes,
                    taskStart: Date(),
                    durationMinutes: minsLeft,
                    triggerInitialImmediatelyIfNow: true
                )
            }
        }

        syncLiveActivityAndPiP()
    }

    func togglePlayPause() {
        setDeepWorkTracking(!isTrackingDeepWork)
    }

    func endCurrentSession(markDismissedIfScheduled: Bool = true) {
        if let session = activeSession {
            if markDismissedIfScheduled && session.isScheduledWallClock {
                dismissedScheduledIDs.insert(session.id)
            }
            if activeDeepWorkSeconds >= 60 {
                HabitMetricsEngine.incrementFocusSessionsToday()
                WidgetSyncCoordinator.syncSnapshotFromStore()
                Task { await DailyNotificationManager.shared.refreshScheduledNotifications() }
            }
        }
        activeSession = nil
        isTrackingDeepWork = false
        remainingSeconds = adHocDurationMinutes * 60
        activeDeepWorkSeconds = 0
        unloggedActiveSecondsRemainder = 0
        FocusLiveActivityManager.shared.endAll()
        FocusPiPManager.shared.stopAndDisarmPiP()
    }

    // MARK: - Wall-Clock Auto-Start Discovery

    func evaluateAutoStartSchedule() {
        let now = Date()
        let todayKey = HabitItem.dateKey(for: now)
        let tasks = SharedModelContainer.shared.fetchFocusTasks(dayKey: todayKey)
        let calendarBlocks = FocusAccountabilityManager.shared.upcomingBlocks

        // Refresh calm nudges once per minute or when schedule changes
        let minuteKey = "\(todayKey)_\(ISOWeekCalendar.current.component(.hour, from: now))_\(ISOWeekCalendar.current.component(.minute, from: now))"
        if minuteKey != lastAutoEvaluatedMinuteKey {
            lastAutoEvaluatedMinuteKey = minuteKey
            FocusNudgeScheduler.shared.rescheduleUpcomingNudges(tasks: tasks, calendarBlocks: calendarBlocks)
        }

        // If user already has an active session running (either ad-hoc or still inside wall-clock bounds), keep it
        if let current = activeSession, current.endDate > now {
            return
        }

        // 1. Check today's incomplete timed FocusTaskItems
        for task in tasks where !task.isCompleted {
            guard let start = task.startTime else { continue }
            let end = start.addingTimeInterval(TimeInterval(max(5, task.durationMinutes) * 60))
            guard start <= now && now < end else { continue }
            let id = task.id.uuidString
            guard !dismissedScheduledIDs.contains(id) else { continue }

            activeSession = LiveSession(
                id: id,
                title: task.title,
                cue: task.trimmedLocation.isEmpty ? task.trimmedNotes : "at \(task.trimmedLocation)",
                startDate: start,
                endDate: end,
                isScheduledWallClock: true,
                requiresPhotoProof: task.requiresPhotoProof,
                taskNotes: task.notes
            )
            editableCue = activeSession?.cue ?? ""
            remainingSeconds = max(0, Int(ceil(end.timeIntervalSince(now))))
            activeDeepWorkSeconds = 0
            unloggedActiveSecondsRemainder = 0
            isTrackingDeepWork = false // Starts wall-clock immediately; Play toggles Active Deep Work tracking
            syncLiveActivityAndPiP()
            return
        }

        // 2. Check imported Google / Apple Calendar events
        let linkedIDs = Set(tasks.compactMap(\.googleCalendarEventID).filter { !$0.isEmpty })
        for block in calendarBlocks where !block.isAllDay && block.dayKey == todayKey {
            if let rID = block.remoteEventID, linkedIDs.contains(rID) { continue }
            let compKey = CalendarEventCompletionStore.eventKey(for: block)
            if CalendarEventCompletionStore.shared.isCompleted(eventKey: compKey) { continue }
            guard block.startDate <= now && now < block.endDate else { continue }
            guard !dismissedScheduledIDs.contains(block.id) else { continue }

            let calProofKey = CalendarPhotoProofStore.stableKey(for: block)
            activeSession = LiveSession(
                id: block.id,
                title: block.title,
                cue: block.trimmedLocation.isEmpty ? block.notes : "at \(block.trimmedLocation)",
                startDate: block.startDate,
                endDate: block.endDate,
                isScheduledWallClock: true,
                requiresPhotoProof: CalendarPhotoProofStore.isEnabled(forKey: calProofKey),
                taskNotes: block.notes
            )
            editableCue = activeSession?.cue ?? ""
            remainingSeconds = max(0, Int(ceil(block.endDate.timeIntervalSince(now))))
            activeDeepWorkSeconds = 0
            unloggedActiveSecondsRemainder = 0
            isTrackingDeepWork = false
            syncLiveActivityAndPiP()
            return
        }
    }

    // MARK: - 1-Second Heartbeat (Wall Clock + Active Deep Work + PiP Frame)

    private func handleSecondTick() {
        evaluateAutoStartSchedule()
        guard let session = activeSession else { return }

        let now = Date()

        // 1. Update remaining countdown
        if session.isScheduledWallClock {
            // Scheduled block ALWAYS ticks on real wall-clock time even while paused
            remainingSeconds = max(0, Int(ceil(session.endDate.timeIntervalSince(now))))
        } else if isTrackingDeepWork {
            remainingSeconds = max(0, remainingSeconds - 1)
        }

        // 2. Accumulate genuine Active Deep Work seconds ONLY while Play/Active is ON
        if isTrackingDeepWork {
            activeDeepWorkSeconds += 1
            unloggedActiveSecondsRemainder += 1
            if unloggedActiveSecondsRemainder >= 60 {
                unloggedActiveSecondsRemainder -= 60
                HabitMetricsEngine.addFocusMinutesToday(1)
                WidgetSyncCoordinator.syncSnapshotFromStore()
            }
        }

        // 3. Render 1 fps Floating PiP Pill Frame (Normal OR Unified Photo-Proof Morph!)
        let pendingPhotoSecs: Int? = {
            guard let req = PhotoProofScheduler.shared.activeCaptureRequest else { return nil }
            let left = Int(ceil(req.deadline.timeIntervalSinceNow))
            return left > 0 ? left : nil
        }()

        FocusPiPManager.shared.renderFrame(
            title: session.title,
            countdownText: formattedRemainingClock,
            isActiveDeepWork: isTrackingDeepWork,
            activeMinutesLogged: activeMinutesLoggedForSession,
            photoProofSecondsLeft: pendingPhotoSecs
        )

        // 4. Finish automatically when remaining countdown hits 0
        if remainingSeconds <= 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            endCurrentSession(markDismissedIfScheduled: true)
        }
    }

    private func syncLiveActivityAndPiP() {
        guard let session = activeSession else {
            FocusLiveActivityManager.shared.endAll()
            FocusPiPManager.shared.stopAndDisarmPiP()
            return
        }

        FocusPiPManager.shared.armPiPIfNeeded()

        if session.isScheduledWallClock {
            FocusLiveActivityManager.shared.start(
                taskTitle: session.title,
                focusCue: editableCue.isEmpty ? session.cue : editableCue,
                durationSeconds: max(60, remainingSeconds)
            )
            if !isTrackingDeepWork {
                FocusLiveActivityManager.shared.update(
                    isPaused: false, // Wall clock keeps counting on Lock Screen
                    remainingSeconds: remainingSeconds,
                    totalDurationSeconds: totalBlockSeconds
                )
            }
        } else {
            if isTrackingDeepWork {
                FocusLiveActivityManager.shared.start(
                    taskTitle: session.title,
                    focusCue: editableCue.isEmpty ? session.cue : editableCue,
                    durationSeconds: max(60, remainingSeconds)
                )
            } else {
                FocusLiveActivityManager.shared.update(
                    isPaused: true,
                    remainingSeconds: remainingSeconds,
                    totalDurationSeconds: totalBlockSeconds
                )
            }
        }
    }
}
