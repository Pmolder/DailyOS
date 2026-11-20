import Foundation
import SwiftData

// MARK: - Weekday Helper

enum Weekday: Int, CaseIterable, Codable, Identifiable, Comparable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    var shortName: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }

    var singleLetter: String {
        switch self {
        case .sunday: return "S"
        case .monday: return "M"
        case .tuesday: return "T"
        case .wednesday: return "W"
        case .thursday: return "T"
        case .friday: return "F"
        case .saturday: return "S"
        }
    }

    static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func formatSummary(for days: Set<Int>) -> String {
        if days.isEmpty {
            return "One-time"
        }
        if days.count == 7 {
            return "Every day"
        }
        let weekdays: Set<Int> = [2, 3, 4, 5, 6]
        let weekends: Set<Int> = [1, 7]
        if days == weekdays {
            return "Weekdays"
        }
        if days == weekends {
            return "Weekends"
        }
        return days.sorted()
            .compactMap { Weekday(rawValue: $0)?.shortName }
            .joined(separator: ", ")
    }
}

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

// MARK: - Dismissal Mission Types

enum MissionType: String, CaseIterable, Codable, Identifiable {
    case pushups = "pushups"
    case squats = "squats"
    case qrBarcode = "qr_barcode"
    case steps = "steps"
    case math = "math"
    case none = "none"

    var id: String { rawValue }

    /// Anti-cheat Wake mission modes exposed in the alarm editor.
    static var wakeModes: [MissionType] {
        [.pushups, .squats, .qrBarcode]
    }

    var displayName: String {
        switch self {
        case .pushups: return "AI Camera Pushups (Vision)"
        case .squats: return "AI Camera Squats (Vision)"
        case .qrBarcode: return "QR / Barcode Scan"
        case .steps: return "Step Counter (CoreMotion)"
        case .math: return "Math Challenge"
        case .none: return "Standard (No Mission)"
        }
    }

    var shortBadge: String {
        switch self {
        case .pushups: return "AI Pushups"
        case .squats: return "AI Squats"
        case .qrBarcode: return "QR/Barcode"
        case .steps: return "Steps"
        case .math: return "Math"
        case .none: return "Dismiss"
        }
    }

    var iconName: String {
        switch self {
        case .pushups: return "figure.core.training"
        case .squats: return "figure.strengthtraining.functional"
        case .qrBarcode: return "qrcode.viewfinder"
        case .steps: return "figure.walk"
        case .math: return "function"
        case .none: return "bell.fill"
        }
    }
}

enum MathDifficulty: String, CaseIterable, Codable, Identifiable {
    case easy = "easy"
    case medium = "medium"
    case hard = "hard"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .easy: return "Easy (e.g. 6 × 7 + 14)"
        case .medium: return "Medium (e.g. 14 × 8 + 37)"
        case .hard: return "Hard (e.g. 23 × 16 + 148)"
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
    var repGoal: Int = 15
    var stepGoal: Int
    var mathDifficultyRaw: String
    var mathProblemCount: Int
    var customTargetBarcode: String
    var snoozeEnabled: Bool
    var createdAt: Date
    var lastTriggeredMinuteKey: String

    init(
        id: UUID = UUID(),
        label: String = "Nuclear Wake Up",
        hour: Int = 7,
        minute: Int = 0,
        isEnabled: Bool = true,
        repeatDays: Set<Int> = [2, 3, 4, 5, 6],
        tone: AlarmTone = .nuclearSiren,
        missionType: MissionType = .pushups,
        repGoal: Int = 15,
        stepGoal: Int = 50,
        mathDifficulty: MathDifficulty = .medium,
        mathProblemCount: Int = 3,
        customTargetBarcode: String = "",
        snoozeEnabled: Bool = false,
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
        self.repGoal = max(3, repGoal)
        self.stepGoal = max(5, stepGoal)
        self.mathDifficultyRaw = mathDifficulty.rawValue
        self.mathProblemCount = max(1, mathProblemCount)
        self.customTargetBarcode = customTargetBarcode
        self.snoozeEnabled = snoozeEnabled
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
        get { MissionType(rawValue: missionTypeRaw) ?? .pushups }
        set { missionTypeRaw = newValue.rawValue }
    }

    var mathDifficulty: MathDifficulty {
        get { MathDifficulty(rawValue: mathDifficultyRaw) ?? .medium }
        set { mathDifficultyRaw = newValue.rawValue }
    }

    var formattedTime: String {
        String(format: "%02d:%02d", hour, minute)
    }

    var repeatSummary: String {
        Weekday.formatSummary(for: repeatDays)
    }

    var missionSummary: String {
        switch missionType {
        case .pushups:
            return "\(repGoal) AI Pushups"
        case .squats:
            return "\(repGoal) AI Squats"
        case .qrBarcode:
            return "Scan QR/Barcode"
        case .steps:
            return "\(stepGoal) Steps"
        case .math:
            return "\(mathProblemCount)x \(mathDifficulty.rawValue.capitalized) Math"
        case .none:
            return "Standard Dismiss"
        }
    }

    /// Computes the next Date at which this alarm should fire after `referenceDate`.
    func nextTriggerDate(after referenceDate: Date = Date()) -> Date? {
        let calendar = Calendar.current
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
