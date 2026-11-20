import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - FileDocument Wrapper for .fileExporter

struct DailyOSBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var jsonData: Data

    init(jsonData: Data = Data()) {
        self.jsonData = jsonData
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.jsonData = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: jsonData)
    }
}

// MARK: - 1-Tap JSON Backup & Restore Service

@MainActor
enum BackupService {
    static func exportJSONData() throws -> Data {
        let store = SharedModelContainer.shared
        let alarms = store.fetchAlarms()
        let habits = store.fetchHabits()
        let manualBlocks = store.fetchManualFocusBlocks()
        let checkInLogs = store.fetchFocusCheckInLogs()

        let payload = DailyOSBackupPayload(
            schemaVersion: 2,
            exportedAt: Date(),
            registeredBarcode: store.registeredBarcode,
            registeredBarcodeLabel: store.registeredBarcodeLabel,
            trackedCalendarIDs: FocusAccountabilityManager.shared.trackedCalendarIDs.sorted(),
            focusCheckInIntervalMinutes: FocusAccountabilityManager.shared.checkInIntervalMinutes,
            offlineVisionFallbackEnabled: KeychainService.offlineVisionFallbackEnabled,
            alarms: alarms.map {
                AlarmBackupDTO(
                    id: $0.id,
                    label: $0.label,
                    hour: $0.hour,
                    minute: $0.minute,
                    isEnabled: $0.isEnabled,
                    repeatDaysRaw: $0.repeatDaysRaw,
                    toneRaw: $0.toneRaw,
                    missionTypeRaw: $0.missionTypeRaw,
                    repGoal: $0.repGoal,
                    stepGoal: $0.stepGoal,
                    mathDifficultyRaw: $0.mathDifficultyRaw,
                    mathProblemCount: $0.mathProblemCount,
                    customTargetBarcode: $0.customTargetBarcode,
                    createdAt: $0.createdAt
                )
            },
            habits: habits.map {
                HabitBackupDTO(
                    id: $0.id,
                    title: $0.title,
                    notes: $0.notes,
                    iconName: $0.iconName,
                    timeOfDayRaw: $0.timeOfDayRaw,
                    sortOrder: $0.sortOrder,
                    reminderEnabled: $0.reminderEnabled,
                    reminderHour: $0.reminderHour,
                    reminderMinute: $0.reminderMinute,
                    repeatDaysRaw: $0.repeatDaysRaw,
                    soundOptionRaw: $0.soundOptionRaw,
                    completedDatesRaw: $0.completedDatesRaw,
                    createdAt: $0.createdAt
                )
            },
            manualFocusBlocks: manualBlocks.map {
                ManualFocusBlockDTO(
                    id: $0.id,
                    title: $0.title,
                    notes: $0.notes,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isActive: $0.isActive,
                    createdAt: $0.createdAt
                )
            },
            focusCheckInLogs: checkInLogs.map {
                FocusCheckInLogDTO(
                    id: $0.id,
                    taskTitle: $0.taskTitle,
                    calendarSource: $0.calendarSource,
                    timestamp: $0.timestamp,
                    verified: $0.verified,
                    reason: $0.reason,
                    wasOfflineFallback: $0.wasOfflineFallback
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func exportJSONString() throws -> String {
        let data = try exportJSONData()
        guard let str = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "DailyOSBackup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode backup JSON as UTF-8."]
            )
        }
        return str
    }

    static func importJSONData(_ data: Data) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(DailyOSBackupPayload.self, from: data)

        let store = SharedModelContainer.shared
        let context = store.mainContext

        // Clear existing local records cleanly before restoring backup
        for alarm in store.fetchAlarms() {
            context.delete(alarm)
        }
        for habit in store.fetchHabits() {
            context.delete(habit)
        }
        for block in store.fetchManualFocusBlocks() {
            context.delete(block)
        }
        for log in store.fetchFocusCheckInLogs() {
            context.delete(log)
        }

        for dto in payload.alarms {
            let item = AlarmItem(
                id: dto.id,
                label: dto.label,
                hour: dto.hour,
                minute: dto.minute,
                isEnabled: dto.isEnabled,
                repeatDays: [],
                tone: AlarmTone(rawValue: dto.toneRaw) ?? .nuclearSiren,
                missionType: MissionType(rawValue: dto.missionTypeRaw) ?? .pushups,
                repGoal: dto.repGoal,
                stepGoal: dto.stepGoal,
                mathDifficulty: MathDifficulty(rawValue: dto.mathDifficultyRaw) ?? .medium,
                mathProblemCount: dto.mathProblemCount,
                customTargetBarcode: dto.customTargetBarcode,
                createdAt: dto.createdAt
            )
            item.repeatDaysRaw = dto.repeatDaysRaw
            context.insert(item)
        }

        for dto in payload.habits {
            let item = HabitItem(
                id: dto.id,
                title: dto.title,
                notes: dto.notes,
                iconName: dto.iconName,
                timeOfDay: HabitTimeOfDay(rawValue: dto.timeOfDayRaw) ?? .morning,
                sortOrder: dto.sortOrder,
                reminderEnabled: dto.reminderEnabled,
                reminderHour: dto.reminderHour,
                reminderMinute: dto.reminderMinute,
                repeatDays: [],
                soundOption: NotificationSoundOption(rawValue: dto.soundOptionRaw) ?? .chimeBell,
                createdAt: dto.createdAt
            )
            item.repeatDaysRaw = dto.repeatDaysRaw
            item.completedDatesRaw = dto.completedDatesRaw
            context.insert(item)
        }

        for dto in payload.manualFocusBlocks {
            let block = ManualFocusBlock(
                id: dto.id,
                title: dto.title,
                notes: dto.notes,
                startDate: dto.startDate,
                endDate: dto.endDate,
                isActive: dto.isActive,
                createdAt: dto.createdAt
            )
            context.insert(block)
        }

        for dto in payload.focusCheckInLogs {
            let log = FocusCheckInLog(
                id: dto.id,
                taskTitle: dto.taskTitle,
                calendarSource: dto.calendarSource,
                timestamp: dto.timestamp,
                verified: dto.verified,
                reason: dto.reason,
                wasOfflineFallback: dto.wasOfflineFallback
            )
            context.insert(log)
        }

        store.registeredBarcode = payload.registeredBarcode
        store.registeredBarcodeLabel = payload.registeredBarcodeLabel
        KeychainService.offlineVisionFallbackEnabled = payload.offlineVisionFallbackEnabled
        FocusAccountabilityManager.shared.restoreSettings(
            trackedCalendarIDs: Set(payload.trackedCalendarIDs),
            intervalMinutes: payload.focusCheckInIntervalMinutes
        )

        store.save()
        AlarmEngine.shared.syncWithAlarms()
        FocusAccountabilityManager.shared.refreshTodaySchedule()

        return "Restored \(payload.alarms.count) alarms, \(payload.habits.count) habits, \(payload.manualFocusBlocks.count) focus blocks, and \(payload.focusCheckInLogs.count) check-in logs."
    }
}
