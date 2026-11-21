import Foundation
import SwiftData

// MARK: - Alarm Tone

enum AlarmTone: String, CaseIterable, Codable, Identifiable {
    case nuclearSiren = "nuclear_siren"
    case classicPulse = "classic_pulse"
    case radarChime = "radar_chime"
    case digitalSiren = "digital_siren"
    case submarineAlert = "submarine_alert"
    case synthEngine = "synth_engine"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nuclearSiren: return "Nuclear Siren / Klaxon"
        case .classicPulse: return "Classic Pulse (880Hz)"
        case .radarChime: return "Radar Beacon (1046Hz)"
        case .digitalSiren: return "Cyber Siren (Dual Sweep)"
        case .submarineAlert: return "Klaxon Horn (587Hz)"
        case .synthEngine: return "AVAudioEngine Direct Synth"
        }
    }

    var bundledFileName: String? {
        switch self {
        case .nuclearSiren: return "nuclear_siren.wav"
        case .classicPulse: return "alarm_classic.wav"
        case .radarChime: return "alarm_radar.wav"
        case .digitalSiren: return "alarm_siren.wav"
        case .submarineAlert: return "alarm_klaxon.wav"
        case .synthEngine: return nil
        }
    }

    var baseFrequency: Double {
        switch self {
        case .nuclearSiren: return 620.0
        case .classicPulse: return 880.0
        case .radarChime: return 1046.5
        case .digitalSiren: return 784.0
        case .submarineAlert: return 587.33
        case .synthEngine: return 987.77
        }
    }

    var secondaryFrequency: Double {
        switch self {
        case .nuclearSiren: return 1480.0
        case .classicPulse: return 1760.0
        case .radarChime: return 1318.5
        case .digitalSiren: return 1568.0
        case .submarineAlert: return 880.0
        case .synthEngine: return 1479.98
        }
    }

    var modulationRateHz: Double {
        switch self {
        case .nuclearSiren: return 1.8
        case .classicPulse: return 4.0
        case .radarChime: return 6.0
        case .digitalSiren: return 8.0
        case .submarineAlert: return 2.5
        case .synthEngine: return 5.0
        }
    }
}

// MARK: - Wake Dismissal Mission Types (Squats + Steps Only)

enum MissionType: String, CaseIterable, Codable, Identifiable {
    case squats = "squats"
    case steps = "steps"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .squats: return "AI Camera Squats (Vision)"
        case .steps: return "Steps (CoreMotion Pedometer)"
        }
    }

    var shortBadge: String {
        switch self {
        case .squats: return "Squats"
        case .steps: return "Steps"
        }
    }

    var iconName: String {
        switch self {
        case .squats: return "figure.strengthtraining.functional"
        case .steps: return "figure.walk"
        }
    }
}

// MARK: - SwiftData Alarm Model

@Model
final class AlarmItem {
    var id: UUID
    var label: String
    var hour: Int
    var minute: Int
    var isEnabled: Bool
    var repeatDaysRaw: String
    var toneRaw: String
    var missionTypeRaw: String
    var repGoal: Int = 20
    var stepGoal: Int = 50
    var createdAt: Date
    var lastTriggeredMinuteKey: String

    init(
        id: UUID = UUID(),
        label: String = "",
        hour: Int = 7,
        minute: Int = 0,
        isEnabled: Bool = true,
        repeatDays: Set<Int> = [2, 3, 4, 5, 6],
        tone: AlarmTone = .nuclearSiren,
        missionType: MissionType = .squats,
        repGoal: Int = 20,
        stepGoal: Int = 50,
        createdAt: Date = Date(),
        lastTriggeredMinuteKey: String = ""
    ) {
        self.id = id
        self.label = label
        self.hour = hour
        self.minute = minute
        self.isEnabled = isEnabled
        self.repeatDaysRaw = repeatDays.sorted().map(String.init).joined(separator: ",")
        self.toneRaw = tone.rawValue
        self.missionTypeRaw = missionType.rawValue
        self.repGoal = max(5, repGoal)
        self.stepGoal = max(10, stepGoal)
        self.createdAt = createdAt
        self.lastTriggeredMinuteKey = lastTriggeredMinuteKey
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

    var tone: AlarmTone {
        get { AlarmTone(rawValue: toneRaw) ?? .nuclearSiren }
        set { toneRaw = newValue.rawValue }
    }

    var missionType: MissionType {
        get { MissionType(rawValue: missionTypeRaw) ?? .squats }
        set { missionTypeRaw = newValue.rawValue }
    }

    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Wake Alarm" : trimmed
    }

    var formattedTime: String {
        String(format: "%02d:%02d", hour, minute)
    }

    var repeatSummary: String {
        Weekday.formatSummary(for: repeatDays)
    }

    var missionSummary: String {
        switch missionType {
        case .squats:
            return "\(repGoal) Squats"
        case .steps:
            return "\(stepGoal) Steps"
        }
    }

    /// Computes the next Date at which this alarm should fire after `referenceDate` using ISO-8601 local calendar.
    func nextTriggerDate(after referenceDate: Date = Date()) -> Date? {
        let calendar = ISOWeekCalendar.current
        let activeDays = repeatDays

        for dayOffset in 0...7 {
            guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: referenceDate) else {
                continue
            }
            var components = calendar.dateComponents([.year, .month, .day], from: candidateDay)
            components.hour = hour
            components.minute = minute
            components.second = 0

            guard let candidateDate = calendar.date(from: components) else {
                continue
            }

            if candidateDate <= referenceDate {
                continue
            }

            if activeDays.isEmpty {
                return candidateDate
            }

            let weekday = calendar.component(.weekday, from: candidateDate)
            if activeDays.contains(weekday) {
                return candidateDate
            }
        }
        return nil
    }
}
