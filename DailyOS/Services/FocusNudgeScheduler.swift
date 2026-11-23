import Foundation
import UserNotifications

/// Exact Scheduled Timed Task Start Notification Scheduler:
/// Applies EXCLUSIVELY to scheduled timed tasks (`FocusTaskItem` with `startTime != nil`)
/// and imported Google/Apple Calendar events (NEVER for self-started Anytime / Quick Deep Work tasks):
/// 1. 5 min before start (`startTime - 300s`): `"In 5 min: [Task Title]"`
/// 2. 1 min before start (`startTime - 60s`): `"In 1 min: [Task Title]"`
/// 3. At start (`T+0s`) and every 20 seconds (`T+0s, +20s, +40s ... +280s`): `"Start now: [Task Title]"`
/// Dynamically capped at <= 40 total pending Focus start slots so iOS's 64-notification limit is never exceeded.
@MainActor
final class FocusNudgeScheduler {
    static let shared = FocusNudgeScheduler()

    static let idPrefix = "focus_nudge_"
    static let startNudgeType = "focus_start_nudge"
    static let pre5HeadsUpType = "focus_pre5_nudge"
    static let pre1HeadsUpType = "focus_pre1_nudge"

    private static let maxTotalScheduledSlots = 40
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

    // MARK: - Reschedule Upcoming Scheduled Task Start Notifications (Capped <= 40 Slots)

    func rescheduleUpcomingNudges(
        tasks: [FocusTaskItem],
        calendarBlocks: [FocusBlockDisplayItem]
    ) {
        let now = Date()
        let todayKey = HabitItem.dateKey(for: now)
        let acknowledged = acknowledgedTaskIDsByDay[todayKey] ?? []
        let linkedIDs = Set(tasks.compactMap(\.googleCalendarEventID).filter { !$0.isEmpty })
        let horizon = now.addingTimeInterval(24 * 3600)

        var entries: [TimedFocusEntry] = []

        // 1. Pre-scheduled timed FocusTaskItems ONLY (startTime != nil)
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

        // 2. Imported Google / Apple Calendar events
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

        let sorted = entries.sorted { $0.startDate < $1.startDate }

        center.getPendingNotificationRequests { [weak self] requests in
            let staleIDs = requests.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
            if !staleIDs.isEmpty {
                self?.center.removePendingNotificationRequests(withIdentifiers: staleIDs)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                var budgetRemaining = Self.maxTotalScheduledSlots
                for (entryIndex, entry) in sorted.enumerated() {
                    guard budgetRemaining > 0 else { break }
                    // Soonest task gets full 15-slot 20s burst (5 min); subsequent tasks get up to 8 slots within budget
                    let maxBurstSlots = (entryIndex == 0) ? 15 : 8
                    let used = self.scheduleStartSequence(
                        for: entry,
                        maxBurstSlots: maxBurstSlots,
                        slotBudget: budgetRemaining
                    )
                    budgetRemaining -= used
                }
            }
        }
    }

    @discardableResult
    private func scheduleStartSequence(
        for entry: TimedFocusEntry,
        maxBurstSlots: Int,
        slotBudget: Int
    ) -> Int {
        let now = Date()
        let safeID = sanitizeID(entry.taskID)
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm"
        let startHHmm = f.string(from: entry.startDate)
        let durationLabel = formatDuration(entry.durationMinutes)
        let locSuffix = entry.location.isEmpty ? "" : " • \(entry.location)"
        var scheduledCount = 0

        let baseUserInfo: [String: Any] = [
            "taskID": entry.taskID,
            "safeID": safeID,
            "taskTitle": entry.title,
            "location": entry.location,
            "startTs": entry.startDate.timeIntervalSince1970,
            "endTs": entry.endDate.timeIntervalSince1970,
            "requiresPhotoProof": entry.requiresPhotoProof
        ]

        // 1. 5 Minutes Before Start (`startTime - 300s`)
        if scheduledCount < slotBudget {
            let pre5Interval = entry.startDate.addingTimeInterval(-300).timeIntervalSince(now)
            if pre5Interval > 2.0 {
                let content = UNMutableNotificationContent()
                content.title = "In 5 min: \(entry.title)"
                content.body = "Starts at \(startHHmm) (\(durationLabel))\(locSuffix)."
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.threadIdentifier = "focus_start_\(safeID)"
                var info = baseUserInfo
                info["type"] = Self.pre5HeadsUpType
                content.userInfo = info

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: pre5Interval, repeats: false)
                let req = UNNotificationRequest(identifier: "\(Self.idPrefix)\(safeID)_pre5", content: content, trigger: trigger)
                center.add(req, withCompletionHandler: nil)
                scheduledCount += 1
            }
        }

