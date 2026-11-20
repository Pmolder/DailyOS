import Foundation
import EventKit
import UIKit
import Combine
import UserNotifications

struct CalendarFilterOption: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String
    let colorHex: String
}

/// Manages Tab 3 "Focus":
/// 1. EventKit sync with iOS Apple/Google calendars + calendar filtering (e.g., "KOOL")
/// 2. Manual custom focus blocks
/// 3. Periodic 30–40 minute live camera check-in loop
/// 4. 2-minute escalating warning alarm (0% -> 50%) + 20-second photo proof grace timer
@MainActor
final class FocusAccountabilityManager: ObservableObject {
    static let shared = FocusAccountabilityManager()

    private static let trackedCalendarsKey = "com.patrik.dailyos.trackedCalendarIDs"
    private static let checkInIntervalKey = "com.patrik.dailyos.focusCheckInIntervalMinutes"

    @Published private(set) var calendarAuthStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var availableCalendars: [CalendarFilterOption] = []
    @Published var trackedCalendarIDs: Set<String> = []
    @Published var checkInIntervalMinutes: Int = 35

    @Published private(set) var todayBlocks: [FocusBlockDisplayItem] = []
    @Published private(set) var activeFocusBlock: FocusBlockDisplayItem?

    // Check-In Loop & Warning Alarm State
    @Published private(set) var nextCheckInDate: Date?
    @Published private(set) var secondsUntilNextCheckIn: Int = 0
    @Published var isCheckInDue: Bool = false
    @Published var isPhotoCaptureModalPresented: Bool = false
    @Published private(set) var photoGraceSecondsRemaining: Int = 20
    @Published private(set) var isSubmittingToGemini: Bool = false
    @Published var lastVerificationFeedback: String?
    @Published var lastVerificationWasRejected: Bool = false

    private let eventStore = EKEventStore()
    private var tickTimer: Timer?
    private var graceTimer: Timer?
    private var activeBlockIdentifier: String?
    private var checkInPromptStartedAt: Date?

    private init() {
        loadSavedPreferences()
        startLoopTimer()
        if isCalendarAuthorized {
            loadAvailableCalendars()
            refreshTodaySchedule()
        }
    }

    var isCalendarAuthorized: Bool {
        calendarAuthStatus == .fullAccess
    }

    // MARK: - Preferences

    private func loadSavedPreferences() {
        if let savedIDs = UserDefaults.standard.array(forKey: Self.trackedCalendarsKey) as? [String] {
            trackedCalendarIDs = Set(savedIDs)
        }
        let savedInterval = UserDefaults.standard.integer(forKey: Self.checkInIntervalKey)
        checkInIntervalMinutes = (30...40).contains(savedInterval) ? savedInterval : 35
    }

    func updateCheckInInterval(_ minutes: Int) {
        let clamped = max(30, min(40, minutes))
        checkInIntervalMinutes = clamped
        UserDefaults.standard.set(clamped, forKey: Self.checkInIntervalKey)

        // Reset next check-in timer if a block is currently active and not already overdue
        if activeFocusBlock != nil && !isCheckInDue {
            scheduleNextCheckIn(from: Date())
        }
    }

    func toggleCalendarTracking(_ calendarID: String) {
        if trackedCalendarIDs.contains(calendarID) {
            trackedCalendarIDs.remove(calendarID)
        } else {
            trackedCalendarIDs.insert(calendarID)
        }
        UserDefaults.standard.set(Array(trackedCalendarIDs), forKey: Self.trackedCalendarsKey)
        refreshTodaySchedule()
    }

    func restoreSettings(trackedCalendarIDs: Set<String>, intervalMinutes: Int) {
        self.trackedCalendarIDs = trackedCalendarIDs
        UserDefaults.standard.set(Array(trackedCalendarIDs), forKey: Self.trackedCalendarsKey)
        updateCheckInInterval(intervalMinutes)
    }

    // MARK: - EventKit Calendar Sync

