import Foundation
import SwiftData

/// Local-only SwiftData container (`cloudKitDatabase: .none`).
/// Fresh installs open 100% clean with 0 alarms, 0 habits, 0 focus blocks/tasks, and 0 pre-filled data.
@MainActor
final class SharedModelContainer {
    static let shared = SharedModelContainer()

    let container: ModelContainer

    private init() {
        let schema = Schema([
            AlarmItem.self,
            HabitItem.self,
            ManualFocusBlock.self,
            FocusCheckInLog.self
        ])
        let configuration = ModelConfiguration(
            "DailyOSLocalStoreV3",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none
        )

        do {
            self.container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            let recoveryConfig = ModelConfiguration(
                "DailyOSLocalStoreV3Recovery",
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            do {
                self.container = try ModelContainer(for: schema, configurations: [recoveryConfig])
            } catch {
                fatalError("Failed to initialize local SwiftData ModelContainer: \(error.localizedDescription)")
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
