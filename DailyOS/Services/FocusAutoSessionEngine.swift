import Foundation
import Combine
import UIKit

/// Real-Time Wall-Clock Auto-Start Focus Engine + Active Deep Work Tracker + In-Sheet Completion Flow:
/// - Automatically starts any scheduled timed `FocusTaskItem` or Google/Apple Calendar block at `startDate <= now < endDate`
/// - Scheduled block ALWAYS progresses in real wall-clock time (never freezes when paused)
/// - Calm Elapsed-of-Total Time (`0:42 / 45m` → `1m / 45m` → `35m / 45m` → `1h 05m / 1h 30m`) + `0% → 100%` ring
/// - Play / Pause toggles `isTrackingDeepWork` to count genuine `activeDeepWorkSeconds` into Focused Today & Weekly Recap
/// - Native Lock Screen Live Activity (`FocusLiveActivityManager`) with live iOS `timerInterval` + `pausedAt` (zero PiP)
/// - Reliable automatic 2-min + interval/random Photo Proof arming (works with or without Gemini API key)
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

    struct NextUpTaskInfo: Equatable {
        let headline: String       // e.g., "Next: Gym — Upper Body • in 30m" or "All Clear Today"
        let subtitle: String       // e.g., "5-min heads-up armed before start" or "2 anytime tasks left"
        let isAllClear: Bool
        let nextStartDate: Date?
    }

    enum CompletionOverlayState: Equatable {
        case none
        case completed(focusedMinutes: Int, completedTitle: String, nextUp: NextUpTaskInfo)
    }

    @Published private(set) var activeSession: LiveSession? = nil
    @Published private(set) var isTrackingDeepWork: Bool = false
    @Published private(set) var remainingSeconds: Int = 45 * 60
    @Published private(set) var activeDeepWorkSeconds: Int = 0
    @Published private(set) var completionOverlay: CompletionOverlayState = .none
    @Published var editableCue: String = ""
    @Published var adHocDurationMinutes: Int = 45
    @Published var adHocRequiresPhotoProof: Bool = false
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
        activeSession?.title ?? "Deep Work"
    }

    var sessionTimeWindowLabel: String {
        guard let session = activeSession, session.isScheduledWallClock else {
            return "FOCUS SESSION"
        }
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm"
        return "\(f.string(from: session.startDate)) – \(f.string(from: session.endDate))"
    }

    var totalBlockSeconds: Int {
        guard let s = activeSession else { return max(60, adHocDurationMinutes * 60) }
        return max(60, Int(ceil(s.endDate.timeIntervalSince(s.startDate))))
    }

    var elapsedSeconds: Int {
        guard activeSession != nil else { return 0 }
        return max(0, min(totalBlockSeconds, totalBlockSeconds - remainingSeconds))
    }

    /// Smoothly fills from `0.0 → 1.0` across the session.
    var elapsedProgressFraction: Double {
        guard activeSession != nil, totalBlockSeconds > 0 else { return 0.0 }
        return max(0.0, min(1.0, Double(elapsedSeconds) / Double(totalBlockSeconds)))
    }

    /// Calm Elapsed-of-Total text (`0:42 / 45m`, `1m / 45m`, `35m / 45m`, `1h 05m / 1h 30m`).
    var formattedElapsedOfTotal: String {
        FocusElapsedTimeFormatter.formatElapsedOfTotal(
            elapsedSeconds: elapsedSeconds,
            totalSeconds: totalBlockSeconds
        )
    }

    var activeMinutesLoggedForSession: Int {
        activeDeepWorkSeconds / 60
    }

    var isPhotoProofArmedForCurrentSession: Bool {
        activeSession?.requiresPhotoProof ?? adHocRequiresPhotoProof
    }

    // MARK: - Explicit Controls

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
        completionOverlay = .none
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
            syncLiveActivity()
        }

        if openTimerSheet {
            shouldPresentTimerSheet = true
        }
    }

    func startAdHocSession(
        title: String = "Deep Work",
        minutes: Int? = nil,
        cue: String = "",
        taskID: String? = nil,
        requiresPhotoProof: Bool? = nil,
        taskNotes: String = ""
    ) {
        completionOverlay = .none
        let mins = max(5, min(240, minutes ?? adHocDurationMinutes))
        adHocDurationMinutes = mins
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(mins * 60))
        let id = taskID ?? "adhoc_\(Int(now.timeIntervalSince1970))"
        let proofEnabled = requiresPhotoProof ?? adHocRequiresPhotoProof

        FocusNudgeScheduler.shared.acknowledgeAndClear(taskID: id)

        activeSession = LiveSession(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Deep Work" : title,
            cue: cue,
            startDate: now,
            endDate: end,
            isScheduledWallClock: false,
            requiresPhotoProof: proofEnabled,
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
            startAdHocSession(
                minutes: adHocDurationMinutes,
                cue: editableCue,
                requiresPhotoProof: adHocRequiresPhotoProof
            )
            return
        }

        let wasTracking = isTrackingDeepWork
        isTrackingDeepWork = active

        if let session = activeSession {
            FocusNudgeScheduler.shared.acknowledgeAndClear(taskID: session.id)

            // Arm 2-min + interval/random Photo Proof check-ins reliably on session start (works with or without Gemini key)
            if active && !wasTracking && session.requiresPhotoProof {
                let minsLeft = max(5, Int(ceil(Double(remainingSeconds) / 60.0)))
                PhotoProofScheduler.shared.scheduleProofs(
                    taskID: session.id,
                    taskTitle: session.title,
                    taskNotes: session.taskNotes,
                    taskStart: Date(),
                    durationMinutes: minsLeft,
                    triggerInitialImmediatelyIfNow: false
                )
            }
        }

        syncLiveActivity()
    }

    func togglePlayPause() {
        setDeepWorkTracking(!isTrackingDeepWork)
    }

    // MARK: - 1-Tap "Done" → In-Sheet "Good Job + Next Up" Celebration State

    func completeActiveTaskAndCelebrate() {
        guard let session = activeSession else { return }

        markTaskOrCalendarEventCompleted(sessionID: session.id)
        PhotoProofScheduler.shared.cancelProofs(for: session.id)
        FocusNudgeScheduler.shared.acknowledgeAndClear(taskID: session.id)

        if session.isScheduledWallClock {
            dismissedScheduledIDs.insert(session.id)
        }

        if unloggedActiveSecondsRemainder >= 30 {
            HabitMetricsEngine.addFocusMinutesToday(1)
        }
        let loggedActiveMins = max(
            activeDeepWorkSeconds / 60 + (unloggedActiveSecondsRemainder >= 30 ? 1 : 0),
            elapsedSeconds >= 60 ? (elapsedSeconds / 60) : 1
        )
        let displayedFocusedMins = activeDeepWorkSeconds >= 30
            ? (activeDeepWorkSeconds / 60 + (unloggedActiveSecondsRemainder >= 30 ? 1 : 0))
            : loggedActiveMins

        if activeDeepWorkSeconds >= 30 || elapsedSeconds >= 60 {
            HabitMetricsEngine.incrementFocusSessionsToday()
            WidgetSyncCoordinator.syncSnapshotFromStore()
            Task { await DailyNotificationManager.shared.refreshScheduledNotifications() }
        }

        let nextUp = computeNextUpTask(excludingID: session.id)

        activeSession = nil
        isTrackingDeepWork = false
        remainingSeconds = adHocDurationMinutes * 60
        activeDeepWorkSeconds = 0
        unloggedActiveSecondsRemainder = 0
        FocusLiveActivityManager.shared.endAll()

        completionOverlay = .completed(
            focusedMinutes: max(1, displayedFocusedMins),
            completedTitle: session.title,
            nextUp: nextUp
        )

        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func dismissCompletionOverlay() {
        completionOverlay = .none
    }

    func endCurrentSession(markDismissedIfScheduled: Bool = true) {
        if let session = activeSession {
            PhotoProofScheduler.shared.cancelProofs(for: session.id)
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
        completionOverlay = .none
        remainingSeconds = adHocDurationMinutes * 60
        activeDeepWorkSeconds = 0
        unloggedActiveSecondsRemainder = 0
        FocusLiveActivityManager.shared.endAll()
    }

    // MARK: - Live Next-Up Task Discovery

    func computeNextUpTask(excludingID: String? = nil) -> NextUpTaskInfo {
        let now = Date()
        let todayKey = HabitItem.dateKey(for: now)
        let tasks = SharedModelContainer.shared.fetchFocusTasks(dayKey: todayKey)
        let calendarBlocks = FocusAccountabilityManager.shared.upcomingBlocks
        let linkedIDs = Set(tasks.compactMap(\.googleCalendarEventID).filter { !$0.isEmpty })

        var candidates: [(title: String, startDate: Date)] = []

        for task in tasks where !task.isCompleted {
            if let excluded = excludingID, task.id.uuidString == excluded { continue }
            guard let start = task.startTime, start > now else { continue }
            candidates.append((task.title, start))
        }

        for block in calendarBlocks where !block.isAllDay && block.dayKey == todayKey {
            if let excluded = excludingID, block.id == excluded { continue }
            if let rID = block.remoteEventID, linkedIDs.contains(rID) { continue }
            let compKey = CalendarEventCompletionStore.eventKey(for: block)
            if CalendarEventCompletionStore.shared.isCompleted(eventKey: compKey) { continue }
            guard block.startDate > now else { continue }
            candidates.append((block.title, block.startDate))
        }

        if let next = candidates.sorted(by: { $0.startDate < $1.startDate }).first {
            let minsAway = max(1, Int(ceil(next.startDate.timeIntervalSince(now) / 60.0)))
            let timingText: String
            if minsAway < 60 {
                timingText = "in \(minsAway)m"
            } else if minsAway <= 120 {
                let h = minsAway / 60
                let m = minsAway % 60
                timingText = m == 0 ? "in \(h)h" : "in \(h)h \(m)m"
            } else {
                let f = DateFormatter()
                f.calendar = ISOWeekCalendar.current
                f.timeZone = TimeZone.current
                f.dateFormat = "HH:mm"
                timingText = "at \(f.string(from: next.startDate))"
            }

            return NextUpTaskInfo(
                headline: "Next: \(next.title) • \(timingText)",
                subtitle: "5-min heads-up armed before start",
                isAllClear: false,
                nextStartDate: next.startDate
            )
        }

        let remainingAnytime = tasks.filter { !$0.isCompleted && $0.startTime == nil && $0.id.uuidString != excludingID }.count
        let subtitle = remainingAnytime > 0
            ? (remainingAnytime == 1 ? "1 anytime task left" : "\(remainingAnytime) anytime tasks left")
            : "All scheduled blocks complete"

        return NextUpTaskInfo(
            headline: "All Clear Today",
            subtitle: subtitle,
            isAllClear: true,
            nextStartDate: nil
        )
    }

    private func markTaskOrCalendarEventCompleted(sessionID: String) {
        let todayKey = HabitItem.dateKey(for: Date())
        let tasks = SharedModelContainer.shared.fetchFocusTasks(dayKey: todayKey)

        if let matchedTask = tasks.first(where: { $0.id.uuidString == sessionID }) {
            if !matchedTask.isCompleted {
                matchedTask.isCompleted = true
                SharedModelContainer.shared.save()
            }
            return
        }

        let blocks = FocusAccountabilityManager.shared.upcomingBlocks
        if let matchedBlock = blocks.first(where: { $0.id == sessionID }) {
            let compKey = CalendarEventCompletionStore.eventKey(for: matchedBlock)
            if !CalendarEventCompletionStore.shared.isCompleted(eventKey: compKey) {
                _ = CalendarEventCompletionStore.shared.toggle(eventKey: compKey, dayKey: matchedBlock.dayKey)
            }
        }
    }

    // MARK: - Wall-Clock Auto-Start Discovery

    func evaluateAutoStartSchedule() {
        FocusLiveActivityManager.shared.endStaleActivitiesIfNeeded()

        let now = Date()
        let todayKey = HabitItem.dateKey(for: now)
        let tasks = SharedModelContainer.shared.fetchFocusTasks(dayKey: todayKey)
        let calendarBlocks = FocusAccountabilityManager.shared.upcomingBlocks

        let minuteKey = "\(todayKey)_\(ISOWeekCalendar.current.component(.hour, from: now))_\(ISOWeekCalendar.current.component(.minute, from: now))"
        if minuteKey != lastAutoEvaluatedMinuteKey {
            lastAutoEvaluatedMinuteKey = minuteKey
            FocusNudgeScheduler.shared.rescheduleUpcomingNudges(tasks: tasks, calendarBlocks: calendarBlocks)
        }

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

            completionOverlay = .none
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
            isTrackingDeepWork = false
            syncLiveActivity()

            if task.requiresPhotoProof {
                let minsLeft = max(5, Int(ceil(end.timeIntervalSince(now) / 60.0)))
                PhotoProofScheduler.shared.scheduleProofs(
                    taskID: id,
                    taskTitle: task.title,
                    taskNotes: task.notes,
                    taskStart: now,
                    durationMinutes: minsLeft,
                    triggerInitialImmediatelyIfNow: false
                )
            }
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

            completionOverlay = .none
            let calProofKey = CalendarPhotoProofStore.stableKey(for: block)
            let proofEnabled = CalendarPhotoProofStore.isEnabled(forKey: calProofKey)
            activeSession = LiveSession(
                id: block.id,
                title: block.title,
                cue: block.trimmedLocation.isEmpty ? block.notes : "at \(block.trimmedLocation)",
                startDate: block.startDate,
                endDate: block.endDate,
                isScheduledWallClock: true,
                requiresPhotoProof: proofEnabled,
                taskNotes: block.notes
            )
            editableCue = activeSession?.cue ?? ""
            remainingSeconds = max(0, Int(ceil(block.endDate.timeIntervalSince(now))))
            activeDeepWorkSeconds = 0
            unloggedActiveSecondsRemainder = 0
            isTrackingDeepWork = false
            syncLiveActivity()

            if proofEnabled {
                let minsLeft = max(5, Int(ceil(block.endDate.timeIntervalSince(now) / 60.0)))
                PhotoProofScheduler.shared.scheduleProofs(
                    taskID: calProofKey,
                    taskTitle: block.title,
                    taskNotes: block.notes,
                    taskStart: now,
                    durationMinutes: minsLeft,
                    triggerInitialImmediatelyIfNow: false
                )
            }
            return
        }
    }

    // MARK: - 1-Second Heartbeat

    private func handleSecondTick() {
        evaluateAutoStartSchedule()
        PhotoProofScheduler.shared.evaluateForegroundCheckIns()

        guard let session = activeSession else { return }
        let now = Date()

        if session.isScheduledWallClock {
            remainingSeconds = max(0, Int(ceil(session.endDate.timeIntervalSince(now))))
        } else if isTrackingDeepWork {
            remainingSeconds = max(0, remainingSeconds - 1)
        }

        if isTrackingDeepWork {
            activeDeepWorkSeconds += 1
            unloggedActiveSecondsRemainder += 1
            if unloggedActiveSecondsRemainder >= 60 {
                unloggedActiveSecondsRemainder -= 60
                HabitMetricsEngine.addFocusMinutesToday(1)
                WidgetSyncCoordinator.syncSnapshotFromStore()
            }
        }

        if remainingSeconds <= 0 {
            completeActiveTaskAndCelebrate()
        }
    }

    private func syncLiveActivity() {
        guard let session = activeSession else {
            FocusLiveActivityManager.shared.endAll()
            return
        }

        let pausedOnLockScreen = !session.isScheduledWallClock && !isTrackingDeepWork
        FocusLiveActivityManager.shared.start(
            taskTitle: session.title,
            focusCue: editableCue.isEmpty ? session.cue : editableCue,
            timeWindowLabel: sessionTimeWindowLabel,
            durationSeconds: totalBlockSeconds,
            elapsedSeconds: elapsedSeconds,
            isPaused: pausedOnLockScreen
        )
    }
}
