import Foundation
import SwiftData

// MARK: - Wake-Up QR / Barcode Storage (UserDefaults)

enum WakeQRStorage {
    private static let codeKey = "com.patrik.dailyos.wakeQRCode"
    private static let lastPhysicalKey = "com.patrik.dailyos.lastRandomPhysicalMission"
    private static let lastBrainKey = "com.patrik.dailyos.lastRandomBrainGame"
    private static let defaultReflexKey = "com.patrik.dailyos.defaultReflexThresholdMs"

    static var registeredCode: String {
        get { UserDefaults.standard.string(forKey: codeKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: codeKey) }
    }

    static var isRegistered: Bool {
        !registeredCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var truncatedDisplay: String {
        let code = registeredCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return "Not Set" }
        if code.count <= 18 { return code }
        return "\(code.prefix(10))…\(code.suffix(6))"
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: codeKey)
    }

    static var lastRandomPhysicalMissionRaw: String {
        get { UserDefaults.standard.string(forKey: lastPhysicalKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastPhysicalKey) }
    }

    static var lastRandomBrainGameRaw: String {
        get { UserDefaults.standard.string(forKey: lastBrainKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastBrainKey) }
    }

    static var defaultReflexThresholdMs: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: defaultReflexKey)
            return (180...350).contains(stored) ? stored : 260
        }
        set {
            UserDefaults.standard.set(max(180, min(350, newValue)), forKey: defaultReflexKey)
        }
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

// MARK: - Stage-1 Physical Wake Mission Types

enum MissionType: String, CaseIterable, Codable, Identifiable {
    case random = "random"
    case squats = "squats"
    case steps = "steps"
    case qrBarcode = "qr_barcode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .random: return "Daily Random"
        case .squats: return "Squats (Vision)"
        case .steps: return "Steps (CoreMotion)"
        case .qrBarcode: return "QR / Barcode Scan"
        }
    }

    var shortBadge: String {
        switch self {
        case .random: return "Random"
        case .squats: return "Squats"
        case .steps: return "Steps"
        case .qrBarcode: return "QR Scan"
        }
    }

    var iconName: String {
        switch self {
        case .random: return "dice.fill"
        case .squats: return "figure.strengthtraining.functional"
        case .steps: return "figure.walk"
        case .qrBarcode: return "qrcode.viewfinder"
        }
    }

    /// Resolves `.random` into a concrete Stage-1 mission, excluding QR Scan if none is registered
    /// and avoiding repeating the previous morning's random roll whenever possible.
    func resolvedForTrigger() -> MissionType {
        guard self == .random else { return self }

        var pool: [MissionType] = [.squats, .steps]
        if WakeQRStorage.isRegistered {
            pool.append(.qrBarcode)
        }

        let previousRaw = WakeQRStorage.lastRandomPhysicalMissionRaw
        let nonRepeating = pool.filter { $0.rawValue != previousRaw }
        let candidates = nonRepeating.isEmpty ? pool : nonRepeating
        let chosen = candidates.randomElement() ?? .squats
        WakeQRStorage.lastRandomPhysicalMissionRaw = chosen.rawValue
        return chosen
    }
}

// MARK: - Stage-2 Cognitive Brain Game Modes

enum BrainGameMode: String, CaseIterable, Codable, Identifiable {
    case random = "random"
    case reflexStrike = "reflex_strike"
    case memoryGrid = "memory_grid"
    case mathSprint = "math_sprint"
    case nodeConnect = "node_connect"
    case off = "off"

    var id: String { rawValue }

    static var playableGames: [BrainGameMode] {
        [.reflexStrike, .memoryGrid, .mathSprint, .nodeConnect]
    }

    var displayName: String {
        switch self {
        case .random: return "Daily Random"
        case .reflexStrike: return "Reflex Strike"
        case .memoryGrid: return "Memory Grid"
        case .mathSprint: return "Math Sprint"
        case .nodeConnect: return "Node Connect"
        case .off: return "Off"
        }
    }

    var shortBadge: String {
        switch self {
        case .random: return "Random Brain"
        case .reflexStrike: return "Reflex"
        case .memoryGrid: return "Memory"
        case .mathSprint: return "Math"
        case .nodeConnect: return "Nodes"
        case .off: return "No Brain Game"
        }
    }

