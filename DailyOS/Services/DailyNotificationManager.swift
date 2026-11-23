import Foundation
import UserNotifications
import Combine

// MARK: - Live Daily Progress Snapshot for Placeholder Resolution

struct DailyProgressMetrics {
    let done: Int
    let total: Int
    let left: Int
    let percent: Int
    let streak: Int
}

// MARK: - Curated Sample Template & Custom Notification Models

enum SampleNotificationID: String, CaseIterable, Codable, Identifiable {
    case eveningMomentum = "evening_momentum"
    case morningGameplan = "morning_gameplan"
    case middayPulse = "midday_pulse"
    case hydrationReset = "hydration_reset"
    case streakGuard = "streak_guard"

    var id: String { rawValue }
}

struct SampleNotificationConfig: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var bodyTemplate: String
    var hour: Int
    var minute: Int
    var isEnabled: Bool
    var staySilentWhenComplete: Bool = true
    var isAdaptiveEvening: Bool = false
    var requiresStreakGuard: Bool = false

    var formattedTime: String {
        String(format: "%02d:%02d", hour, minute)
    }

    static var defaults: [SampleNotificationConfig] {
        [
            SampleNotificationConfig(
                id: SampleNotificationID.eveningMomentum.rawValue,
                title: "Evening Momentum Check-In",
                bodyTemplate: "Adaptive 4-tier daily check-in based on your live Today's Score.",
                hour: 20,
                minute: 30,
                isEnabled: true,
                staySilentWhenComplete: true,
                isAdaptiveEvening: true,
                requiresStreakGuard: false
            ),
            SampleNotificationConfig(
                id: SampleNotificationID.morningGameplan.rawValue,
                title: "Morning Gameplan",
                bodyTemplate: "New day, 0% → 100%. You have {total} habits & tasks lined up today.",
                hour: 8,
                minute: 30,
                isEnabled: false
            ),
            SampleNotificationConfig(
                id: SampleNotificationID.middayPulse.rawValue,
                title: "Midday Pulse",
                bodyTemplate: "Halfway check: {percent}% done ({done}/{total}). One quick habit keeps momentum moving.",
                hour: 14,
                minute: 0,
                isEnabled: false
            ),
            SampleNotificationConfig(
                id: SampleNotificationID.hydrationReset.rawValue,
                title: "Hydration & Reset",
                bodyTemplate: "Quick reset: grab a glass of water and clear 1 small task.",
                hour: 15,
                minute: 30,
                isEnabled: false
            ),
            SampleNotificationConfig(
                id: SampleNotificationID.streakGuard.rawValue,
                title: "Streak Guard Alert",
                bodyTemplate: "Don't break your {streak}-day streak — {left} left tonight.",
                hour: 21,
                minute: 30,
                isEnabled: false,
                requiresStreakGuard: true
            )
        ]
    }
}

struct CustomDailyNotification: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var bodyTemplate: String
    var hour: Int
    var minute: Int
    var weekdays: Set<Int> // ISO weekday raw values (2=Mon ... 7=Sat, 1=Sun)
    var isEnabled: Bool = true

    var formattedTime: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

// MARK: - Adaptive Evening Momentum & Custom Notification Manager

@MainActor
final class DailyNotificationManager: ObservableObject {
    static let shared = DailyNotificationManager()

    static let requestIdentifierPrefix = "dailyos_studio_"
    private static let samplesKey = "com.patrik.dailyos.studio.sampleTemplates"
    private static let customKey = "com.patrik.dailyos.studio.customNotifications"

    @Published var sampleTemplates: [SampleNotificationConfig] = []
    @Published var customNotifications: [CustomDailyNotification] = []

    private let center = UNUserNotificationCenter.current()

    private init() {
        loadFromDefaults()
    }

    // MARK: - Persistence

