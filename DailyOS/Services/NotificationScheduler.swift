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

    static let habitCategoryIdentifier = "HABIT_REMINDER_CATEGORY"
    static let alarmCategoryIdentifier = "ALARM_BURST_CATEGORY"
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

        center.setNotificationCategories([habitCategory, alarmCategory])
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

    // MARK: - Master 64-Notification Queue Scheduler

    /// Rebuilds the pending notification queue within iOS's 64-pending-notification limit:
    /// 1. Schedules the 20-notification fallback burst (spaced 5s apart) for the next upcoming active alarm(s).
    /// 2. Fills the remaining queue capacity (up to 64 total pending notifications) with the next chronological habit reminders.
    func rescheduleAll() async {
        WavFileSynthesizer.ensureCustomSoundsInstalled()
        await refreshAuthorizationStatus()

        let alarms = SharedModelContainer.shared.fetchAlarms()
        let habits = SharedModelContainer.shared.fetchHabits()

        center.removeAllPendingNotificationRequests()

        let now = Date()
        var totalScheduled = 0
        var alarmBurstScheduled = 0
        var habitScheduled = 0
        var summaries: [QueuedNotificationSummary] = []

        // 1. Schedule fallback burst of 20 consecutive notifications spaced 5s apart for enabled alarms
        let enabledAlarmsWithDates: [(alarm: AlarmItem, nextDate: Date)] = alarms
            .filter { $0.isEnabled }
            .compactMap { alarm in
                guard let nextDate = alarm.nextTriggerDate(after: now) else { return nil }
                return (alarm, nextDate)
            }
            .sorted { $0.nextDate < $1.nextDate }

        // Reserve room so habits also get queued if multiple alarms exist, while always guaranteeing
        // at least one full 20-notification burst for the next upcoming alarm.
        let maxAlarmBurstsToQueue = min(enabledAlarmsWithDates.count, 2)

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
                content.title = "⏰ \(alarm.label) (\(burstIndex + 1)/\(Self.alarmBurstCount))"
                content.body = "Mission required: \(alarm.missionSummary). Open DailyOS to dismiss!"
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
                    content.sound = .default
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
                            subtitle: "Alarm Fallback Burst #\(burstIndex + 1)",
                            fireDate: fireDate,
                            isAlarmBurst: true
                        )
                    )
                } catch {
                    print("[NotificationScheduler] Failed scheduling alarm burst: \(error.localizedDescription)")
                }
            }
        }

        // 2. Collect all upcoming habit reminders and sort chronologically to fill remaining slots up to 64
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

        let calendar = Calendar.current
        for (idx, event) in eventsToSchedule.enumerated() {
            guard totalScheduled < Self.maxPendingLimit else { break }

            let habit = event.habit
            let fireDate = event.fireDate
            let dateKey = HabitItem.dateKey(for: fireDate)

            let content = UNMutableNotificationContent()
            content.title = event.isSnoozed ? "🔔 Snoozed: \(habit.title)" : "📋 Habit Reminder: \(habit.title)"
            if habit.requiresPhotoProof {
                content.body = habit.notes.isEmpty
                    ? "Time to complete \(habit.title) (Photo Proof enabled)."
                    : "\(habit.notes) • Photo Proof enabled"
            } else {
                content.body = habit.notes.isEmpty
                    ? "Hold notification to Mark Done or Snooze 15m."
                    : habit.notes
            }
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
                        subtitle: "Sound: \(habit.soundOption.displayName)",
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

    // MARK: - Interactive Notification Action Handling

    func handleNotificationResponse(_ response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier

        // Check if this is an alarm burst notification
        if let alarmIDString = userInfo["alarmID"] as? String,
           let alarmUUID = UUID(uuidString: alarmIDString) {
            let alarms = SharedModelContainer.shared.fetchAlarms()
            if let matchingAlarm = alarms.first(where: { $0.id == alarmUUID }) {
                if AlarmEngine.shared.activeRingingAlarm == nil {
                    AlarmEngine.shared.triggerAlarm(matchingAlarm)
                }
            }
            return
        }

        // Handle Habit interactive actions ("Mark Done" and "Snooze 15m")
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
            SharedModelContainer.shared.save()
            await rescheduleAll()

        case Self.actionSnooze15mIdentifier:
            let snoozeTarget = Date().addingTimeInterval(15 * 60)
            habit.snoozedUntil = snoozeTarget
            SharedModelContainer.shared.save()
            await rescheduleAll()

        default:
            break
        }
    }
}
