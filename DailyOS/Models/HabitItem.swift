import Foundation
import SwiftData

// MARK: - Habit Time-of-Day Segment

enum HabitTimeOfDay: String, CaseIterable, Codable, Identifiable {
    case morning = "morning"
    case day = "day"
    case evening = "evening"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .morning: return "Morning"
        case .day: return "Day"
        case .evening: return "Evening"
        }
    }

    var iconName: String {
        switch self {
        case .morning: return "sunrise.fill"
        case .day: return "sun.max.fill"
        case .evening: return "moon.stars.fill"
        }
    }

    var sortIndex: Int {
        switch self {
        case .morning: return 0
        case .day: return 1
        case .evening: return 2
        }
    }
}

// MARK: - Notification Sound Options

enum NotificationSoundOption: String, CaseIterable, Codable, Identifiable {
    case systemDefault = "system_default"
    case chimeBell = "chime_bell"
    case morningBreeze = "morning_breeze"
    case crispPing = "crisp_ping"
    case zenBowl = "zen_bowl"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemDefault: return "System Default"
        case .chimeBell: return "Crystal Chime"
        case .morningBreeze: return "Morning Breeze"
        case .crispPing: return "Crisp Sonar Ping"
        case .zenBowl: return "Zen Singing Bowl"
        }
    }

    var soundFileName: String? {
        switch self {
        case .systemDefault: return nil
        case .chimeBell: return "habit_chime.wav"
        case .morningBreeze: return "habit_breeze.wav"
        case .crispPing: return "habit_ping.wav"
        case .zenBowl: return "habit_zen.wav"
        }
    }

    var notesHz: [Double] {
        switch self {
        case .systemDefault: return [659.25, 880.0]
        case .chimeBell: return [523.25, 659.25, 783.99, 1046.50]
        case .morningBreeze: return [440.0, 554.37, 659.25, 880.0]
        case .crispPing: return [880.0, 1318.51, 1760.0]
        case .zenBowl: return [392.0, 587.33, 783.99]
        }
    }
}

// MARK: - SwiftData Habit Model

