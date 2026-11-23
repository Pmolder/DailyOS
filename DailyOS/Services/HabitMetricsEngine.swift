import Foundation
import SwiftUI

struct MonthlyCompletionPoint: Identifiable {
    let id: Int // 1...12
    let monthShort: String
    let count: Double
}

struct GlobalStreakSummary {
    let currentStreak: Int
    let mondayToSundayCompleted: [Bool] // 7 booleans Mon...Sun for current ISO week
    let todayMondayIndex: Int           // 0...6 (Mon=0, Sun=6)
    let freezesRemaining: Int
    let usedFreezeRecently: Bool
}

struct TodayScoreSummary {
    let score: Int // 0...100
    let headline: String
    let habitsCompleted: Int
    let habitsTotal: Int
    let focusMinutesToday: Int
    let globalStreak: Int
    let wakeCompletedToday: Bool
}

/// Centralized analytics, streak, streak-freeze, and Today's Score calculation engine.
enum HabitMetricsEngine {
    private static let freezesKey = "com.patrik.dailyos.streakFreezesRemaining"
    private static let freezeInitializedKey = "com.patrik.dailyos.streakFreezesInitialized"
    private static let lastFreezeMilestoneKey = "com.patrik.dailyos.lastFreezeMilestone"
    private static let protectedDayKey = "com.patrik.dailyos.streakFreezeProtectedDayKey"
    private static let wakeCompletedDayKey = "com.patrik.dailyos.wakeCompletedDayKey"
    private static let focusMinutesDayKey = "com.patrik.dailyos.focusMinutesDayKey"
    private static let focusMinutesCountKey = "com.patrik.dailyos.focusMinutesCount"
    private static let focusSessionsDayKey = "com.patrik.dailyos.focusSessionsDayKey"
    private static let focusSessionsCountKey = "com.patrik.dailyos.focusSessionsCount"

    // MARK: - Daily Wake & Deep Work Telemetry Helpers

    static func markWakeCompletedToday() {
        UserDefaults.standard.set(HabitItem.dateKey(for: Date()), forKey: wakeCompletedDayKey)
    }

    static var isWakeCompletedToday: Bool {
        UserDefaults.standard.string(forKey: wakeCompletedDayKey) == HabitItem.dateKey(for: Date())
    }

    static func addFocusMinutesToday(_ minutes: Int) {
        let today = HabitItem.dateKey(for: Date())
        let storedDay = UserDefaults.standard.string(forKey: focusMinutesDayKey)
        let base = (storedDay == today) ? UserDefaults.standard.integer(forKey: focusMinutesCountKey) : 0
        UserDefaults.standard.set(today, forKey: focusMinutesDayKey)
        UserDefaults.standard.set(base + max(0, minutes), forKey: focusMinutesCountKey)
        WakeStatsStore.recordFocusMinutes(minutes, forDayKey: today)
    }

    static var focusMinutesToday: Int {
        let today = HabitItem.dateKey(for: Date())
        guard UserDefaults.standard.string(forKey: focusMinutesDayKey) == today else { return 0 }
        return UserDefaults.standard.integer(forKey: focusMinutesCountKey)
    }

    static func incrementFocusSessionsToday() {
        let today = HabitItem.dateKey(for: Date())
        let storedDay = UserDefaults.standard.string(forKey: focusSessionsDayKey)
        let base = (storedDay == today) ? UserDefaults.standard.integer(forKey: focusSessionsCountKey) : 0
        UserDefaults.standard.set(today, forKey: focusSessionsDayKey)
        UserDefaults.standard.set(base + 1, forKey: focusSessionsCountKey)
    }

    static var completedFocusSessionsToday: Int {
        let today = HabitItem.dateKey(for: Date())
        guard UserDefaults.standard.string(forKey: focusSessionsDayKey) == today else { return 0 }
        return UserDefaults.standard.integer(forKey: focusSessionsCountKey)
    }

    // MARK: - Log Map Lookup (O(1) by dayKey)

    static func logsByDayKey(for habitID: UUID, allLogs: [HabitLog]) -> [String: HabitLog] {
        var map: [String: HabitLog] = [:]
        for log in allLogs where log.habitID == habitID {
            map[log.dayKey] = log
        }
        return map
    }

