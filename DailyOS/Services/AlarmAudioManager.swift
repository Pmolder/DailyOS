import Foundation
import AVFoundation
import AudioToolbox
import CoreHaptics
import UIKit
import Combine

/// Unified audio & haptics engine powering:
/// - Overnight silent `.playback + .mixWithOthers` keep-alive loop
/// - Exact 90-second Wake escalation curve (0-30s haptic only, 30-60s 0%->30%, 60-90s 30%->100%)
/// - Mission mute/pause & 100% nuclear penalty blast
/// - Good morning completion chime + AVSpeechSynthesizer
/// - Tab 3 Focus 2-minute escalating warning alarm (0%->50% over 120s)
@MainActor
final class AlarmAudioManager: ObservableObject {
    static let shared = AlarmAudioManager()

    // MARK: - Published Telemetry

    @Published private(set) var isSilentKeepAliveRunning: Bool = false
    @Published private(set) var isWakeSirenActive: Bool = false
    @Published private(set) var isSirenPausedForMission: Bool = false
    @Published private(set) var isPenaltyBlastActive: Bool = false
    @Published private(set) var isUsingSynthFallback: Bool = false
    @Published private(set) var wakeElapsedSeconds: TimeInterval = 0
    @Published private(set) var currentVolumeFraction: Float = 0.0
    @Published private(set) var escalationPhaseLabel: String = "STANDBY"

    // Focus 2-minute warning alarm telemetry
    @Published private(set) var isFocusWarningActive: Bool = false
    @Published private(set) var isFocusWarningPaused: Bool = false
    @Published private(set) var focusWarningElapsedSeconds: TimeInterval = 0
    @Published private(set) var focusWarningVolumeFraction: Float = 0.0

    // MARK: - Private Audio & Haptic State

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

    private var wakeRampTimer: Timer?
    private var wakeHapticTimer: Timer?
    private var wakeStartDate: Date?
    private var activeWakeTone: AlarmTone = .nuclearSiren

    private var focusRampTimer: Timer?
    private var focusHapticTimer: Timer?
    private var focusStartDate: Date?
    private var accumulatedFocusElapsed: TimeInterval = 0

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

    // MARK: - CoreHaptics Setup

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

    // MARK: - TAB 1: Exact 90-Second Escalating Wake Alarm

    /// Starts the exact 90-second escalation curve:
    /// - 0:00 – 0:30: 0% audio volume + rhythmic haptic pulses every 1.2s
    /// - 0:30 – 1:00: smooth linear volume ramp 0% -> 30% + rhythmic haptics
    /// - 1:00 – 1:30: smooth linear volume ramp 30% -> 100%, holding at 100%
    func startWakeEscalation(tone: AlarmTone) {
        stopPreview()
        stopFocusWarning()
        silentPlayer?.stop()
        isSilentKeepAliveRunning = false

        activeWakeTone = tone
        isWakeSirenActive = true
        isSirenPausedForMission = false
        isPenaltyBlastActive = false
        wakeElapsedSeconds = 0
        currentVolumeFraction = 0.0
        escalationPhaseLabel = "PHASE 1 • HAPTIC WAKE (0:00–0:30)"
        wakeStartDate = Date()

        setIdleTimerDisabled(true)
        activateOverridePlaybackSession()
        startWakeAudioSource(tone: tone, initialVolume: 0.0)
        startWakeHapticLoop()

        wakeRampTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickWakeEscalation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeRampTimer = timer
    }

