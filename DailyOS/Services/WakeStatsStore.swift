import Foundation

// MARK: - Lightweight Daily Wake-Up & Focus History Persistence (UserDefaults)

struct WakeCompletionRecord: Codable, Identifiable {
    var id: String { dayKey }
    var dayKey: String
    var physicalMissionType: String
    var brainGameType: String
    var reactionTimeMs: Int?
    var wakeDurationSeconds: Int
}

enum WakeStatsStore {
    private static let wakeRecordsKey = "com.patrik.dailyos.wakeCompletionRecords"
    private static let dailyFocusMinutesMapKey = "com.patrik.dailyos.dailyFocusMinutesHistory"

    static func recordWakeCompletion(
        dayKey: String = HabitItem.dateKey(),
        physicalMission: MissionType,
        brainGame: BrainGameMode?,
        brainSummary: String,
        wakeDurationSeconds: Int
    ) {
        var all = loadAllWakeRecords()
        let parsedMs = extractReactionMs(from: brainSummary)
        let record = WakeCompletionRecord(
            dayKey: dayKey,
            physicalMissionType: physicalMission.rawValue,
            brainGameType: brainGame?.rawValue ?? "off",
            reactionTimeMs: parsedMs,
            wakeDurationSeconds: max(1, wakeDurationSeconds)
        )
        all[dayKey] = record
        saveAllWakeRecords(all)
    }

    static func wakeRecords(forDayKeys keys: [String]) -> [WakeCompletionRecord] {
        let all = loadAllWakeRecords()
        return keys.compactMap { all[$0] }
    }

    static func recordFocusMinutes(_ minutes: Int, forDayKey dayKey: String = HabitItem.dateKey()) {
        guard minutes > 0 else { return }
        var map = UserDefaults.standard.dictionary(forKey: dailyFocusMinutesMapKey) as? [String: Int] ?? [:]
        map[dayKey] = (map[dayKey] ?? 0) + minutes
        UserDefaults.standard.set(map, forKey: dailyFocusMinutesMapKey)
    }

    static func totalFocusMinutes(forDayKeys keys: [String]) -> Int {
        let map = UserDefaults.standard.dictionary(forKey: dailyFocusMinutesMapKey) as? [String: Int] ?? [:]
        return keys.reduce(0) { $0 + (map[$1] ?? 0) }
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: wakeRecordsKey)
        UserDefaults.standard.removeObject(forKey: dailyFocusMinutesMapKey)
    }

    private static func extractReactionMs(from summary: String) -> Int? {
        // Matches patterns like "234 ms", "234ms", "avg 218ms"
        let pattern = #"(\d{2,4})\s*ms"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: summary, range: NSRange(summary.startIndex..., in: summary)),
              let range = Range(match.range(at: 1), in: summary) else {
            return nil
        }
        return Int(summary[range])
    }

    private static func loadAllWakeRecords() -> [String: WakeCompletionRecord] {
        guard let data = UserDefaults.standard.data(forKey: wakeRecordsKey),
              let decoded = try? JSONDecoder().decode([String: WakeCompletionRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveAllWakeRecords(_ map: [String: WakeCompletionRecord]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: wakeRecordsKey)
        }
    }
}