        // 2. 1 Minute Before Start (`startTime - 60s`)
        if scheduledCount < slotBudget {
            let pre1Interval = entry.startDate.addingTimeInterval(-60).timeIntervalSince(now)
            if pre1Interval > 2.0 {
                let content = UNMutableNotificationContent()
                content.title = "In 1 min: \(entry.title)"
                content.body = "Get ready — \(entry.title) starts in 1 minute."
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.threadIdentifier = "focus_start_\(safeID)"
                var info = baseUserInfo
                info["type"] = Self.pre1HeadsUpType
                content.userInfo = info

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: pre1Interval, repeats: false)
                let req = UNNotificationRequest(identifier: "\(Self.idPrefix)\(safeID)_pre1", content: content, trigger: trigger)
                center.add(req, withCompletionHandler: nil)
                scheduledCount += 1
            }
        }

        // 3. At Start (`T = 0s`) and Every 20 Seconds After (`+0s, +20s, +40s ... +280s`)
        for burstIdx in 0..<maxBurstSlots {
            guard scheduledCount < slotBudget else { break }
            let fireDate = entry.startDate.addingTimeInterval(TimeInterval(burstIdx * 20))
            let interval = fireDate.timeIntervalSince(now)
            guard interval > 1.0, fireDate < entry.endDate else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Start now: \(entry.title)"
            content.body = "Your task has started — tap to open timer."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "focus_start_\(safeID)"
            var info = baseUserInfo
            info["type"] = Self.startNudgeType
            info["burstIndex"] = burstIdx
            content.userInfo = info

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let reqID = "\(Self.idPrefix)\(safeID)_s\(burstIdx)"
            let req = UNNotificationRequest(identifier: reqID, content: content, trigger: trigger)
            center.add(req, withCompletionHandler: nil)
            scheduledCount += 1
        }

        return scheduledCount
    }

    // MARK: - Self-Replacing 20-Second Delivery & Instant Tap Cleanup

    func handleDeliveredNudgeReplacement(userInfo: [AnyHashable: Any]) {
        guard (userInfo["type"] as? String) == Self.startNudgeType,
              let safeID = userInfo["safeID"] as? String,
              let burstIdx = userInfo["burstIndex"] as? Int,
              burstIdx > 0 else { return }

        let oldIDs = (0..<burstIdx).map { "\(Self.idPrefix)\(safeID)_s\($0)" }
        center.removeDeliveredNotifications(withIdentifiers: oldIDs)
    }

    @discardableResult
    func handleNotificationTap(userInfo: [AnyHashable: Any]) -> Bool {
        guard let type = userInfo["type"] as? String,
              (type == Self.startNudgeType || type == Self.pre5HeadsUpType || type == Self.pre1HeadsUpType),
              let taskID = userInfo["taskID"] as? String else {
            return false
        }

        acknowledgeAndClear(taskID: taskID)

        if let title = userInfo["taskTitle"] as? String,
           let startTs = userInfo["startTs"] as? Double,
           let endTs = userInfo["endTs"] as? Double {
            let loc = (userInfo["location"] as? String) ?? ""
            let proofOn = (userInfo["requiresPhotoProof"] as? Bool) ?? false
            FocusAutoSessionEngine.shared.focusOnScheduledBlock(
                taskID: taskID,
                title: title,
                cue: loc.isEmpty ? "" : "at \(loc)",
                startDate: Date(timeIntervalSince1970: startTs),
                endDate: Date(timeIntervalSince1970: endTs),
                requiresPhotoProof: proofOn,
                autoStartTracking: true,
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
