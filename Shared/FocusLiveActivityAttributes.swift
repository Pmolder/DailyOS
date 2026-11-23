import Foundation
import ActivityKit

/// Shared ActivityKit attributes for the DailyOS Deep Work Lock Screen Live Activity.
/// Compiled into BOTH `DailyOS` and `DailyOSWidgets` (zero extra App IDs or extensions).
struct FocusActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var startDate: Date
        var endDate: Date
        var isPaused: Bool
        var remainingSecondsWhenPaused: Int
    }

    var taskTitle: String
    var focusCue: String
    var accentHex: String
}
