import Foundation
import UserNotifications
import Combine
import SwiftData

struct QueuedNotificationSummary: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let fireDate: Date
    let isAlarmBurst: Bool
}

@MainActor
final class NotificationScheduler: ObservableObject {
    static let shared = NotificationScheduler()

    static let maxPendingLimit: Int = 64
    static let alarmBurstCount: Int = 20
    static let alarmBurstSpacingSeconds: TimeInterval = 5.0
    static let focusCascadeCount: Int = 36

    static let habitCategoryIdentifier = "HABIT_REMINDER_CATEGORY"
    static let alarmCategoryIdentifier = "ALARM_BURST_CATEGORY"
    static let focusTaskAlarmCategoryIdentifier = "FOCUS_TASK_ALARM_CATEGORY"
    static let actionMarkDoneIdentifier = "ACTION_MARK_DONE"
    static let actionSnooze15mIdentifier = "ACTION_SNOOZE_15M"

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var totalPendingCount: Int = 0
    @Published private(set) var pendingHabitCount: Int = 0
    @Published private(set) var pendingAlarmBurstCount: Int = 0
    @Published private(set) var queuedSummaries: [QueuedNotificationSummary] = []

    private let center = UNUserNotificationCenter.current()

    private init() {
        registerNotificationCategories()
        Task {
            await refreshAuthorizationStatus()
        }
    }

    // MARK: - Setup & Permissions