    /// Returns progress fraction (0.0...1.0) for a single habit on a given date.
    static func progressRatio(
        for habit: HabitItem,
        on date: Date,
        logMap: [String: HabitLog]
    ) -> Double {
        let key = HabitItem.dateKey(for: date)
        let target = habit.effectiveDailyTarget

        if let log = logMap[key] {
            if habit.kind == .quit {
                return log.value >= 0 ? 1.0 : 0.0
            }
            return min(1.0, max(0.0, log.value / target))
        }

        // Backward compatibility with legacy completedDatesRaw
        if habit.completedDateStrings.contains(key) {
            return 1.0
        }

        // Quit habits treat days between createdAt and today with no slip log as clean
        if habit.kind == .quit {
            let cal = ISOWeekCalendar.current
            let dayStart = cal.startOfDay(for: date)
            let createdStart = cal.startOfDay(for: habit.createdAt)
            let todayStart = cal.startOfDay(for: Date())
            if dayStart >= createdStart && dayStart < todayStart {
                return 1.0
            }
        }

        return 0.0
    }

    static func loggedValue(
        for habit: HabitItem,
        on date: Date,
        logMap: [String: HabitLog]
    ) -> Double {
        let key = HabitItem.dateKey(for: date)
        if let log = logMap[key] {
            return max(0.0, log.value)
        }
        if habit.completedDateStrings.contains(key) {
            return habit.effectiveDailyTarget
        }
        return 0.0
    }

    static func isDayComplete(
        for habit: HabitItem,
        on date: Date,
        logMap: [String: HabitLog]
    ) -> Bool {
        progressRatio(for: habit, on: date, logMap: logMap) >= 1.0
    }

    // MARK: - Per-Habit Streaks & Summary Subtitle

    static func currentStreak(for habit: HabitItem, logMap: [String: HabitLog]) -> Int {
        let cal = ISOWeekCalendar.current
        let today = cal.startOfDay(for: Date())
        let createdStart = cal.startOfDay(for: habit.createdAt)

        if habit.kind == .quit {
            // Consecutive days free without a slip (value < 0)
            var cleanDays = 0
            for offset in 0..<1095 {
                guard let checkDay = cal.date(byAdding: .day, value: -offset, to: today) else { break }
                if checkDay < createdStart { break }
                let key = HabitItem.dateKey(for: checkDay)
                if let log = logMap[key], log.value < 0 {
                    break
                }
                if offset == 0 {
                    if let log = logMap[key], log.value >= 1.0 {
                        cleanDays += 1
                    } else if habit.completedDateStrings.contains(key) {
                        cleanDays += 1
                    }
                } else {
                    cleanDays += 1
                }
            }
            return cleanDays
        }

        var streak = 0
        for offset in 0..<1095 {
            guard let checkDay = cal.date(byAdding: .day, value: -offset, to: today) else { break }
            if isDayComplete(for: habit, on: checkDay, logMap: logMap) {
                streak += 1
            } else {
                if offset == 0 { continue }
                if !habit.isScheduled(on: checkDay) { continue }
                break
            }
        }
        return streak
    }

    static func bestStreak(for habit: HabitItem, logMap: [String: HabitLog]) -> Int {
        let cal = ISOWeekCalendar.current
        let today = cal.startOfDay(for: Date())
        var best = 0
        var running = 0

        for offset in stride(from: 365, through: 0, by: -1) {
            guard let checkDay = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            if isDayComplete(for: habit, on: checkDay, logMap: logMap) {
                running += 1
                best = max(best, running)
            } else if habit.isScheduled(on: checkDay) {
                running = 0
            }
        }
        return max(best, currentStreak(for: habit, logMap: logMap))
    }

    static func streakSubtitle(for habit: HabitItem, logMap: [String: HabitLog]) -> String {
        let s = currentStreak(for: habit, logMap: logMap)
        if habit.kind == .quit {
            return s == 1 ? "1 day free" : "\(s) days free"
        }
        return s == 1 ? "1 day streak" : "\(s) day streak"
    }

    // MARK: - Year Analytics (Total, Completion Rate %, Monthly Completions)

    static func totalFormatted(for habit: HabitItem, inYear year: Int, logMap: [String: HabitLog]) -> String {
        let prefix = String(format: "%04d-", year)
        if habit.trackingMode == .quantity {
            var sum = 0.0
            for (key, log) in logMap where key.hasPrefix(prefix) && log.value > 0 {
                sum += log.value
            }
            let unit = habit.unitLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let numStr = formatCompactNumber(sum)
            return unit.isEmpty ? numStr : "\(numStr) \(unit)"
        } else {
            let count = completionDaysCount(for: habit, inYear: year, logMap: logMap)
            return count == 1 ? "1 day" : "\(count) days"
        }
    }

