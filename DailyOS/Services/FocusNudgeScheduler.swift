import Foundation
import UserNotifications

/// Calm Focus Notification Scheduler (standard gentle vibration — NEVER loud sirens):
/// 1. 5-Minute Pre-Task Heads-Up (`startDate - 5m`)
/// 2. Start + 1-Minute Self-Replacing Check-In Loop (`T+0m` ... `T+5m`, 6 slots max per task)
///    grouped under one `threadIdentifier` with automatic removal of previous minute's banner.
@MainActor
final class FocusNudgeScheduler {
    static let shared = FocusNudgeScheduler()

    static let idPrefix = "focus_nudge_"
    static let startNudgeType = "focus_start_nudge"
    static let preHeadsUpType = "focus_pre5_nudge"

    private let center = UNUserNotificationCenter.current()
    private var acknowledgedTaskIDsByDay: [String: Set<String>] = [:]

    private init() {}

    struct TimedFocusEntry {
        let taskID: String
        let title: String
        let location: String
        let startDate: Date
        let endDate: Date
        let durationMinutes: Int
        let requiresPhotoProof: Bool
    }

    // MARK: - Reschedule Upcoming Calm Focus Nudges (Capped Safely Below 64 Queue Limit)

    func rescheduleUpcomingNudges(
        tasks: [FocusTaskItem],
        calendarBlocks: [FocusBlockDisplayItem]
    ) {
        let now = Date()
        let todayKey = HabitItem.dateKey(for: now)
        let acknowledged = acknowledgedTaskIDsByDay[todayKey] ?? []

        // Build unified upcoming timed entries (incomplete only, next 24h)
        let linkedIDs = Set(tasks.compactMap(\.googleCalendarEventID).filter { !$0.isEmpty })
        let horizon = now.addingTimeInterval(24 * 3600)

        var entries: [TimedFocusEntry] = []

        for task in tasks where !task.isCompleted {
            guard let start = task.startTime else { continue }
            let end = start.addingTimeInterval(TimeInterval(max(5, task.durationMinutes) * 60))
            guard end > now, start <= horizon else { continue }
            let id = task.id.uuidString
            guard !acknowledged.contains(id) else { continue }
            entries.append(
                TimedFocusEntry(
                    taskID: id,
                    title: task.title,
                    location: task.trimmedLocation,
                    startDate: start,
                    endDate: end,
                    durationMinutes: task.durationMinutes,
                    requiresPhotoProof: task.requiresPhotoProof
                )
            )
        }

        for block in calendarBlocks where !block.isAllDay {
            if let rID = block.remoteEventID, linkedIDs.contains(rID) { continue }
            let compKey = CalendarEventCompletionStore.eventKey(for: block)
            if CalendarEventCompletionStore.shared.isCompleted(eventKey: compKey) { continue }
            guard block.endDate > now, block.startDate <= horizon else { continue }
            guard !acknowledged.contains(block.id) else { continue }
            let calProofKey = CalendarPhotoProofStore.stableKey(for: block)
            entries.append(
                TimedFocusEntry(
                    taskID: block.id,
                    title: block.title,
                    location: block.trimmedLocation,
                    startDate: block.startDate,
                    endDate: block.endDate,
                    durationMinutes: max(5, Int(round(block.durationMinutes))),
                    requiresPhotoProof: CalendarPhotoProofStore.isEnabled(forKey: calProofKey)
                )
            )
        }

        // Sort chronologically and cap to top 3 upcoming blocks (3 * 7 = 21 max slots)
        let capped = Array(entries.sorted { $0.startDate < $1.startDate }.prefix(3))

        center.getPendingNotificationRequests { [weak self] requests in
            let staleIDs = requests.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
            if !staleIDs.isEmpty {
                self?.center.removePendingNotificationRequests(withIdentifiers: staleIDs)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                for entry in capped {
                    self.scheduleNudges(for: entry)
                }
            }
        }
    }

    private func scheduleNudges(for entry: TimedFocusEntry) {
        let now = Date()
        let safeID = sanitizeID(entry.taskID)
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm"
        let startHHmm = f.string(from: entry.startDate)
        let endHHmm = f.string(from: entry.endDate)
        let durationLabel = formatDuration(entry.durationMinutes)

        // 1. 5-Minute Pre-Task Heads-Up
        let pre5Date = entry.startDate.addingTimeInterval(-5 * 60)
        let pre5Interval = pre5Date.timeIntervalSince(now)
        if pre5Interval > 2.0 {
            let content = UNMutableNotificationContent()
            content.title = "⏳ In 5 min: \(entry.title)"
            if !entry.location.isEmpty {
                content.body = "Head to \(entry.location) & get ready to start at \(startHHmm)."
            } else {
                content.body = "Get ready to start at \(startHHmm) (\(durationLabel))."
            }
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "focus_start_\(safeID)"
            content.userInfo = [
                "type": Self.preHeadsUpType,
                "taskID": entry.taskID,
                "safeID": safeID,
                "taskTitle": entry.title
            ]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: pre5Interval, repeats: false)
            let req = UNNotificationRequest(identifier: "\(Self.idPrefix)\(safeID)_pre5", content: content, trigger: trigger)
            center.add(req, withCompletionHandler: nil)
        }