@Model
final class HabitItem {
    var id: UUID
    var title: String
    var notes: String
    var iconName: String
    var timeOfDayRaw: String = HabitTimeOfDay.morning.rawValue
    var sortOrder: Int = 0
    var reminderEnabled: Bool
    var reminderHour: Int
    var reminderMinute: Int
    var repeatDaysRaw: String
    var soundOptionRaw: String
    var completedDatesRaw: String
    var snoozedUntil: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        notes: String = "",
        iconName: String = "checkmark.seal.fill",
        timeOfDay: HabitTimeOfDay = .morning,
        sortOrder: Int = 0,
        reminderEnabled: Bool = false,
        reminderHour: Int = 8,
        reminderMinute: Int = 0,
        repeatDays: Set<Int> = [2, 3, 4, 5, 6, 7, 1],
        soundOption: NotificationSoundOption = .chimeBell,
        completedDates: Set<String> = [],
        snoozedUntil: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.iconName = iconName
        self.timeOfDayRaw = timeOfDay.rawValue
        self.sortOrder = sortOrder
        self.reminderEnabled = reminderEnabled
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
        self.repeatDaysRaw = repeatDays.sorted().map(String.init).joined(separator: ",")
        self.soundOptionRaw = soundOption.rawValue
        self.completedDatesRaw = completedDates.sorted().joined(separator: ",")
        self.snoozedUntil = snoozedUntil
        self.createdAt = createdAt
    }

    var timeOfDay: HabitTimeOfDay {
        get { HabitTimeOfDay(rawValue: timeOfDayRaw) ?? .morning }
        set { timeOfDayRaw = newValue.rawValue }
    }

    var repeatDays: Set<Int> {
        get {
            guard !repeatDaysRaw.isEmpty else { return [] }
            return Set(
                repeatDaysRaw
                    .split(separator: ",")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            )
        }
        set {
            repeatDaysRaw = newValue.sorted().map(String.init).joined(separator: ",")
        }
    }

    var soundOption: NotificationSoundOption {
        get { NotificationSoundOption(rawValue: soundOptionRaw) ?? .systemDefault }
        set { soundOptionRaw = newValue.rawValue }
    }

    var completedDateStrings: Set<String> {
        get {
            guard !completedDatesRaw.isEmpty else { return [] }
            return Set(
                completedDatesRaw
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        }
        set {
            completedDatesRaw = newValue.sorted().joined(separator: ",")
        }
    }

    var formattedReminderTime: String {
        String(format: "%02d:%02d", reminderHour, reminderMinute)
    }

    var repeatSummary: String {
        Weekday.formatSummary(for: repeatDays)
    }

    static func dateKey(for date: Date = Date()) -> String {
        let calendar = ISOWeekCalendar.current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func date(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        return ISOWeekCalendar.current.date(from: comps)
    }

    func isCompleted(on date: Date = Date()) -> Bool {
        completedDateStrings.contains(Self.dateKey(for: date))
    }

    func isScheduled(on date: Date = Date()) -> Bool {
        let days = repeatDays
        if days.isEmpty { return true }
        let weekday = ISOWeekCalendar.current.component(.weekday, from: date)
        return days.contains(weekday)
    }

    func markCompleted(on date: Date = Date()) {
        let key = Self.dateKey(for: date)
        var current = completedDateStrings
        current.insert(key)
        completedDateStrings = current
        snoozedUntil = nil
    }

    func markIncomplete(on date: Date = Date()) {
        let key = Self.dateKey(for: date)
        var current = completedDateStrings
        current.remove(key)
        completedDateStrings = current
    }

    func toggleCompletion(on date: Date = Date()) {
        if isCompleted(on: date) {
            markIncomplete(on: date)
        } else {
            markCompleted(on: date)
        }
    }

    // MARK: - Accuracy & Consistency Analytics

    func completionRate(lastDays days: Int, referenceDate: Date = Date()) -> Double {
        guard days > 0 else { return 0.0 }
        let calendar = ISOWeekCalendar.current
        let completed = completedDateStrings
        var scheduledCount = 0
        var completedCount = 0

        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: referenceDate) else { continue }
            if isScheduled(on: day) {
                scheduledCount += 1
                if completed.contains(Self.dateKey(for: day)) {
                    completedCount += 1
                }
            }
        }
        guard scheduledCount > 0 else { return 0.0 }
        return Double(completedCount) / Double(scheduledCount)
    }

    var allTimeCompletionRate: Double {
        let calendar = ISOWeekCalendar.current
        let today = calendar.startOfDay(for: Date())
        let createdDay = calendar.startOfDay(for: createdAt)

        let earliestLogged = completedDateStrings
            .compactMap { Self.date(from: $0) }
            .map { calendar.startOfDay(for: $0) }
            .min()

        let startDay = min(createdDay, earliestLogged ?? createdDay)
        let daySpan = max(1, (calendar.dateComponents([.day], from: startDay, to: today).day ?? 0) + 1)
        return completionRate(lastDays: min(daySpan, 3650), referenceDate: today)
    }

    static func dailyCompletionSummary(habits: [HabitItem], on date: Date) -> (completed: Int, scheduled: Int, ratio: Double) {
        let scheduledHabits = habits.filter { $0.isScheduled(on: date) }
        guard !scheduledHabits.isEmpty else { return (0, 0, 0.0) }
        let completedCount = scheduledHabits.filter { $0.isCompleted(on: date) }.count
        return (completedCount, scheduledHabits.count, Double(completedCount) / Double(scheduledHabits.count))
    }

    var currentStreak: Int {
        let calendar = ISOWeekCalendar.current
        let completed = completedDateStrings
        guard !completed.isEmpty else { return 0 }

        var streak = 0
        let today = Date()

        for dayOffset in 0..<365 {
            guard let checkDate = calendar.date(byAdding: .day, value: -dayOffset, to: today) else {
                break
            }
            let key = Self.dateKey(for: checkDate)
            if completed.contains(key) {
                streak += 1
            } else {
                if dayOffset == 0 {
                    continue
                }
                if !isScheduled(on: checkDate) {
                    continue
                }
                break
            }
        }
        return streak
    }

    func upcomingReminderDates(from referenceDate: Date = Date(), daysAhead: Int = 21) -> [Date] {
        guard reminderEnabled else { return [] }
        let calendar = ISOWeekCalendar.current
        let activeDays = repeatDays.isEmpty ? Set(1...7) : repeatDays
        var results: [Date] = []

        if let snoozed = snoozedUntil, snoozed > referenceDate {
            results.append(snoozed)
        }

        for offset in 0..<daysAhead {
            guard let targetDay = calendar.date(byAdding: .day, value: offset, to: referenceDate) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: targetDay)
            guard activeDays.contains(weekday) else { continue }

            if offset == 0 && isCompleted(on: targetDay) {
                continue
            }

            var comps = calendar.dateComponents([.year, .month, .day], from: targetDay)
            comps.hour = reminderHour
            comps.minute = reminderMinute
            comps.second = 0

            if let candidate = calendar.date(from: comps), candidate > referenceDate {
                results.append(candidate)
            }
        }

        return results.sorted()
    }
}
