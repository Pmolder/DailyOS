import Foundation
import Combine
import UIKit

/// Real-Time Wall-Clock Auto-Start Focus Engine + Active Deep Work Tracker + Post-Completion Celebration / Next-Up Flow:
/// - Automatically starts any scheduled timed `FocusTaskItem` or Google/Apple Calendar block at `startDate <= now < endDate`
/// - Scheduled block ALWAYS progresses in real wall-clock time (never freezes when paused)
/// - Calm Elapsed-of-Total Time (`0:42 / 45m` → `35m / 45m` → `1h 05m / 1h 30m`) + `0% → 100%` progress bar
/// - Play / Pause toggles `isTrackingDeepWork` to count genuine `activeDeepWorkSeconds` into Focused Today & Weekly Recap
/// - 1-Tap "✓ Done" (or natural block end) plays an in-pill 2-phase Celebration (`6s`) → Next Up Preview (`20s` / docked if `<15m`)
///   with ZERO extra completion notification spam.
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
        let headline: String       // e.g., "NEXT: Gym — Upper Body • in 30m" or "✓ ALL CLEAR TODAY"
        let subtitle: String       // e.g., "5-min heads-up armed" or "2 anytime left"
        let isAllClear: Bool
        let nextStartDate: Date?
        let startsWithin15Minutes: Bool
    }

    enum CompletionOverlayState: Equatable {
        case none
        case celebrating(focusedMinutes: Int, completedTitle: String, startedAt: Date, nextUp: NextUpTaskInfo)
        case nextUp(info: NextUpTaskInfo, startedAt: Date)
    }

    @Published private(set) var activeSession: LiveSession? = nil
    @Published private(set) var isTrackingDeepWork: Bool = false
    @Published private(set) var remainingSeconds: Int = 45 * 60
    @Published private(set) var activeDeepWorkSeconds: Int = 0
    @Published private(set) var completionOverlay: CompletionOverlayState = .none
    @Published var editableCue: String = ""
    @Published var adHocDurationMinutes: Int = 45
    @Published var shouldPresentTimerSheet: Bool = false
    @Published var restoredFromPiP: Bool = false

    private var tickCancellable: AnyCancellable?
    private var unloggedActiveSecondsRemainder: Int = 0
    private var dismissedScheduledIDs: Set<String> = []
    private var lastAutoEvaluatedMinuteKey: String = ""
    private var lastLiveActivityLabel: String = ""

    private init() {
        tickCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.handleSecondTick()
            }
    }

    // MARK: - Derived Display Values (Calm Elapsed-of-Total Time)

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

    var elapsedSeconds: Int {
        guard activeSession != nil else { return 0 }
        return max(0, min(totalBlockSeconds, totalBlockSeconds - remainingSeconds))
    }

    /// Smoothly fills from `0.0 → 1.0` across the session.
    var elapsedProgressFraction: Double {
        guard activeSession != nil, totalBlockSeconds > 0 else { return 0.0 }
        return max(0.0, min(1.0, Double(elapsedSeconds) / Double(totalBlockSeconds)))
    }

    /// Calm Elapsed-of-Total text (`0:42 / 45m`, `35m / 45m`, `35m / 1h 30m`, `1h 05m / 1h 30m`).
    var formattedElapsedOfTotal: String {
        FocusElapsedTimeFormatter.formatElapsedOfTotal(
            elapsedSeconds: elapsedSeconds,
            totalSeconds: totalBlockSeconds
        )
    }

    var activeMinutesLoggedForSession: Int {
        activeDeepWorkSeconds / 60
    }

    // MARK: - PiP Tap Restore Handler

    func handleRestoreFromPiPTap() {
        restoredFromPiP = true
        if activeSession != nil && remainingSeconds <= 0 {
            completeActiveTaskAndCelebrate()
        }
        shouldPresentTimerSheet = true
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
        completionOverlay = .none
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

    // MARK: - 1-Tap "✓ Done" → In-Pill Celebration ("Good Job") + Next Up Preview (Zero Notification Spam)

    func completeActiveTaskAndCelebrate() {
        guard let session = activeSession else { return }

        // 1. Mark matching FocusTaskItem or Synced Calendar Block as completed
        markTaskOrCalendarEventCompleted(sessionID: session.id)
        PhotoProofScheduler.shared.cancelProofs(for: session.id)
        FocusNudgeScheduler.shared.acknowledgeAndClear(taskID: session.id)

        if session.isScheduledWallClock {
            dismissedScheduledIDs.insert(session.id)
        }

        // 2. Log remaining partial active seconds (if user focused >= 30s) & increment session count
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

        // 3. Compute live Next Up Preview (next timed FocusTaskItem or Google/Apple Calendar event today)
        let nextUp = computeNextUpTask(excludingID: session.id)

        // 4. Transition cleanly into Phase 1 (6s Celebration) directly inside Floating PiP & Timer Sheet
        activeSession = nil
        isTrackingDeepWork = false
        remainingSeconds = adHocDurationMinutes * 60
        activeDeepWorkSeconds = 0
        unloggedActiveSecondsRemainder = 0
        restoredFromPiP = false
        lastLiveActivityLabel = ""
        FocusLiveActivityManager.shared.endAll()

        completionOverlay = .celebrating(
            focusedMinutes: max(1, displayedFocusedMins),
            completedTitle: session.title,
            startedAt: Date(),
            nextUp: nextUp
        )

        FocusPiPManager.shared.armPiPIfNeeded()
        FocusPiPManager.shared.renderFrame(
            mode: .celebration(
                focusedMinutes: max(1, displayedFocusedMins),
                completedTitle: session.title,
                shimmerPhase: 0.15
            )
        )

        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func dismissCompletionOverlay() {
        completionOverlay = .none
        if activeSession == nil {
            FocusPiPManager.shared.stopAndDisarmPiP()
        }
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
        completionOverlay = .none
        restoredFromPiP = false
        remainingSeconds = adHocDurationMinutes * 60
        activeDeepWorkSeconds = 0
        unloggedActiveSecondsRemainder = 0
        lastLiveActivityLabel = ""
        FocusLiveActivityManager.shared.endAll()
        FocusPiPManager.shared.stopAndDisarmPiP()
    }

    // MARK: - Live Next-Up Task Discovery (Today's Timed Focus Tasks + Synced Calendar Events)

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

            let subtitle = minsAway <= 15
                ? "Auto-starting soon • stay ready"
                : "5-min heads-up armed before start"

            return NextUpTaskInfo(
                headline: "NEXT: \(next.title) • \(timingText)",
                subtitle: subtitle,
                isAllClear: false,
                nextStartDate: next.startDate,
                startsWithin15Minutes: minsAway <= 15
            )
        }

        let remainingAnytime = tasks.filter { !$0.isCompleted && $0.startTime == nil && $0.id.uuidString != excludingID }.count
        let subtitle = remainingAnytime > 0
            ? (remainingAnytime == 1 ? "1 anytime task left" : "\(remainingAnytime) anytime tasks left")
            : "All scheduled blocks complete"

        return NextUpTaskInfo(
            headline: "✓ ALL CLEAR TODAY",
            subtitle: subtitle,
            isAllClear: true,
            nextStartDate: nil,
            startsWithin15Minutes: false
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

            completionOverlay = .none
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

    // MARK: - 1-Second Heartbeat

    private func handleSecondTick() {
        evaluateAutoStartSchedule()

        // A. Handle Post-Completion Celebration (6s) → Next Up Preview (20s or docked if <15m)
        if activeSession == nil {
            handleCompletionOverlayTick()
            return
        }

        guard let session = activeSession else { return }
        let now = Date()

        // 1. Update remaining / elapsed progress
        if session.isScheduledWallClock {
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

        // 3. Keep Lock Screen Live Activity label in sync whenever elapsed-of-total minute changes
        let currentLabel = formattedElapsedOfTotal
        if currentLabel != lastLiveActivityLabel && (elapsedSeconds >= 60 || elapsedSeconds % 5 == 0) {
            lastLiveActivityLabel = currentLabel
            FocusLiveActivityManager.shared.update(
                isPaused: !session.isScheduledWallClock && !isTrackingDeepWork,
                remainingSeconds: remainingSeconds,
                totalDurationSeconds: totalBlockSeconds,
                elapsedOfTotalText: currentLabel
            )
        }

        // 4. Render 1 fps Floating PiP Pill Frame (Photo-Proof Alert OR Calm Elapsed-of-Total Pill)
        if let req = PhotoProofScheduler.shared.activeCaptureRequest {
            let secsLeft = Int(ceil(req.deadline.timeIntervalSinceNow))
            if secsLeft > 0 {
                FocusPiPManager.shared.renderFrame(
                    mode: .photoProofAlert(title: req.taskTitle, secondsLeft: secsLeft)
                )
            } else {
                FocusPiPManager.shared.renderFrame(
                    mode: .activeFocus(
                        title: session.title,
                        elapsedOfTotalText: currentLabel,
                        progressFraction: elapsedProgressFraction,
                        isActiveDeepWork: isTrackingDeepWork,
                        activeMinutesLogged: activeMinutesLoggedForSession
                    )
                )
            }
        } else {
            FocusPiPManager.shared.renderFrame(
                mode: .activeFocus(
                    title: session.title,
                    elapsedOfTotalText: currentLabel,
                    progressFraction: elapsedProgressFraction,
                    isActiveDeepWork: isTrackingDeepWork,
                    activeMinutesLogged: activeMinutesLoggedForSession
                )
            )
        }

        // 5. Auto-trigger Celebration + Next Up when block reaches 100% (45m / 45m)
        if remainingSeconds <= 0 {
            completeActiveTaskAndCelebrate()
        }
    }

    private func handleCompletionOverlayTick() {
        let now = Date()
        switch completionOverlay {
        case .none:
            return

        case .celebrating(let focusedMins, let completedTitle, let startedAt, _):
            let elapsed = now.timeIntervalSince(startedAt)
            if elapsed >= 6.0 {
                let refreshedNext = computeNextUpTask()
                completionOverlay = .nextUp(info: refreshedNext, startedAt: now)
                FocusPiPManager.shared.renderFrame(
                    mode: .nextUpPreview(
                        headline: refreshedNext.headline,
                        subtitle: refreshedNext.subtitle,
                        isAllClear: refreshedNext.isAllClear
                    )
                )
            } else {
                let phase = min(1.0, max(0.0, elapsed / 6.0))
                FocusPiPManager.shared.renderFrame(
                    mode: .celebration(
                        focusedMinutes: focusedMins,
                        completedTitle: completedTitle,
                        shimmerPhase: phase
                    )
                )
            }

        case .nextUp(let info, let startedAt):
            let elapsed = now.timeIntervalSince(startedAt)
            // Keep docked if next task starts within 15 min, otherwise auto-dismiss after 20s
            if info.startsWithin15Minutes, let nextStart = info.nextStartDate, nextStart > now {
                let refreshed = computeNextUpTask()
                completionOverlay = .nextUp(info: refreshed, startedAt: startedAt)
                FocusPiPManager.shared.renderFrame(
                    mode: .nextUpPreview(
                        headline: refreshed.headline,
                        subtitle: refreshed.subtitle,
                        isAllClear: refreshed.isAllClear
                    )
                )
            } else if elapsed >= 20.0 {
                dismissCompletionOverlay()
            } else {
                FocusPiPManager.shared.renderFrame(
                    mode: .nextUpPreview(
                        headline: info.headline,
                        subtitle: info.subtitle,
                        isAllClear: info.isAllClear
                    )
                )
            }
        }
    }

    private func syncLiveActivityAndPiP() {
        guard let session = activeSession else {
            FocusLiveActivityManager.shared.endAll()
            if case .none = completionOverlay {
                FocusPiPManager.shared.stopAndDisarmPiP()
            }
            return
        }

        FocusPiPManager.shared.armPiPIfNeeded()
        let label = formattedElapsedOfTotal
        lastLiveActivityLabel = label

        if session.isScheduledWallClock {
            FocusLiveActivityManager.shared.start(
                taskTitle: session.title,
                focusCue: editableCue.isEmpty ? session.cue : editableCue,
                durationSeconds: totalBlockSeconds,
                elapsedSeconds: elapsedSeconds
            )
            if !isTrackingDeepWork {
                FocusLiveActivityManager.shared.update(
                    isPaused: false,
                    remainingSeconds: remainingSeconds,
                    totalDurationSeconds: totalBlockSeconds,
                    elapsedOfTotalText: label
                )
            }
        } else {
            if isTrackingDeepWork {
                FocusLiveActivityManager.shared.start(
                    taskTitle: session.title,
                    focusCue: editableCue.isEmpty ? session.cue : editableCue,
                    durationSeconds: totalBlockSeconds,
                    elapsedSeconds: elapsedSeconds
                )
            } else {
                FocusLiveActivityManager.shared.update(
                    isPaused: true,
                    remainingSeconds: remainingSeconds,
                    totalDurationSeconds: totalBlockSeconds,
                    elapsedOfTotalText: label
                )
            }
        }
    }
}