    func registerNotificationCategories() {
        let markDoneAction = UNNotificationAction(
            identifier: Self.actionMarkDoneIdentifier,
            title: "Mark Done",
            options: []
        )
        let snoozeAction = UNNotificationAction(
            identifier: Self.actionSnooze15mIdentifier,
            title: "Snooze 15m",
            options: []
        )

        let habitCategory = UNNotificationCategory(
            identifier: Self.habitCategoryIdentifier,
            actions: [markDoneAction, snoozeAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let alarmCategory = UNNotificationCategory(
            identifier: Self.alarmCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Registered with .customDismissAction so iOS reports UNNotificationDismissActionIdentifier
        // if the user swipes/clears a Focus Task Alarm notification to dodge it!
        let focusTaskAlarmCategory = UNNotificationCategory(
            identifier: Self.focusTaskAlarmCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        center.setNotificationCategories([habitCategory, alarmCategory, focusTaskAlarmCategory])
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        WavFileSynthesizer.ensureCustomSoundsInstalled()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if granted {
                await rescheduleAll()
            }
            return granted
        } catch {
            print("[NotificationScheduler] Authorization error: \(error.localizedDescription)")
            await refreshAuthorizationStatus()
            return false
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    // MARK: - Focus Task Alarm Anti-Force-Close Cascade & Evasion Burst

    /// Schedules a dense cascade of `.timeSensitive` local notifications (spaced every 6s)
    /// so force-closing or backgrounding DailyOS during an active Task Check-In Alarm cannot silence alerts.
    func scheduleFocusTaskAlarmCascade(
        taskID: String,
        taskTitle: String,
        taskNotes: String,
        taskSource: String,
        isEvasionBurst: Bool
    ) {
        WavFileSynthesizer.ensureCustomSoundsInstalled()
        cancelFocusTaskAlarmCascade()

        let count = isEvasionBurst ? 24 : Self.focusCascadeCount
        let spacing: TimeInterval = isEvasionBurst ? 5.0 : 6.0

        for idx in 0..<count {
            let fireDelay: TimeInterval
            if isEvasionBurst {
                fireDelay = idx == 0 ? 1.0 : TimeInterval(idx) * spacing
            } else {
                fireDelay = TimeInterval(idx + 1) * spacing
            }

            let content = UNMutableNotificationContent()
            if isEvasionBurst {
                content.title = "⚠️ Evasion Detected — Alarm Still Active!"
                content.body = "\(taskTitle): Open DailyOS immediately to submit live photo proof!"
            } else {
                content.title = "🚨 Task Alarm Active: \(taskTitle)"
                content.body = "Open DailyOS to submit live photo proof!"
            }
            content.categoryIdentifier = Self.focusTaskAlarmCategoryIdentifier
            content.interruptionLevel = .timeSensitive
            content.sound = UNNotificationSound(named: UNNotificationSoundName("focus_warning.wav"))
            content.userInfo = [
                "type": "focus_task_alarm",
                "taskID": taskID,
                "taskTitle": taskTitle,
                "taskNotes": taskNotes,
                "taskSource": taskSource,
                "evasionBurst": isEvasionBurst
            ]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1.0, fireDelay), repeats: false)
            let requestID = "focus_cascade_\(idx)"
            let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
            center.add(request)
        }
    }

    /// Pre-schedules a cascade starting exactly when an upcoming check-in deadline expires.
    func scheduleUpcomingCheckInDeadlineCascade(
        deadlineDate: Date,
        taskID: String,
        taskTitle: String,
        taskNotes: String,
        taskSource: String
    ) {
        WavFileSynthesizer.ensureCustomSoundsInstalled()
        cancelFocusTaskAlarmCascade()

        let baseDelay = deadlineDate.timeIntervalSinceNow
        guard baseDelay > 1.0 else {
            scheduleFocusTaskAlarmCascade(
                taskID: taskID,
                taskTitle: taskTitle,
                taskNotes: taskNotes,
                taskSource: taskSource,
                isEvasionBurst: false
            )
            return
        }

        // Schedule 20 alerts starting at the exact check-in deadline, spaced 6s apart
        for idx in 0..<20 {
            let fireDelay = baseDelay + TimeInterval(idx) * 6.0
            let content = UNMutableNotificationContent()
            content.title = idx == 0
                ? "📸 Focus Proof Due: \(taskTitle)"
                : "🚨 Task Alarm Active: \(taskTitle)"
            content.body = "Open DailyOS to submit live photo proof!"
            content.categoryIdentifier = Self.focusTaskAlarmCategoryIdentifier
            content.interruptionLevel = .timeSensitive
            content.sound = UNNotificationSound(named: UNNotificationSoundName("focus_warning.wav"))
            content.userInfo = [
                "type": "focus_task_alarm",
                "taskID": taskID,
                "taskTitle": taskTitle,
                "taskNotes": taskNotes,
                "taskSource": taskSource
            ]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDelay, repeats: false)
            let request = UNNotificationRequest(identifier: "focus_cascade_\(idx)", content: content, trigger: trigger)
            center.add(request)
        }
    }

    /// Cancels all pending & delivered focus task alarm cascade notifications (only called once proof is verified).
    func cancelFocusTaskAlarmCascade() {
        let ids = (0..<Self.focusCascadeCount).map { "focus_cascade_\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: - Master 64-Notification Queue Scheduler

    func rescheduleAll() async {
        WavFileSynthesizer.ensureCustomSoundsInstalled()
        await refreshAuthorizationStatus()

        let alarms = SharedModelContainer.shared.fetchAlarms()
        let habits = SharedModelContainer.shared.fetchHabits()

        // Preserve independently managed notifications (Focus cascades, Notification Studio, Photo Proof, Focus Nudges)
        let preservedPrefixes = [
            "focus_cascade_",
            DailyNotificationManager.requestIdentifierPrefix,
            PhotoProofScheduler.identifierPrefix,
            "focus_nudge_"
        ]
        let existing = await center.pendingNotificationRequests()
        let preservedCount = existing.filter { req in
            preservedPrefixes.contains { req.identifier.hasPrefix($0) }
        }.count
        let toRemove = existing
            .map(\.identifier)
            .filter { id in !preservedPrefixes.contains { id.hasPrefix($0) } }
        center.removePendingNotificationRequests(withIdentifiers: toRemove)

        let now = Date()
        var totalScheduled = preservedCount
        var alarmBurstScheduled = 0
        var habitScheduled = 0
        var summaries: [QueuedNotificationSummary] = []

        // 0. Automatic Sleep-Cycle Wind-Down Bedtime Reminders for Enabled Alarms
        for alarm in alarms where alarm.isEnabled && alarm.bedtimeReminderEnabled {
            let bed = alarm.bedtimeSchedule()
            let content = UNMutableNotificationContent()
            content.title = "🌙 Wind-Down for \(alarm.formattedTime) Wake"
            content.body = "Start Night Routine now & lights out by \(bed.lightsOutText) for \(alarm.sleepCycleCount) full sleep cycles (\(alarm.sleepDurationHoursText))."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.userInfo = [
                "type": "bedtime_lockin",
                "alarmID": alarm.id.uuidString
            ]

            let activeDays = alarm.repeatDays
            if activeDays.isEmpty || activeDays.count == 7 {
                guard totalScheduled < Self.maxPendingLimit else { break }
                var comps = DateComponents()
                comps.calendar = ISOWeekCalendar.current
                comps.hour = bed.windDownHour
                comps.minute = bed.windDownMinute
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: !activeDays.isEmpty)
                let req = UNNotificationRequest(identifier: "bedtime_lockin_\(alarm.id.uuidString)_all", content: content, trigger: trigger)
                if (try? await center.add(req)) != nil {
                    totalScheduled += 1
                }
            } else {
                for wakeWeekday in activeDays.sorted() {
                    guard totalScheduled < Self.maxPendingLimit else { break }
                    // Shift weekday back by 1 if wind-down occurs the evening before wake time
                    let targetWeekday: Int
                    if bed.fallsOnPreviousDay {
                        targetWeekday = (wakeWeekday == 1) ? 7 : (wakeWeekday - 1)
                    } else {
                        targetWeekday = wakeWeekday
                    }
                    var comps = DateComponents()
                    comps.calendar = ISOWeekCalendar.current
                    comps.weekday = targetWeekday
                    comps.hour = bed.windDownHour
                    comps.minute = bed.windDownMinute
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                    let req = UNNotificationRequest(identifier: "bedtime_lockin_\(alarm.id.uuidString)_w\(targetWeekday)", content: content, trigger: trigger)
                    if (try? await center.add(req)) != nil {
                        totalScheduled += 1
                    }
                }
            }
        }

        // 1. Wake alarm 20-alert fallback burst spaced 5s apart
        let enabledAlarmsWithDates: [(alarm: AlarmItem, nextDate: Date)] = alarms
            .filter { $0.isEnabled }
            .compactMap { alarm in
                guard let nextDate = alarm.nextTriggerDate(after: now) else { return nil }
                return (alarm, nextDate)
            }
            .sorted { $0.nextDate < $1.nextDate }

        let maxAlarmBurstsToQueue = min(enabledAlarmsWithDates.count, 1)

        for entryIndex in 0..<maxAlarmBurstsToQueue {
            let entry = enabledAlarmsWithDates[entryIndex]
            let alarm = entry.alarm
            let baseDate = entry.nextDate

            for burstIndex in 0..<Self.alarmBurstCount {
                guard totalScheduled < Self.maxPendingLimit else { break }

                let fireDate = baseDate.addingTimeInterval(TimeInterval(burstIndex * Int(Self.alarmBurstSpacingSeconds)))
                let timeInterval = fireDate.timeIntervalSince(now)
                guard timeInterval >= 1.0 else { continue }

                let content = UNMutableNotificationContent()
                content.title = "⏰ \(alarm.displayLabel) (\(burstIndex + 1)/\(Self.alarmBurstCount))"
                content.body = "Mission required: \(alarm.missionSummary). Open DailyOS now!"
                content.categoryIdentifier = Self.alarmCategoryIdentifier
                content.interruptionLevel = .timeSensitive
                content.userInfo = [
                    "type": "alarm_burst",
                    "alarmID": alarm.id.uuidString,
                    "burstIndex": burstIndex
                ]

                if let soundFile = alarm.tone.bundledFileName {
                    content.sound = UNNotificationSound(named: UNNotificationSoundName(soundFile))
                } else {
                    content.sound = UNNotificationSound(named: UNNotificationSoundName("nuclear_siren.wav"))
                }

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
                let requestID = "alarm_burst_\(alarm.id.uuidString)_\(burstIndex)"
                let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)

                do {
                    try await center.add(request)
                    totalScheduled += 1
                    alarmBurstScheduled += 1
                    summaries.append(
                        QueuedNotificationSummary(
                            id: requestID,
                            title: content.title,
                            subtitle: "Wake Fallback Burst #\(burstIndex + 1)",
                            fireDate: fireDate,
                            isAlarmBurst: true
                        )
                    )
                } catch {
                    print("[NotificationScheduler] Failed scheduling alarm burst: \(error.localizedDescription)")
                }
            }
        }

        // 2. Fill remaining queue slots up to 64 with upcoming habit reminders
        struct UpcomingHabitEvent {
            let habit: HabitItem
            let fireDate: Date
            let isSnoozed: Bool
        }

        var upcomingHabitEvents: [UpcomingHabitEvent] = []
        for habit in habits where habit.reminderEnabled {
            let dates = habit.upcomingReminderDates(from: now, daysAhead: 30)
            for d in dates {
                let isSnoozeMatch = habit.snoozedUntil.map { abs($0.timeIntervalSince(d)) < 2.0 } ?? false
                upcomingHabitEvents.append(UpcomingHabitEvent(habit: habit, fireDate: d, isSnoozed: isSnoozeMatch))
            }
        }

        upcomingHabitEvents.sort { $0.fireDate < $1.fireDate }

        let remainingHabitSlots = max(0, Self.maxPendingLimit - totalScheduled)
        let eventsToSchedule = upcomingHabitEvents.prefix(remainingHabitSlots)
        let calendar = ISOWeekCalendar.current

        for (idx, event) in eventsToSchedule.enumerated() {
            guard totalScheduled < Self.maxPendingLimit else { break }

            let habit = event.habit
            let fireDate = event.fireDate
            let dateKey = HabitItem.dateKey(for: fireDate)

            let content = UNMutableNotificationContent()
            content.title = event.isSnoozed ? "🔔 Snoozed: \(habit.title)" : "✓ \(habit.timeOfDay.displayName) Habit: \(habit.title)"
            content.body = habit.notes.isEmpty ? "Hold to Mark Done or Snooze 15m." : habit.notes
            content.categoryIdentifier = Self.habitCategoryIdentifier
            content.interruptionLevel = .timeSensitive
            content.userInfo = [
                "type": "habit_reminder",
                "habitID": habit.id.uuidString,
                "dateKey": dateKey
            ]

            if let customSoundFile = habit.soundOption.soundFileName {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(customSoundFile))
            } else {
                content.sound = .default
            }

            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let timestampToken = Int(fireDate.timeIntervalSince1970)
            let requestID = "habit_\(habit.id.uuidString)_\(timestampToken)_\(idx)"
            let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)

            do {
                try await center.add(request)
                totalScheduled += 1
                habitScheduled += 1
                summaries.append(
                    QueuedNotificationSummary(
                        id: requestID,
                        title: habit.title,
                        subtitle: "\(habit.timeOfDay.displayName) • \(habit.soundOption.displayName)",
                        fireDate: fireDate,
                        isAlarmBurst: false
                    )
                )
            } catch {
                print("[NotificationScheduler] Failed scheduling habit notification: \(error.localizedDescription)")
            }
        }

        summaries.sort { $0.fireDate < $1.fireDate }
        self.totalPendingCount = totalScheduled
        self.pendingAlarmBurstCount = alarmBurstScheduled
        self.pendingHabitCount = habitScheduled
        self.queuedSummaries = summaries
    }

