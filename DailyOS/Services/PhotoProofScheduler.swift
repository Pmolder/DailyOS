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

// MARK: - Smart Focus Photo Proof & Random Spot-Check Scheduler (100% Reliable With or Without Gemini Key)

@MainActor
final class PhotoProofScheduler: ObservableObject {
    static let shared = PhotoProofScheduler()

    static let identifierPrefix = "dailyos_photoproof_"
    static let notificationType = "smart_photo_proof"

    private struct ScheduledForegroundCheckIn {
        let checkInID: String
        let taskID: String
        let taskTitle: String
        let taskNotes: String
        let isInitialCheck: Bool
        let fireDate: Date
        let taskStart: Date
        let taskEnd: Date
        let captureSeconds: Int
    }

    @Published var activeCaptureRequest: ActivePhotoProofRequest? = nil
    @Published var logRevision: Int = 0

    private let center = UNUserNotificationCenter.current()
    private var foregroundQueue: [ScheduledForegroundCheckIn] = []
    private var firedCheckInIDs: Set<String> = []
    private var foregroundTickCancellable: AnyCancellable?

    private init() {
        foregroundTickCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.evaluateForegroundCheckIns()
            }
    }

    // MARK: - Automatic Notification Permission Check

    func ensureNotificationAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                self?.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }

    // MARK: - Schedule Opted-In Task (Reliable T0 + 2 Min Initial Check + Recurring / Hidden Random Spot-Check)

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

        // 1. Initial Photo Check-In at T0 + initialPhotoMinutes (default 2 minutes after start)
        let initialCheckID = "init_\(UUID().uuidString.prefix(8))"
        let desiredInitialFire = effectiveStart.addingTimeInterval(TimeInterval(initialMins * 60))
        let maxAllowedInitial = effectiveEnd.addingTimeInterval(-TimeInterval(max(35, captureSecs)))
        let initialFireDate = min(desiredInitialFire, maxAllowedInitial)

        if initialFireDate > now.addingTimeInterval(2.0) {
            scheduleCheckInAlert(
                taskID: taskID,
                checkInID: initialCheckID,
                taskTitle: cleanTitle,
                taskNotes: taskNotes,
                isInitial: true,
                fireDate: initialFireDate,
                taskStart: effectiveStart,
                taskEnd: effectiveEnd,
                captureSeconds: captureSecs
            )
        } else if triggerInitialImmediatelyIfNow {
            let initialDeadline = now.addingTimeInterval(TimeInterval(captureSecs))
            activeCaptureRequest = ActivePhotoProofRequest(
                id: initialCheckID,
                taskID: taskID,
                taskTitle: cleanTitle,
                taskNotes: taskNotes,
                isInitialCheck: true,
                taskStart: effectiveStart,
                taskEnd: effectiveEnd,
                deadline: initialDeadline
            )
        }

        // 2. Follow-Up Spot-Checks: Long Task (>= interval) vs Short Task (< interval)
        if durationMinutes >= intervalMins {
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
            // Hidden Uniformly Random Mid-Task Spot-Check (never exposed in UI)
            let earliest = initialFireDate.addingTimeInterval(60)
            let latest = effectiveEnd.addingTimeInterval(-TimeInterval(max(60, captureSecs)))

            let randomFireDate: Date
            if earliest < latest {
                let span = latest.timeIntervalSince(earliest)
                let offset = Double.random(in: 0...span)
                randomFireDate = earliest.addingTimeInterval(offset)
            } else {
                let fraction = Double.random(in: 0.45...0.80)
                randomFireDate = effectiveStart.addingTimeInterval(effectiveEnd.timeIntervalSince(effectiveStart) * fraction)
            }

            if randomFireDate > initialFireDate.addingTimeInterval(30) && randomFireDate < effectiveEnd {
                scheduleCheckInAlert(
                    taskID: taskID,
                    checkInID: "spot_\(UUID().uuidString.prefix(8))",
                    taskTitle: cleanTitle,
                    taskNotes: taskNotes,
                    isInitial: false,
                    fireDate: randomFireDate,
                    taskStart: effectiveStart,
                    taskEnd: effectiveEnd,
                    captureSeconds: captureSecs
                )
            }
        }
    }

    /// Re-anchors recurring interval check-ins cleanly to `T_initial + photoIntervalMinutes` after Initial Photo is submitted.
    func handleInitialPhotoSubmitted(for request: ActivePhotoProofRequest) {
        let intervalMins = PhotoProofSettings.photoIntervalMinutes
        let captureSecs = PhotoProofSettings.photoCaptureSeconds
        let totalDurationMins = Int(round(request.taskEnd.timeIntervalSince(request.taskStart) / 60.0))

        guard request.isInitialCheck, totalDurationMins >= intervalMins else { return }

        cancelPendingCheckIns(forTaskID: request.taskID, keepOnlyCheckInID: nil)
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

        while cursor <= cutoff && index <= 12 {
            if cursor > Date().addingTimeInterval(10) {
                scheduleCheckInAlert(
                    taskID: taskID,
                    checkInID: "rec\(index)_\(UUID().uuidString.prefix(6))",
                    taskTitle: taskTitle,
                    taskNotes: taskNotes,
                    isInitial: false,
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

    // MARK: - Dual Trigger: Live Foreground Timer + 3-Pulse Time-Sensitive Notification Burst (T+0s, T+8s, T+16s)

    private func scheduleCheckInAlert(
        taskID: String,
        checkInID: String,
        taskTitle: String,
        taskNotes: String,
        isInitial: Bool,
        fireDate: Date,
        taskStart: Date,
        taskEnd: Date,
        captureSeconds: Int
    ) {
        // 1. Live foreground trigger so PhotoProofCaptureSheet pops up immediately if DailyOS is open
        foregroundQueue.append(
            ScheduledForegroundCheckIn(
                checkInID: checkInID,
                taskID: taskID,
                taskTitle: taskTitle,
                taskNotes: taskNotes,
                isInitialCheck: isInitial,
                fireDate: fireDate,
                taskStart: taskStart,
                taskEnd: taskEnd,
                captureSeconds: captureSeconds
            )
        )

        // 2. Time-Sensitive UNUserNotificationCenter burst (T+0s, T+8s, T+16s) for background/locked phone
        let deadline = fireDate.addingTimeInterval(TimeInterval(captureSeconds))
        let offsets: [Double] = [0.0, 8.0, 16.0]

        for (pulse, offset) in offsets.enumerated() {
            guard offset < Double(captureSeconds) - 2.0 else { continue }
            let pulseDate = fireDate.addingTimeInterval(offset)
            let intervalFromNow = pulseDate.timeIntervalSinceNow
            guard intervalFromNow > 1.0 else { continue }

            let secondsLeft = max(1, captureSeconds - Int(round(offset)))
            let content = UNMutableNotificationContent()
            content.title = "Photo Proof — \(secondsLeft)s Left"
            content.body = "Snap a quick photo for \"\(taskTitle)\" right now!"
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.userInfo = [
                "type": Self.notificationType,
                "checkInID": checkInID,
                "taskID": taskID,
                "taskTitle": taskTitle,
                "taskNotes": taskNotes,
                "isInitialCheck": isInitial,
                "taskStartTimestamp": taskStart.timeIntervalSince1970,
                "taskEndTimestamp": taskEnd.timeIntervalSince1970,
                "deadlineTimestamp": deadline.timeIntervalSince1970
            ]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: intervalFromNow, repeats: false)
            let identifier = "\(Self.identifierPrefix)\(taskID)_\(checkInID)_p\(pulse)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            center.add(request, withCompletionHandler: nil)
        }
    }

    func evaluateForegroundCheckIns() {
        guard !foregroundQueue.isEmpty else { return }
        let now = Date()

        // Drop expired items
        foregroundQueue.removeAll { item in
            let deadline = item.fireDate.addingTimeInterval(TimeInterval(item.captureSeconds))
            return deadline <= now
        }

        guard activeCaptureRequest == nil else { return }

        if let idx = foregroundQueue.firstIndex(where: { $0.fireDate <= now && !firedCheckInIDs.contains($0.checkInID) }) {
            let item = foregroundQueue.remove(at: idx)
            firedCheckInIDs.insert(item.checkInID)
            cancelBurst(checkInID: item.checkInID)

            let deadline = item.fireDate.addingTimeInterval(TimeInterval(item.captureSeconds))
            let remaining = max(10, Int(ceil(deadline.timeIntervalSince(now))))
            activeCaptureRequest = ActivePhotoProofRequest(
                id: item.checkInID,
                taskID: item.taskID,
                taskTitle: item.taskTitle,
                taskNotes: item.taskNotes,
                isInitialCheck: item.isInitialCheck,
                taskStart: item.taskStart,
                taskEnd: item.taskEnd,
                deadline: now.addingTimeInterval(TimeInterval(remaining))
            )
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }

    // MARK: - Notification Deep-Link & Foreground Handlers

    @discardableResult
    func handleNotificationInteraction(userInfo: [AnyHashable: Any]) -> Bool {
        guard (userInfo["type"] as? String) == Self.notificationType,
              let checkInID = userInfo["checkInID"] as? String,
              let taskID = userInfo["taskID"] as? String,
              let taskTitle = userInfo["taskTitle"] as? String else {
            return false
        }

        firedCheckInIDs.insert(checkInID)
        foregroundQueue.removeAll { $0.checkInID == checkInID }
        cancelBurst(checkInID: checkInID)

        let taskNotes = (userInfo["taskNotes"] as? String) ?? ""
        let isInitial = (userInfo["isInitialCheck"] as? Bool) ?? false
        let startTs = (userInfo["taskStartTimestamp"] as? Double) ?? Date().timeIntervalSince1970
        let endTs = (userInfo["taskEndTimestamp"] as? Double) ?? Date().addingTimeInterval(1800).timeIntervalSince1970
        let deadlineTs = (userInfo["deadlineTimestamp"] as? Double) ?? Date().addingTimeInterval(TimeInterval(PhotoProofSettings.photoCaptureSeconds)).timeIntervalSince1970
        let deadline = Date(timeIntervalSince1970: deadlineTs)

        if deadline <= Date() {
            PhotoProofLogStore.recordMissed(taskID: taskID)
            logRevision += 1
            return true
        }

        if activeCaptureRequest?.id != checkInID {
            activeCaptureRequest = ActivePhotoProofRequest(
                id: checkInID,
                taskID: taskID,
                taskTitle: taskTitle,
                taskNotes: taskNotes,
                isInitialCheck: isInitial,
                taskStart: Date(timeIntervalSince1970: startTs),
                taskEnd: Date(timeIntervalSince1970: endTs),
                deadline: deadline
            )
        }
        return true
    }

    // MARK: - Clean Cancellation Helpers

    func cancelBurst(checkInID: String) {
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.contains("_\(checkInID)_p") }
            if !ids.isEmpty {
                self?.center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    func cancelProofs(for taskID: String) {
        foregroundQueue.removeAll { $0.taskID == taskID }
        cancelPendingCheckIns(forTaskID: taskID, keepOnlyCheckInID: nil)
    }

    private func cancelPendingCheckIns(forTaskID taskID: String, keepOnlyCheckInID: String?) {
        let prefix = "\(Self.identifierPrefix)\(taskID)_"
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { id in
                guard id.hasPrefix(prefix) else { return false }
                if let keep = keepOnlyCheckInID, id.contains("_\(keep)_p") {
                    return false
                }
                return true
            }
            if !ids.isEmpty {
                self?.center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    func cancelAllProofs() {
        activeCaptureRequest = nil
        foregroundQueue.removeAll()
        firedCheckInIDs.removeAll()
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
            if !ids.isEmpty {
                self?.center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    func markVerifiedAndDismiss(_ request: ActivePhotoProofRequest) {
        cancelBurst(checkInID: request.id)
        PhotoProofLogStore.recordVerified(taskID: request.taskID)
        logRevision += 1
        handleInitialPhotoSubmitted(for: request)
        activeCaptureRequest = nil
    }

    func markMissedAndDismiss(_ request: ActivePhotoProofRequest) {
        cancelBurst(checkInID: request.id)
        PhotoProofLogStore.recordMissed(taskID: request.taskID)
        logRevision += 1
        activeCaptureRequest = nil
    }
}
