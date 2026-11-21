import Foundation

/// Enforces Estonian / ISO-8601 Monday-first calendar week (`firstWeekday = 2`)
/// while respecting the device's local timezone (e.g., `Europe/Tallinn`).
enum ISOWeekCalendar {
    static var current: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        cal.firstWeekday = 2 // Monday
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    /// Returns 0 for Monday, 1 for Tuesday, ..., 6 for Sunday.
    static func mondayBasedDayIndex(for date: Date) -> Int {
        let weekday = current.component(.weekday, from: date) // Sun=1, Mon=2, ..., Sat=7
        return (weekday + 5) % 7
    }

    /// Returns the start of the ISO-8601 Monday-first week containing `date`.
    static func startOfMondayWeek(for date: Date) -> Date {
        let cal = current
        let dayStart = cal.startOfDay(for: date)
        let offset = mondayBasedDayIndex(for: dayStart)
        return cal.date(byAdding: .day, value: -offset, to: dayStart) ?? dayStart
    }
}

// MARK: - Monday-First Weekday Helper

enum Weekday: Int, CaseIterable, Codable, Identifiable, Comparable {
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7
    case sunday = 1

    var id: Int { rawValue }

    var isoOrderIndex: Int {
        switch self {
        case .monday: return 0
        case .tuesday: return 1
        case .wednesday: return 2
        case .thursday: return 3
        case .friday: return 4
        case .saturday: return 5
        case .sunday: return 6
        }
    }

    var shortName: String {
        switch self {
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        case .sunday: return "Sun"
        }
    }

    var singleLetter: String {
        switch self {
        case .monday: return "M"
        case .tuesday: return "T"
        case .wednesday: return "W"
        case .thursday: return "T"
        case .friday: return "F"
        case .saturday: return "S"
        case .sunday: return "S"
        }
    }

    static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.isoOrderIndex < rhs.isoOrderIndex
    }

    static func formatSummary(for days: Set<Int>) -> String {
        if days.isEmpty {
            return "One-time"
        }
        if days.count == 7 {
            return "Every day"
        }
        let weekdays: Set<Int> = [2, 3, 4, 5, 6]
        let weekends: Set<Int> = [7, 1]
        if days == weekdays {
            return "Mon–Fri"
        }
        if days == weekends {
            return "Sat–Sun"
        }
        return allCases
            .filter { days.contains($0.rawValue) }
            .map(\.shortName)
            .joined(separator: ", ")
    }
}
