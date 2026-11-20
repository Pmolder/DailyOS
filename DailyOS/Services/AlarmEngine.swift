import Foundation
import UIKit
import Combine
import SwiftData

/// Coordinates Wake alarms, Guided Access monitoring, clock ticking, and `AlarmAudioManager`.
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

    var isUsingSynthEngineFallback: Bool {
        audioManager.isUsingSynthFallback
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

        let calendar = Calendar.current
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

    // MARK: - Trigger, Mission Controls & Completion

    func triggerAlarm(_ alarm: AlarmItem) {
        activeRingingAlarm = alarm
        isAlarmRinging = true
        NotificationScheduler.shared.cancelAlarmBurstNotifications(for: alarm.id)
        audioManager.startWakeEscalation(tone: alarm.tone)
    }

    func pauseSirenForMission() {
        audioManager.pauseWakeSirenForMission()
    }

    func triggerPenaltyBlast() {
        audioManager.blastNuclearPenaltyFullVolume()
    }

    func dismissActiveAlarm() {
        if let current = activeRingingAlarm {
            NotificationScheduler.shared.cancelAlarmBurstNotifications(for: current.id)
            if current.repeatDays.isEmpty {
                current.isEnabled = false
                SharedModelContainer.shared.save()
            }
        }

        activeRingingAlarm = nil
        isAlarmRinging = false
        audioManager.completeWakeMissionAndCelebrate()

        // Reschedule pending notifications while keeping idle timer re-enabled after wake completion
        Task {
            await NotificationScheduler.shared.rescheduleAll()
        }
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
