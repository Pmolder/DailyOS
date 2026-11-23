import Foundation
import SwiftData

/// Task-first Focus item persisted in SwiftData for the Day Slider & Week Overview Hub.
@Model
final class FocusTaskItem {
    var id: UUID = UUID()
    var title: String = ""
    var location: String = ""
    var notes: String = ""
    var dayKey: String = ""
    var startTime: Date? = nil
    var durationMinutes: Int = 60
    var isCompleted: Bool = false
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        title: String,
        location: String = "",
        notes: String = "",
        dayKey: String = HabitItem.dateKey(),
        startTime: Date? = nil,
        durationMinutes: Int = 60,
        isCompleted: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.notes = notes
        self.dayKey = dayKey
        self.startTime = startTime
        self.durationMinutes = max(5, min(720, durationMinutes))
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }

    var trimmedLocation: String {
        location.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var formattedDuration: String {
        let mins = max(5, durationMinutes)
        if mins < 60 {
            return "\(mins)m"
        }
        let hours = mins / 60
        let rem = mins % 60
        if rem == 0 {
            return "\(hours)h"
        }
        if rem == 30 {
            return "\(hours).5h"
        }
        return "\(hours)h \(rem)m"
    }

    var formattedTimeRangeAndDuration: String {
        guard let start = startTime else {
            return formattedDuration
        }
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm"
        return "\(f.string(from: start)) – \(f.string(from: end)) · \(formattedDuration)"
    }

    var formattedCompactPrefix: String {
        guard let start = startTime else {
            return "Anytime · \(formattedDuration)"
        }
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm"
        return "\(f.string(from: start)) · \(formattedDuration)"
    }

    /// Chronological sort key within a day: timed tasks sorted by HH:mm first, anytime tasks afterward.
    var sortMinutesOfDay: Int {
        guard let start = startTime else { return Int.max }
        let comps = ISOWeekCalendar.current.dateComponents([.hour, .minute], from: start)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}
