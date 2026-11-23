import Foundation
import ActivityKit

/// Shared smart elapsed-of-total time formatter compiled into BOTH `DailyOS` and `DailyOSWidgets`.
/// - First 60s (`elapsed < 60`): `0:42 / 45m`
/// - Once >= 60s: calm minutes-only (`1m / 45m`, `35m / 45m`, `35m / 1h 30m`, `1h 05m / 1h 30m`)
enum FocusElapsedTimeFormatter {
    static func formatTotalDuration(minutes: Int) -> String {
        let totalMins = max(1, minutes)
        if totalMins < 60 {
            return "\(totalMins)m"
        }
        let h = totalMins / 60
        let r = totalMins % 60
        if r == 0 {
            return "\(h)h"
        }
        return "\(h)h \(r)m"
    }

    static func formatTotalDuration(seconds: Int) -> String {
        let totalMins = max(1, Int(round(Double(max(60, seconds)) / 60.0)))
        return formatTotalDuration(minutes: totalMins)
    }

    static func formatElapsed(seconds: Int) -> String {
        let clamped = max(0, seconds)
        if clamped < 60 {
            return String(format: "0:%02d", clamped)
        }
        let mins = clamped / 60
        if mins < 60 {
            return "\(mins)m"
        }
        let h = mins / 60
        let r = mins % 60
        return String(format: "%dh %02dm", h, r)
    }

    static func formatElapsedOfTotal(elapsedSeconds: Int, totalSeconds: Int) -> String {
        let safeTotal = max(60, totalSeconds)
        let clampedElapsed = max(0, min(safeTotal, elapsedSeconds))
        return "\(formatElapsed(seconds: clampedElapsed)) / \(formatTotalDuration(seconds: safeTotal))"
    }
}

/// Shared ActivityKit attributes for the DailyOS Deep Work Lock Screen Live Activity.
/// Compiled into BOTH `DailyOS` and `DailyOSWidgets` (zero extra App IDs or extensions).
struct FocusActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var startDate: Date
        var endDate: Date
        var isPaused: Bool
        var remainingSecondsWhenPaused: Int
        var totalDurationMinutes: Int
        var pausedAt: Date?

        init(
            startDate: Date,
            endDate: Date,
            isPaused: Bool,
            remainingSecondsWhenPaused: Int,
            totalDurationMinutes: Int = 45,
            pausedAt: Date? = nil
        ) {
            self.startDate = startDate
            self.endDate = endDate
            self.isPaused = isPaused
            self.remainingSecondsWhenPaused = remainingSecondsWhenPaused
            self.totalDurationMinutes = max(1, totalDurationMinutes)
            self.pausedAt = pausedAt
        }
    }

    var taskTitle: String
    var focusCue: String
    var accentHex: String
    var timeWindowLabel: String

    init(
        taskTitle: String,
        focusCue: String,
        accentHex: String = "#60A5FA",
        timeWindowLabel: String = "FOCUS SESSION"
    ) {
        self.taskTitle = taskTitle
        self.focusCue = focusCue
        self.accentHex = accentHex
        self.timeWindowLabel = timeWindowLabel
    }
}
