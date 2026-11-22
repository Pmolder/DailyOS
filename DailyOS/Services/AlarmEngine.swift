import Foundation
import UIKit
import Combine
import SwiftData

/// Coordinates Wake alarms, Daily Randomization, Guided Access monitoring, clock ticking, and `AlarmAudioManager`.
@MainActor
final class AlarmEngine: ObservableObject {
    static let shared = AlarmEngine()

    @Published private(set) var activeRingingAlarm: AlarmItem?
    @Published private(set) var isAlarmRinging: Bool = false
    @Published private(set) var isGuidedAccessEnabled: Bool = UIAccessibility.isGuidedAccessEnabled
    @Published private(set) var nextScheduledAlarmDate: Date?
    @Published private(set) var armedAlarmCount: Int = 0

    let audioManager = AlarmAudioManager.shared

    var isSilentKeepAliveRunning: Bool {
        audioManager.isSilentKeepAliveRunning
    }

    private var checkTimer: Timer?
    private var guidedAccessObserver: NSObjectProtocol?

    private init() {
        WavFileSynthesizer.ensureCustomSoundsInstalled()
        isGuidedAccessEnabled = UIAccessibility.isGuidedAccessEnabled
        observeGuidedAccessStatus()
        startMonitoringClock()
    }

    // MARK: - Guided Access Monitoring

    private func observeGuidedAccessStatus() {
        guidedAccessObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.guidedAccessStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isGuidedAccessEnabled = UIAccessibility.isGuidedAccessEnabled
            }
        }
    }

    func refreshGuidedAccessStatus() {
        isGuidedAccessEnabled = UIAccessibility.isGuidedAccessEnabled
    }

    // MARK: - Clock Monitoring & Synchronization

    func startMonitoringClock() {
        checkTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAlarmsTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    func syncWithAlarms() {
        let alarms = SharedModelContainer.shared.fetchAlarms()
        let enabledAlarms = alarms.filter { $0.isEnabled }
        armedAlarmCount = enabledAlarms.count

        let now = Date()
        nextScheduledAlarmDate = enabledAlarms
            .compactMap { $0.nextTriggerDate(after: now) }
            .min()

        if !isAlarmRinging && !audioManager.isFocusWarningActive {
            if !enabledAlarms.isEmpty {
                audioManager.startSilentKeepAliveIfNeeded()
                audioManager.setIdleTimerDisabled(true)
            } else {
                audioManager.stopSilentKeepAlive(reEnableIdleTimer: true)
            }
        }

        Task {
            await NotificationScheduler.shared.rescheduleAll()
        }
    }

    private func evaluateAlarmsTick() {
        let alarms = SharedModelContainer.shared.fetchAlarms()
        let enabledAlarms = alarms.filter { $0.isEnabled }
        armedAlarmCount = enabledAlarms.count

        let now = Date()
        nextScheduledAlarmDate = enabledAlarms
            .compactMap { $0.nextTriggerDate(after: now) }
            .min()

        if !isAlarmRinging && !audioManager.isFocusWarningActive {
            if !enabledAlarms.isEmpty {
                if !audioManager.isSilentKeepAliveRunning {
                    audioManager.startSilentKeepAliveIfNeeded()
                }
            } else if audioManager.isSilentKeepAliveRunning {
                audioManager.stopSilentKeepAlive(reEnableIdleTimer: true)
            }
        }

        guard activeRingingAlarm == nil else { return }

        let calendar = ISOWeekCalendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        guard let year = comps.year,
              let month = comps.month,
              let day = comps.day,
              let hour = comps.hour,
              let minute = comps.minute,
              let weekday = comps.weekday else {
            return
        }

        let currentMinuteKey = String(format: "%04d-%02d-%02d-%02d-%02d", year, month, day, hour, minute)

        for alarm in enabledAlarms {
            guard alarm.hour == hour && alarm.minute == minute else { continue }
            guard alarm.lastTriggeredMinuteKey != currentMinuteKey else { continue }

            let activeDays = alarm.repeatDays
            if !activeDays.isEmpty && !activeDays.contains(weekday) {
                continue
            }

            alarm.lastTriggeredMinuteKey = currentMinuteKey
            SharedModelContainer.shared.save()
            triggerAlarm(alarm)
            break
        }
    }

    // MARK: - Trigger, Stateful Penalty Controls & Completion

    func triggerAlarm(_ alarm: AlarmItem) {
        activeRingingAlarm = alarm
        isAlarmRinging = true
        NotificationScheduler.shared.cancelAlarmBurstNotifications(for: alarm.id)
        audioManager.startWakeEscalation(tone: alarm.tone)
    }

    /// Launches a temporary non-persisted alarm to preview the Solar-Orange Wake UI & missions from Settings.
    func triggerTestWakeAlarm(
        mission: MissionType = .random,
        brainGame: BrainGameMode = .random
    ) {
        let nowComps = ISOWeekCalendar.current.dateComponents([.hour, .minute], from: Date())
        let previewAlarm = AlarmItem(
            label: "Wake Preview",
            hour: nowComps.hour ?? 7,
            minute: nowComps.minute ?? 0,
            isEnabled: false,
            repeatDays: [],
            tone: .nuclearSiren,
            missionType: mission,
            repGoal: 5,
            stepGoal: 50,
            stepsTimeLimitSeconds: 120,
            qrGraceSeconds: 45,
            brainGameMode: brainGame,
            reflexThresholdMs: WakeQRStorage.defaultReflexThresholdMs
        )
        triggerAlarm(previewAlarm)
    }

    @discardableResult
    func silenceForChallenge() -> Double {
        audioManager.pauseChallengePenaltyAndSaveProgress()
    }

    func startOrResumeInactivityPenalty() {
        audioManager.startOrResumeChallengePenaltyRamp()
    }

    /// Permanently stops all alarms & cancels fallback notifications upon winning Stage-1 + Stage-2
    /// while keeping the "WAKE COMPLETE" summary card visible until the user taps "START MY DAY".
    func finalizeWakeAudioAndNotifications() {
        HabitMetricsEngine.markWakeCompletedToday()
        if let current = activeRingingAlarm {
            NotificationScheduler.shared.cancelAlarmBurstNotifications(for: current.id)
            if current.repeatDays.isEmpty && current.isEnabled {
                current.isEnabled = false
                SharedModelContainer.shared.save()
            }
        }
        audioManager.completeWakeMissionAndCelebrate()
        Task {
            await NotificationScheduler.shared.rescheduleAll()
        }
    }

    func dismissActiveAlarm() {
        if audioManager.isWakeSirenActive {
            finalizeWakeAudioAndNotifications()
        }
        activeRingingAlarm = nil
        isAlarmRinging = false
    }

    // MARK: - Preview Forwarding

    func previewAlarmTone(_ tone: AlarmTone) {
        audioManager.previewAlarmTone(tone)
    }

    func previewNotificationSound(_ option: NotificationSoundOption) {
        audioManager.previewNotificationSound(option)
    }

    func stopPreview() {
        audioManager.stopPreview()
    }
}