        // 2. Start + 1-Minute Self-Replacing Check-In Loop (T+0m ... T+5m, 6 slots)
        for minuteOffset in 0...5 {
            let fireDate = entry.startDate.addingTimeInterval(TimeInterval(minuteOffset * 60))
            let interval = fireDate.timeIntervalSince(now)
            guard interval > 1.0, fireDate < entry.endDate else { continue }

            let content = UNMutableNotificationContent()
            content.title = "⚡ Time to start: \(entry.title)"
            content.body = "Your \(startHHmm)–\(endHHmm) block just started — tap to open Focus & start tracking."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "focus_start_\(safeID)"
            content.userInfo = [
                "type": Self.startNudgeType,
                "taskID": entry.taskID,
                "safeID": safeID,
                "minuteIndex": minuteOffset,
                "taskTitle": entry.title,
                "location": entry.location,
                "startTs": entry.startDate.timeIntervalSince1970,
                "endTs": entry.endDate.timeIntervalSince1970
            ]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let reqID = "\(Self.idPrefix)\(safeID)_m\(minuteOffset)"
            let req = UNNotificationRequest(identifier: reqID, content: content, trigger: trigger)
            center.add(req, withCompletionHandler: nil)
        }
    }

    // MARK: - Self-Replacing Delivery & Instant Tap Cleanup

    /// Deletes previous minute's delivered banner when the new 1-minute nudge arrives so Notification Center stays clean.
    func handleDeliveredNudgeReplacement(userInfo: [AnyHashable: Any]) {
        guard (userInfo["type"] as? String) == Self.startNudgeType,
              let safeID = userInfo["safeID"] as? String,
              let minuteIndex = userInfo["minuteIndex"] as? Int,
              minuteIndex > 0 else { return }

        let oldIDs = (0..<minuteIndex).map { "\(Self.idPrefix)\(safeID)_m\($0)" }
        center.removeDeliveredNotifications(withIdentifiers: oldIDs)
    }

    /// Deep-links straight into FocusActiveTimerSheet and clears all remaining pending & delivered nudges for this task.
    @discardableResult
    func handleNotificationTap(userInfo: [AnyHashable: Any]) -> Bool {
        guard let type = userInfo["type"] as? String,
              (type == Self.startNudgeType || type == Self.preHeadsUpType),
              let taskID = userInfo["taskID"] as? String else {
            return false
        }

        acknowledgeAndClear(taskID: taskID)

        if let title = userInfo["taskTitle"] as? String,
           let startTs = userInfo["startTs"] as? Double,
           let endTs = userInfo["endTs"] as? Double {
            let loc = (userInfo["location"] as? String) ?? ""
            FocusAutoSessionEngine.shared.focusOnScheduledBlock(
                taskID: taskID,
                title: title,
                cue: loc.isEmpty ? "" : "at \(loc)",
                startDate: Date(timeIntervalSince1970: startTs),
                endDate: Date(timeIntervalSince1970: endTs),
                openTimerSheet: true
            )
        } else {
            FocusAutoSessionEngine.shared.shouldPresentTimerSheet = true
        }
        return true
    }

    func acknowledgeAndClear(taskID: String) {
        let todayKey = HabitItem.dateKey()
        var set = acknowledgedTaskIDsByDay[todayKey] ?? []
        set.insert(taskID)
        acknowledgedTaskIDsByDay[todayKey] = set

        let safeID = sanitizeID(taskID)
        let prefix = "\(Self.idPrefix)\(safeID)_"

        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty {
                self?.center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
        center.getDeliveredNotifications { [weak self] notifications in
            let ids = notifications.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty {
                self?.center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    func cancelAllNudges() {
        acknowledgedTaskIDsByDay.removeAll()
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
            if !ids.isEmpty {
                self?.center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
        center.getDeliveredNotifications { [weak self] notifications in
            let ids = notifications.map(\.request.identifier).filter { $0.hasPrefix(Self.idPrefix) }
            if !ids.isEmpty {
                self?.center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    private func sanitizeID(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let filtered = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(filtered.prefix(24))
    }

    private func formatDuration(_ mins: Int) -> String {
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        let r = mins % 60
        if r == 0 { return "\(h)h" }
        if r == 30 { return "\(h).5h" }
        return "\(h)h \(r)m"
    }
}