    private func tickWakeEscalation() {
        guard isWakeSirenActive, let startDate = wakeStartDate else { return }

        if isSirenPausedForMission {
            applyWakeVolume(0.0)
            return
        }

        if isPenaltyBlastActive {
            currentVolumeFraction = 1.0
            escalationPhaseLabel = "PENALTY BLAST • 100% NUCLEAR SIREN"
            applyWakeVolume(1.0)
            return
        }

        let elapsed = Date().timeIntervalSince(startDate)
        wakeElapsedSeconds = elapsed

        let targetVolume: Float
        if elapsed < 30.0 {
            targetVolume = 0.0
            escalationPhaseLabel = "PHASE 1 • HAPTIC WAKE (0:00–0:30)"
        } else if elapsed < 60.0 {
            let fraction = (elapsed - 30.0) / 30.0
            targetVolume = Float(fraction * 0.30)
            escalationPhaseLabel = "PHASE 2 • RAMPING 0% → 30%"
        } else if elapsed < 90.0 {
            let fraction = (elapsed - 60.0) / 30.0
            targetVolume = Float(0.30 + fraction * 0.70)
            escalationPhaseLabel = "PHASE 3 • NUCLEAR RAMP 30% → 100%"
        } else {
            targetVolume = 1.0
            escalationPhaseLabel = "MAX NUCLEAR SIREN • 100%"
        }

        currentVolumeFraction = max(0.0, min(1.0, targetVolume))
        applyWakeVolume(currentVolumeFraction)
    }

    /// Immediately mutes/pauses the siren when the user taps "Start Mission" or resumes active mission progress.
    func pauseWakeSirenForMission() {
        guard isWakeSirenActive else { return }
        isSirenPausedForMission = true
        isPenaltyBlastActive = false
        currentVolumeFraction = 0.0
        escalationPhaseLabel = "MISSION ACTIVE • SIREN MUTED"
        applyWakeVolume(0.0)
        wakeHapticTimer?.invalidate()
        wakeHapticTimer = nil
    }

    /// Immediately blasts the nuclear siren at 100% volume on mission timeout or >3s inactivity.
    func blastNuclearPenaltyFullVolume() {
        guard isWakeSirenActive else { return }
        isSirenPausedForMission = false
        isPenaltyBlastActive = true
        currentVolumeFraction = 1.0
        escalationPhaseLabel = "PENALTY BLAST • 100% NUCLEAR SIREN"

        activateOverridePlaybackSession()
        if wakeFilePlayer == nil && synthAudioEngine == nil {
            startWakeAudioSource(tone: activeWakeTone, initialVolume: 1.0)
        } else {
            if let player = wakeFilePlayer, !player.isPlaying {
                player.play()
            }
            if let engine = synthAudioEngine, !engine.isRunning {
                try? engine.start()
            }
            applyWakeVolume(1.0)
        }
        startWakeHapticLoop()
    }

    /// Stops the wake siren completely, plays the completion chime, speaks "Good morning", and unlocks idle timer.
    func completeWakeMissionAndCelebrate() {
        stopWakeAudioOnly()
        wakeRampTimer?.invalidate()
        wakeRampTimer = nil
        wakeHapticTimer?.invalidate()
        wakeHapticTimer = nil

        isWakeSirenActive = false
        isSirenPausedForMission = false
        isPenaltyBlastActive = false
        wakeElapsedSeconds = 0
        currentVolumeFraction = 0.0
        escalationPhaseLabel = "MISSION COMPLETE"

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
                guard let self, self.isWakeSirenActive, !self.isSirenPausedForMission else { return }
                self.triggerRhythmicHapticPulse(intensity: 1.0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeHapticTimer = timer
    }

    private func startWakeAudioSource(tone: AlarmTone, initialVolume: Float) {
        stopWakeAudioOnly()

        // Try bundled or generated WAV file first (unless direct AVAudioEngine synth selected)
        if let fileName = tone.bundledFileName,
           let url = WavFileSynthesizer.resolveSoundURL(fileName: fileName),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.numberOfLoops = -1
            player.volume = initialVolume
            player.prepareToPlay()
            if player.play() {
                wakeFilePlayer = player
                isUsingSynthFallback = false
                return
            }
        }

        // Programmatic AVAudioEngine fallback so nuclear siren rings out-of-the-box with zero external files
        startAVAudioEngineNuclearSynth(
            baseFrequency: tone.baseFrequency,
            secondaryFrequency: tone.secondaryFrequency,
            modulationRateHz: tone.modulationRateHz,
            initialVolume: initialVolume
        )
    }

