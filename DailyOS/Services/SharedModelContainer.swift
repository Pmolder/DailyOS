import Foundation
import SwiftData
import UIKit

@MainActor
final class SharedModelContainer {
    static let shared = SharedModelContainer()

    let container: ModelContainer

    private static let seededKey = "com.patrik.dailyos.didSeedInitialData.v2"
    static let registeredBarcodeKey = "com.patrik.dailyos.registeredTargetBarcode"
    static let registeredBarcodeLabelKey = "com.patrik.dailyos.registeredTargetBarcodeLabel"

    private init() {
        let schema = Schema([
            AlarmItem.self,
            HabitItem.self,
            ManualFocusBlock.self,
            FocusCheckInLog.self
        ])
        let configuration = ModelConfiguration(
            "DailyOSLocalStoreV2",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none
        )

        do {
            self.container = try ModelContainer(for: schema, configurations: [configuration])
            seedInitialDataIfNeeded()
        } catch {
            // Safe fallback recovery if an incompatible dev SQLite store exists
            let fallbackConfig = ModelConfiguration(
                "DailyOSLocalStoreRecovery",
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            do {
                self.container = try ModelContainer(for: schema, configurations: [fallbackConfig])
                seedInitialDataIfNeeded()
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

    // MARK: - Registered Target Barcode Storage

    var registeredBarcode: String {
        get {
            UserDefaults.standard.string(forKey: Self.registeredBarcodeKey) ?? "DAILYOS-WAKE-QR"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.registeredBarcodeKey)
        }
    }

    var registeredBarcodeLabel: String {
        get {
            UserDefaults.standard.string(forKey: Self.registeredBarcodeLabelKey) ?? "Bathroom Mirror QR"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.registeredBarcodeLabelKey)
        }
    }

    // MARK: - Photo Proof Disk Storage

    static var habitProofsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("HabitProofs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    static func savePhotoProofImage(_ image: UIImage, habitID: UUID, dateString: String) -> String? {
        guard let jpegData = image.jpegData(compressionQuality: 0.82) else { return nil }
        let fileName = "proof_\(habitID.uuidString)_\(dateString)_\(Int(Date().timeIntervalSince1970)).jpg"
        let fileURL = habitProofsDirectory.appendingPathComponent(fileName)
        do {
            try jpegData.write(to: fileURL, options: .atomic)
            return fileName
        } catch {
            print("[SharedModelContainer] Failed to write photo proof: \(error)")
            return nil
        }
    }

    static func loadPhotoProofImage(fileName: String) -> UIImage? {
        let fileURL = habitProofsDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Initial Seed Data

    private func seedInitialDataIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.seededKey) else { return }

        if fetchAlarms().isEmpty {
            let pushupWake = AlarmItem(
                label: "Weekday Nuclear Wake",
                hour: 7,
                minute: 0,
                isEnabled: true,
                repeatDays: [2, 3, 4, 5, 6],
                tone: .nuclearSiren,
                missionType: .pushups,
                repGoal: 15
            )
            let squatWake = AlarmItem(
                label: "Weekend Leg Wake",
                hour: 8,
                minute: 0,
                isEnabled: false,
                repeatDays: [1, 7],
                tone: .nuclearSiren,
                missionType: .squats,
                repGoal: 20
            )
            let qrWake = AlarmItem(
                label: "Bathroom Barcode Override",
                hour: 6,
                minute: 45,
                isEnabled: false,
                repeatDays: [2, 3, 4, 5, 6],
                tone: .digitalSiren,
                missionType: .qrBarcode,
                repGoal: 15
            )
            mainContext.insert(pushupWake)
            mainContext.insert(squatWake)
            mainContext.insert(qrWake)
        }

        if fetchHabits().isEmpty {
            let morningWater = HabitItem(
                title: "Hydrate 500ml Water",
                notes: "Immediately after wake mission",
                iconName: "drop.fill",
                timeOfDay: .morning,
                sortOrder: 0,
                reminderEnabled: true,
                reminderHour: 7,
                reminderMinute: 15
            )
            let morningSunlight = HabitItem(
                title: "10m Sunlight & Mobility",
                notes: "No phone scrolling before light exposure",
                iconName: "sun.max.fill",
                timeOfDay: .morning,
                sortOrder: 1,
                reminderEnabled: false,
                reminderHour: 7,
                reminderMinute: 30
            )
            let dayDeepWork = HabitItem(
                title: "Deep Work Block (90m)",
                notes: "Zero distractions during priority block",
                iconName: "brain.head.profile",
                timeOfDay: .day,
                sortOrder: 0,
                reminderEnabled: true,
                reminderHour: 13,
                reminderMinute: 0
            )
            let dayWorkout = HabitItem(
                title: "Strength / Cardio Training",
                notes: "Hit daily movement target",
                iconName: "figure.strengthtraining.traditional",
                timeOfDay: .day,
                sortOrder: 1,
                reminderEnabled: false,
                reminderHour: 17,
                reminderMinute: 30
            )
            let eveningRead = HabitItem(
                title: "Read 20 Pages",
                notes: "Wind down away from blue light",
                iconName: "book.fill",
                timeOfDay: .evening,
                sortOrder: 0,
                reminderEnabled: true,
                reminderHour: 21,
                reminderMinute: 30
            )
            let eveningPrep = HabitItem(
                title: "Arm Wake Alarm & Guided Access",
                notes: "Triple-click side button before sleep",
                iconName: "lock.shield.fill",
                timeOfDay: .evening,
                sortOrder: 1,
                reminderEnabled: true,
                reminderHour: 22,
                reminderMinute: 30
            )
            mainContext.insert(morningWater)
            mainContext.insert(morningSunlight)
            mainContext.insert(dayDeepWork)
            mainContext.insert(dayWorkout)
            mainContext.insert(eveningRead)
            mainContext.insert(eveningPrep)
        }

        save()
        UserDefaults.standard.set(true, forKey: Self.seededKey)
    }
}