    func requestCalendarAccess() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
            if granted {
                loadAvailableCalendars()
                refreshTodaySchedule()
            }
        } catch {
            print("[FocusAccountabilityManager] EventKit access error: \(error.localizedDescription)")
            calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
        }
    }

    func loadAvailableCalendars() {
        calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
        guard isCalendarAuthorized else { return }

        let ekCalendars = eventStore.calendars(for: .event)
        availableCalendars = ekCalendars.map { cal in
            CalendarFilterOption(
                id: cal.calendarIdentifier,
                title: cal.title,
                sourceTitle: cal.source?.title ?? "Local",
                colorHex: cal.cgColor?.components?.prefix(3).map { String(format: "%02X", Int($0 * 255)) }.joined() ?? "6366F1"
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // Auto-select all calendars on first sync (prioritizing any named "KOOL" or default)
        if trackedCalendarIDs.isEmpty && !availableCalendars.isEmpty {
            trackedCalendarIDs = Set(availableCalendars.map(\.id))
            UserDefaults.standard.set(Array(trackedCalendarIDs), forKey: Self.trackedCalendarsKey)
        }
    }

    func refreshTodaySchedule() {
        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now.addingTimeInterval(86400)

        var combined: [FocusBlockDisplayItem] = []

        // 1. Synced iOS Calendar Events (Apple / Google / Exchange)
        if isCalendarAuthorized {
            let selectedEKCalendars = eventStore.calendars(for: .event).filter {
                trackedCalendarIDs.isEmpty || trackedCalendarIDs.contains($0.calendarIdentifier)
            }
            if !selectedEKCalendars.isEmpty {
                let predicate = eventStore.predicateForEvents(
                    withStart: startOfDay,
                    end: endOfDay,
                    calendars: selectedEKCalendars
                )
                let events = eventStore.events(matching: predicate).filter { !$0.isAllDay }
                for ev in events {
                    let eventID = ev.eventIdentifier ?? "\(ev.title ?? "Event")_\(ev.startDate.timeIntervalSince1970)"
                    combined.append(
                        FocusBlockDisplayItem(
                            id: "ek_\(eventID)",
                            title: ev.title ?? "Untitled Event",
                            notes: ev.notes ?? ev.location ?? "",
                            calendarTitle: ev.calendar?.title ?? "Calendar",
                            startDate: ev.startDate,
                            endDate: ev.endDate,
                            isManual: false,
                            manualBlockID: nil
                        )
                    )
                }
            }
        }

        // 2. Manual Custom Focus Blocks from SwiftData
        let manualBlocks = SharedModelContainer.shared.fetchManualFocusBlocks()
            .filter { $0.isActive && $0.endDate > startOfDay && $0.startDate < endOfDay }

        for block in manualBlocks {
            combined.append(
                FocusBlockDisplayItem(
                    id: "manual_\(block.id.uuidString)",
                    title: block.title,
                    notes: block.notes,
                    calendarTitle: "Manual Focus",
                    startDate: block.startDate,
                    endDate: block.endDate,
                    isManual: true,
                    manualBlockID: block.id
                )
            )
        }

        combined.sort { $0.startDate < $1.startDate }
        todayBlocks = combined

        evaluateActiveBlock(at: now)
    }

    func addManualFocusBlock(title: String, notes: String, durationMinutes: Int) {
        let now = Date()
        let block = ManualFocusBlock(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Deep Work Block" : title,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: now,
            endDate: now.addingTimeInterval(TimeInterval(max(15, durationMinutes) * 60)),
            isActive: true
        )
        SharedModelContainer.shared.mainContext.insert(block)
        SharedModelContainer.shared.save()
        refreshTodaySchedule()
    }

    func endManualFocusBlock(id: UUID) {
        let blocks = SharedModelContainer.shared.fetchManualFocusBlocks()
        if let target = blocks.first(where: { $0.id == id }) {
            target.isActive = false
            target.endDate = Date()
            SharedModelContainer.shared.save()
        }
        if activeFocusBlock?.manualBlockID == id {
            clearCheckInState()
        }
        refreshTodaySchedule()
    }

    // MARK: - Periodic 30–40 Min Accountability Loop

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

        guard activeFocusBlock != nil else {
            secondsUntilNextCheckIn = 0
            nextCheckInDate = nil
            return
        }

        if isCheckInDue {
            // If check-in became due and wasn't opened within 10s prompt window, ensure 2-minute escalating warning runs
            if let promptStart = checkInPromptStartedAt,
               now.timeIntervalSince(promptStart) >= 10.0,
               !isPhotoCaptureModalPresented,
               !AlarmAudioManager.shared.isFocusWarningActive,
               !AlarmEngine.shared.isAlarmRinging {
                AlarmAudioManager.shared.startFocusWarningEscalation()
            }
            return
        }

        if let nextDate = nextCheckInDate {
            let remaining = Int(ceil(nextDate.timeIntervalSince(now)))
            if remaining <= 0 {
                secondsUntilNextCheckIn = 0
                triggerCheckInDue(immediateAlarm: false)
            } else {
                secondsUntilNextCheckIn = remaining
            }
        }
    }

    private func evaluateActiveBlock(at now: Date) {
        let ongoing = todayBlocks.first(where: { $0.isOngoing(at: now) })

        if ongoing?.id != activeBlockIdentifier {
            activeBlockIdentifier = ongoing?.id
            activeFocusBlock = ongoing

            if ongoing != nil {
                scheduleNextCheckIn(from: now)
            } else {
                clearCheckInState()
            }
        } else {
            activeFocusBlock = ongoing
        }
    }

    private func scheduleNextCheckIn(from referenceDate: Date) {
        let interval = TimeInterval(checkInIntervalMinutes * 60)
        let targetDate = referenceDate.addingTimeInterval(interval)
        nextCheckInDate = targetDate
        secondsUntilNextCheckIn = Int(interval)
        scheduleCheckInLocalNotification(at: targetDate, taskTitle: activeFocusBlock?.title ?? "Focus Session")
    }

    /// Triggers an immediate accountability check-in (used automatically when timer hits 0, or via "Test Check-In Now").
    func triggerCheckInDue(immediateAlarm: Bool = false) {
        // If no active block exists when manually testing, create a quick test display context
        if activeFocusBlock == nil {
            let now = Date()
            activeFocusBlock = FocusBlockDisplayItem(
                id: "adhoc_test",
                title: "Active Focus Session",
                notes: "Stay on task and submit live photo proof.",
                calendarTitle: "Focus Check-In",
                startDate: now,
                endDate: now.addingTimeInterval(3600),
                isManual: true,
                manualBlockID: nil
            )
            activeBlockIdentifier = "adhoc_test"
        }

        isCheckInDue = true
        lastVerificationFeedback = nil
        lastVerificationWasRejected = false
        checkInPromptStartedAt = Date()

        scheduleCheckInLocalNotification(at: Date().addingTimeInterval(1), taskTitle: activeFocusBlock?.title ?? "Focus Session")

        if immediateAlarm {
            AlarmAudioManager.shared.startFocusWarningEscalation()
        }
    }

    /// User tapped "Take Proof Photo": immediately pauses the 2-min warning alarm and starts the 20s grace timer.
    func beginPhotoProofCaptureWithGraceTimer() {
        AlarmAudioManager.shared.pauseFocusWarningForPhotoProof()
        isPhotoCaptureModalPresented = true
        lastVerificationWasRejected = false
        start20SecondGraceTimer()
    }

    private func start20SecondGraceTimer() {
        graceTimer?.invalidate()
        photoGraceSecondsRemaining = 20

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isPhotoCaptureModalPresented && !self.isSubmittingToGemini else { return }

                if self.photoGraceSecondsRemaining > 1 {
                    self.photoGraceSecondsRemaining -= 1
                } else {
                    self.photoGraceSecondsRemaining = 0
                    self.graceTimer?.invalidate()
                    self.graceTimer = nil
                    // 20-second grace expired without submission -> resume escalating warning alarm!
                    self.lastVerificationWasRejected = true
                    self.lastVerificationFeedback = "20-second grace window expired! Warning alarm resumed until proof is verified."
                    if AlarmAudioManager.shared.isFocusWarningActive {
                        AlarmAudioManager.shared.resumeFocusWarningAfterFailureOrTimeout()
                    } else {
                        AlarmAudioManager.shared.startFocusWarningEscalation()
                        AlarmAudioManager.shared.resumeFocusWarningAfterFailureOrTimeout()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        graceTimer = timer
    }

    func cancelPhotoCaptureWithoutSubmitting() {
        graceTimer?.invalidate()
        graceTimer = nil
        isPhotoCaptureModalPresented = false
        if isCheckInDue {
            if AlarmAudioManager.shared.isFocusWarningActive {
                AlarmAudioManager.shared.resumeFocusWarningAfterFailureOrTimeout()
            } else {
                AlarmAudioManager.shared.startFocusWarningEscalation()
            }
        }
    }

    /// Sends live captured photo to `GeminiVisionService` and handles pass/fail state.
    func submitLiveProofPhoto(_ image: UIImage) async {
        guard !isSubmittingToGemini else { return }
        graceTimer?.invalidate()
        graceTimer = nil
        isSubmittingToGemini = true
        lastVerificationFeedback = "Verifying with Gemini 2.5 Flash..."
        lastVerificationWasRejected = false

        let taskTitle = activeFocusBlock?.title ?? "Focus Session"
        let taskNotes = activeFocusBlock?.notes ?? ""
        let source = activeFocusBlock?.calendarTitle ?? "Focus"

        let result = await GeminiVisionService.verifyFocusPhoto(
            image: image,
            taskTitle: taskTitle,
            taskDescription: taskNotes
        )

        isSubmittingToGemini = false

        // Persist check-in attempt in SwiftData
        let log = FocusCheckInLog(
            taskTitle: taskTitle,
            calendarSource: source,
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
            isCheckInDue = false
            isPhotoCaptureModalPresented = false
            checkInPromptStartedAt = nil
            AlarmAudioManager.shared.stopFocusWarning()

            let feedback = UINotificationFeedbackGenerator()
            feedback.notificationOccurred(.success)

            // Queue next 30-40 min check-in if block is still active
            if activeFocusBlock?.id != "adhoc_test" {
                scheduleNextCheckIn(from: Date())
            } else {
                activeFocusBlock = nil
                activeBlockIdentifier = nil
                nextCheckInDate = nil
            }
        } else {
            lastVerificationFeedback = "REJECTED: \(result.reason)"
            lastVerificationWasRejected = true

            let feedback = UINotificationFeedbackGenerator()
            feedback.notificationOccurred(.error)

            // AI rejected photo -> immediately resume warning alarm until valid proof is submitted!
            if AlarmAudioManager.shared.isFocusWarningActive {
                AlarmAudioManager.shared.resumeFocusWarningAfterFailureOrTimeout()
            } else {
                AlarmAudioManager.shared.startFocusWarningEscalation()
                AlarmAudioManager.shared.resumeFocusWarningAfterFailureOrTimeout()
            }
        }
    }

    private func clearCheckInState() {
        graceTimer?.invalidate()
        graceTimer = nil
        isCheckInDue = false
        isPhotoCaptureModalPresented = false
        checkInPromptStartedAt = nil
        nextCheckInDate = nil
        secondsUntilNextCheckIn = 0
        AlarmAudioManager.shared.stopFocusWarning()
    }

    private func scheduleCheckInLocalNotification(at fireDate: Date, taskTitle: String) {
        let center = UNUserNotificationCenter.current()
        let requestID = "focus_accountability_checkin"
        center.removePendingNotificationRequests(withIdentifiers: [requestID])

        let interval = max(1.0, fireDate.timeIntervalSinceNow)
        let content = UNMutableNotificationContent()
        content.title = "📸 Focus Check-In Due: \(taskTitle)"
        content.body = "Open DailyOS and submit a live camera proof photo before the 2-minute warning alarm escalates."
        content.interruptionLevel = .timeSensitive
        content.sound = UNNotificationSound(named: UNNotificationSoundName("focus_warning.wav"))
        content.userInfo = ["type": "focus_checkin", "taskTitle": taskTitle]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
        center.add(request)
    }
}