    private func loadFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: Self.samplesKey),
           let decoded = try? JSONDecoder().decode([SampleNotificationConfig].self, from: data),
           !decoded.isEmpty {
            // Merge any newly added default templates cleanly
            var merged = decoded
            for def in SampleNotificationConfig.defaults where !merged.contains(where: { $0.id == def.id }) {
                merged.append(def)
            }
            sampleTemplates = merged
        } else {
            sampleTemplates = SampleNotificationConfig.defaults
        }

        if let data = UserDefaults.standard.data(forKey: Self.customKey),
           let decoded = try? JSONDecoder().decode([CustomDailyNotification].self, from: data) {
            customNotifications = decoded
        } else {
            customNotifications = []
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sampleTemplates) {
            UserDefaults.standard.set(data, forKey: Self.samplesKey)
        }
        if let data = try? JSONEncoder().encode(customNotifications) {
            UserDefaults.standard.set(data, forKey: Self.customKey)
        }
    }

    func resetToDefaults() {
        sampleTemplates = SampleNotificationConfig.defaults
        customNotifications = []
        persist()
        Task { await refreshScheduledNotifications() }
    }

    // MARK: - Mutations

    func updateSample(_ updated: SampleNotificationConfig) {
        if let idx = sampleTemplates.firstIndex(where: { $0.id == updated.id }) {
            sampleTemplates[idx] = updated
            persist()
            Task { await refreshScheduledNotifications() }
        }
    }

    func upsertCustom(_ item: CustomDailyNotification) {
        if let idx = customNotifications.firstIndex(where: { $0.id == item.id }) {
            customNotifications[idx] = item
        } else {
            customNotifications.append(item)
        }
        persist()
        Task { await refreshScheduledNotifications() }
    }

    func deleteCustom(id: UUID) {
        customNotifications.removeAll { $0.id == id }
        persist()
        Task { await refreshScheduledNotifications() }
    }

    // MARK: - Live Progress Metrics & Placeholder Engine

    func currentMetrics() -> DailyProgressMetrics {
        let store = SharedModelContainer.shared
        let habits = store.fetchHabits().filter { !$0.isArchived }
        let logs = store.fetchHabitLogs()
        let todayKey = HabitItem.dateKey(for: Date())
        let todayTasks = store.fetchFocusTasks(dayKey: todayKey)
        let score = HabitMetricsEngine.todayScoreSummary(habits: habits, allLogs: logs, todayTasks: todayTasks)

        let tasksCompleted = todayTasks.filter(\.isCompleted).count
        let tasksTotal = todayTasks.count

        let total = score.habitsTotal + tasksTotal
        let done = score.habitsCompleted + tasksCompleted
        let left = max(0, total - done)

        let percent: Int
        if total > 0 {
            percent = max(0, min(100, Int(round((Double(done) / Double(total)) * 100.0))))
        } else {
            percent = score.score
        }

        return DailyProgressMetrics(
            done: done,
            total: total,
            left: left,
            percent: percent,
            streak: score.globalStreak
        )
    }

    func resolvePlaceholders(_ template: String, metrics: DailyProgressMetrics? = nil) -> String {
        let m = metrics ?? currentMetrics()
        return template
            .replacingOccurrences(of: "{done}", with: "\(m.done)")
            .replacingOccurrences(of: "{total}", with: "\(m.total)")
            .replacingOccurrences(of: "{left}", with: "\(m.left)")
            .replacingOccurrences(of: "{percent}", with: "\(m.percent)")
            .replacingOccurrences(of: "{streak}", with: "\(m.streak)")
    }

    /// Adaptive 4-tier evening copy based on live daily progress.
    func adaptiveEveningBody(for config: SampleNotificationConfig, metrics: DailyProgressMetrics? = nil) -> String? {
        let m = metrics ?? currentMetrics()
        switch m.percent {
        case 100:
            if config.staySilentWhenComplete {
                return nil
            }
            return resolvePlaceholders("100% Locked In ({done}/{total}) — clean sweep today.", metrics: m)
        case 80...99:
            return resolvePlaceholders("🔥 {percent}% locked in — just {left} left to protect your {streak}-day streak before bed!", metrics: m)
        case 40...79:
            return resolvePlaceholders("{done}/{total} complete ({percent}%) — solid momentum. Knock out the last {left} tonight and finish strong!", metrics: m)
        default:
            return resolvePlaceholders("Today's Score: {percent}% ({done}/{total} done). You still have time tonight to knock out a couple quick wins and make today count.", metrics: m)
        }
    }

    func renderedPreview(for sample: SampleNotificationConfig) -> String {
        let m = currentMetrics()
        if sample.isAdaptiveEvening {
            return adaptiveEveningBody(for: sample, metrics: m)
                ?? "Silent tonight — 100% complete ({done}/{total}).".replacingOccurrences(of: "{done}", with: "\(m.done)").replacingOccurrences(of: "{total}", with: "\(m.total)")
        }
        return resolvePlaceholders(sample.bodyTemplate, metrics: m)
    }

    // MARK: - Scheduling & 3-Second Live Preview

    func sendTestPreview(title: String, bodyTemplate: String, isAdaptiveEvening: Bool = false, staySilentWhenComplete: Bool = false) async {
        _ = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
        let m = currentMetrics()
        let resolvedTitle = resolvePlaceholders(title.isEmpty ? "DailyOS" : title, metrics: m)
        let resolvedBody: String
        if isAdaptiveEvening {
            let temp = SampleNotificationConfig(
                id: "test",
                title: title,
                bodyTemplate: bodyTemplate,
                hour: 20,
                minute: 30,
                isEnabled: true,
                staySilentWhenComplete: false,
                isAdaptiveEvening: true
            )
            resolvedBody = adaptiveEveningBody(for: temp, metrics: m) ?? resolvePlaceholders(bodyTemplate, metrics: m)
        } else {
            resolvedBody = resolvePlaceholders(bodyTemplate, metrics: m)
        }

        let content = UNMutableNotificationContent()
        content.title = resolvedTitle
        content.body = resolvedBody
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(Self.requestIdentifierPrefix)preview_\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    /// Recomputes today's real metrics and refreshes all Daily Notification Studio requests cleanly.
    func refreshScheduledNotifications() async {
        let pending = await center.pendingNotificationRequests()
        let studioIDs = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.requestIdentifierPrefix) && !$0.contains("preview_") }
        if !studioIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: studioIDs)
        }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let metrics = currentMetrics()

        // 1. Sample Templates
        for sample in sampleTemplates where sample.isEnabled {
            if sample.requiresStreakGuard {
                guard metrics.streak >= 2 && metrics.left > 0 else { continue }
            }

            let resolvedBody: String
            if sample.isAdaptiveEvening {
                guard let body = adaptiveEveningBody(for: sample, metrics: metrics) else {
                    continue // Stay silent when 100% done
                }
                resolvedBody = body
            } else {
                resolvedBody = resolvePlaceholders(sample.bodyTemplate, metrics: metrics)
            }

            let content = UNMutableNotificationContent()
            content.title = resolvePlaceholders(sample.title, metrics: metrics)
            content.body = resolvedBody
            content.sound = .default
            content.interruptionLevel = .timeSensitive

            var comps = DateComponents()
            comps.calendar = ISOWeekCalendar.current
            comps.hour = sample.hour
            comps.minute = sample.minute

            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            let req = UNNotificationRequest(
                identifier: "\(Self.requestIdentifierPrefix)sample_\(sample.id)",
                content: content,
                trigger: trigger
            )
            try? await center.add(req)
        }

        // 2. Custom User Notifications
        for item in customNotifications where item.isEnabled {
            let content = UNMutableNotificationContent()
            content.title = resolvePlaceholders(item.title.isEmpty ? "DailyOS Reminder" : item.title, metrics: metrics)
            content.body = resolvePlaceholders(item.bodyTemplate, metrics: metrics)
            content.sound = .default
            content.interruptionLevel = .timeSensitive

            if item.weekdays.isEmpty || item.weekdays.count == 7 {
                var comps = DateComponents()
                comps.calendar = ISOWeekCalendar.current
                comps.hour = item.hour
                comps.minute = item.minute
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                let req = UNNotificationRequest(
                    identifier: "\(Self.requestIdentifierPrefix)custom_\(item.id.uuidString)_daily",
                    content: content,
                    trigger: trigger
                )
                try? await center.add(req)
            } else {
                for wd in item.weekdays.sorted() {
                    var comps = DateComponents()
                    comps.calendar = ISOWeekCalendar.current
                    comps.weekday = wd
                    comps.hour = item.hour
                    comps.minute = item.minute
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                    let req = UNNotificationRequest(
                        identifier: "\(Self.requestIdentifierPrefix)custom_\(item.id.uuidString)_w\(wd)",
                        content: content,
                        trigger: trigger
                    )
                    try? await center.add(req)
                }
            }
        }
    }
}
