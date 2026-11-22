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
        let habitLogs = store.fetchHabitLogs()
        let manualBlocks = store.fetchManualFocusBlocks()
        let checkInLogs = store.fetchFocusCheckInLogs()

        let payload = DailyOSBackupPayload(
            schemaVersion: 5,
            exportedAt: Date(),
            trackedAppleCalendarIDs: FocusAccountabilityManager.shared.trackedAppleCalendarIDs.sorted(),
            appleCalendarSyncEnabled: FocusAccountabilityManager.shared.appleCalendarSyncEnabled,
            googleCalendarSyncEnabled: GoogleAuthService.shared.syncGoogleCalendarEnabled,
            googleTasksSyncEnabled: GoogleAuthService.shared.syncGoogleTasksEnabled,
            offlineVisionFallbackEnabled: KeychainService.offlineVisionFallbackEnabled,
            registeredWakeQRCode: WakeQRStorage.registeredCode,
            defaultReflexThresholdMs: WakeQRStorage.defaultReflexThresholdMs,
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
                    stepsTimeLimitSeconds: $0.stepsTimeLimitSeconds,
                    qrGraceSeconds: $0.qrGraceSeconds,
                    brainGameModeRaw: $0.brainGameModeRaw,
                    reflexThresholdMs: $0.reflexThresholdMs,
                    createdAt: $0.createdAt
                )
            },
            habits: habits.map {
                HabitBackupDTO(
                    id: $0.id,
                    title: $0.title,
                    notes: $0.notes,
                    iconName: $0.iconName,
                    colorHex: $0.colorHex,
                    kindRaw: $0.kindRaw,
                    trackingModeRaw: $0.trackingModeRaw,
                    dailyTarget: $0.dailyTarget,
                    unitLabel: $0.unitLabel,
                    isArchived: $0.isArchived,
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
            habitLogs: habitLogs.map {
                HabitLogBackupDTO(
                    id: $0.id,
                    habitID: $0.habitID,
                    dayKey: $0.dayKey,
                    date: $0.date,
                    value: $0.value,
                    note: $0.note,
                    updatedAt: $0.updatedAt
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

        for alarm in store.fetchAlarms() { context.delete(alarm) }
        for habit in store.fetchHabits() { context.delete(habit) }
        for hlog in store.fetchHabitLogs() { context.delete(hlog) }
        for block in store.fetchManualFocusBlocks() { context.delete(block) }
        for log in store.fetchFocusCheckInLogs() { context.delete(log) }

        for dto in payload.alarms {
            let item = AlarmItem(
                id: dto.id,
                label: dto.label,
                hour: dto.hour,
                minute: dto.minute,
                isEnabled: dto.isEnabled,
                repeatDays: [],
                tone: AlarmTone(rawValue: dto.toneRaw) ?? .nuclearSiren,
                missionType: MissionType(rawValue: dto.missionTypeRaw) ?? .random,
                repGoal: dto.repGoal,
                stepGoal: dto.stepGoal,
                stepsTimeLimitSeconds: dto.stepsTimeLimitSeconds ?? 600,
                qrGraceSeconds: dto.qrGraceSeconds ?? 60,
                brainGameMode: BrainGameMode(rawValue: dto.brainGameModeRaw ?? "") ?? .random,
                reflexThresholdMs: dto.reflexThresholdMs ?? 260,
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
                colorHex: dto.colorHex ?? "#34D399",
                kind: HabitKind(rawValue: dto.kindRaw ?? "") ?? .build,
                trackingMode: HabitTrackingMode(rawValue: dto.trackingModeRaw ?? "") ?? .binary,
                dailyTarget: dto.dailyTarget ?? 1.0,
                unitLabel: dto.unitLabel ?? "",
                timeOfDay: HabitTimeOfDay(rawValue: dto.timeOfDayRaw) ?? .morning,
                sortOrder: dto.sortOrder,
                reminderEnabled: dto.reminderEnabled,
                reminderHour: dto.reminderHour,
                reminderMinute: dto.reminderMinute,
                repeatDays: [],
                soundOption: NotificationSoundOption(rawValue: dto.soundOptionRaw) ?? .chimeBell,
                isArchived: dto.isArchived ?? false,
                createdAt: dto.createdAt
            )
            item.repeatDaysRaw = dto.repeatDaysRaw
            item.completedDatesRaw = dto.completedDatesRaw
            context.insert(item)
        }

        for dto in (payload.habitLogs ?? []) {
            let log = HabitLog(
                id: dto.id,
                habitID: dto.habitID,
                dayKey: dto.dayKey,
                date: dto.date,
                value: dto.value,
                note: dto.note,
                updatedAt: dto.updatedAt
            )
            context.insert(log)
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

        if let qr = payload.registeredWakeQRCode {
            WakeQRStorage.registeredCode = qr
        }
        if let reflexMs = payload.defaultReflexThresholdMs {
            WakeQRStorage.defaultReflexThresholdMs = reflexMs
        }

        KeychainService.offlineVisionFallbackEnabled = payload.offlineVisionFallbackEnabled
        FocusAccountabilityManager.shared.restoreSettings(
            trackedAppleCalendarIDs: Set(payload.trackedAppleCalendarIDs),
            appleEnabled: payload.appleCalendarSyncEnabled,
            googleCalendarEnabled: payload.googleCalendarSyncEnabled,
            googleTasksEnabled: payload.googleTasksSyncEnabled
        )

        store.save()
        AlarmEngine.shared.syncWithAlarms()
        FocusAccountabilityManager.shared.refreshScheduleLocally()

        return "Restored \(payload.alarms.count) alarms, \(payload.habits.count) habits, \(payload.manualFocusBlocks.count) tasks, and \(payload.focusCheckInLogs.count) logs."
    }
}
