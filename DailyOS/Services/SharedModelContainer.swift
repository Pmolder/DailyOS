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

        // Attempt 1: Open persistent v3 SQLite store
        if let opened = try? ModelContainer(for: schema, configurations: [persistentConfig]) {
            self.container = opened
            self.isUsingInMemoryFallback = false
            return
        }

        // Attempt 2: Delete stale/corrupted SQLite files (including -wal / -shm) and retry
        Self.removeStoreFiles(at: storeURL)
        if let recovered = try? ModelContainer(for: schema, configurations: [persistentConfig]) {
            self.container = recovered
            self.isUsingInMemoryFallback = false
            return
        }

        // Attempt 3: Guaranteed safe in-memory fallback (never fatalError on launch)
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

        // Final safeguard with default in-memory schema
        let fallbackSchema = Schema([AlarmItem.self, HabitItem.self, ManualFocusBlock.self, FocusCheckInLog.self])
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
