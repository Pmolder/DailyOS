import Foundation
import Combine

/// Persistent UserDefaults store tracking 1-tap completion state for imported Google Calendar
/// and Apple Calendar events across Day/Week Focus views, Today's Score, Widgets, and Notifications.
@MainActor
final class CalendarEventCompletionStore: ObservableObject {
    static let shared = CalendarEventCompletionStore()

    private static let completedMapKey = "com.patrik.dailyos.calendarEventCompletions"
    private static let completedDayKeyMapKey = "com.patrik.dailyos.calendarEventCompletionDayKeys"

    @Published private(set) var revision: Int = 0

    private init() {}

    /// Computes a stable persistence key for any imported calendar or Google Tasks display block.
    static func eventKey(for block: FocusBlockDisplayItem) -> String {
        if let remoteID = block.remoteEventID?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteID.isEmpty {
            return remoteID
        }
        if !block.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return block.id
        }
        return "\(block.title)_\(Int(block.startDate.timeIntervalSince1970))"
    }

    func isCompleted(eventKey: String) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: Self.completedMapKey) as? [String: Bool] ?? [:]
        return map[eventKey] ?? false
    }

    func isCompleted(_ block: FocusBlockDisplayItem) -> Bool {
        isCompleted(eventKey: Self.eventKey(for: block))
    }

    @discardableResult
    func toggle(eventKey: String, dayKey: String = HabitItem.dateKey()) -> Bool {
        let next = !isCompleted(eventKey: eventKey)
        setCompleted(eventKey: eventKey, next, dayKey: dayKey)
        return next
    }

    func setCompleted(eventKey: String, _ completed: Bool, dayKey: String = HabitItem.dateKey()) {
        var map = UserDefaults.standard.dictionary(forKey: Self.completedMapKey) as? [String: Bool] ?? [:]
        var dayMap = UserDefaults.standard.dictionary(forKey: Self.completedDayKeyMapKey) as? [String: String] ?? [:]

        if completed {
            map[eventKey] = true
            dayMap[eventKey] = dayKey
        } else {
            map.removeValue(forKey: eventKey)
            dayMap.removeValue(forKey: eventKey)
        }

        UserDefaults.standard.set(map, forKey: Self.completedMapKey)
        UserDefaults.standard.set(dayMap, forKey: Self.completedDayKeyMapKey)
        revision += 1

        // Immediately sync Home Screen widgets & live Evening Momentum notifications
        WidgetSyncCoordinator.syncSnapshotFromStore()
        Task {
            await DailyNotificationManager.shared.refreshScheduledNotifications()
        }
    }

    func completedCount(forDayKey dayKey: String) -> Int {
        let map = UserDefaults.standard.dictionary(forKey: Self.completedMapKey) as? [String: Bool] ?? [:]
        let dayMap = UserDefaults.standard.dictionary(forKey: Self.completedDayKeyMapKey) as? [String: String] ?? [:]
        return dayMap.reduce(0) { count, pair in
            if pair.value == dayKey && (map[pair.key] == true) {
                return count + 1
            }
            return count
        }
    }

    func clearAll() {
        UserDefaults.standard.removeObject(forKey: Self.completedMapKey)
        UserDefaults.standard.removeObject(forKey: Self.completedDayKeyMapKey)
        revision += 1
    }
}
