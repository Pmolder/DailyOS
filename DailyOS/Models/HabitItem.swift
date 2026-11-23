import Foundation
import SwiftData
import SwiftUI

// MARK: - Habit Kind & Tracking Mode

enum HabitKind: String, CaseIterable, Codable, Identifiable {
    case build = "build"
    case quit = "quit"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .build: return "Build A Habit"
        case .quit: return "Quit A Habit"
        }
    }

    var helperCaption: String {
        switch self {
        case .build: return "Mark each day you complete it."
        case .quit: return "Track consecutive days clean."
        }
    }
}

enum HabitTrackingMode: String, CaseIterable, Codable, Identifiable {
    case binary = "binary"
    case quantity = "quantity"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .binary: return "Simple Check-in"
        case .quantity: return "Numeric Goal"
        }
    }
}

// MARK: - Habit Time-of-Day Spotlight Tag (Safe Defaults for Lightweight Migration)

enum HabitTimeOfDay: String, CaseIterable, Codable, Identifiable {
    case anytime = "anytime"
    case morning = "morning"
    case night = "night"

    var id: String { rawValue }

    static func from(raw: String) -> HabitTimeOfDay {
        switch raw.lowercased() {
        case "morning": return .morning
        case "night", "evening": return .night
        default: return .anytime
        }
    }

    var displayName: String {
        switch self {
        case .anytime: return "Anytime"
        case .morning: return "Morning"
        case .night: return "Night"
        }
    }

    var pillLabel: String {
        switch self {
        case .anytime: return "Anytime"
        case .morning: return "☀️ Morning"
        case .night: return "🌙 Night"
        }
    }

    var iconName: String {
        switch self {
        case .anytime: return "clock"
        case .morning: return "sun.max.fill"
        case .night: return "moon.stars.fill"
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

// MARK: - SwiftData HabitLog Model (O(1) Local Day Key + Quantified Value + Journal Note)

@Model
final class HabitLog {
    var id: UUID
    var habitID: UUID
    var dayKey: String // "yyyy-MM-dd" in local ISO-8601 calendar
    var date: Date
    var value: Double // >= target = completed (for quit habits: >= 1 means clean, < 0 means slip)
    var note: String?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        habitID: UUID,
        dayKey: String,
        date: Date,
        value: Double = 1.0,
        note: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.habitID = habitID
        self.dayKey = dayKey
        self.date = date
        self.value = value
        self.note = note
        self.updatedAt = updatedAt
    }

    var hasNote: Bool {
        guard let n = note?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !n.isEmpty
    }
}

// MARK: - SwiftData HabitItem Model (Safe Defaults for Lightweight Migration)

@Model
final class HabitItem {
    var id: UUID
    var title: String
    var notes: String
    var iconName: String
    var colorHex: String = "#34D399"
    var kindRaw: String = HabitKind.build.rawValue
    var trackingModeRaw: String = HabitTrackingMode.binary.rawValue
    var dailyTarget: Double = 1.0
    var unitLabel: String = ""
    var timeOfDayRaw: String = HabitTimeOfDay.anytime.rawValue
    var sortOrder: Int = 0
    var reminderEnabled: Bool
    var reminderHour: Int
    var reminderMinute: Int
    var repeatDaysRaw: String
    var soundOptionRaw: String
    var completedDatesRaw: String
    var snoozedUntil: Date?
    var isArchived: Bool = false
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        notes: String = "",
        iconName: String = "checkmark.seal.fill",
        colorHex: String = "#34D399",
        kind: HabitKind = .build,
        trackingMode: HabitTrackingMode = .binary,
        dailyTarget: Double = 1.0,
        unitLabel: String = "",
        timeOfDay: HabitTimeOfDay = .anytime,
        sortOrder: Int = 0,
        reminderEnabled: Bool = false,
        reminderHour: Int = 8,
        reminderMinute: Int = 0,
        repeatDays: Set<Int> = [2, 3, 4, 5, 6, 7, 1],
        soundOption: NotificationSoundOption = .chimeBell,
        completedDates: Set<String> = [],
        snoozedUntil: Date? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.iconName = iconName
        self.colorHex = colorHex
        self.kindRaw = kind.rawValue
        self.trackingModeRaw = trackingMode.rawValue
        self.dailyTarget = max(1.0, dailyTarget)
        self.unitLabel = unitLabel
        self.timeOfDayRaw = timeOfDay.rawValue
        self.sortOrder = sortOrder
        self.reminderEnabled = reminderEnabled
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
        self.repeatDaysRaw = repeatDays.sorted().map(String.init).joined(separator: ",")
        self.soundOptionRaw = soundOption.rawValue
        self.completedDatesRaw = completedDates.sorted().joined(separator: ",")
        self.snoozedUntil = snoozedUntil
        self.isArchived = isArchived
        self.createdAt = createdAt
    }

    // Semantic aliases matching v3.4 spec
    var name: String {
        get { title }
        set { title = newValue }
    }

    var subtitle: String {
        get { notes }
        set { notes = newValue }
    }

    var accentColor: Color {
        Color(hex: colorHex)
    }

    var kind: HabitKind {
        get { HabitKind(rawValue: kindRaw) ?? .build }
        set { kindRaw = newValue.rawValue }
    }

    var trackingMode: HabitTrackingMode {
        get { HabitTrackingMode(rawValue: trackingModeRaw) ?? .binary }
        set { trackingModeRaw = newValue.rawValue }
    }

    var timeOfDay: HabitTimeOfDay {
        get { HabitTimeOfDay.from(raw: timeOfDayRaw) }
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

    var effectiveDailyTarget: Double {
        trackingMode == .quantity ? max(1.0, dailyTarget) : 1.0
    }

    var formattedReminderTime: String {
        String(format: "%02d:%02d", reminderHour, reminderMinute)
    }

    var scheduleBadgeText: String {
        let days = repeatDays
        if days.isEmpty || days.count == 7 { return "Daily" }
        return Weekday.formatSummary(for: days)
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

    var currentStreak: Int {
        let calendar = ISOWeekCalendar.current
        let completed = completedDateStrings
        guard !completed.isEmpty else { return 0 }

        var streak = 0
        let today = Date()

        for dayOffset in 0..<365 {
            guard let checkDate = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { break }
            let key = Self.dateKey(for: checkDate)
            if completed.contains(key) {
                streak += 1
            } else {
                if dayOffset == 0 { continue }
                if !isScheduled(on: checkDate) { continue }
                break
            }
        }
        return streak
    }

    func upcomingReminderDates(from referenceDate: Date = Date(), daysAhead: Int = 21) -> [Date] {
        guard reminderEnabled && !isArchived else { return [] }
        let calendar = ISOWeekCalendar.current
        let activeDays = repeatDays.isEmpty ? Set(1...7) : repeatDays
        var results: [Date] = []

        if let snoozed = snoozedUntil, snoozed > referenceDate {
            results.append(snoozed)
        }

        for offset in 0..<daysAhead {
            guard let targetDay = calendar.date(byAdding: .day, value: offset, to: referenceDate) else { continue }
            let weekday = calendar.component(.weekday, from: targetDay)
            guard activeDays.contains(weekday) else { continue }
            if offset == 0 && isCompleted(on: targetDay) { continue }

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