    private func applyWakeVolume(_ volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        wakeFilePlayer?.volume = clamped
        synthAudioEngine?.mainMixerNode.outputVolume = clamped
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

    // MARK: - TAB 3: Focus 2-Minute Escalating Warning Alarm (0% -> 50% over 120s)

    func startFocusWarningEscalation() {
        guard !isWakeSirenActive else { return }
        stopPreview()
        silentPlayer?.stop()
        isSilentKeepAliveRunning = false

        isFocusWarningActive = true
        isFocusWarningPaused = false
        accumulatedFocusElapsed = 0
        focusWarningElapsedSeconds = 0
        focusWarningVolumeFraction = 0.0
        focusStartDate = Date()

        setIdleTimerDisabled(true)
        activateOverridePlaybackSession()
        startFocusAudioPlayer(initialVolume: 0.0)
        startFocusWarningTimers()
    }

    func pauseFocusWarningForPhotoProof() {
        guard isFocusWarningActive else { return }
        if let start = focusStartDate {
            accumulatedFocusElapsed += Date().timeIntervalSince(start)
        }
        focusStartDate = nil
        isFocusWarningPaused = true
        focusWarningPlayer?.volume = 0.0
        focusWarningPlayer?.pause()
        focusHapticTimer?.invalidate()
        focusHapticTimer = nil
    }

    func resumeFocusWarningAfterFailureOrTimeout() {
        guard isFocusWarningActive else { return }
        isFocusWarningPaused = false
        // Ensure immediately audible on timeout or AI rejection (minimum 25% ramping to 50%)
        accumulatedFocusElapsed = max(accumulatedFocusElapsed, 60.0)
        focusStartDate = Date()
        activateOverridePlaybackSession()

        if focusWarningPlayer == nil {
            startFocusAudioPlayer(initialVolume: 0.25)
        } else {
            focusWarningPlayer?.play()
        }
        startFocusWarningTimers()
    }

    func stopFocusWarning() {
        focusRampTimer?.invalidate()
        focusRampTimer = nil
        focusHapticTimer?.invalidate()
        focusHapticTimer = nil
        focusWarningPlayer?.stop()
        focusWarningPlayer = nil
        focusStartDate = nil
        accumulatedFocusElapsed = 0
        isFocusWarningActive = false
        isFocusWarningPaused = false
        focusWarningElapsedSeconds = 0
        focusWarningVolumeFraction = 0.0

        if !isWakeSirenActive {
            AlarmEngine.shared.syncWithAlarms()
        }
    }

    private func startFocusAudioPlayer(initialVolume: Float) {
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
            player.volume = initialVolume
            player.prepareToPlay()
            player.play()
            focusWarningPlayer = player
        }
    }

    private func startFocusWarningTimers() {
        focusRampTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickFocusWarning()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusRampTimer = timer

        focusHapticTimer?.invalidate()
        triggerRhythmicHapticPulse(intensity: 0.75)
        let hTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isFocusWarningActive, !self.isFocusWarningPaused else { return }
                self.triggerRhythmicHapticPulse(intensity: 0.75)
            }
        }
        RunLoop.main.add(hTimer, forMode: .common)
        focusHapticTimer = hTimer
    }

    private func tickFocusWarning() {
        guard isFocusWarningActive, !isFocusWarningPaused, let start = focusStartDate else { return }
        let elapsed = accumulatedFocusElapsed + Date().timeIntervalSince(start)
        focusWarningElapsedSeconds = elapsed

        // Linear ramp from 0% to 50% over 120 seconds (2 minutes)
        let fraction = min(1.0, elapsed / 120.0)
        let volume = Float(fraction * 0.50)
        focusWarningVolumeFraction = volume
        focusWarningPlayer?.volume = volume
    }

    // MARK: - AVAudioEngine Real-Time Nuclear Siren Synthesizer

    private func startAVAudioEngineNuclearSynth(
        baseFrequency: Double,
        secondaryFrequency: Double,
        modulationRateHz: Double,
        initialVolume: Float
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
        mainMixer.outputVolume = initialVolume

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
        startWakeAudioSource(tone: tone, initialVolume: 0.45)

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

        if !isWakeSirenActive {
            stopWakeAudioOnly()
        }
    }

    // MARK: - Session Activation & Interruption Recovery

    private func activateOverridePlaybackSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback overrides hardware Silent/Mute switch and survives screen lock
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
                    if self.isWakeSirenActive && !self.isSirenPausedForMission {
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
