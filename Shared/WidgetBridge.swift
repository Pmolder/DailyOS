import Foundation
import SwiftUI
import AppIntents
import WidgetKit

// MARK: - Shared Widget Data Models (Compiled into BOTH DailyOS & DailyOSWidgets)

struct WidgetHabitItem: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var iconName: String
    var colorHex: String
    var kind: String          // "build" | "quit"
    var trackingMode: String  // "binary" | "quantity"
    var dailyTarget: Double
    var todayValue: Double
    var streak: Int
    var last7Days: [Double]           // 7 ratios Mon...Sun for current ISO week
    var currentMonthDays: [Int: Double] // day-of-month (1...31) -> ratio (0...1)

    var effectiveTarget: Double {
        trackingMode == "quantity" ? max(1.0, dailyTarget) : 1.0
    }

    var todayProgressRatio: Double {
        if kind == "quit" {
            return todayValue >= 1.0 ? 1.0 : 0.0
        }
        return min(1.0, max(0.0, todayValue / effectiveTarget))
    }

    var isCompletedToday: Bool {
        todayProgressRatio >= 1.0
    }
}

struct WidgetSnapshot: Codable {
    var updatedAt: Date
    var todayKey: String
    var todayScore: Int
    var scoreHeadline: String
    var globalStreak: Int
    var streakFreezes: Int
    var habits: [WidgetHabitItem]
    var habitsPercent: Int
    var habitsDone: Int
    var habitsTotal: Int
    var todoPercent: Int
    var todoDone: Int
    var todoTotal: Int

    init(
        updatedAt: Date,
        todayKey: String,
        todayScore: Int,
        scoreHeadline: String,
        globalStreak: Int,
        streakFreezes: Int,
        habits: [WidgetHabitItem],
        habitsPercent: Int? = nil,
        habitsDone: Int? = nil,
        habitsTotal: Int? = nil,
        todoPercent: Int = 0,
        todoDone: Int = 0,
        todoTotal: Int = 0
    ) {
        self.updatedAt = updatedAt
        self.todayKey = todayKey
        self.todayScore = todayScore
        self.scoreHeadline = scoreHeadline
        self.globalStreak = globalStreak
        self.streakFreezes = streakFreezes
        self.habits = habits
        self.habitsPercent = habitsPercent ?? todayScore
        self.habitsDone = habitsDone ?? habits.filter(\.isCompletedToday).count
        self.habitsTotal = habitsTotal ?? habits.count
        self.todoPercent = todoPercent
        self.todoDone = todoDone
        self.todoTotal = todoTotal
    }

    enum CodingKeys: String, CodingKey {
        case updatedAt, todayKey, todayScore, scoreHeadline, globalStreak, streakFreezes, habits
        case habitsPercent, habitsDone, habitsTotal, todoPercent, todoDone, todoTotal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        todayKey = try c.decodeIfPresent(String.self, forKey: .todayKey) ?? WidgetBridge.todayDateKey()
        todayScore = try c.decodeIfPresent(Int.self, forKey: .todayScore) ?? 0
        scoreHeadline = try c.decodeIfPresent(String.self, forKey: .scoreHeadline) ?? "Let's start."
        globalStreak = try c.decodeIfPresent(Int.self, forKey: .globalStreak) ?? 0
        streakFreezes = try c.decodeIfPresent(Int.self, forKey: .streakFreezes) ?? 1
        habits = try c.decodeIfPresent([WidgetHabitItem].self, forKey: .habits) ?? []
        habitsPercent = try c.decodeIfPresent(Int.self, forKey: .habitsPercent) ?? todayScore
        habitsDone = try c.decodeIfPresent(Int.self, forKey: .habitsDone) ?? habits.filter(\.isCompletedToday).count
        habitsTotal = try c.decodeIfPresent(Int.self, forKey: .habitsTotal) ?? habits.count
        todoPercent = try c.decodeIfPresent(Int.self, forKey: .todoPercent) ?? 0
        todoDone = try c.decodeIfPresent(Int.self, forKey: .todoDone) ?? 0
        todoTotal = try c.decodeIfPresent(Int.self, forKey: .todoTotal) ?? 0
    }

    static func empty(todayKey: String = WidgetBridge.todayDateKey()) -> WidgetSnapshot {
        WidgetSnapshot(
            updatedAt: Date(),
            todayKey: todayKey,
            todayScore: 0,
            scoreHeadline: "Let's start.",
            globalStreak: 0,
            streakFreezes: 1,
            habits: [],
            habitsPercent: 0,
            habitsDone: 0,
            habitsTotal: 0,
            todoPercent: 0,
            todoDone: 0,
            todoTotal: 0
        )
    }
}

struct PendingWidgetDelta: Codable {
    var habitID: String
    var dayKey: String
    var newValue: Double
    var timestamp: Date
}

// MARK: - Crash-Proof Shared App Group JSON Bridge

enum WidgetBridge {
    static let appGroupID = "group.com.patrik.dailyos"
    private static let snapshotFileName = "widget_snapshot.json"
    private static let deltasFileName = "widget_deltas.json"

