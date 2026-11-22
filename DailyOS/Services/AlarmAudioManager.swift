import Foundation
import AVFoundation
import AudioToolbox
import CoreHaptics
import UIKit
import Combine

/// Unified audio, haptics, and real-time hardware volume escalation engine.
/// Drives 4 exact hardware volume profiles via `SystemVolumeController` while keeping
/// `AVAudioPlayer.volume = 1.0` so hardware volume controls the real acoustic output:
/// 1. Wake Alarm: 0-30s vibration only (0%), 30-60s hardware 1%->15%, 60-90s hardware 15%->50% hold.
/// 2. Wake Challenge Inactivity Penalty: hardware 1%->50% over 15s.
/// 3. Focus Task Check-In Alarm (Normal): hardware 1%->22% over 120s (never >22%).
/// 4. Focus Task Check-In Alarm (Evasion Penalty): hardware 0%->22% over 10s (never >22%).
@MainActor
final class AlarmAudioManager: ObservableObject {
    static let shared = AlarmAudioManager()

    // MARK: - Published Telemetry

    @Published private(set) var isSilentKeepAliveRunning: Bool = false
    @Published private(set) var isWakeSirenActive: Bool = false
    @Published private(set) var isSirenSilencedForChallenge: Bool = false
    @Published private(set) var isPenaltyBlastActive: Bool = false
    @Published private(set) var isUsingSynthFallback: Bool = false
    @Published private(set) var wakeElapsedSeconds: TimeInterval = 0
    @Published private(set) var currentTargetVolumeFraction: Float = 0.0
    @Published private(set) var escalationPhaseLabel: String = "STANDBY"

    // Focus Task Check-In Alarm telemetry
    @Published private(set) var isFocusWarningActive: Bool = false
    @Published private(set) var isFocusWarningPaused: Bool = false
    @Published private(set) var isFocusEvasionPenalty: Bool = false
    @Published private(set) var focusWarningElapsedSeconds: TimeInterval = 0
    @Published private(set) var focusWarningVolumeFraction: Float = 0.0

    // MARK: - Private Audio & Haptic State

    private let volumeController = SystemVolumeController.shared

    private var silentPlayer: AVAudioPlayer?
    private var wakeFilePlayer: AVAudioPlayer?
    private var focusWarningPlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?
    private var completionChimePlayer: AVAudioPlayer?

