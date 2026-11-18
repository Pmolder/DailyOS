import Foundation
import AppIntents
import SwiftData

// MARK: - Habit AppEntity & Query

struct HabitAppEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Habit"
    static var defaultQuery = HabitEntityQuery()

    var id: UUID
    var title: String
    var streak: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "Streak: \(streak) day(s)"
        )
    }
}

struct HabitEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [HabitAppEntity] {
        let habits = SharedModelContainer.shared.fetchHabits()
        return habits
            .filter { identifiers.contains($0.id) }
            .map { HabitAppEntity(id: $0.id, title: $0.title, streak: $0.currentStreak) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [HabitAppEntity] {
        let habits = SharedModelContainer.shared.fetchHabits()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return habits
            .filter { query.isEmpty || $0.title.lowercased().contains(query) }
            .map { HabitAppEntity(id: $0.id, title: $0.title, streak: $0.currentStreak) }
    }

    @MainActor
    func suggestedEntities() async throws -> [HabitAppEntity] {
        let habits = SharedModelContainer.shared.fetchHabits()
        return habits.map { HabitAppEntity(id: $0.id, title: $0.title, streak: $0.currentStreak) }
    }
}

// MARK: - 1. "Complete Habit" AppIntent

struct CompleteHabitIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Habit"
    static var description = IntentDescription(
        "Marks a selected DailyOS habit as completed for today and updates your notification queue."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Habit")
    var habit: HabitAppEntity?

    @Parameter(title: "Habit Name (Optional Text Match)")
    var habitName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Complete \(\.$habit)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let allHabits = SharedModelContainer.shared.fetchHabits()
        guard !allHabits.isEmpty else {
            return .result(dialog: "No habits exist in DailyOS yet.")
        }

        var targetHabit: HabitItem?

        if let selectedEntity = habit {
            targetHabit = allHabits.first(where: { $0.id == selectedEntity.id })
        }

        if targetHabit == nil, let nameQuery = habitName?.trimmingCharacters(in: .whitespacesAndNewlines), !nameQuery.isEmpty {
            targetHabit = allHabits.first(where: {
                $0.title.localizedCaseInsensitiveContains(nameQuery)
            })
        }

        if targetHabit == nil {
            // Default to first uncompleted habit scheduled for today, or first habit overall
            targetHabit = allHabits.first(where: { !$0.isCompleted(on: Date()) }) ?? allHabits.first
        }

        guard let resolvedHabit = targetHabit else {
            return .result(dialog: "Could not find a matching habit to complete.")
        }

        resolvedHabit.markCompleted(on: Date())
        SharedModelContainer.shared.save()
        await NotificationScheduler.shared.rescheduleAll()

        let updatedStreak = resolvedHabit.currentStreak
        return .result(
            dialog: "Completed '\(resolvedHabit.title)' for today! Current streak: \(updatedStreak) day(s)."
        )
    }
}

// MARK: - 2. "Arm Morning Alarm" AppIntent

struct ArmMorningAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Arm Morning Alarm"
    static var description = IntentDescription(
        "Arms your morning alarm in DailyOS, activates the silent background audio keep-alive loop, and queues the 20-notification fallback burst."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Hour (24h)", default: 7, controlStyle: .field, inclusiveRange: (0, 23))
    var hour: Int

    @Parameter(title: "Minute", default: 0, controlStyle: .field, inclusiveRange: (0, 59))
    var minute: Int

    @Parameter(title: "Update Existing Morning Alarm Time", default: false)
    var overrideTime: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Arm Morning Alarm at \(\.$hour):\(\.$minute)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clampedHour = max(0, min(23, hour))
        let clampedMinute = max(0, min(59, minute))
        let allAlarms = SharedModelContainer.shared.fetchAlarms()

        let targetAlarm: AlarmItem
        if let exactMatch = allAlarms.first(where: { $0.hour == clampedHour && $0.minute == clampedMinute }) {
            exactMatch.isEnabled = true
            exactMatch.lastTriggeredMinuteKey = ""
            targetAlarm = exactMatch
        } else if let morningAlarm = allAlarms.first(where: { $0.hour >= 4 && $0.hour <= 11 }) ?? allAlarms.first {
            if overrideTime {
                morningAlarm.hour = clampedHour
                morningAlarm.minute = clampedMinute
            }
            morningAlarm.isEnabled = true
            morningAlarm.lastTriggeredMinuteKey = ""
            targetAlarm = morningAlarm
        } else {
            let newAlarm = AlarmItem(
                label: "Morning Alarm",
                hour: clampedHour,
                minute: clampedMinute,
                isEnabled: true,
                repeatDays: [2, 3, 4, 5, 6],
                tone: .classicPulse,
                missionType: .math,
                stepGoal: 50,
                mathDifficulty: .medium,
                mathProblemCount: 3
            )
            SharedModelContainer.shared.mainContext.insert(newAlarm)
            targetAlarm = newAlarm
        }

        SharedModelContainer.shared.save()
        AlarmEngine.shared.syncWithAlarms()
        await NotificationScheduler.shared.rescheduleAll()

        return .result(
            dialog: "Armed '\(targetAlarm.label)' for \(targetAlarm.formattedTime) (\(targetAlarm.missionSummary)). Silent overnight keep-alive and 20-notification burst are active."
        )
    }
}

// MARK: - AppShortcutsProvider

struct DailyOSShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CompleteHabitIntent(),
            phrases: [
                "Complete a habit in \(.applicationName)",
                "Mark my habit done in \(.applicationName)",
                "Check off habit with \(.applicationName)"
            ],
            shortTitle: "Complete Habit",
            systemImageName: "checkmark.circle.fill"
        )
        AppShortcut(
            intent: ArmMorningAlarmIntent(),
            phrases: [
                "Arm morning alarm in \(.applicationName)",
                "Enable my morning alarm in \(.applicationName)",
                "Wake me up with \(.applicationName)"
            ],
            shortTitle: "Arm Morning Alarm",
            systemImageName: "alarm.waves.left.and.right.fill"
        )
    }
}
