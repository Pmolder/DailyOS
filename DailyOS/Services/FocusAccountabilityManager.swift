import Foundation
import EventKit
import UIKit
import Combine

struct CalendarFilterOption: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String
}

/// Manages Tab 3 "Focus":
/// 1. Direct Google Calendar & Google Tasks sync (via OAuth 2.0 + PKCE) + optional Apple Calendar (EventKit) + Local Future Scheduled Tasks.
/// 2. Multi-day ISO-8601 Monday-first schedule view.
/// 3. Exact check-in rules:
///    - Initial proof due within the first 5 minutes of task start (T+0 to T+5m).
///    - Tasks <= 35 minutes: no further check-ins after initial proof.
///    - Tasks > 35 minutes: recurring proof every 30 minutes after the 1st check-in until task ends.
/// 4. Anti-Force-Close & Evasion Penalty:
///    - Dense background notification cascade when alarm active or window expiring.
///    - Swiping away notification sets `evasionPenaltyActive = true` + immediate burst.
///    - Reopening app or tapping notification while active/evaded forces full-screen Task Check-In Alarm
///      with 10-second 0% -> 22% hardware volume Evasion Penalty ramp.
@MainActor
final class FocusAccountabilityManager: ObservableObject {
    static let shared = FocusAccountabilityManager()

    private static let trackedAppleCalendarsKey = "com.patrik.dailyos.trackedAppleCalendarIDs"
    private static let appleCalendarEnabledKey = "com.patrik.dailyos.appleCalendarSyncEnabled"

    // Anti-force-close & evasion persistence keys
    private static let activeAlarmTaskIDKey = "com.patrik.dailyos.activeTaskAlarmID"
    private static let activeAlarmTaskTitleKey = "com.patrik.dailyos.activeTaskAlarmTitle"
    private static let activeAlarmTaskNotesKey = "com.patrik.dailyos.activeTaskAlarmNotes"
    private static let activeAlarmTaskSourceKey = "com.patrik.dailyos.activeTaskAlarmSource"
    private static let evasionPenaltyActiveKey = "com.patrik.dailyos.evasionPenaltyActive"

    // Calendar & Sync State
    @Published private(set) var appleCalendarAuthStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published var appleCalendarSyncEnabled: Bool = false
    @Published private(set) var availableAppleCalendars: [CalendarFilterOption] = []
    @Published var trackedAppleCalendarIDs: Set<String> = []
    @Published private(set) var isSyncingGoogle: Bool = false
    @Published private(set) var lastGoogleSyncMessage: String?

    // Multi-Day Unified Schedule
    @Published private(set) var upcomingBlocks: [FocusBlockDisplayItem] = []
    @Published private(set) var activeFocusBlock: FocusBlockDisplayItem?

    // Exact 5-Min Initial + 30-Min Recurring Check-In State
    @Published private(set) var completedCheckInsForCurrentBlock: Int = 0
    @Published private(set) var isCurrentBlockCleared: Bool = false
    @Published private(set) var nextCheckInDeadline: Date?
    @Published private(set) var secondsUntilCheckInDeadline: Int = 0
    @Published private(set) var checkInPhaseLabel: String = "No active focus task"

    // Full-Screen Alarm & Live Photo Proof State
    @Published var isFocusAlarmFullScreenPresented: Bool = false
    @Published private(set) var isEvasionPenaltyActive: Bool = false
    @Published private(set) var activeAlarmTitle: String = ""
    @Published private(set) var activeAlarmNotes: String = ""
    @Published private(set) var activeAlarmSource: String = ""

    @Published var isCapturingPhotoProof: Bool = false
    @Published private(set) var photoGraceSecondsRemaining: Int = 20
    @Published private(set) var isSubmittingToGemini: Bool = false
    @Published var lastVerificationFeedback: String?
    @Published var lastVerificationWasRejected: Bool = false