    func cancelAlarmBurstNotifications(for alarmID: UUID) {
        let identifiers = (0..<Self.alarmBurstCount).map { "alarm_burst_\(alarmID.uuidString)_\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    // MARK: - Interactive Notification & Dismissal Handling

    func handleNotificationResponse(_ response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier

        // 1. Focus Task Alarm — detect swipe dismissal (evasion) vs tap!
        if let type = userInfo["type"] as? String, type == "focus_task_alarm" {
            let taskID = (userInfo["taskID"] as? String) ?? "active_focus_task"
            let taskTitle = (userInfo["taskTitle"] as? String) ?? "Scheduled Focus Task"
            let taskNotes = (userInfo["taskNotes"] as? String) ?? ""
            let taskSource = (userInfo["taskSource"] as? String) ?? "Focus"

            if actionID == UNNotificationDismissActionIdentifier {
                // User swiped away the Focus Task Alarm notification -> activate Evasion Penalty + immediate burst!
                FocusAccountabilityManager.shared.handleNotificationDismissedEvasion(
                    taskID: taskID,
                    taskTitle: taskTitle,
                    taskNotes: taskNotes,
                    taskSource: taskSource
                )
            } else {
                // User tapped the notification -> open full-screen Task Check-In Alarm immediately
                FocusAccountabilityManager.shared.handleTaskAlarmNotificationTap(
                    taskID: taskID,
                    taskTitle: taskTitle,
                    taskNotes: taskNotes,
                    taskSource: taskSource
                )
            }
            return
        }

        // 2. Wake Alarm Burst Notification Tap
        if let alarmIDString = userInfo["alarmID"] as? String,
           let alarmUUID = UUID(uuidString: alarmIDString) {
            let alarms = SharedModelContainer.shared.fetchAlarms()
            if let matchingAlarm = alarms.first(where: { $0.id == alarmUUID }),
               AlarmEngine.shared.activeRingingAlarm == nil {
                AlarmEngine.shared.triggerAlarm(matchingAlarm)
            }
            return
        }

        // 3. Habit Interactive Actions ("Mark Done" & "Snooze 15m")
        guard let habitIDString = userInfo["habitID"] as? String,
              let habitUUID = UUID(uuidString: habitIDString) else {
            return
        }

        let habits = SharedModelContainer.shared.fetchHabits()
        guard let habit = habits.first(where: { $0.id == habitUUID }) else {
            return
        }

        switch actionID {
        case Self.actionMarkDoneIdentifier:
            habit.markCompleted(on: Date())
            SharedModelContainer.shared.setHabitLog(
                for: habit,
                on: Date(),
                value: habit.effectiveDailyTarget
            )
            SharedModelContainer.shared.save()
            await rescheduleAll()

        case Self.actionSnooze15mIdentifier:
            habit.snoozedUntil = Date().addingTimeInterval(15 * 60)
            SharedModelContainer.shared.save()
            await rescheduleAll()

        default:
            break
        }
    }
}
