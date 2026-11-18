import Foundation
import SwiftData

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

// MARK: - Photo Proof Record

struct PhotoProofRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var dateString: String
    var fileName: String
    var capturedAt: Date
}

// MARK: - SwiftData Habit Model

@Model
final class HabitItem {
    var id: UUID
    var title: String
    var notes: String
    var iconName: String
    var reminderEnabled: Bool
    var reminderHour: Int
    var reminderMinute: Int
    var repeatDaysRaw: String
    var soundOptionRaw: String
    var requiresPhotoProof: Bool
    var completedDatesRaw: String
    var photoProofsData: Data?
    var snoozedUntil: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String = "Morning Hydration",
        notes: String = "Drink 500ml of water right after waking up",
        iconName: String = "drop.fill",
        reminderEnabled: Bool = true,
        reminderHour: Int = 8,
        reminderMinute: Int = 0,
        repeatDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7],
        soundOption: NotificationSoundOption = .chimeBell,
        requiresPhotoProof: Bool = false,
        completedDates: Set<String> = [],
        photoProofs: [PhotoProofRecord] = [],
        snoozedUntil: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.iconName = iconName
        self.reminderEnabled = reminderEnabled
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
        self.repeatDaysRaw = repeatDays.sorted().map(String.init).joined(separator: ",")
        self.soundOptionRaw = soundOption.rawValue
        self.requiresPhotoProof = requiresPhotoProof
        self.completedDatesRaw = completedDates.sorted().joined(separator: ",")
        self.photoProofsData = try? JSONEncoder().encode(photoProofs)
        self.snoozedUntil = snoozedUntil
        self.createdAt = createdAt
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

    var photoProofs: [PhotoProofRecord] {
        get {
            guard let data = photoProofsData else { return [] }
            return (try? JSONDecoder().decode([PhotoProofRecord].self, from: data)) ?? []
        }
        set {
            photoProofsData = try? JSONEncoder().encode(newValue)
        }
    }

    var formattedReminderTime: String {
        String(format: "%02d:%02d", reminderHour, reminderMinute)
    }

    var repeatSummary: String {
        Weekday.formatSummary(for: repeatDays)
    }

    static func dateKey(for date: Date = Date()) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    func isCompleted(on date: Date = Date()) -> Bool {
        completedDateStrings.contains(Self.dateKey(for: date))
    }

    func isScheduled(on date: Date = Date()) -> Bool {
        let days = repeatDays
        if days.isEmpty { return true }
        let weekday = Calendar.current.component(.weekday, from: date)
        return days.contains(weekday)
    }

    func markCompleted(on date: Date = Date(), photoFileName: String? = nil) {
        let key = Self.dateKey(for: date)
        var current = completedDateStrings
        current.insert(key)
        completedDateStrings = current
        snoozedUntil = nil

        if let photoFileName {
            var proofs = photoProofs.filter { $0.dateString != key }
            proofs.append(PhotoProofRecord(dateString: key, fileName: photoFileName, capturedAt: Date()))
            photoProofs = proofs
        }
    }

    func markIncomplete(on date: Date = Date()) {
        let key = Self.dateKey(for: date)
        var current = completedDateStrings
        current.remove(key)
        completedDateStrings = current
    }

    func photoProof(for date: Date = Date()) -> PhotoProofRecord? {
        let key = Self.dateKey(for: date)
        return photoProofs.first(where: { $0.dateString == key })
    }

    var currentStreak: Int {
        let calendar = Calendar.current
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
                    // Today not yet completed; allow streak from yesterday
                    continue
                }
                if !isScheduled(on: checkDate) {
                    // Not scheduled on this weekday; streak continues across unscheduled days
                    continue
                }
                break
            }
        }
        return streak
    }

    /// Generates upcoming reminder fire dates over the next `daysAhead` days for the 64-notification queue.
    func upcomingReminderDates(from referenceDate: Date = Date(), daysAhead: Int = 21) -> [Date] {
        guard reminderEnabled else { return [] }
        let calendar = Calendar.current
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

            // If today is already completed, skip today's scheduled reminder
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