    var iconName: String {
        switch self {
        case .random: return "brain.head.profile"
        case .reflexStrike: return "bolt.fill"
        case .memoryGrid: return "square.grid.3x3.fill"
        case .mathSprint: return "function"
        case .nodeConnect: return "point.3.connected.trianglepath.dotted"
        case .off: return "minus.circle"
        }
    }

    /// Resolves `.random` into one of the 4 playable cognitive games (avoiding back-to-back repeats),
    /// or returns `nil` when `.off`.
    func resolvedForTrigger() -> BrainGameMode? {
        switch self {
        case .off:
            return nil
        case .reflexStrike, .memoryGrid, .mathSprint, .nodeConnect:
            return self
        case .random:
            let pool = Self.playableGames
            let previousRaw = WakeQRStorage.lastRandomBrainGameRaw
            let nonRepeating = pool.filter { $0.rawValue != previousRaw }
            let candidates = nonRepeating.isEmpty ? pool : nonRepeating
            let chosen = candidates.randomElement() ?? .reflexStrike
            WakeQRStorage.lastRandomBrainGameRaw = chosen.rawValue
            return chosen
        }
    }
}

// MARK: - SwiftData Alarm Model (Safe Defaults for Lightweight Migration)

@Model
final class AlarmItem {
    var id: UUID
    var label: String
    var hour: Int
    var minute: Int
    var isEnabled: Bool
    var repeatDaysRaw: String
    var toneRaw: String
    var soundID: String = AlarmSoundscape.goldenHour.rawValue
    var missionTypeRaw: String
    var repGoal: Int = 15
    var stepGoal: Int = 500
    var stepsTimeLimitSeconds: Int = 600
    var qrGraceSeconds: Int = 60
    var brainGameModeRaw: String = BrainGameMode.random.rawValue
    var reflexThresholdMs: Int = 260
    var sleepCycleCount: Int = 5
    var windDownMinutes: Int = 15
    var bedtimeReminderEnabled: Bool = true
    var stage3Enabled: Bool = true
    var stage3TimeLimitSeconds: Int = 120
    var stage3ChecklistItemsData: String = AlarmItem.defaultStage3ChecklistJSON
    var createdAt: Date
    var lastTriggeredMinuteKey: String

    static let defaultStage3ChecklistItems: [String] = [
        "Drink a full glass of water",
        "Look at bright light for 30 seconds",
        "Splash face with cold water"
    ]

