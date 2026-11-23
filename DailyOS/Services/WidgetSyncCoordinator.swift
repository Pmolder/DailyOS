import Foundation
import SwiftData
import WidgetKit

/// Main-app coordinator bridging SwiftData (`HabitItem` + `HabitLog`) with the crash-proof App Group
/// `WidgetBridge` JSON snapshot and consuming interactive Home Screen widget check-in deltas.
@MainActor
enum WidgetSyncCoordinator {
    /// Consumes any pending Home Screen widget check-in deltas into SwiftData, then refreshes the snapshot.
    static func consumePendingDeltasAndSync() {
        let deltas = WidgetBridge.takePendingDeltas()
        let store = SharedModelContainer.shared

        if !deltas.isEmpty {
            let habits = store.fetchHabits()
            for delta in deltas {
                guard let uuid = UUID(uuidString: delta.habitID),
                      let habit = habits.first(where: { $0.id == uuid }),
                      let date = HabitItem.date(from: delta.dayKey) else {
                    continue
                }
                store.setHabitLog(for: habit, on: date, value: delta.newValue, preserveExistingNote: true)
            }
        }

        syncSnapshotFromStore()
    }

    /// Rebuilds `widget_snapshot.json` from current SwiftData habits & logs and reloads all WidgetKit timelines.
    static func syncSnapshotFromStore() {
        let store = SharedModelContainer.shared
        let allHabits = store.fetchHabits().filter { !$0.isArchived }
        let allLogs = store.fetchHabitLogs()

        let cal = ISOWeekCalendar.current
        let today = Date()
        let todayKey = HabitItem.dateKey(for: today)
        let monday = ISOWeekCalendar.startOfMondayWeek(for: today)

        let monthComps = cal.dateComponents([.year, .month], from: today)
        let monthStart = cal.date(from: monthComps)
        let daysInMonth = monthStart.flatMap { cal.range(of: .day, in: .month, for: $0) } ?? (1..<31)

        var widgetHabits: [WidgetHabitItem] = []
        widgetHabits.reserveCapacity(allHabits.count)

        for habit in allHabits {
            let logMap = HabitMetricsEngine.logsByDayKey(for: habit.id, allLogs: allLogs)
            let todayVal = HabitMetricsEngine.loggedValue(for: habit, on: today, logMap: logMap)
            let streak = HabitMetricsEngine.currentStreak(for: habit, logMap: logMap)

            // Current ISO week Mon...Sun ratios
            var weekRatios: [Double] = []
            for offset in 0..<7 {
                if let d = cal.date(byAdding: .day, value: offset, to: monday) {
                    weekRatios.append(HabitMetricsEngine.progressRatio(for: habit, on: d, logMap: logMap))
                } else {
                    weekRatios.append(0.0)
                }
            }

            // Current month day-of-month -> ratio map
            var monthMap: [Int: Double] = [:]
            if let mStart = monthStart {
                for day in daysInMonth {
                    if let d = cal.date(byAdding: .day, value: day - 1, to: mStart) {
                        let r = HabitMetricsEngine.progressRatio(for: habit, on: d, logMap: logMap)
                        if r > 0 {
                            monthMap[day] = r
                        }
                    }
                }
            }

            widgetHabits.append(
                WidgetHabitItem(
                    id: habit.id.uuidString,
                    name: habit.title,
                    iconName: habit.iconName,
                    colorHex: habit.colorHex,
                    kind: habit.kindRaw,
                    trackingMode: habit.trackingModeRaw,
                    dailyTarget: habit.effectiveDailyTarget,
                    todayValue: todayVal,
                    streak: streak,
                    last7Days: weekRatios,
                    currentMonthDays: monthMap
                )
            )
        }

        let todayTasks = store.fetchFocusTasks(dayKey: todayKey)
        let linkedIDs = Set(todayTasks.compactMap(\.googleCalendarEventID).filter { !$0.isEmpty })
        let todayCalBlocks = FocusAccountabilityManager.shared.upcomingBlocks.filter { block in
            guard block.dayKey == todayKey else { return false }
            if let rID = block.remoteEventID, linkedIDs.contains(rID) { return false }
            return true
        }
        let calDone = todayCalBlocks.filter { CalendarEventCompletionStore.shared.isCompleted($0) }.count
        let score = HabitMetricsEngine.todayScoreSummary(
            habits: allHabits,
            allLogs: allLogs,
            todayTasks: todayTasks,
            completedCalendarEventsCount: calDone,
            totalCalendarEventsCount: todayCalBlocks.count
        )
        let globalStreak = HabitMetricsEngine.globalStreakSummary(habits: allHabits, allLogs: allLogs)

        let snapshot = WidgetSnapshot(
            updatedAt: Date(),
            todayKey: todayKey,
            todayScore: score.habitsPercent,
            scoreHeadline: score.headline,
            globalStreak: globalStreak.currentStreak,
            streakFreezes: globalStreak.freezesRemaining,
            habits: widgetHabits,
            habitsPercent: score.habitsPercent,
            habitsDone: score.habitsCompleted,
            habitsTotal: score.habitsTotal,
            todoPercent: score.todoPercent,
            todoDone: score.todoCompleted,
            todoTotal: score.todoTotal
        )

        WidgetBridge.saveSnapshot(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
