import Foundation
import UserNotifications
import Combine
import UIKit

// MARK: - Configurable Smart Focus Photo Proof Settings (UserDefaults / @AppStorage)

enum PhotoProofSettings {
    static let initialMinutesKey = "dailyos.photoProof.initialPhotoMinutes"
    static let intervalMinutesKey = "dailyos.photoProof.photoIntervalMinutes"
    static let captureSecondsKey = "dailyos.photoProof.photoCaptureSeconds"

    static var initialPhotoMinutes: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: initialMinutesKey)
            return (1...10).contains(val) ? val : 2
        }
        set {
            UserDefaults.standard.set(max(1, min(10, newValue)), forKey: initialMinutesKey)
        }
    }

    static var photoIntervalMinutes: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: intervalMinutesKey)
            return (10...60).contains(val) ? val : 30
        }
        set {
            UserDefaults.standard.set(max(10, min(60, newValue)), forKey: intervalMinutesKey)
        }
    }

    static var photoCaptureSeconds: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: captureSecondsKey)
            return (15...120).contains(val) ? val : 30
        }
        set {
            UserDefaults.standard.set(max(15, min(120, newValue)), forKey: captureSecondsKey)
        }
    }
}

// MARK: - Imported Calendar Event Opt-In Store

enum CalendarPhotoProofStore {
    private static let storageKey = "com.patrik.dailyos.calendarPhotoProofOptInMap"

    static func stableKey(for block: FocusBlockDisplayItem) -> String {
        let ts = Int(block.startDate.timeIntervalSince1970)
        return "\(block.id)_\(ts)"
    }

    static func isEnabled(forKey key: String) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Bool] ?? [:]
        return map[key] ?? false
    }

    static func setEnabled(_ enabled: Bool, forKey key: String) {
        var map = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Bool] ?? [:]
        if enabled {
            map[key] = true
        } else {
            map.removeValue(forKey: key)
        }
        UserDefaults.standard.set(map, forKey: storageKey)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

// MARK: - Persistent Photo Proof Status & Weekly Log Store

enum PhotoProofStatus: String, Codable {
    case armed
    case verified
    case missed
}

struct PhotoProofTaskRecord: Codable {
    var verifiedCount: Int
    var missedCount: Int
    var lastStatus: PhotoProofStatus
    var lastDayKey: String
}

enum PhotoProofLogStore {
    private static let recordsKey = "com.patrik.dailyos.photoProofRecords"
    private static let dailyVerifiedCountsKey = "com.patrik.dailyos.photoProofDailyVerified"

    static func record(for taskID: String) -> PhotoProofTaskRecord? {
        loadAll()[taskID]
    }

    static func markArmed(taskID: String) {
        var all = loadAll()
        var existing = all[taskID] ?? PhotoProofTaskRecord(
            verifiedCount: 0,
            missedCount: 0,
            lastStatus: .armed,
            lastDayKey: HabitItem.dateKey()
        )
        if existing.verifiedCount == 0 && existing.missedCount == 0 {
            existing.lastStatus = .armed
        }
        existing.lastDayKey = HabitItem.dateKey()
        all[taskID] = existing
        saveAll(all)
    }

    static func recordVerified(taskID: String) {
        var all = loadAll()
        var existing = all[taskID] ?? PhotoProofTaskRecord(
            verifiedCount: 0,
            missedCount: 0,
            lastStatus: .verified,
            lastDayKey: HabitItem.dateKey()
        )
        existing.verifiedCount += 1
        existing.lastStatus = .verified
        existing.lastDayKey = HabitItem.dateKey()
        all[taskID] = existing
        saveAll(all)

        let todayKey = HabitItem.dateKey()
        var daily = UserDefaults.standard.dictionary(forKey: dailyVerifiedCountsKey) as? [String: Int] ?? [:]
        daily[todayKey] = (daily[todayKey] ?? 0) + 1
        UserDefaults.standard.set(daily, forKey: dailyVerifiedCountsKey)
    }