    private let eventStore = EKEventStore()
    private var cachedGoogleBlocks: [FocusBlockDisplayItem] = []
    private var tickTimer: Timer?
    private var graceTimer: Timer?
    private var trackedActiveBlockID: String?
    private var alarmTriggeredForCurrentDeadline: Bool = false

    private init() {
        loadSavedPreferences()
        startLoopTimer()
        if appleCalendarSyncEnabled && isAppleCalendarAuthorized {
            loadAvailableAppleCalendars()
        }
        refreshScheduleLocally()
    }

    var isAppleCalendarAuthorized: Bool {
        appleCalendarAuthStatus == .fullAccess
    }

    // MARK: - Preferences

    private func loadSavedPreferences() {
        appleCalendarSyncEnabled = UserDefaults.standard.bool(forKey: Self.appleCalendarEnabledKey)
        if let savedIDs = UserDefaults.standard.array(forKey: Self.trackedAppleCalendarsKey) as? [String] {
            trackedAppleCalendarIDs = Set(savedIDs)
        }
        isEvasionPenaltyActive = UserDefaults.standard.bool(forKey: Self.evasionPenaltyActiveKey)
    }

    func setAppleCalendarSyncEnabled(_ enabled: Bool) {
        appleCalendarSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.appleCalendarEnabledKey)
        if enabled && isAppleCalendarAuthorized {
            loadAvailableAppleCalendars()
        }
        refreshScheduleLocally()
    }

    func toggleAppleCalendarTracking(_ calendarID: String) {
        if trackedAppleCalendarIDs.contains(calendarID) {
            trackedAppleCalendarIDs.remove(calendarID)
        } else {
            trackedAppleCalendarIDs.insert(calendarID)
        }
        UserDefaults.standard.set(Array(trackedAppleCalendarIDs), forKey: Self.trackedAppleCalendarsKey)
        refreshScheduleLocally()
    }

    func restoreSettings(
        trackedAppleCalendarIDs: Set<String>,
        appleEnabled: Bool,
        googleCalendarEnabled: Bool,
        googleTasksEnabled: Bool
    ) {
        self.trackedAppleCalendarIDs = trackedAppleCalendarIDs
        UserDefaults.standard.set(Array(trackedAppleCalendarIDs), forKey: Self.trackedAppleCalendarsKey)
        setAppleCalendarSyncEnabled(appleEnabled)
        GoogleAuthService.shared.setGoogleCalendarSync(googleCalendarEnabled)
        GoogleAuthService.shared.setGoogleTasksSync(googleTasksEnabled)
    }

    // MARK: - Apple Calendar (EventKit - Optional Toggleable Source)

    func requestAppleCalendarAccess() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            appleCalendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
            if granted {
                setAppleCalendarSyncEnabled(true)
                loadAvailableAppleCalendars()
                refreshScheduleLocally()
            }
        } catch {
            print("[FocusAccountabilityManager] EventKit access error: \(error.localizedDescription)")
            appleCalendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
        }
    }

    func loadAvailableAppleCalendars() {
        appleCalendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
        guard isAppleCalendarAuthorized else { return }

        availableAppleCalendars = eventStore.calendars(for: .event).map { cal in
            CalendarFilterOption(
                id: cal.calendarIdentifier,
                title: cal.title,
                sourceTitle: cal.source?.title ?? "Local"
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        if trackedAppleCalendarIDs.isEmpty && !availableAppleCalendars.isEmpty {
            trackedAppleCalendarIDs = Set(availableAppleCalendars.map(\.id))
            UserDefaults.standard.set(Array(trackedAppleCalendarIDs), forKey: Self.trackedAppleCalendarsKey)
        }
    }

    // MARK: - Google Calendar & Google Tasks Sync

    func syncAllSources() async {
        refreshScheduleLocally()

        let auth = GoogleAuthService.shared
        guard auth.isConnected, (auth.syncGoogleCalendarEnabled || auth.syncGoogleTasksEnabled) else {
            cachedGoogleBlocks = []
            refreshScheduleLocally()
            return
        }

        isSyncingGoogle = true
        defer { isSyncingGoogle = false }

        guard let accessToken = await auth.getValidAccessToken() else {
            lastGoogleSyncMessage = "Google token unavailable — reconnect in Settings."
            return
        }

        var fetched: [FocusBlockDisplayItem] = []

        if auth.syncGoogleCalendarEnabled {
            let calEvents = await GoogleSyncService.fetchUpcomingCalendarEvents(accessToken: accessToken, daysAhead: 14)
            fetched.append(contentsOf: calEvents)
        }

        if auth.syncGoogleTasksEnabled {
            let taskItems = await GoogleSyncService.fetchScheduledGoogleTasks(accessToken: accessToken, daysAhead: 21)
            fetched.append(contentsOf: taskItems)
        }

        cachedGoogleBlocks = fetched
        lastGoogleSyncMessage = "Synced \(fetched.count) Google item(s) at \(Date().formatted(date: .omitted, time: .shortened))"
        refreshScheduleLocally()
    }

    // MARK: - Multi-Day Unified Schedule Assembly

    func refreshScheduleLocally() {
        let now = Date()
        let cal = ISOWeekCalendar.current
        let todayStart = cal.startOfDay(for: now)
        let horizonEnd = cal.date(byAdding: .day, value: 21, to: todayStart) ?? now.addingTimeInterval(21 * 86400)

        var combined: [FocusBlockDisplayItem] = []

        // 1. Google Calendar + Google Tasks (cached from REST API v3/v1)
        let auth = GoogleAuthService.shared
        for item in cachedGoogleBlocks where item.endDate > todayStart {
            if item.source == .googleCalendar && !auth.syncGoogleCalendarEnabled { continue }
            if item.source == .googleTasks && !auth.syncGoogleTasksEnabled { continue }
            combined.append(item)
        }

        // 2. Optional Apple Calendar (EventKit)
        if appleCalendarSyncEnabled && isAppleCalendarAuthorized {
            let selectedCals = eventStore.calendars(for: .event).filter {
                trackedAppleCalendarIDs.isEmpty || trackedAppleCalendarIDs.contains($0.calendarIdentifier)
            }
            if !selectedCals.isEmpty {
                let predicate = eventStore.predicateForEvents(
                    withStart: todayStart,
                    end: horizonEnd,
                    calendars: selectedCals
                )
                let events = eventStore.events(matching: predicate).filter { !$0.isAllDay && $0.endDate > todayStart }
                for ev in events {
                    let eventID = ev.eventIdentifier ?? "\(ev.title ?? "Event")_\(ev.startDate.timeIntervalSince1970)"
                    combined.append(
                        FocusBlockDisplayItem(
                            id: "apple_\(eventID)",
                            title: ev.title ?? "Calendar Event",
                            notes: ev.notes ?? ev.location ?? "",
                            calendarTitle: ev.calendar?.title ?? "Apple Calendar",
                            source: .appleCalendar,
                            startDate: ev.startDate,
                            endDate: ev.endDate,
                            manualBlockID: nil
                        )
                    )
                }
            }
        }

        // 3. Local Native Future Scheduled Focus Tasks (SwiftData)
        let localBlocks = SharedModelContainer.shared.fetchManualFocusBlocks()
            .filter { $0.isActive && $0.endDate > todayStart }

        for block in localBlocks {
            combined.append(
                FocusBlockDisplayItem(
                    id: "local_\(block.id.uuidString)",
                    title: block.title,
                    notes: block.notes,
                    calendarTitle: "Local Task",
                    source: .local,
                    startDate: block.startDate,
                    endDate: block.endDate,
                    manualBlockID: block.id
                )
            )
        }

        combined.sort { $0.startDate < $1.startDate }
        upcomingBlocks = combined

        evaluateActiveBlock(at: now)
    }

    /// Creates a scheduled local task for ANY future date and time window (e.g., 3 days ahead, 14:00-17:00).
    func addScheduledTask(title: String, notes: String, startDate: Date, endDate: Date) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, endDate > startDate else { return }

        let block = ManualFocusBlock(
            title: trimmedTitle,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: startDate,
            endDate: endDate,
            isActive: true
        )
        SharedModelContainer.shared.mainContext.insert(block)
        SharedModelContainer.shared.save()
        refreshScheduleLocally()
    }

    func deleteScheduledTask(id: UUID) {
        let blocks = SharedModelContainer.shared.fetchManualFocusBlocks()
        if let target = blocks.first(where: { $0.id == id }) {
            SharedModelContainer.shared.mainContext.delete(target)
            SharedModelContainer.shared.save()
        }
        if activeFocusBlock?.manualBlockID == id {
            resetBlockCheckInTracking()
        }
        refreshScheduleLocally()
    }

    // MARK: - Exact Check-In Timing Loop (Initial 5m + Recurring 30m for Tasks > 35m)

    private func startLoopTimer() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickFocusLoop()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tickFocusLoop() {
        let now = Date()
        evaluateActiveBlock(at: now)

        guard let active = activeFocusBlock else {
            secondsUntilCheckInDeadline = 0
            nextCheckInDeadline = nil
            checkInPhaseLabel = "No active focus task"
            return
        }

        if isCurrentBlockCleared {
            secondsUntilCheckInDeadline = 0
            nextCheckInDeadline = nil
            checkInPhaseLabel = "Initial proof verified — task cleared (≤ 35 min)"
            return
        }

        guard let deadline = nextCheckInDeadline else { return }
        let remaining = Int(ceil(deadline.timeIntervalSince(now)))
        secondsUntilCheckInDeadline = max(0, remaining)

        if completedCheckInsForCurrentBlock == 0 {
            checkInPhaseLabel = remaining > 0
                ? "Initial 5-min proof window open"
                : "Initial 5-min proof missed — Alarm Active!"
        } else {
            checkInPhaseLabel = remaining > 0
                ? "Next 30-min recurring proof due"
                : "Recurring 30-min proof missed — Alarm Active!"
        }

        // Trigger Normal Focus Task Alarm (1% -> 22% over 2 min) if deadline expired!
        if remaining <= 0 && !alarmTriggeredForCurrentDeadline && !AlarmEngine.shared.isAlarmRinging {
            alarmTriggeredForCurrentDeadline = true
            activateFocusTaskAlarm(
                taskID: active.id,
                taskTitle: active.title,
                taskNotes: active.notes,
                taskSource: active.source.badgeTitle,
                evasionPenalty: isEvasionPenaltyActive
            )
        }
    }

    private func evaluateActiveBlock(at now: Date) {
        let ongoing = upcomingBlocks.first(where: { $0.isOngoing(at: now) })

        if ongoing?.id != trackedActiveBlockID {
            trackedActiveBlockID = ongoing?.id
            activeFocusBlock = ongoing

            if let block = ongoing {
                // New active task started at T+0: Initial proof required within first 5 minutes (T+0 to T+5 min)!
                completedCheckInsForCurrentBlock = 0
                isCurrentBlockCleared = false
                alarmTriggeredForCurrentDeadline = false

                let initialDeadline = block.startDate.addingTimeInterval(5 * 60)
                nextCheckInDeadline = initialDeadline

                if initialDeadline > now {
                    NotificationScheduler.shared.scheduleUpcomingCheckInDeadlineCascade(
                        deadlineDate: initialDeadline,
                        taskID: block.id,
                        taskTitle: block.title,
                        taskNotes: block.notes,
                        taskSource: block.source.badgeTitle
                    )
                }
            } else {
                // Only clear deadline tracking if there is no unresolved persisted alarm
                if !hasPersistedActiveTaskAlarm {
                    resetBlockCheckInTracking()
                }
            }
        } else {
            activeFocusBlock = ongoing
        }
    }

    private func resetBlockCheckInTracking() {
        completedCheckInsForCurrentBlock = 0
        isCurrentBlockCleared = false
        nextCheckInDeadline = nil
        secondsUntilCheckInDeadline = 0
        alarmTriggeredForCurrentDeadline = false
        checkInPhaseLabel = "No active focus task"
    }

    // MARK: - Anti-Force-Close & Evasion Penalty State Machine

    var hasPersistedActiveTaskAlarm: Bool {
        UserDefaults.standard.string(forKey: Self.activeAlarmTaskIDKey) != nil
    }

    private func persistActiveTaskAlarm(taskID: String, title: String, notes: String, source: String) {
        UserDefaults.standard.set(taskID, forKey: Self.activeAlarmTaskIDKey)
        UserDefaults.standard.set(title, forKey: Self.activeAlarmTaskTitleKey)
        UserDefaults.standard.set(notes, forKey: Self.activeAlarmTaskNotesKey)
        UserDefaults.standard.set(source, forKey: Self.activeAlarmTaskSourceKey)
    }

    private func clearPersistedActiveTaskAlarm() {
        UserDefaults.standard.removeObject(forKey: Self.activeAlarmTaskIDKey)
        UserDefaults.standard.removeObject(forKey: Self.activeAlarmTaskTitleKey)
        UserDefaults.standard.removeObject(forKey: Self.activeAlarmTaskNotesKey)
        UserDefaults.standard.removeObject(forKey: Self.activeAlarmTaskSourceKey)
        UserDefaults.standard.set(false, forKey: Self.evasionPenaltyActiveKey)
        isEvasionPenaltyActive = false
    }

    /// Triggers the full-screen Task Check-In Alarm + hardware volume ramp + background notification cascade.
    func activateFocusTaskAlarm(
        taskID: String,
        taskTitle: String,
        taskNotes: String,
        taskSource: String,
        evasionPenalty: Bool
    ) {
        activeAlarmTitle = taskTitle
        activeAlarmNotes = taskNotes
        activeAlarmSource = taskSource
        isEvasionPenaltyActive = evasionPenalty
        lastVerificationFeedback = nil
        lastVerificationWasRejected = false

        persistActiveTaskAlarm(taskID: taskID, title: taskTitle, notes: taskNotes, source: taskSource)
        if evasionPenalty {
            UserDefaults.standard.set(true, forKey: Self.evasionPenaltyActiveKey)
        }

        isFocusAlarmFullScreenPresented = true

        // Pre-schedule dense 6s background notification cascade in case user backgrounds/force-closes
        NotificationScheduler.shared.scheduleFocusTaskAlarmCascade(
            taskID: taskID,
            taskTitle: taskTitle,
            taskNotes: taskNotes,
            taskSource: taskSource,
            isEvasionBurst: evasionPenalty
        )

        if !AlarmEngine.shared.isAlarmRinging {
            AlarmAudioManager.shared.startFocusTaskAlarm(evasionPenalty: evasionPenalty)
        }
    }

    /// Called by `UNUserNotificationCenterDelegate` when user swipes away a Focus Task Alarm notification!
    func handleNotificationDismissedEvasion(
        taskID: String,
        taskTitle: String,
        taskNotes: String,
        taskSource: String
    ) {
        persistActiveTaskAlarm(taskID: taskID, title: taskTitle, notes: taskNotes, source: taskSource)
        UserDefaults.standard.set(true, forKey: Self.evasionPenaltyActiveKey)
        isEvasionPenaltyActive = true

        // Immediately schedule fresh aggressive burst (1s, 5s, 10s...) reminding them alarm is still active
        NotificationScheduler.shared.scheduleFocusTaskAlarmCascade(
            taskID: taskID,
            taskTitle: taskTitle,
            taskNotes: taskNotes,
            taskSource: taskSource,
            isEvasionBurst: true
        )
    }

    /// Called when user taps a Focus Task Alarm notification.
    func handleTaskAlarmNotificationTap(
        taskID: String,
        taskTitle: String,
        taskNotes: String,
        taskSource: String
    ) {
        let evasionFlag = UserDefaults.standard.bool(forKey: Self.evasionPenaltyActiveKey)
        activateFocusTaskAlarm(
            taskID: taskID,
            taskTitle: taskTitle,
            taskNotes: taskNotes,
            taskSource: taskSource,
            evasionPenalty: evasionFlag
        )
    }

    /// Called on app launch and `scenePhase == .active`:
    /// If the user force-closed the app during an active task alarm OR swiped away notifications (`evasionPenaltyActive == true`),
    /// immediately force open the full-screen Task Check-In Alarm with the 10-second 0% -> 22% Evasion Penalty ramp!
    func handleAppReopenCheck() {
        let evasionFlag = UserDefaults.standard.bool(forKey: Self.evasionPenaltyActiveKey)
        let persistedID = UserDefaults.standard.string(forKey: Self.activeAlarmTaskIDKey)

        guard evasionFlag || persistedID != nil else { return }

        let taskID = persistedID ?? "persisted_focus_alarm"
        let title = UserDefaults.standard.string(forKey: Self.activeAlarmTaskTitleKey) ?? "Scheduled Focus Task"
        let notes = UserDefaults.standard.string(forKey: Self.activeAlarmTaskNotesKey) ?? ""
        let source = UserDefaults.standard.string(forKey: Self.activeAlarmTaskSourceKey) ?? "Focus"

        // Reopening after force-close or notification swipe-dismiss triggers the 10-second 0% -> 22% Evasion Penalty!
        let shouldEscalateEvasion = evasionFlag || !AlarmAudioManager.shared.isFocusWarningActive
        if !isFocusAlarmFullScreenPresented || !AlarmAudioManager.shared.isFocusWarningActive {
            activateFocusTaskAlarm(
                taskID: taskID,
                taskTitle: title,
                taskNotes: notes,
                taskSource: source,
                evasionPenalty: shouldEscalateEvasion
            )
        }
    }

    // MARK: - Voluntary Early Proof & Live Camera Proof Submission

    /// Opens live camera proof proactively while within the 5-min initial or 30-min recurring window (before alarm fires).
    func openVoluntaryProofCapture(for block: FocusBlockDisplayItem) {
        activeAlarmTitle = block.title
        activeAlarmNotes = block.notes
        activeAlarmSource = block.source.badgeTitle
        lastVerificationFeedback = nil
        lastVerificationWasRejected = false
        isFocusAlarmFullScreenPresented = true
        isCapturingPhotoProof = true
        photoGraceSecondsRemaining = 20
        start20SecondPhotoGraceTimer()
    }

    /// Triggered from the Full-Screen Task Alarm when user taps "Take Proof Photo".
    func beginPhotoProofCaptureFromAlarm() {
        AlarmAudioManager.shared.pauseFocusWarningForPhotoProof()
        isCapturingPhotoProof = true
        lastVerificationWasRejected = false
        start20SecondPhotoGraceTimer()
    }

    private func start20SecondPhotoGraceTimer() {
        graceTimer?.invalidate()
        photoGraceSecondsRemaining = 20

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCapturingPhotoProof && !self.isSubmittingToGemini else { return }

                if self.photoGraceSecondsRemaining > 1 {
                    self.photoGraceSecondsRemaining -= 1
                } else {
                    self.photoGraceSecondsRemaining = 0
                    self.graceTimer?.invalidate()
                    self.graceTimer = nil
                    self.lastVerificationWasRejected = true
                    self.lastVerificationFeedback = "20-second capture window expired! Alarm resumed."
                    AlarmAudioManager.shared.resumeFocusWarningAfterFailureOrTimeout(
                        evasionPenalty: self.isEvasionPenaltyActive
                    )
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        graceTimer = timer
    }

    func returnFromCameraWithoutSubmitting() {
        graceTimer?.invalidate()
        graceTimer = nil
        isCapturingPhotoProof = false

        // If this was a voluntary early proof (no active alarm), allow dismissing the sheet cleanly.
        if !hasPersistedActiveTaskAlarm && !AlarmAudioManager.shared.isFocusWarningActive {
            isFocusAlarmFullScreenPresented = false
        } else {
            AlarmAudioManager.shared.resumeFocusWarningAfterFailureOrTimeout(
                evasionPenalty: isEvasionPenaltyActive
            )
        }
    }

    func submitLiveProofPhoto(_ image: UIImage) async {
        guard !isSubmittingToGemini else { return }
        graceTimer?.invalidate()
        graceTimer = nil
        isSubmittingToGemini = true
        lastVerificationFeedback = "Verifying with Gemini 2.5 Flash..."
        lastVerificationWasRejected = false

        let taskTitle = activeAlarmTitle.isEmpty ? (activeFocusBlock?.title ?? "Focus Task") : activeAlarmTitle
        let taskNotes = activeAlarmNotes.isEmpty ? (activeFocusBlock?.notes ?? "") : activeAlarmNotes
        let taskSource = activeAlarmSource.isEmpty ? (activeFocusBlock?.source.badgeTitle ?? "Focus") : activeAlarmSource

        let result = await GeminiVisionService.verifyFocusPhoto(
            image: image,
            taskTitle: taskTitle,
            taskDescription: taskNotes
        )

        isSubmittingToGemini = false

        let log = FocusCheckInLog(
            taskTitle: taskTitle,
            calendarSource: taskSource,
            timestamp: Date(),
            verified: result.verified,
            reason: result.reason,
            wasOfflineFallback: result.usedOfflineFallback
        )
        SharedModelContainer.shared.mainContext.insert(log)
        SharedModelContainer.shared.save()

        if result.verified {
            lastVerificationFeedback = "VERIFIED: \(result.reason)"
            lastVerificationWasRejected = false
            isCapturingPhotoProof = false
            isFocusAlarmFullScreenPresented = false
            alarmTriggeredForCurrentDeadline = false

            // ONLY cancel cascade & alarm state once verified!
            clearPersistedActiveTaskAlarm()
            NotificationScheduler.shared.cancelFocusTaskAlarmCascade()
            AlarmAudioManager.shared.stopFocusWarning()

            UINotificationFeedbackGenerator().notificationOccurred(.success)

            // Apply exact <= 35m vs > 35m recurring schedule rule!
            if let block = activeFocusBlock {
                completedCheckInsForCurrentBlock += 1
                if !block.requiresRecurringCheckIns {
                    // Task <= 35 minutes: no further check-ins required after initial proof!
                    isCurrentBlockCleared = true
                    nextCheckInDeadline = nil
                    secondsUntilCheckInDeadline = 0
                } else {
                    // Task > 35 minutes: schedule next proof exactly 30 minutes after this check-in!
                    let nextDue = Date().addingTimeInterval(30 * 60)
                    if nextDue < block.endDate {
                        nextCheckInDeadline = nextDue
                        NotificationScheduler.shared.scheduleUpcomingCheckInDeadlineCascade(
                            deadlineDate: nextDue,
                            taskID: block.id,
                            taskTitle: block.title,
                            taskNotes: block.notes,
                            taskSource: block.source.badgeTitle
                        )
                    } else {
                        isCurrentBlockCleared = true
                        nextCheckInDeadline = nil
                        secondsUntilCheckInDeadline = 0
                    }
                }
            }
        } else {
            lastVerificationFeedback = "REJECTED: \(result.reason)"
            lastVerificationWasRejected = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)

            // AI rejected photo -> resume alarm until valid proof is submitted!
            AlarmAudioManager.shared.resumeFocusWarningAfterFailureOrTimeout(
                evasionPenalty: isEvasionPenaltyActive
            )
        }
    }
}