    static var isoCalendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2 // Monday
        cal.minimumDaysInFirstWeek = 4
        cal.timeZone = TimeZone.current
        return cal
    }

    static func todayDateKey(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = isoCalendar
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func mondayBasedDayIndex(for date: Date = Date()) -> Int {
        let weekday = isoCalendar.component(.weekday, from: date)
        return (weekday + 5) % 7 // Mon=0 ... Sun=6
    }

    private static var sharedDirectoryURL: URL {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return groupURL
        }
        // Graceful fallback so unsigned/simulator environments never crash
        let fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return fallback
    }

    private static var snapshotURL: URL {
        sharedDirectoryURL.appendingPathComponent(snapshotFileName)
    }

    private static var deltasURL: URL {
        sharedDirectoryURL.appendingPathComponent(deltasFileName)
    }

    // MARK: - Snapshot Read / Write

    static func loadSnapshot() -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: snapshotURL) else {
            return .empty()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else {
            return .empty()
        }
        return snapshot
    }

    static func saveSnapshot(_ snapshot: WidgetSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    // MARK: - Pending Deltas Queue (Widget -> Main App)

    static func loadPendingDeltas() -> [PendingWidgetDelta] {
        guard let data = try? Data(contentsOf: deltasURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PendingWidgetDelta].self, from: data)) ?? []
    }

    static func appendPendingDelta(_ delta: PendingWidgetDelta) {
        var existing = loadPendingDeltas()
        existing.append(delta)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(existing) {
            try? data.write(to: deltasURL, options: .atomic)
        }
    }

    static func takePendingDeltas() -> [PendingWidgetDelta] {
        let deltas = loadPendingDeltas()
        if !deltas.isEmpty {
            try? FileManager.default.removeItem(at: deltasURL)
        }
        return deltas
    }

    static func clearAllBridgeFiles() {
        try? FileManager.default.removeItem(at: snapshotURL)
        try? FileManager.default.removeItem(at: deltasURL)
    }

    // MARK: - Instant Interactive Toggle Mutation (Runs Inside Widget Extension)

    @discardableResult
    static func toggleHabitInSnapshot(habitID: String) -> WidgetSnapshot {
        var snapshot = loadSnapshot()
        let today = Date()
        let todayKey = todayDateKey(for: today)
        let todayMonIdx = mondayBasedDayIndex(for: today)
        let dayOfMonth = isoCalendar.component(.day, from: today)

        guard let index = snapshot.habits.firstIndex(where: { $0.id == habitID }) else {
            return snapshot
        }

        var item = snapshot.habits[index]
        let target = item.effectiveTarget
        let wasComplete = item.isCompletedToday
        let newValue: Double

        if item.trackingMode == "quantity" && item.kind != "quit" {
            let nextVal = floor(item.todayValue) + 1.0
            newValue = nextVal > target ? 0.0 : nextVal
        } else {
            newValue = wasComplete ? 0.0 : target
        }

        item.todayValue = newValue
        let newRatio = item.todayProgressRatio

        // Update Mon-Sun strip for today
        if item.last7Days.count == 7 && (0..<7).contains(todayMonIdx) {
            item.last7Days[todayMonIdx] = newRatio
        }
        item.currentMonthDays[dayOfMonth] = newRatio

        // Optimistically nudge streak
        if !wasComplete && item.isCompletedToday {
            item.streak = max(1, item.streak + 1)
        } else if wasComplete && !item.isCompletedToday {
            item.streak = max(0, item.streak - 1)
        }

        snapshot.habits[index] = item
        snapshot.todayKey = todayKey
        snapshot.updatedAt = Date()

        // Recompute pure Habits-only score optimistically
        if !snapshot.habits.isEmpty {
            let avg = snapshot.habits.reduce(0.0) { $0 + $1.todayProgressRatio } / Double(snapshot.habits.count)
            let computed = max(0, min(100, Int(round(avg * 100.0))))
            snapshot.todayScore = computed
            snapshot.habitsPercent = computed
            snapshot.habitsDone = snapshot.habits.filter(\.isCompletedToday).count
            snapshot.habitsTotal = snapshot.habits.count
            switch computed {
            case 90...100: snapshot.scoreHeadline = "Locked in."
            case 70...89: snapshot.scoreHeadline = "Dialed in."
            case 40...69: snapshot.scoreHeadline = "Building momentum."
            default: snapshot.scoreHeadline = "Let's start."
            }
        }

        saveSnapshot(snapshot)
        appendPendingDelta(
            PendingWidgetDelta(
                habitID: habitID,
                dayKey: todayKey,
                newValue: newValue,
                timestamp: Date()
            )
        )
        return snapshot
    }
}

// MARK: - Interactive Home Screen Widget Check-In Intent (iOS 17+)

struct ToggleHabitWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Habit Check-In"
    static var description = IntentDescription("Logs or toggles a DailyOS habit directly from the Home Screen widget.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Habit ID")
    var habitID: String

    init() {
        self.habitID = ""
    }

    init(habitID: String) {
        self.habitID = habitID
    }

    func perform() async throws -> some IntentResult {
        guard !habitID.isEmpty else { return .result() }
        _ = WidgetBridge.toggleHabitInSnapshot(habitID: habitID)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Shared Hex Color Helper (Safe for Extension)

extension Color {
    static func dailyHex(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: Double
        switch cleaned.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 0.376; g = 0.647; b = 0.980
        }
        return Color(red: r, green: g, blue: b)
    }
}