    private var synthAudioEngine: AVAudioEngine?
    private var synthSourceNode: AVAudioSourceNode?

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var hapticEngine: CHHapticEngine?
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)

    private var wakeScheduleTimer: Timer?
    private var wakeHapticTimer: Timer?
    private var wakeStartDate: Date?
    private var wakePhaseIndex: Int = 0
    private var activeWakeTone: AlarmTone = .nuclearSiren

    private var focusMonitorTimer: Timer?
    private var focusHapticTimer: Timer?
    private var focusStartDate: Date?
    private var focusTargetDuration: TimeInterval = 120.0
    private var focusStartVolume: Float = 0.01

    private var previewStopWorkItem: DispatchWorkItem?

    private init() {
        WavFileSynthesizer.ensureCustomSoundsInstalled()
        prepareHapticEngine()
        setupAudioSessionObservers()
    }

    // MARK: - Idle Timer Control

    func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    // MARK: - CoreHaptics

    private func prepareHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = false
            engine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    try? self?.hapticEngine?.start()
                }
            }
            try engine.start()
            hapticEngine = engine
        } catch {
            print("[AlarmAudioManager] CoreHaptics init notice: \(error.localizedDescription)")
        }
    }

    private func triggerRhythmicHapticPulse(intensity: Float = 1.0) {
        heavyImpact.prepare()
        heavyImpact.impactOccurred(intensity: CGFloat(intensity))
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)

        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if hapticEngine == nil {
                prepareHapticEngine()
            }
            try hapticEngine?.start()
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.85)
            let strength = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
            let pulse1 = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [strength, sharpness],
                relativeTime: 0,
                duration: 0.35
            )
            let pulse2 = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [strength, sharpness],
                relativeTime: 0.45
            )
            let pattern = try CHHapticPattern(events: [pulse1, pulse2], parameters: [])
            let player = try hapticEngine?.makePlayer(with: pattern)
            try player?.start(atTime: 0)
        } catch {
            // Fallback already triggered via UIImpactFeedbackGenerator + SystemSound vibrate
        }
    }

    // MARK: - Overnight Silent Keep-Alive Loop

    func startSilentKeepAliveIfNeeded() {
        guard !isWakeSirenActive && !isFocusWarningActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
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
            setIdleTimerDisabled(true)
        } catch {
            print("[AlarmAudioManager] Silent keep-alive error: \(error.localizedDescription)")
            isSilentKeepAliveRunning = false
        }
    }

    func stopSilentKeepAlive(reEnableIdleTimer: Bool = true) {
        silentPlayer?.stop()
        isSilentKeepAliveRunning = false
        if reEnableIdleTimer && !isWakeSirenActive && !isFocusWarningActive {
            setIdleTimerDisabled(false)
        }
        if !isWakeSirenActive && !isFocusWarningActive && previewPlayer == nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    // MARK: - PROFILE 1: Wake Alarm (0-30s Vibration Only -> 30-60s 1%-15% -> 60-90s 15%-50%)

    func startWakeEscalation(tone: AlarmTone) {
        stopPreview()
        stopFocusWarning()

        activeWakeTone = tone
        isWakeSirenActive = true
        isSirenSilencedForChallenge = false
        isPenaltyBlastActive = false
        wakeElapsedSeconds = 0
        wakePhaseIndex = 0
        currentTargetVolumeFraction = 0.0
        escalationPhaseLabel = "PHASE 1 • VIBRATION ONLY (0:00–0:30)"
        wakeStartDate = Date()

        setIdleTimerDisabled(true)
        volumeController.ensureMountedInKeyWindow()
        volumeController.stopVolumeControl()
        stopWakeAudioOnly()

        // Keep audio session alive silently during 0-30s vibration-only phase
        startSilentKeepAliveForVibrationPhase()
        startWakeHapticLoop()

        wakeScheduleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickWakeEscalation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeScheduleTimer = timer
    }

    private func startSilentKeepAliveForVibrationPhase() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            if silentPlayer == nil {
                let silentWav = WavFileSynthesizer.makeSilentWavData(durationSeconds: 2.0)
                let player = try AVAudioPlayer(data: silentWav)
                player.numberOfLoops = -1
                player.volume = 0.01
                player.prepareToPlay()
                silentPlayer = player
            }
            silentPlayer?.play()
        } catch {
            print("[AlarmAudioManager] Vibration phase audio session error: \(error.localizedDescription)")
        }
    }

    private func tickWakeEscalation() {
        guard isWakeSirenActive else { return }

        if isSirenSilencedForChallenge {
            currentTargetVolumeFraction = 0.0
            return
        }

        if isPenaltyBlastActive {
            currentTargetVolumeFraction = volumeController.targetHardwareVolume
            let progress = min(1.0, max(0.0, currentTargetVolumeFraction / 0.50))
            applyWakePlayerGain(SystemVolumeController.logarithmicPlayerGain(normalizedProgress: progress, maxGain: 1.0))
            escalationPhaseLabel = "INACTIVITY PENALTY • RAMPING 1% → 50% (15s)"
            return
        }

        guard let startDate = wakeStartDate else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        wakeElapsedSeconds = elapsed

        if elapsed < 30.0 {
            // 0s – 30s: Vibration only, 0% audible alarm
            currentTargetVolumeFraction = 0.0
            escalationPhaseLabel = "PHASE 1 • VIBRATION ONLY (0:00–0:30)"
        } else if elapsed < 60.0 {
            // 30s – 60s: Hardware volume 1% (0.01) -> 15% (0.15) + logarithmic player gain
            if wakePhaseIndex < 1 {
                wakePhaseIndex = 1
                silentPlayer?.stop()
                activateOverridePlaybackSession()
                startWakeAudioSource(tone: activeWakeTone, initialGain: SystemVolumeController.logarithmicPlayerGain(normalizedProgress: 0.02, maxGain: 1.0))
                volumeController.startRamp(from: 0.01, to: 0.15, duration: 30.0)
            }
            currentTargetVolumeFraction = volumeController.targetHardwareVolume
            let progress = min(1.0, max(0.0, currentTargetVolumeFraction / 0.50))
            applyWakePlayerGain(SystemVolumeController.logarithmicPlayerGain(normalizedProgress: progress, maxGain: 1.0))
            escalationPhaseLabel = "PHASE 2 • HARDWARE RAMP 1% → 15%"
        } else if elapsed < 90.0 {
            // 60s – 90s: Hardware volume 15% (0.15) -> 50% (0.50) + logarithmic player gain
            if wakePhaseIndex < 2 {
                wakePhaseIndex = 2
                if wakeFilePlayer == nil && synthAudioEngine == nil {
                    silentPlayer?.stop()
                    activateOverridePlaybackSession()
                    startWakeAudioSource(tone: activeWakeTone, initialGain: SystemVolumeController.logarithmicPlayerGain(normalizedProgress: 0.30, maxGain: 1.0))
                }
                volumeController.startRamp(from: 0.15, to: 0.50, duration: 30.0)
            }
            currentTargetVolumeFraction = volumeController.targetHardwareVolume
            let progress = min(1.0, max(0.0, currentTargetVolumeFraction / 0.50))
            applyWakePlayerGain(SystemVolumeController.logarithmicPlayerGain(normalizedProgress: progress, maxGain: 1.0))
            escalationPhaseLabel = "PHASE 3 • HARDWARE RAMP 15% → 50%"
        } else {
            // 90s+: Hold hardware volume at 50% (0.50) & full player gain with volume-button correction
            if wakePhaseIndex < 3 {
                wakePhaseIndex = 3
                volumeController.setLockedTargetVolume(0.50)
            }
            currentTargetVolumeFraction = 0.50
            applyWakePlayerGain(1.0)
            escalationPhaseLabel = "HOLDING HARDWARE VOLUME AT 50%"
        }
    }

    // MARK: - PROFILE 2: Wake Challenge Silence & 15s Inactivity Penalty (1% -> 50%)

    /// Immediately silences the alarm and releases volume lock when "Do Challenge" is tapped
    /// or immediately when a squat is completed after inactivity.
    func silenceWakeForChallenge() {
        guard isWakeSirenActive else { return }
        isSirenSilencedForChallenge = true
        isPenaltyBlastActive = false
        currentTargetVolumeFraction = 0.0
        escalationPhaseLabel = "CHALLENGE ACTIVE • ALARM SILENCED"

        stopWakeAudioOnly()
        silentPlayer?.stop()
        volumeController.stopVolumeControl()
        wakeHapticTimer?.invalidate()
        wakeHapticTimer = nil
    }

    /// Immediately resumes alarm sound and smoothly ramps hardware system volume + logarithmic player gain
    /// from 1% (0.01) to 50% (0.50) over 15 seconds with active hardware volume-button correction.
    func startWakeInactivityPenalty() {
        guard isWakeSirenActive else { return }
        isSirenSilencedForChallenge = false
        isPenaltyBlastActive = true
        escalationPhaseLabel = "INACTIVITY PENALTY • RAMPING 1% → 50% (15s)"

        silentPlayer?.stop()
        activateOverridePlaybackSession()
        let initialGain = SystemVolumeController.logarithmicPlayerGain(normalizedProgress: 0.02, maxGain: 1.0)
        startWakeAudioSource(tone: activeWakeTone, initialGain: initialGain)
        volumeController.startRamp(from: 0.01, to: 0.50, duration: 15.0)
        currentTargetVolumeFraction = volumeController.targetHardwareVolume
        startWakeHapticLoop()
    }

    /// Stops the wake alarm completely, plays completion chime + "Good morning", unlocks idle timer.
    func completeWakeMissionAndCelebrate() {
        stopWakeAudioOnly()
        silentPlayer?.stop()
        volumeController.stopVolumeControl()

        wakeScheduleTimer?.invalidate()
        wakeScheduleTimer = nil
        wakeHapticTimer?.invalidate()
        wakeHapticTimer = nil

        isWakeSirenActive = false
        isSirenSilencedForChallenge = false
        isPenaltyBlastActive = false
        wakeElapsedSeconds = 0
        wakePhaseIndex = 0
        currentTargetVolumeFraction = 0.0
        escalationPhaseLabel = "CHALLENGE COMPLETE"

        setIdleTimerDisabled(false)
        playGoodMorningChimeAndSpeech()
    }

    private func playGoodMorningChimeAndSpeech() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("[AlarmAudioManager] Speech session error: \(error.localizedDescription)")
        }

        if let chimeURL = WavFileSynthesizer.resolveSoundURL(fileName: "good_morning_chime.wav"),
           let chime = try? AVAudioPlayer(contentsOf: chimeURL) {
            chime.volume = 0.85
            chime.prepareToPlay()
            chime.play()
            completionChimePlayer = chime
        }

        let utterance = AVSpeechUtterance(string: "Good morning")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        utterance.volume = 1.0
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(utterance)
    }

    private func startWakeHapticLoop() {
        wakeHapticTimer?.invalidate()
        triggerRhythmicHapticPulse(intensity: 1.0)
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isWakeSirenActive, !self.isSirenSilencedForChallenge else { return }
                self.triggerRhythmicHapticPulse(intensity: 1.0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeHapticTimer = timer
    }

    private func applyWakePlayerGain(_ gain: Float) {
        let clamped = max(0.0, min(1.0, gain))
        wakeFilePlayer?.volume = clamped
        synthAudioEngine?.mainMixerNode.outputVolume = clamped
    }

    private func startWakeAudioSource(tone: AlarmTone, initialGain: Float) {
        stopWakeAudioOnly()

        if let fileName = tone.bundledFileName,
           let url = WavFileSynthesizer.resolveSoundURL(fileName: fileName),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.numberOfLoops = -1
            player.volume = max(0.0, min(1.0, initialGain))
            player.prepareToPlay()
            if player.play() {
                wakeFilePlayer = player
                isUsingSynthFallback = false
                return
            }
        }

        startAVAudioEngineNuclearSynth(
            baseFrequency: tone.baseFrequency,
            secondaryFrequency: tone.secondaryFrequency,
            modulationRateHz: tone.modulationRateHz,
            initialGain: initialGain
        )
    }

    private func stopWakeAudioOnly() {
        wakeFilePlayer?.stop()
        wakeFilePlayer = nil

        if let engine = synthAudioEngine {
            engine.stop()
            if let node = synthSourceNode {
                engine.detach(node)
            }
        }
        synthAudioEngine = nil
        synthSourceNode = nil
        isUsingSynthFallback = false
    }

    // MARK: - PROFILES 3 & 4: Focus / Task Check-In Alarm
    // Normal: 1% (0.01) -> 22% (0.22) over 120s
    // Evasion Penalty: 0% (0.00) -> 22% (0.22) over 10s

    func startFocusTaskAlarm(evasionPenalty: Bool) {
        guard !isWakeSirenActive else { return }
        stopPreview()
        silentPlayer?.stop()
        isSilentKeepAliveRunning = false

        isFocusWarningActive = true
        isFocusWarningPaused = false
        isFocusEvasionPenalty = evasionPenalty
        focusWarningElapsedSeconds = 0
        focusStartDate = Date()

        let startVol: Float = evasionPenalty ? 0.00 : 0.01
        let duration: TimeInterval = evasionPenalty ? 10.0 : 120.0
        focusStartVolume = startVol
        focusTargetDuration = duration
        focusWarningVolumeFraction = startVol

        setIdleTimerDisabled(true)
        activateOverridePlaybackSession()
        let initialProgress = startVol / 0.22
        startFocusAudioPlayer(initialGain: SystemVolumeController.logarithmicPlayerGain(normalizedProgress: initialProgress, maxGain: 0.75))
        volumeController.startRamp(from: startVol, to: 0.22, duration: duration)
        startFocusWarningTimers()
    }

    func pauseFocusWarningForPhotoProof() {
        guard isFocusWarningActive else { return }
        isFocusWarningPaused = true
        focusWarningPlayer?.pause()
        volumeController.stopVolumeControl()
        focusHapticTimer?.invalidate()
        focusHapticTimer = nil
    }

    func resumeFocusWarningAfterFailureOrTimeout(evasionPenalty: Bool) {
        guard !isWakeSirenActive else { return }
        startFocusTaskAlarm(evasionPenalty: evasionPenalty)
    }

    func stopFocusWarning() {
        focusMonitorTimer?.invalidate()
        focusMonitorTimer = nil
        focusHapticTimer?.invalidate()
        focusHapticTimer = nil
        focusWarningPlayer?.stop()
        focusWarningPlayer = nil
        focusStartDate = nil

        if !isWakeSirenActive {
            volumeController.stopVolumeControl()
        }

        isFocusWarningActive = false
        isFocusWarningPaused = false
        isFocusEvasionPenalty = false
        focusWarningElapsedSeconds = 0
        focusWarningVolumeFraction = 0.0

        if !isWakeSirenActive {
            AlarmEngine.shared.syncWithAlarms()
        }
    }

    private func startFocusAudioPlayer(initialGain: Float) {
        focusWarningPlayer?.stop()

        let wavData: Data
        if let url = WavFileSynthesizer.resolveSoundURL(fileName: "focus_warning.wav"),
           let fileData = try? Data(contentsOf: url) {
            wavData = fileData
        } else {
            wavData = WavFileSynthesizer.makeAlarmToneWavData(
                baseFreq: 698.46,
                secondaryFreq: 1046.5,
                modulationHz: 3.0,
                durationSeconds: 3.0
            )
        }

        if let player = try? AVAudioPlayer(data: wavData) {
            player.numberOfLoops = -1
            player.volume = max(0.0, min(1.0, initialGain))
            player.prepareToPlay()
            player.play()
            focusWarningPlayer = player
        }
    }

    private func startFocusWarningTimers() {
        focusMonitorTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isFocusWarningActive, !self.isFocusWarningPaused, let start = self.focusStartDate else { return }
                self.focusWarningElapsedSeconds = Date().timeIntervalSince(start)
                let currentTarget = min(0.22, self.volumeController.targetHardwareVolume)
                self.focusWarningVolumeFraction = currentTarget
                let progress = min(1.0, max(0.0, currentTarget / 0.22))
                self.focusWarningPlayer?.volume = SystemVolumeController.logarithmicPlayerGain(
                    normalizedProgress: progress,
                    maxGain: 0.75
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusMonitorTimer = timer

        focusHapticTimer?.invalidate()
        triggerRhythmicHapticPulse(intensity: 0.85)
        let hTimer = Timer(timeInterval: 1.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isFocusWarningActive, !self.isFocusWarningPaused else { return }
                self.triggerRhythmicHapticPulse(intensity: 0.85)
            }
        }
        RunLoop.main.add(hTimer, forMode: .common)
        focusHapticTimer = hTimer
    }

    // MARK: - AVAudioEngine Fallback Synth

    private func startAVAudioEngineNuclearSynth(
        baseFrequency: Double,
        secondaryFrequency: Double,
        modulationRateHz: Double,
        initialGain: Float
    ) {
        let engine = AVAudioEngine()
        let mainMixer = engine.mainMixerNode
        let outputFormat = mainMixer.outputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 44_100.0

        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return
        }

        var carrierPhase: Double = 0.0
        var tritonePhase: Double = 0.0
        var sweepPhase: Double = 0.0
        let twoPi = 2.0 * Double.pi
        let lowFreq = min(baseFrequency, secondaryFrequency)
        let highFreq = max(baseFrequency, secondaryFrequency)

        let sourceNode = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for frame in 0..<Int(frameCount) {
                sweepPhase += twoPi * (modulationRateHz * 0.25) / sampleRate
                if sweepPhase >= twoPi { sweepPhase -= twoPi }

                let sweep = 0.5 - 0.5 * cos(sweepPhase)
                let freq = lowFreq + (highFreq - lowFreq) * sweep

                carrierPhase += twoPi * freq / sampleRate
                if carrierPhase >= twoPi { carrierPhase -= twoPi }

                tritonePhase += twoPi * (freq * 1.4142) / sampleRate
                if tritonePhase >= twoPi { tritonePhase -= twoPi }

                let primary = sin(carrierPhase) + 0.5 * sin(2.0 * carrierPhase)
                let klaxon: Double = sin(tritonePhase) >= 0.0 ? 0.55 : -0.55
                let sampleVal = Float(max(-0.96, min(0.96, tanh((primary * 0.65 + klaxon * 0.55) * 1.35) * 0.92)))

                for buffer in ablPointer {
                    let samples = UnsafeMutableBufferPointer<Float>(buffer)
                    if frame < samples.count {
                        samples[frame] = sampleVal
                    }
                }
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: mainMixer, format: sourceFormat)
        mainMixer.outputVolume = max(0.0, min(1.0, initialGain))

        do {
            try engine.start()
            synthAudioEngine = engine
            synthSourceNode = sourceNode
            isUsingSynthFallback = true
        } catch {
            print("[AlarmAudioManager] AVAudioEngine synth start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Tone & Sound Previews

    func previewAlarmTone(_ tone: AlarmTone) {
        guard !isWakeSirenActive && !isFocusWarningActive else { return }
        stopPreview()

        activateOverridePlaybackSession()
        if let fileName = tone.bundledFileName,
           let url = WavFileSynthesizer.resolveSoundURL(fileName: fileName),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = 0.45
            player.prepareToPlay()
            player.play()
            previewPlayer = player
        }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.stopPreview()
            }
        }
        previewStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func previewNotificationSound(_ option: NotificationSoundOption) {
        guard !isWakeSirenActive && !isFocusWarningActive else { return }
        stopPreview()

        let wavData = WavFileSynthesizer.makeArpeggioWavData(notesHz: option.notesHz, noteDuration: 0.18)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: wavData)
            player.volume = 0.85
            player.prepareToPlay()
            player.play()
            previewPlayer = player
        } catch {
            print("[AlarmAudioManager] Preview sound failed: \(error.localizedDescription)")
        }
    }

    func stopPreview() {
        previewStopWorkItem?.cancel()
        previewStopWorkItem = nil
        previewPlayer?.stop()
        previewPlayer = nil
    }

    // MARK: - Session Activation & Interruption Recovery

    private func activateOverridePlaybackSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("[AlarmAudioManager] AudioSession override error: \(error.localizedDescription)")
        }
    }

    private func setupAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeVal = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let typeVal, let type = AVAudioSession.InterruptionType(rawValue: typeVal), type == .ended {
                    if self.isWakeSirenActive && !self.isSirenSilencedForChallenge {
                        self.activateOverridePlaybackSession()
                        self.wakeFilePlayer?.play()
                        if let engine = self.synthAudioEngine, !engine.isRunning {
                            try? engine.start()
                        }
                    } else if self.isFocusWarningActive && !self.isFocusWarningPaused {
                        self.activateOverridePlaybackSession()
                        self.focusWarningPlayer?.play()
                    } else if self.isSilentKeepAliveRunning {
                        self.startSilentKeepAliveIfNeeded()
                    }
                }
            }
        }
    }
}
