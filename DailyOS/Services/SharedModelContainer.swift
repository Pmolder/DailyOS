import Foundation
import SwiftData
import UIKit

@MainActor
final class SharedModelContainer {
    static let shared = SharedModelContainer()

    let container: ModelContainer

    private static let seededKey = "com.patrik.dailyos.didSeedInitialData"
    static let registeredBarcodeKey = "com.patrik.dailyos.registeredTargetBarcode"
    static let registeredBarcodeLabelKey = "com.patrik.dailyos.registeredTargetBarcodeLabel"

    private init() {
        let schema = Schema([
            AlarmItem.self,
            HabitItem.self
        ])
        let configuration = ModelConfiguration(
            "DailyOSLocalStore",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none
        )

        do {
            self.container = try ModelContainer(for: schema, configurations: [configuration])
            seedInitialDataIfNeeded()
        } catch {
            fatalError("Failed to initialize local SwiftData ModelContainer: \(error.localizedDescription)")
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
                SortDescriptor(\.reminderHour, order: .forward),
                SortDescriptor(\.reminderMinute, order: .forward),
                SortDescriptor(\.createdAt, order: .forward)
            ]
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

        let existingAlarms = fetchAlarms()
        let existingHabits = fetchHabits()

        if existingAlarms.isEmpty {
            let weekdayMorning = AlarmItem(
                label: "Morning Wake Up",
                hour: 7,
                minute: 0,
                isEnabled: true,
                repeatDays: [2, 3, 4, 5, 6],
                tone: .classicPulse,
                missionType: .math,
                stepGoal: 50,
                mathDifficulty: .medium,
                mathProblemCount: 3
            )
            let workoutAlarm = AlarmItem(
                label: "Gym & Cardio Walk",
                hour: 6,
                minute: 30,
                isEnabled: false,
                repeatDays: [2, 4, 6],
                tone: .digitalSiren,
                missionType: .steps,
                stepGoal: 50,
                mathDifficulty: .easy,
                mathProblemCount: 3
            )
            let bathroomScanAlarm = AlarmItem(
                label: "No-Snooze Bathroom QR",
                hour: 7,
                minute: 15,
                isEnabled: false,
                repeatDays: [1, 7],
                tone: .radarChime,
                missionType: .qrBarcode,
                stepGoal: 50,
                mathDifficulty: .medium,
                mathProblemCount: 3
            )
            mainContext.insert(weekdayMorning)
            mainContext.insert(workoutAlarm)
            mainContext.insert(bathroomScanAlarm)
        }

        if existingHabits.isEmpty {
            let hydrateHabit = HabitItem(
                title: "Drink 500ml Water",
                notes: "Hydrate immediately after dismissing morning alarm",
                iconName: "drop.fill",
                reminderEnabled: true,
                reminderHour: 7,
                reminderMinute: 15,
                repeatDays: [1, 2, 3, 4, 5, 6, 7],
                soundOption: .chimeBell,
                requiresPhotoProof: false
            )
            let workoutHabit = HabitItem(
                title: "Daily Workout / Desk Setup",
                notes: "Take a live camera snapshot of workout or clean desk",
                iconName: "figure.strengthtraining.traditional",
                reminderEnabled: true,
                reminderHour: 18,
                reminderMinute: 0,
                repeatDays: [2, 3, 4, 5, 6],
                soundOption: .crispPing,
                requiresPhotoProof: true
            )
            let readingHabit = HabitItem(
                title: "Read 20 Pages",
                notes: "Evening deep reading session without screens",
                iconName: "book.fill",
                reminderEnabled: true,
                reminderHour: 21,
                reminderMinute: 30,
                repeatDays: [1, 2, 3, 4, 5, 6, 7],
                soundOption: .zenBowl,
                requiresPhotoProof: false
            )
            mainContext.insert(hydrateHabit)
            mainContext.insert(workoutHabit)
            mainContext.insert(readingHabit)
        }

        save()
        UserDefaults.standard.set(true, forKey: Self.seededKey)
    }
}