    static func completionDaysCount(for habit: HabitItem, inYear year: Int, logMap: [String: HabitLog]) -> Int {
        let cal = ISOWeekCalendar.current
        guard let yearStart = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let nextYearStart = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return 0
        }
        let todayEnd = cal.startOfDay(for: Date())
        let limitEnd = min(todayEnd, cal.date(byAdding: .day, value: -1, to: nextYearStart) ?? todayEnd)
        guard yearStart <= limitEnd else { return 0 }

        var count = 0
        var cursor = yearStart
        while cursor <= limitEnd {
            if isDayComplete(for: habit, on: cursor, logMap: logMap) {
                count += 1
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return count
    }

    static func completionRatePercent(for habit: HabitItem, inYear year: Int, logMap: [String: HabitLog]) -> Int {
        let cal = ISOWeekCalendar.current
        guard let yearStart = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let nextYearStart = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return 0
        }
        let today = cal.startOfDay(for: Date())
        let yearEnd = min(today, cal.date(byAdding: .day, value: -1, to: nextYearStart) ?? today)
        guard yearStart <= yearEnd else { return 0 }

        // Start from earliest of createdAt or first logged day in that year
        let createdDay = cal.startOfDay(for: habit.createdAt)
        let prefix = String(format: "%04d-", year)
        let earliestLog = logMap.keys
            .filter { $0.hasPrefix(prefix) }
            .compactMap { HabitItem.date(from: $0) }
            .min()
        let effectiveStart = max(yearStart, min(createdDay, earliestLog ?? createdDay))
        guard effectiveStart <= yearEnd else { return 0 }

        var scheduled = 0
        var completed = 0
        var cursor = effectiveStart
        while cursor <= yearEnd {
            if habit.isScheduled(on: cursor) {
                scheduled += 1
                if isDayComplete(for: habit, on: cursor, logMap: logMap) {
                    completed += 1
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        guard scheduled > 0 else { return 0 }
        return Int(round((Double(completed) / Double(scheduled)) * 100.0))
    }

    static func monthlyCompletions(for habit: HabitItem, inYear year: Int, logMap: [String: HabitLog]) -> [MonthlyCompletionPoint] {
        let cal = ISOWeekCalendar.current
        let monthLabels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var counts = [Double](repeating: 0.0, count: 12)

        guard let yearStart = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let nextYearStart = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return monthLabels.enumerated().map { MonthlyCompletionPoint(id: $0.offset + 1, monthShort: $0.element, count: 0) }
        }

        let today = cal.startOfDay(for: Date())
        let yearEnd = min(today, cal.date(byAdding: .day, value: -1, to: nextYearStart) ?? today)

        if yearStart <= yearEnd {
            var cursor = yearStart
            while cursor <= yearEnd {
                if isDayComplete(for: habit, on: cursor, logMap: logMap) {
                    let m = cal.component(.month, from: cursor)
                    if (1...12).contains(m) {
                        counts[m - 1] += 1.0
                    }
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }

        return (0..<12).map { idx in
            MonthlyCompletionPoint(id: idx + 1, monthShort: monthLabels[idx], count: counts[idx])
        }
    }

    // MARK: - Global Streak, Streak Freezes & Today's Score

    static var streakFreezesRemaining: Int {
        if !UserDefaults.standard.bool(forKey: freezeInitializedKey) {
            UserDefaults.standard.set(true, forKey: freezeInitializedKey)
            UserDefaults.standard.set(1, forKey: freezesKey)
            return 1
        }
        return max(0, min(3, UserDefaults.standard.integer(forKey: freezesKey)))
    }

    static func globalStreakSummary(habits: [HabitItem], allLogs: [HabitLog]) -> GlobalStreakSummary {
        let activeHabits = habits.filter { !$0.isArchived }
        let cal = ISOWeekCalendar.current
        let today = cal.startOfDay(for: Date())
        let monday = ISOWeekCalendar.startOfMondayWeek(for: today)
        let todayMonIdx = ISOWeekCalendar.mondayBasedDayIndex(for: today)

        // Precompute log maps per habit
        var maps: [UUID: [String: HabitLog]] = [:]
        for h in activeHabits {
            maps[h.id] = logsByDayKey(for: h.id, allLogs: allLogs)
        }

        func dayPassedThreshold(_ day: Date) -> Bool {
            let scheduled = activeHabits.filter { $0.isScheduled(on: day) }
            guard !scheduled.isEmpty else { return false }
            let completed = scheduled.filter {
                isDayComplete(for: $0, on: day, logMap: maps[$0.id] ?? [:])
            }.count
            return (Double(completed) / Double(scheduled.count)) >= 0.70
        }

        // Compute Monday...Sunday status for current ISO week
        var weekStatuses: [Bool] = []
        for idx in 0..<7 {
            if let d = cal.date(byAdding: .day, value: idx, to: monday), d <= today {
                weekStatuses.append(dayPassedThreshold(d))
            } else {
                weekStatuses.append(false)
            }
        }

        // Compute global streak with automatic 1-day Streak Freeze protection
        var freezes = streakFreezesRemaining
        var usedFreeze = false
        var streak = 0
        let existingProtectedDay = UserDefaults.standard.string(forKey: protectedDayKey)

        for offset in 0..<365 {
            guard let checkDay = cal.date(byAdding: .day, value: -offset, to: today) else { break }
            let key = HabitItem.dateKey(for: checkDay)

            if dayPassedThreshold(checkDay) {
                streak += 1
            } else if offset == 0 {
                // Today still in progress
                continue
            } else if existingProtectedDay == key {
                usedFreeze = true
                streak += 1
            } else if !usedFreeze && freezes > 0 && offset <= 2 {
                // Auto-protect a single missed day with an available Streak Freeze
                usedFreeze = true
                freezes -= 1
                UserDefaults.standard.set(freezes, forKey: freezesKey)
                UserDefaults.standard.set(key, forKey: protectedDayKey)
                streak += 1
            } else {
                break
            }
        }

        // Earn +1 Streak Freeze every 7-day streak milestone up to max 3
        let milestone = streak / 7
        let lastMilestone = UserDefaults.standard.integer(forKey: lastFreezeMilestoneKey)
        if milestone > lastMilestone && milestone > 0 {
            let updatedFreezes = min(3, freezes + 1)
            UserDefaults.standard.set(updatedFreezes, forKey: freezesKey)
            UserDefaults.standard.set(milestone, forKey: lastFreezeMilestoneKey)
            freezes = updatedFreezes
        }

        return GlobalStreakSummary(
            currentStreak: streak,
            mondayToSundayCompleted: weekStatuses,
            todayMondayIndex: todayMonIdx,
            freezesRemaining: freezes,
            usedFreezeRecently: usedFreeze
        )
    }

    static func todayScoreSummary(
        habits: [HabitItem],
        allLogs: [HabitLog],
        todayTasks: [FocusTaskItem] = []
    ) -> TodayScoreSummary {
        let activeHabits = habits.filter { !$0.isArchived }
        let today = Date()
        let scheduledToday = activeHabits.filter { $0.isScheduled(on: today) }

        var habitScoreSum = 0.0
        var completedCount = 0

        for h in scheduledToday {
            let map = logsByDayKey(for: h.id, allLogs: allLogs)
            let ratio = progressRatio(for: h, on: today, logMap: map)
            habitScoreSum += ratio
            if ratio >= 1.0 {
                completedCount += 1
            }
        }

        let completedTasks = todayTasks.filter(\.isCompleted).count
        let totalItems = scheduledToday.count + todayTasks.count
        let combinedScoreSum = habitScoreSum + Double(completedTasks)
        let combinedRatio = totalItems == 0 ? 0.0 : (combinedScoreSum / Double(totalItems))
        let focusMins = focusMinutesToday
        let wakeDone = isWakeCompletedToday

        // Weight: 75% habits+tasks + 15% focus (up to 60m) + 10% wake completion
        let rawScore: Double
        if totalItems == 0 {
            let focusBoost = min(1.0, Double(focusMins) / 60.0) * 60.0
            let wakeBoost = wakeDone ? 40.0 : 0.0
            rawScore = focusBoost + wakeBoost
        } else {
            let focusBoost = min(1.0, Double(focusMins) / 60.0) * 15.0
            let wakeBoost = wakeDone ? 10.0 : 0.0
            rawScore = (combinedRatio * 75.0) + focusBoost + wakeBoost
        }

        let score = max(0, min(100, Int(round(rawScore))))
        let headline: String
        switch score {
        case 90...100: headline = "Locked in."
        case 70...89: headline = "Dialed in."
        case 40...69: headline = "Building momentum."
        default: headline = "Let's start."
        }

        let streakInfo = globalStreakSummary(habits: habits, allLogs: allLogs)

        return TodayScoreSummary(
            score: score,
            headline: headline,
            habitsCompleted: completedCount,
            habitsTotal: scheduledToday.count,
            focusMinutesToday: focusMins,
            globalStreak: streakInfo.currentStreak,
            wakeCompletedToday: wakeDone
        )
    }

    private static func formatCompactNumber(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", value / 1000.0)
        }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }
}
