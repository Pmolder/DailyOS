import Foundation
import AVFoundation
import AudioToolbox
import Combine
import SwiftData

@MainActor
final class AlarmEngine: ObservableObject {
    static let shared = AlarmEngine()

    @Published private(set) var activeRingingAlarm: AlarmItem?
    @Published private(set) var isSilentKeepAliveRunning: Bool = false
    @Published private(set) var isUsingSynthEngineFallback: Bool = false
    @Published private(set) var nextScheduledAlarmDate: Date?
    @Published private(set) var armedAlarmCount: Int = 0

    private var silentPlayer: AVAudioPlayer?
    private var alarmFilePlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?

    private var synthAudioEngine: AVAudioEngine?
    private var synthSourceNode: AVAudioSourceNode?

    private var checkTimer: Timer?
    private var vibrationTimer: Timer?
    private var previewStopWorkItem: DispatchWorkItem?

    private init() {
        WavFileSynthesizer.ensureCustomSoundsInstalled()
        setupAudioSessionObservers()
        startMonitoringClock()
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

    /// Synchronizes background silent loop and notification burst schedule with current SwiftData alarms.
    func syncWithAlarms() {
        let alarms = SharedModelContainer.shared.fetchAlarms()
        let enabledAlarms = alarms.filter { $0.isEnabled }
        armedAlarmCount = enabledAlarms.count

        let now = Date()
        nextScheduledAlarmDate = enabledAlarms
            .compactMap { $0.nextTriggerDate(after: now) }
            .min()

        if activeRingingAlarm == nil {
            if !enabledAlarms.isEmpty {
                startSilentKeepAliveIfNeeded()
            } else {
                stopSilentKeepAlive()
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

        // Ensure silent loop stays alive if at least one alarm is enabled and none is ringing
        if activeRingingAlarm == nil {
            if !enabledAlarms.isEmpty {
                if !isSilentKeepAliveRunning || !(silentPlayer?.isPlaying ?? false) {
                    startSilentKeepAliveIfNeeded()
                }
            } else if isSilentKeepAliveRunning {
                stopSilentKeepAlive()
            }
        }

        // Do not trigger a second alarm while one is already actively ringing
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

    // MARK: - Silent Overnight Keep-Alive Loop

    private func startSilentKeepAliveIfNeeded() {
        guard activeRingingAlarm == nil else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            // .playback + .mixWithOthers keeps the app alive in the background overnight
            // without hijacking other audio apps or showing a Lock Screen media player widget.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if silentPlayer == nil {
                let silentWav = WavFileSynthesizer.makeSilentWavData(durationSeconds: 2.0)
                let player = try AVAudioPlayer(data: silentWav)
                player.numberOfLoops = -1
                player.volume = 0.01
                player.prepareToPlay()
                silentPlayer = player
            }

            if !(silentPlayer?.isPlaying ?? false) {
                silentPlayer?.play()
            }
            isSilentKeepAliveRunning = true
        } catch {
            print("[AlarmEngine] Failed to start silent keep-alive audio loop: \(error.localizedDescription)")
            isSilentKeepAliveRunning = false
        }
    }

    private func stopSilentKeepAlive() {
        silentPlayer?.stop()
        isSilentKeepAliveRunning = false
        if activeRingingAlarm == nil && previewPlayer == nil && synthAudioEngine == nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    // MARK: - Trigger & Ringing Audio (Mute Switch Override)

    func triggerAlarm(_ alarm: AlarmItem) {
        stopPreview()
        silentPlayer?.stop()
        isSilentKeepAliveRunning = false

        activeRingingAlarm = alarm

        // Remove pending/delivered fallback burst notifications for this alarm since in-app engine took over
        NotificationScheduler.shared.cancelAlarmBurstNotifications(for: alarm.id)

        startRingingAudio(for: alarm.tone)
        startVibrationLoop()
    }

    private func startRingingAudio(for tone: AlarmTone) {
        stopRingingAudioOnly()

        do {
            let session = AVAudioSession.sharedInstance()
            // Full .playback without .mixWithOthers bypasses the hardware Silent/Mute switch at full priority
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("[AlarmEngine] AudioSession activation error during alarm ring: \(error.localizedDescription)")
        }

        // 1. Check if a bundled .wav or .mp3 file exists in Bundle.main first (unless direct synth engine is selected)
        if let fileName = tone.bundledFileName {
            let nsName = fileName as NSString
            let base = nsName.deletingPathExtension
            let ext = nsName.pathExtension.isEmpty ? "wav" : nsName.pathExtension

            let bundledURL = Bundle.main.url(forResource: base, withExtension: ext)
                ?? Bundle.main.url(forResource: base, withExtension: "mp3")

            if let url = bundledURL,
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.numberOfLoops = -1
                player.volume = 1.0
                player.prepareToPlay()
                if player.play() {
                    alarmFilePlayer = player
                    isUsingSynthEngineFallback = false
                    return
                }
            }
        }

        // 2. Fallback (or direct selection): Real-time AVAudioEngine synthesized dual-frequency alarm siren
        startAVAudioEngineSynth(
            baseFrequency: tone.baseFrequency,
            secondaryFrequency: tone.secondaryFrequency,
            modulationRateHz: tone.modulationRateHz
        )
    }

    /// Synthesizes a loud, unmistakable multi-harmonic alarm tone in real time using `AVAudioEngine`
    /// so the project compiles and rings out-of-the-box with zero external `.wav`/`.mp3` dependencies.
    private func startAVAudioEngineSynth(
        baseFrequency: Double,
        secondaryFrequency: Double,
        modulationRateHz: Double
    ) {
        let engine = AVAudioEngine()
        let mainMixer = engine.mainMixerNode
        let outputFormat = mainMixer.outputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 44_100.0

        guard let sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            return
        }

        var carrierPhase: Double = 0.0
        var harmonicPhase: Double = 0.0
        var lfoPhase: Double = 0.0
        let twoPi = 2.0 * Double.pi

        let sourceNode = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for frame in 0..<Int(frameCount) {
                lfoPhase += twoPi * modulationRateHz / sampleRate
                if lfoPhase >= twoPi { lfoPhase -= twoPi }

                let lfoValue = sin(lfoPhase)
                let activeFrequency = lfoValue >= 0.0 ? baseFrequency : secondaryFrequency

                carrierPhase += twoPi * activeFrequency / sampleRate
                if carrierPhase >= twoPi { carrierPhase -= twoPi }

                harmonicPhase += twoPi * (activeFrequency * 2.0) / sampleRate
                if harmonicPhase >= twoPi { harmonicPhase -= twoPi }

                // Square-like rich harmonic wave + fundamental sine for maximum audibility
                let fundamental = sin(carrierPhase)
                let overtone = 0.45 * sin(harmonicPhase)
                let squareComponent: Double = fundamental >= 0.0 ? 0.35 : -0.35
                let combined = Float(max(-0.95, min(0.95, (fundamental + overtone + squareComponent) * 0.55)))

                for buffer in ablPointer {
                    let samples = UnsafeMutableBufferPointer<Float>(buffer)
                    if frame < samples.count {
                        samples[frame] = combined
                    }
                }
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: mainMixer, format: sourceFormat)
        mainMixer.outputVolume = 1.0

        do {
            try engine.start()
            synthAudioEngine = engine
            synthSourceNode = sourceNode
            isUsingSynthEngineFallback = true
        } catch {
            print("[AlarmEngine] AVAudioEngine failed to start synth tone: \(error.localizedDescription)")
        }
    }

    private func startVibrationLoop() {
        vibrationTimer?.invalidate()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        let timer = Timer(timeInterval: 1.6, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        RunLoop.main.add(timer, forMode: .common)
        vibrationTimer = timer
    }

    private func stopRingingAudioOnly() {
        alarmFilePlayer?.stop()
        alarmFilePlayer = nil

        if let engine = synthAudioEngine {
            engine.stop()
            if let node = synthSourceNode {
                engine.detach(node)
            }
        }
        synthAudioEngine = nil
        synthSourceNode = nil
        isUsingSynthEngineFallback = false
    }

    // MARK: - Dismissal & Snooze

    func dismissActiveAlarm() {
        stopRingingAudioOnly()
        vibrationTimer?.invalidate()
        vibrationTimer = nil

        if let current = activeRingingAlarm {
            NotificationScheduler.shared.cancelAlarmBurstNotifications(for: current.id)
            if current.repeatDays.isEmpty {
                current.isEnabled = false
                SharedModelContainer.shared.save()
            }
        }

        activeRingingAlarm = nil
        syncWithAlarms()
    }

    // MARK: - Tone & Sound Previews for Editors

    func previewAlarmTone(_ tone: AlarmTone) {
        guard activeRingingAlarm == nil else { return }
        stopPreview()

        startRingingAudio(for: tone)

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.stopPreview()
            }
        }
        previewStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func previewNotificationSound(_ option: NotificationSoundOption) {
        guard activeRingingAlarm == nil else { return }
        stopPreview()

        let wavData = WavFileSynthesizer.makeArpeggioWavData(notesHz: option.notesHz, noteDuration: 0.20)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: wavData)
            player.volume = 0.9
            player.prepareToPlay()
            player.play()
            previewPlayer = player
        } catch {
            print("[AlarmEngine] Failed to preview notification sound: \(error.localizedDescription)")
        }
    }

    func stopPreview() {
        previewStopWorkItem?.cancel()
        previewStopWorkItem = nil
        previewPlayer?.stop()
        previewPlayer = nil

        if activeRingingAlarm == nil {
            stopRingingAudioOnly()
            syncWithAlarms()
        }
    }

    // MARK: - Audio Session Interruption Recovery

    private func setupAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeVal = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let typeVal, let type = AVAudioSession.InterruptionType(rawValue: typeVal) {
                    switch type {
                    case .began:
                        break
                    case .ended:
                        if let active = self.activeRingingAlarm {
                            self.startRingingAudio(for: active.tone)
                        } else {
                            self.syncWithAlarms()
                        }
                    @unknown default:
                        break
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let active = self.activeRingingAlarm {
                    self.startRingingAudio(for: active.tone)
                } else if self.armedAlarmCount > 0 {
                    self.startSilentKeepAliveIfNeeded()
                }
            }
        }
    }
}
