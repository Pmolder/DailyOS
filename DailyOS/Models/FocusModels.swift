import Foundation
import SwiftData

// MARK: - SwiftData Manual Focus Block Model

@Model
final class ManualFocusBlock {
    var id: UUID
    var title: String
    var notes: String
    var startDate: Date
    var endDate: Date
    var isActive: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        startDate: Date = Date(),
        endDate: Date = Date().addingTimeInterval(60 * 60),
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = isActive
        self.createdAt = createdAt
    }

    func isOngoing(at date: Date = Date()) -> Bool {
        isActive && startDate <= date && endDate > date
    }
}

// MARK: - SwiftData Focus Check-In Log Model

@Model
final class FocusCheckInLog {
    var id: UUID
    var taskTitle: String
    var calendarSource: String
    var timestamp: Date
    var verified: Bool
    var reason: String
    var wasOfflineFallback: Bool

    init(
        id: UUID = UUID(),
        taskTitle: String,
        calendarSource: String,
        timestamp: Date = Date(),
        verified: Bool,
        reason: String,
        wasOfflineFallback: Bool = false
    ) {
        self.id = id
        self.taskTitle = taskTitle
        self.calendarSource = calendarSource
        self.timestamp = timestamp
        self.verified = verified
        self.reason = reason
        self.wasOfflineFallback = wasOfflineFallback
    }
}

// MARK: - Unified Focus Block Display Model (Calendar + Manual)

struct FocusBlockDisplayItem: Identifiable, Equatable {
    let id: String
    let title: String
    let notes: String
    let calendarTitle: String
    let startDate: Date
    let endDate: Date
    let isManual: Bool
    let manualBlockID: UUID?

    func isOngoing(at date: Date = Date()) -> Bool {
        startDate <= date && endDate > date
    }

    var timeRangeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"
    }
}

// MARK: - JSON Backup DTOs (SideStore Weekly Re-Install Protection)

struct DailyOSBackupPayload: Codable {
    var schemaVersion: Int = 2
    var exportedAt: Date = Date()
    var registeredBarcode: String
    var registeredBarcodeLabel: String
    var trackedCalendarIDs: [String]
    var focusCheckInIntervalMinutes: Int
    var offlineVisionFallbackEnabled: Bool
    var alarms: [AlarmBackupDTO]
    var habits: [HabitBackupDTO]
    var manualFocusBlocks: [ManualFocusBlockDTO]
    var focusCheckInLogs: [FocusCheckInLogDTO]
}

struct AlarmBackupDTO: Codable {
    var id: UUID
    var label: String
    var hour: Int
    var minute: Int
    var isEnabled: Bool
    var repeatDaysRaw: String
    var toneRaw: String
    var missionTypeRaw: String
    var repGoal: Int
    var stepGoal: Int
    var mathDifficultyRaw: String
    var mathProblemCount: Int
    var customTargetBarcode: String
    var createdAt: Date
}

struct HabitBackupDTO: Codable {
    var id: UUID
    var title: String
    var notes: String
    var iconName: String
    var timeOfDayRaw: String
    var sortOrder: Int
    var reminderEnabled: Bool
    var reminderHour: Int
    var reminderMinute: Int
    var repeatDaysRaw: String
    var soundOptionRaw: String
    var completedDatesRaw: String
    var createdAt: Date
}

struct ManualFocusBlockDTO: Codable {
    var id: UUID
    var title: String
    var notes: String
    var startDate: Date
    var endDate: Date
    var isActive: Bool
    var createdAt: Date
}

struct FocusCheckInLogDTO: Codable {
    var id: UUID
    var taskTitle: String
    var calendarSource: String
    var timestamp: Date
    var verified: Bool
    var reason: String
    var wasOfflineFallback: Bool
}