    static func recordMissed(taskID: String) {
        var all = loadAll()
        var existing = all[taskID] ?? PhotoProofTaskRecord(
            verifiedCount: 0,
            missedCount: 0,
            lastStatus: .missed,
            lastDayKey: HabitItem.dateKey()
        )
        existing.missedCount += 1
        existing.lastStatus = .missed
        existing.lastDayKey = HabitItem.dateKey()
        all[taskID] = existing
        saveAll(all)
    }

    static func clearRecord(for taskID: String) {
        var all = loadAll()
        all.removeValue(forKey: taskID)
        saveAll(all)
    }

    static func verifiedCount(forDayKeys keys: [String]) -> Int {
        let daily = UserDefaults.standard.dictionary(forKey: dailyVerifiedCountsKey) as? [String: Int] ?? [:]
        return keys.reduce(0) { $0 + (daily[$1] ?? 0) }
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: recordsKey)
        UserDefaults.standard.removeObject(forKey: dailyVerifiedCountsKey)
    }

    private static func loadAll() -> [String: PhotoProofTaskRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let decoded = try? JSONDecoder().decode([String: PhotoProofTaskRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveAll(_ map: [String: PhotoProofTaskRecord]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }
}

// MARK: - Active Photo Proof Capture Request

struct ActivePhotoProofRequest: Identifiable, Equatable {
    let id: String // checkInID
    let taskID: String
    let taskTitle: String
    let taskNotes: String
    let isInitialCheck: Bool
    let taskStart: Date
    let taskEnd: Date
    let deadline: Date
}

// MARK: - Smart Focus Photo Proof Scheduler (Exact 30s / 10s / Every-30s Backup Alerts + PiP Zero-Double-Alert Coordination)

@MainActor
final class PhotoProofScheduler: ObservableObject {
    static let shared = PhotoProofScheduler()

    static let identifierPrefix = "dailyos_photoproof_"
    static let notificationType = "smart_photo_proof"

    private struct ScheduledCheckIn {
        let checkInID: String
        let taskID: String
        let taskTitle: String
        let taskNotes: String
        let isInitialCheck: Bool
        let isRandomized: Bool
        let fireDate: Date
        let taskStart: Date
        let taskEnd: Date
        let captureSeconds: Int
    }

    @Published var activeCaptureRequest: ActivePhotoProofRequest? = nil
    @Published var logRevision: Int = 0

    var hasActiveCheckIn: Bool {
        activeCaptureRequest != nil
    }

    var activeCheckInRemainingSeconds: Int? {
        guard let req = activeCaptureRequest else { return nil }
        let secs = Int(ceil(req.deadline.timeIntervalSinceNow))
        return secs > 0 ? secs : 0
    }

    private let center = UNUserNotificationCenter.current()
    private var scheduledQueue: [ScheduledCheckIn] = []
    private var firedCheckInIDs: Set<String> = []
    private var suppressedBackupCheckInIDs: Set<String> = []
    private var tickCancellable: AnyCancellable?

    private init() {
        tickCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.evaluateScheduledCheckIns()
            }
    }

    // MARK: - PiP Pill Center Indicator (Non-Nil ONLY for Non-Randomized Fixed-Interval Check-Ins)

    func fixedIntervalMinutesUntilNextPhoto(for taskID: String) -> Int? {
        let now = Date()
        guard let next = scheduledQueue
            .filter({ $0.taskID == taskID && !$0.isRandomized && $0.fireDate > now })
            .sorted(by: { $0.fireDate < $1.fireDate })
            .first else {
            return nil
        }
        return max(1, Int(ceil(next.fireDate.timeIntervalSince(now) / 60.0)))
    }

    // MARK: - Automatic Notification Permission Check

    func ensureNotificationAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                self?.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }

    // MARK: - Schedule Opted-In Task (T0 + 2m Initial Check + Fixed Recurring OR Hidden Random Mid-Task Check)

    func scheduleProofs(
        taskID: String,
        taskTitle: String,
        taskNotes: String = "",
        taskStart: Date,
        durationMinutes: Int,
        triggerInitialImmediatelyIfNow: Bool = false
    ) {
        ensureNotificationAuthorization()
        cancelProofs(for: taskID)
        PhotoProofLogStore.markArmed(taskID: taskID)
        logRevision += 1

        let cleanTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Focus Task" : taskTitle
        let initialMins = PhotoProofSettings.initialPhotoMinutes
        let intervalMins = PhotoProofSettings.photoIntervalMinutes
        let captureSecs = PhotoProofSettings.photoCaptureSeconds
        let totalSecs = TimeInterval(max(5, durationMinutes) * 60)
        let now = Date()
        let effectiveStart = max(taskStart, now)
        let taskEnd = taskStart.addingTimeInterval(totalSecs)
        let effectiveEnd = max(taskEnd, now.addingTimeInterval(totalSecs))

        guard effectiveEnd > now.addingTimeInterval(35) else { return }

        let isLongFixedIntervalTask = durationMinutes >= intervalMins

        // 1. Initial Photo Check-In at T0 + initialPhotoMinutes (default 2 min after start)
        let initialCheckID = "init_\(UUID().uuidString.prefix(8))"
        let desiredInitialFire = effectiveStart.addingTimeInterval(TimeInterval(initialMins * 60))
        let maxAllowedInitial = effectiveEnd.addingTimeInterval(-TimeInterval(max(35, captureSecs)))
        let initialFireDate = min(desiredInitialFire, maxAllowedInitial)

        if initialFireDate > now.addingTimeInterval(2.0) {
            scheduleCheckIn(
                taskID: taskID,
                checkInID: initialCheckID,
                taskTitle: cleanTitle,
                taskNotes: taskNotes,
                isInitial: true,
                isRandomized: !isLongFixedIntervalTask,
                fireDate: initialFireDate,
                taskStart: effectiveStart,
                taskEnd: effectiveEnd,
                captureSeconds: captureSecs
            )
        } else if triggerInitialImmediatelyIfNow {
            activeCaptureRequest = ActivePhotoProofRequest(
                id: initialCheckID,
                taskID: taskID,
                taskTitle: cleanTitle,
                taskNotes: taskNotes,
                isInitialCheck: true,
                taskStart: effectiveStart,
                taskEnd: effectiveEnd,
                deadline: now.addingTimeInterval(TimeInterval(captureSecs))
            )
        }

        // 2. Follow-Up Spot-Checks: Long Fixed-Interval vs Short Hidden Random
        if isLongFixedIntervalTask {
            scheduleRecurringChecks(
                taskID: taskID,
                taskTitle: cleanTitle,
                taskNotes: taskNotes,
                anchorDate: max(initialFireDate, now),
                taskStart: effectiveStart,
                taskEnd: effectiveEnd,
                intervalMinutes: intervalMins,
                captureSeconds: captureSecs
            )
        } else {
            // 1 Hidden Uniformly Random Mid-Task Spot-Check (never exposed on pill or UI)
            let earliest = initialFireDate.addingTimeInterval(60)
            let latest = effectiveEnd.addingTimeInterval(-TimeInterval(max(60, captureSecs)))

            let randomFireDate: Date
            if earliest < latest {
                let span = latest.timeIntervalSince(earliest)
                randomFireDate = earliest.addingTimeInterval(Double.random(in: 0...span))
            } else {
                let fraction = Double.random(in: 0.45...0.80)
                randomFireDate = effectiveStart.addingTimeInterval(effectiveEnd.timeIntervalSince(effectiveStart) * fraction)
            }

            if randomFireDate > initialFireDate.addingTimeInterval(30) && randomFireDate < effectiveEnd {
                scheduleCheckIn(
                    taskID: taskID,
                    checkInID: "spot_\(UUID().uuidString.prefix(8))",
                    taskTitle: cleanTitle,
                    taskNotes: taskNotes,
                    isInitial: false,
                    isRandomized: true,
                    fireDate: randomFireDate,
                    taskStart: effectiveStart,
                    taskEnd: effectiveEnd,
                    captureSeconds: captureSecs
                )
            }
        }
    }

    func handleInitialPhotoSubmitted(for request: ActivePhotoProofRequest) {
        let intervalMins = PhotoProofSettings.photoIntervalMinutes
        let captureSecs = PhotoProofSettings.photoCaptureSeconds
        let totalDurationMins = Int(round(request.taskEnd.timeIntervalSince(request.taskStart) / 60.0))

        guard request.isInitialCheck, totalDurationMins >= intervalMins else { return }

        cancelPendingCheckIns(forTaskID: request.taskID)
        scheduleRecurringChecks(
            taskID: request.taskID,
            taskTitle: request.taskTitle,
            taskNotes: request.taskNotes,
            anchorDate: Date(),
            taskStart: request.taskStart,
            taskEnd: request.taskEnd,
            intervalMinutes: intervalMins,
            captureSeconds: captureSecs
        )
    }

    private func scheduleRecurringChecks(
        taskID: String,
        taskTitle: String,
        taskNotes: String,
        anchorDate: Date,
        taskStart: Date,
        taskEnd: Date,
        intervalMinutes: Int,
        captureSeconds: Int
    ) {
        let step = TimeInterval(intervalMinutes * 60)
        var cursor = anchorDate.addingTimeInterval(step)
        let cutoff = taskEnd.addingTimeInterval(-120)
        var index = 1

        while cursor <= cutoff && index <= 8 {
            if cursor > Date().addingTimeInterval(10) {
                scheduleCheckIn(
                    taskID: taskID,
                    checkInID: "rec\(index)_\(UUID().uuidString.prefix(6))",
                    taskTitle: taskTitle,
                    taskNotes: taskNotes,
                    isInitial: false,
                    isRandomized: false,
                    fireDate: cursor,
                    taskStart: taskStart,
                    taskEnd: taskEnd,
                    captureSeconds: captureSeconds
                )
            }
            cursor = cursor.addingTimeInterval(step)
            index += 1
        }
    }

    // MARK: - Exact Backup Notification Schedule: -30s, -10s, and +0s/+30s/+60s/+90s/+120s/+150s

    private func scheduleCheckIn(
        taskID: String,
        checkInID: String,
        taskTitle: String,
        taskNotes: String,
        isInitial: Bool,
        isRandomized: Bool,
        fireDate: Date,
        taskStart: Date,
        taskEnd: Date,
        captureSeconds: Int
    ) {
        scheduledQueue.append(
            ScheduledCheckIn(
                checkInID: checkInID,
                taskID: taskID,
                taskTitle: taskTitle,
                taskNotes: taskNotes,
                isInitialCheck: isInitial,
                isRandomized: isRandomized,
                fireDate: fireDate,
                taskStart: taskStart,
                taskEnd: taskEnd,
                captureSeconds: captureSeconds
            )
        )

        let now = Date()
        // Extend backup tap window to cover the repeating +0s..+150s reminders if phone was locked
        let backupDeadline = fireDate.addingTimeInterval(TimeInterval(max(captureSeconds, 180)))
        let baseInfo: [String: Any] = [
            "type": Self.notificationType,
            "checkInID": checkInID,
            "taskID": taskID,
            "taskTitle": taskTitle,
            "taskNotes": taskNotes,
            "isInitialCheck": isInitial,
            "taskStartTimestamp": taskStart.timeIntervalSince1970,
            "taskEndTimestamp": taskEnd.timeIntervalSince1970,
            "deadlineTimestamp": backupDeadline.timeIntervalSince1970
        ]

        // 1. 30 Seconds Before (`T_capture - 30s`)
        let pre30Interval = fireDate.addingTimeInterval(-30).timeIntervalSince(now)
        if pre30Interval > 2.0 {
            let content = UNMutableNotificationContent()
            content.title = "Photo proof in 30s"
            content.body = "Get ready to snap a photo for \(taskTitle)."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "photo_proof_\(checkInID)"
            content.userInfo = baseInfo

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: pre30Interval, repeats: false)
            let id = "\(Self.identifierPrefix)\(taskID)_\(checkInID)_pre30"
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger), withCompletionHandler: nil)
        }

        // 2. 10 Seconds Before (`T_capture - 10s`)
        let pre10Interval = fireDate.addingTimeInterval(-10).timeIntervalSince(now)
        if pre10Interval > 2.0 {
            let content = UNMutableNotificationContent()
            content.title = "Photo proof in 10s"
            content.body = "Prepare to post your photo for \(taskTitle)."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "photo_proof_\(checkInID)"
            content.userInfo = baseInfo

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: pre10Interval, repeats: false)
            let id = "\(Self.identifierPrefix)\(taskID)_\(checkInID)_pre10"
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger), withCompletionHandler: nil)
        }

        // 3. At `T_capture` (`0s`) and Every 30 Seconds After (`+0s, +30s, +60s, +90s, +120s, +150s`)
        let repeatOffsets: [Double] = [0, 30, 60, 90, 120, 150]
        for (idx, offset) in repeatOffsets.enumerated() {
            let pulseDate = fireDate.addingTimeInterval(offset)
            let interval = pulseDate.timeIntervalSince(now)
            guard interval > 1.0, pulseDate < taskEnd else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Post picture now!"
            content.body = "Capture your photo proof for \(taskTitle)."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "photo_proof_\(checkInID)"
            content.userInfo = baseInfo

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let id = "\(Self.identifierPrefix)\(taskID)_\(checkInID)_p\(idx)"
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger), withCompletionHandler: nil)
        }
    }

    // MARK: - Live Heartbeat (Zero Double Alerts With Active PiP Pill + Immediate Foreground Capture)

    func evaluateScheduledCheckIns() {
        let now = Date()

        // Expire active capture request if its countdown runs out while PiP is showing RED alert
        if let active = activeCaptureRequest, active.deadline <= now {
            markMissedAndDismiss(active)
        }

        guard !scheduledQueue.isEmpty else { return }

        // If PiP pill is currently active and a check-in is within 40s, cancel its backup banners so ONLY the red vibrating pill alerts
        if FocusPiPManager.shared.isPiPActive {
            for item in scheduledQueue where !suppressedBackupCheckInIDs.contains(item.checkInID) {
                let untilFire = item.fireDate.timeIntervalSince(now)
                if untilFire <= 40.0 && untilFire > -5.0 {
                    suppressedBackupCheckInIDs.insert(item.checkInID)
                    cancelNotificationsForCheckIn(checkInID: item.checkInID)
                }
            }
        }

        // Drop stale items well past their window
        scheduledQueue.removeAll { item in
            item.fireDate.addingTimeInterval(TimeInterval(item.captureSeconds + 180)) <= now
        }

        guard activeCaptureRequest == nil else { return }

        if let idx = scheduledQueue.firstIndex(where: { $0.fireDate <= now && !firedCheckInIDs.contains($0.checkInID) }) {
            let item = scheduledQueue.remove(at: idx)
            firedCheckInIDs.insert(item.checkInID)

            // Cancel backup banners if DailyOS is foreground OR PiP pill is actively alerting in solid RED
            if FocusPiPManager.shared.isPiPActive || UIApplication.shared.applicationState == .active {
                cancelNotificationsForCheckIn(checkInID: item.checkInID)
            }

            activeCaptureRequest = ActivePhotoProofRequest(
                id: item.checkInID,
                taskID: item.taskID,
                taskTitle: item.taskTitle,
                taskNotes: item.taskNotes,
                isInitialCheck: item.isInitialCheck,
                taskStart: item.taskStart,
                taskEnd: item.taskEnd,
                deadline: now.addingTimeInterval(TimeInterval(item.captureSeconds))
            )
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }

    // MARK: - Notification Tap Deep-Link Handler

    @discardableResult
    func handleNotificationInteraction(userInfo: [AnyHashable: Any]) -> Bool {
        guard (userInfo["type"] as? String) == Self.notificationType,
              let checkInID = userInfo["checkInID"] as? String,
              let taskID = userInfo["taskID"] as? String,
              let taskTitle = userInfo["taskTitle"] as? String else {
            return false
        }

        firedCheckInIDs.insert(checkInID)
        scheduledQueue.removeAll { $0.checkInID == checkInID }
        cancelNotificationsForCheckIn(checkInID: checkInID)

        let taskNotes = (userInfo["taskNotes"] as? String) ?? ""
        let isInitial = (userInfo["isInitialCheck"] as? Bool) ?? false
        let startTs = (userInfo["taskStartTimestamp"] as? Double) ?? Date().timeIntervalSince1970
        let endTs = (userInfo["taskEndTimestamp"] as? Double) ?? Date().addingTimeInterval(1800).timeIntervalSince1970
        let captureSecs = PhotoProofSettings.photoCaptureSeconds
        let freshDeadline = Date().addingTimeInterval(TimeInterval(captureSecs))

        if activeCaptureRequest?.id != checkInID {
            activeCaptureRequest = ActivePhotoProofRequest(
                id: checkInID,
                taskID: taskID,
                taskTitle: taskTitle,
                taskNotes: taskNotes,
                isInitialCheck: isInitial,
                taskStart: Date(timeIntervalSince1970: startTs),
                taskEnd: Date(timeIntervalSince1970: endTs),
                deadline: freshDeadline
            )
        }
        return true
    }

    // MARK: - Clean Cancellation Helpers

    func cancelNotificationsForCheckIn(checkInID: String) {
        let marker = "_\(checkInID)_"
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.contains(marker) }
            if !ids.isEmpty {
                self?.center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
        center.getDeliveredNotifications { [weak self] notifications in
            let ids = notifications.map(\.request.identifier).filter { $0.contains(marker) }
            if !ids.isEmpty {
                self?.center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    func cancelProofs(for taskID: String) {
        scheduledQueue.removeAll { $0.taskID == taskID }
        cancelPendingCheckIns(forTaskID: taskID)
    }

    private func cancelPendingCheckIns(forTaskID taskID: String) {
        let prefix = "\(Self.identifierPrefix)\(taskID)_"
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

    func cancelAllProofs() {
        activeCaptureRequest = nil
        scheduledQueue.removeAll()
        firedCheckInIDs.removeAll()
        suppressedBackupCheckInIDs.removeAll()
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
            if !ids.isEmpty {
                self?.center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
        center.getDeliveredNotifications { [weak self] notifications in
            let ids = notifications.map(\.request.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
            if !ids.isEmpty {
                self?.center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    func markVerifiedAndDismiss(_ request: ActivePhotoProofRequest) {
        cancelNotificationsForCheckIn(checkInID: request.id)
        PhotoProofLogStore.recordVerified(taskID: request.taskID)
        logRevision += 1
        handleInitialPhotoSubmitted(for: request)
        activeCaptureRequest = nil
    }

    func markMissedAndDismiss(_ request: ActivePhotoProofRequest) {
        cancelNotificationsForCheckIn(checkInID: request.id)
        PhotoProofLogStore.recordMissed(taskID: request.taskID)
        logRevision += 1
        activeCaptureRequest = nil
    }
}
