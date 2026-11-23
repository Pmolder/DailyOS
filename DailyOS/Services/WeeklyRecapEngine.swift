import Foundation

struct WeeklyRecapSummary {
    let dateRangeLabel: String
    let avgWeeklyScore: Int
    let scoreHeadline: String
    let dailyScores: [Int] // 7 scores Mon...Sun
    let totalFocusMinutes: Int
    let completedFocusTasks: Int
    let verifiedPhotoProofs: Int
    let habitConsistencyPercent: Int
    let topHabitName: String
    let topHabitIcon: String
    let topHabitColorHex: String
    let topHabitCompletedDays: Int
    let topHabitWeekRatios: [Double]
    let bestActiveStreak: Int
    let morningsConquered: Int
    let avgReactionMs: Int?

    var formattedFocusTime: String {
        let mins = max(0, totalFocusMinutes)
        if mins == 0 { return "0m" }
        let h = mins / 60
        let m = mins % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    var formattedReactionSpeed: String {
        guard let ms = avgReactionMs else { return "--" }
        return "\(ms) ms"
    }
}

/// Aggregates the current ISO Monday–Sunday week from live SwiftData + Wake/Photo stores.
@MainActor
enum WeeklyRecapEngine {
    static func buildCurrentWeekRecap() -> WeeklyRecapSummary {
        let cal = ISOWeekCalendar.current
        let today = cal.startOfDay(for: Date())
        let monday = ISOWeekCalendar.startOfMondayWeek(for: today)
        let weekDates: [Date] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
        let weekKeys: [String] = weekDates.map { HabitItem.dateKey(for: $0) }
        let elapsedDates = weekDates.filter { $0 <= today }

        let store = SharedModelContainer.shared
        let activeHabits = store.fetchHabits().filter { !$0.isArchived }
        let allLogs = store.fetchHabitLogs()
        let allTasks = store.fetchFocusTasks()

        // Precompute log maps
        var logMaps: [UUID: [String: HabitLog]] = [:]
        for h in activeHabits {
            logMaps[h.id] = HabitMetricsEngine.logsByDayKey(for: h.id, allLogs: allLogs)
        }

        // Daily scores & habit consistency across elapsed days of this ISO week
        var dailyScores: [Int] = []
        var totalScheduledSlots = 0
        var totalCompletedSlots = 0

        for day in weekDates {
            if day > today {
                dailyScores.append(0)
                continue
            }
            let key = HabitItem.dateKey(for: day)
            let scheduled = activeHabits.filter { $0.isScheduled(on: day) }
            let dayTasks = allTasks.filter { $0.dayKey == key }

            var ratioSum = 0.0
            for h in scheduled {
                let r = HabitMetricsEngine.progressRatio(for: h, on: day, logMap: logMaps[h.id] ?? [:])
                ratioSum += r
                totalScheduledSlots += 1
                if r >= 1.0 { totalCompletedSlots += 1 }
            }

            let tasksDone = dayTasks.filter(\.isCompleted).count
            let totalItems = scheduled.count + dayTasks.count
            let dayScore: Int
            if totalItems > 0 {
                dayScore = max(0, min(100, Int(round(((ratioSum + Double(tasksDone)) / Double(totalItems)) * 100.0))))
            } else {
                let focusMins = WakeStatsStore.totalFocusMinutes(forDayKeys: [key])
                dayScore = min(100, Int(round((Double(focusMins) / 60.0) * 100.0)))
            }
            dailyScores.append(dayScore)
        }

        let elapsedCount = max(1, elapsedDates.count)
        let avgScore = Int(round(Double(dailyScores.prefix(elapsedCount).reduce(0, +)) / Double(elapsedCount)))

        let headline: String
        switch avgScore {
        case 90...100: headline = "Locked in."
        case 70...89: headline = "Dialed in."
        case 40...69: headline = "Building momentum."
        default: headline = "Warming up."
        }

        let consistencyPct = totalScheduledSlots > 0
            ? Int(round((Double(totalCompletedSlots) / Double(totalScheduledSlots)) * 100.0))
            : 0

        // Top Habit & Best Active Streak
        var topHabit: HabitItem? = activeHabits.first
        var topDays = -1
        var topRatios: [Double] = Array(repeating: 0.0, count: 7)
        var bestActiveStreak = 0

        for h in activeHabits {
            let map = logMaps[h.id] ?? [:]
            let streak = HabitMetricsEngine.currentStreak(for: h, logMap: map)
            bestActiveStreak = max(bestActiveStreak, streak)

            let ratios = weekDates.map { d -> Double in
                guard d <= today else { return 0.0 }
                return HabitMetricsEngine.progressRatio(for: h, on: d, logMap: map)
            }
            let doneCount = ratios.filter { $0 >= 1.0 }.count
            if doneCount > topDays {
                topDays = doneCount
                topHabit = h
                topRatios = ratios
            }
        }

        let globalStreak = HabitMetricsEngine.globalStreakSummary(habits: activeHabits, allLogs: allLogs).currentStreak
        bestActiveStreak = max(bestActiveStreak, globalStreak)

        // Focus & Photo Proofs
        let recordedFocusMins = max(
            WakeStatsStore.totalFocusMinutes(forDayKeys: weekKeys),
            HabitMetricsEngine.focusMinutesToday
        )
        let weekKeySet = Set(weekKeys)
        let completedTasks = allTasks.filter { weekKeySet.contains($0.dayKey) && $0.isCompleted }.count
        let verifiedProofs = PhotoProofLogStore.verifiedCount(forDayKeys: weekKeys)

        // Wake Performance
        let wakeRecords = WakeStatsStore.wakeRecords(forDayKeys: weekKeys)
        let reactionSamples = wakeRecords.compactMap(\.reactionTimeMs)
        let avgReaction: Int? = reactionSamples.isEmpty
            ? nil
            : Int(round(Double(reactionSamples.reduce(0, +)) / Double(reactionSamples.count)))

        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone.current
        f.dateFormat = "d MMM"
        let rangeLabel: String
        if let first = weekDates.first, let last = weekDates.last {
            rangeLabel = "\(f.string(from: first)) – \(f.string(from: last))"
        } else {
            rangeLabel = "This Week"
        }

        return WeeklyRecapSummary(
            dateRangeLabel: rangeLabel,
            avgWeeklyScore: avgScore,
            scoreHeadline: headline,
            dailyScores: dailyScores,
            totalFocusMinutes: recordedFocusMins,
            completedFocusTasks: completedTasks,
            verifiedPhotoProofs: verifiedProofs,
            habitConsistencyPercent: consistencyPct,
            topHabitName: topHabit?.title ?? "Start a Habit",
            topHabitIcon: topHabit?.iconName ?? "sparkles",
            topHabitColorHex: topHabit?.colorHex ?? "#60A5FA",
            topHabitCompletedDays: max(0, topDays),
            topHabitWeekRatios: topRatios,
            bestActiveStreak: bestActiveStreak,
            morningsConquered: wakeRecords.count,
            avgReactionMs: avgReaction
        )
    }
}