    static var defaultStage3ChecklistJSON: String {
        guard let data = try? JSONEncoder().encode(defaultStage3ChecklistItems),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    init(
        id: UUID = UUID(),
        label: String = "",
        hour: Int = 7,
        minute: Int = 0,
        isEnabled: Bool = true,
        repeatDays: Set<Int> = [2, 3, 4, 5, 6],
        tone: AlarmTone = .nuclearSiren,
        soundID: String = AlarmSoundscape.goldenHour.rawValue,
        missionType: MissionType = .random,
        repGoal: Int = 15,
        stepGoal: Int = 500,
        stepsTimeLimitSeconds: Int = 600,
        qrGraceSeconds: Int = 60,
        brainGameMode: BrainGameMode = .random,
        reflexThresholdMs: Int = WakeQRStorage.defaultReflexThresholdMs,
        sleepCycleCount: Int = 5,
        windDownMinutes: Int = 15,
        bedtimeReminderEnabled: Bool = true,
        stage3Enabled: Bool = true,
        stage3TimeLimitSeconds: Int = 120,
        stage3ChecklistItems: [String] = AlarmItem.defaultStage3ChecklistItems,
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
        self.soundID = AlarmSoundscape.resolve(legacyOrID: soundID).rawValue
        self.missionTypeRaw = missionType.rawValue
        self.repGoal = max(5, repGoal)
        self.stepGoal = max(50, min(5000, stepGoal))
        self.stepsTimeLimitSeconds = max(30, min(3600, stepsTimeLimitSeconds))
        self.qrGraceSeconds = max(20, min(180, qrGraceSeconds))
        self.brainGameModeRaw = brainGameMode.rawValue
        self.reflexThresholdMs = max(180, min(350, reflexThresholdMs))
        self.sleepCycleCount = max(4, min(6, sleepCycleCount))
        self.windDownMinutes = max(5, min(60, windDownMinutes))
        self.bedtimeReminderEnabled = bedtimeReminderEnabled
        self.stage3Enabled = stage3Enabled
        self.stage3TimeLimitSeconds = max(60, min(300, stage3TimeLimitSeconds))
        if let data = try? JSONEncoder().encode(stage3ChecklistItems),
           let jsonStr = String(data: data, encoding: .utf8) {
            self.stage3ChecklistItemsData = jsonStr
        } else {
            self.stage3ChecklistItemsData = AlarmItem.defaultStage3ChecklistJSON
        }
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

    var soundscape: AlarmSoundscape {
        get {
            if let direct = AlarmSoundscape(rawValue: soundID) {
                return direct
            }
            return AlarmSoundscape.resolve(legacyOrID: toneRaw)
        }
        set {
            soundID = newValue.rawValue
        }
    }

    var missionType: MissionType {
        get { MissionType(rawValue: missionTypeRaw) ?? .random }
        set { missionTypeRaw = newValue.rawValue }
    }

    var brainGameMode: BrainGameMode {
        get { BrainGameMode(rawValue: brainGameModeRaw) ?? .random }
        set { brainGameModeRaw = newValue.rawValue }
    }

    var stage3ChecklistItems: [String] {
        get {
            guard let data = stage3ChecklistItemsData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return Self.defaultStage3ChecklistItems
            }
            let cleaned = decoded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return cleaned.isEmpty ? Self.defaultStage3ChecklistItems : cleaned
        }
        set {
            let cleaned = Array(newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(5))
            if let data = try? JSONEncoder().encode(cleaned),
               let str = String(data: data, encoding: .utf8) {
                stage3ChecklistItemsData = str
            }
        }
    }

    var sleepDurationHoursText: String {
        Self.sleepDurationText(forCycles: sleepCycleCount)
    }

    static func sleepDurationText(forCycles cycles: Int) -> String {
        let totalMins = max(1, cycles) * 90
        let hours = totalMins / 60
        let rem = totalMins % 60
        return rem == 0 ? "\(hours)h" : "\(hours).5h"
    }

    static func computeBedtime(
        wakeHour: Int,
        wakeMinute: Int,
        cycles: Int,
        windDownMinutes: Int
    ) -> (windDownHour: Int, windDownMinute: Int, lightsOutHour: Int, lightsOutMinute: Int, windDownText: String, lightsOutText: String, fallsOnPreviousDay: Bool) {
        let wakeTotal = wakeHour * 60 + wakeMinute
        let lightsOutRaw = wakeTotal - (max(1, cycles) * 90)
        let windDownRaw = lightsOutRaw - max(0, windDownMinutes)

        let lightsOutWrapped = ((lightsOutRaw % 1440) + 1440) % 1440
        let windDownWrapped = ((windDownRaw % 1440) + 1440) % 1440

        let loH = lightsOutWrapped / 60
        let loM = lightsOutWrapped % 60
        let wdH = windDownWrapped / 60
        let wdM = windDownWrapped % 60

        return (
            windDownHour: wdH,
            windDownMinute: wdM,
            lightsOutHour: loH,
            lightsOutMinute: loM,
            windDownText: String(format: "%02d:%02d", wdH, wdM),
            lightsOutText: String(format: "%02d:%02d", loH, loM),
            fallsOnPreviousDay: windDownRaw < 0
        )
    }

    func bedtimeSchedule() -> (windDownHour: Int, windDownMinute: Int, lightsOutHour: Int, lightsOutMinute: Int, windDownText: String, lightsOutText: String, fallsOnPreviousDay: Bool) {
        Self.computeBedtime(
            wakeHour: hour,
            wakeMinute: minute,
            cycles: sleepCycleCount,
            windDownMinutes: windDownMinutes
        )
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

    var formattedStepsTimeLimit: String {
        let mins = stepsTimeLimitSeconds / 60
        let secs = stepsTimeLimitSeconds % 60
        if mins == 0 { return "\(secs)s" }
        if secs == 0 { return "\(mins)m" }
        return "\(mins)m \(secs)s"
    }

    var missionSummary: String {
        switch missionType {
        case .random:
            return "Daily Random"
        case .squats:
            return "\(repGoal) Squats"
        case .steps:
            return "\(stepGoal) Steps • \(formattedStepsTimeLimit)"
        case .qrBarcode:
            return "QR Scan • \(qrGraceSeconds)s"
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
