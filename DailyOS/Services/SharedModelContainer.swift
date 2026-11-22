import Foundation
import SwiftData

/// Local-only SwiftData container (`cloudKitDatabase: .none`).
/// Uses an explicit versioned store URL (`DailyOS_v3.sqlite`) with automatic stale-store
/// deletion + retry and a guaranteed in-memory fallback so schema changes NEVER fatalError() on launch.
@MainActor
final class SharedModelContainer {
    static let shared = SharedModelContainer()

    let container: ModelContainer
    let isUsingInMemoryFallback: Bool

    private init() {
        let schema = Schema([
            AlarmItem.self,
            HabitItem.self,
            HabitLog.self,
            ManualFocusBlock.self,
            FocusCheckInLog.self
        ])

        let storeURL = Self.persistentStoreURL()
        let persistentConfig = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )

        if let opened = try? ModelContainer(for: schema, configurations: [persistentConfig]) {
            self.container = opened
            self.isUsingInMemoryFallback = false
            return
        }

        Self.removeStoreFiles(at: storeURL)
        if let recovered = try? ModelContainer(for: schema, configurations: [persistentConfig]) {
            self.container = recovered
            self.isUsingInMemoryFallback = false
            return
        }

        let inMemoryConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        if let memContainer = try? ModelContainer(for: schema, configurations: [inMemoryConfig]) {
            self.container = memContainer
            self.isUsingInMemoryFallback = true
            return
        }

        let fallbackSchema = Schema([
            AlarmItem.self,
            HabitItem.self,
            HabitLog.self,
            ManualFocusBlock.self,
            FocusCheckInLog.self
        ])
        self.container = try! ModelContainer(
            for: fallbackSchema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        self.isUsingInMemoryFallback = true
    }

    private static func persistentStoreURL() -> URL {
        let fm = FileManager.default
        let baseDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if !fm.fileExists(atPath: baseDir.path) {
            try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }
        return baseDir.appendingPathComponent("DailyOS_v3.sqlite")
    }

    private static func removeStoreFiles(at storeURL: URL) {
        let fm = FileManager.default
        let candidates = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
        for file in candidates {
            if fm.fileExists(atPath: file.path) {
                try? fm.removeItem(at: file)
            }
        }
    }

    var mainContext: ModelContext {
        container.mainContext
    }

    func fetchAlarms() -> [AlarmItem] {
        let descriptor = FetchDescriptor<AlarmItem>(
            sortBy: [
                SortDescriptor(\.hour, order: .forward),
                SortDescriptor(\.minute, order: .forward)
            ]
        )
        return (try? mainContext.fetch(descriptor)) ?? []
    }

    func fetchHabits() -> [HabitItem] {
        let descriptor = FetchDescriptor<HabitItem>(
            sortBy: [
                SortDescriptor(\.sortOrder, order: .forward),
                SortDescriptor(\.createdAt, order: .forward)
            ]
        )
        return (try? mainContext.fetch(descriptor)) ?? []
    }

    func fetchHabitLogs(for habitID: UUID? = nil) -> [HabitLog] {
        let descriptor = FetchDescriptor<HabitLog>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let all = (try? mainContext.fetch(descriptor)) ?? []
        if let habitID {
            return all.filter { $0.habitID == habitID }
        }
        return all
    }

    /// Upserts a `HabitLog` for `(habit, date)` and synchronizes legacy `completedDateStrings`.
    func setHabitLog(
        for habit: HabitItem,
        on date: Date,
        value: Double,
        note: String? = nil,
        preserveExistingNote: Bool = true
    ) {
        let key = HabitItem.dateKey(for: date)
        let existingLogs = fetchHabitLogs(for: habit.id)
        if let existing = existingLogs.first(where: { $0.dayKey == key }) {
            existing.value = value
            if !preserveExistingNote || note != nil {
                existing.note = note
            }
            existing.updatedAt = Date()
        } else {
            let newLog = HabitLog(
                habitID: habit.id,
                dayKey: key,
                date: ISOWeekCalendar.current.startOfDay(for: date),
                value: value,
                note: note
            )
            mainContext.insert(newLog)
        }

        if value >= habit.effectiveDailyTarget {
            habit.markCompleted(on: date)
        } else {
            habit.markIncomplete(on: date)
        }
        save()
    }

    func updateHabitNote(for habit: HabitItem, on date: Date, note: String?) {
        let key = HabitItem.dateKey(for: date)
        let cleaned = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNote = (cleaned?.isEmpty == true) ? nil : cleaned

        let existingLogs = fetchHabitLogs(for: habit.id)
        if let existing = existingLogs.first(where: { $0.dayKey == key }) {
            existing.note = finalNote
            existing.updatedAt = Date()
        } else if let finalNote {
            let value: Double = habit.isCompleted(on: date) ? habit.effectiveDailyTarget : 0.0
            let newLog = HabitLog(
                habitID: habit.id,
                dayKey: key,
                date: ISOWeekCalendar.current.startOfDay(for: date),
                value: value,
                note: finalNote
            )
            mainContext.insert(newLog)
        }
        save()
    }

    func fetchManualFocusBlocks() -> [ManualFocusBlock] {
        let descriptor = FetchDescriptor<ManualFocusBlock>(
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        return (try? mainContext.fetch(descriptor)) ?? []
    }

    func fetchFocusCheckInLogs() -> [FocusCheckInLog] {
        let descriptor = FetchDescriptor<FocusCheckInLog>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? mainContext.fetch(descriptor)) ?? []
    }

    func save() {
        do {
            if mainContext.hasChanges {
                try mainContext.save()
            }
        } catch {
            print("[SharedModelContainer] Save error: \(error.localizedDescription)")
        }
    }
}
