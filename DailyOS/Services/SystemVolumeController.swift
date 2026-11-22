import Foundation
import MediaPlayer
import AVFoundation
import UIKit
import Combine

/// Dedicated hardware system volume controller using an offscreen, non-hidden `MPVolumeView`
/// (`alpha = 0.001`) mounted directly inside the active key `UIWindow`.
/// Drives real-time hardware volume ramps (updating the iOS Control Center volume bar) and
/// prevents lowering volume via hardware Volume Down buttons using `AVAudioSession.outputVolume` KVO.
@MainActor
final class SystemVolumeController: ObservableObject {
    static let shared = SystemVolumeController()

    @Published private(set) var currentHardwareVolume: Float = AVAudioSession.sharedInstance().outputVolume
    @Published private(set) var targetHardwareVolume: Float = 0.0
    @Published private(set) var isVolumeLockActive: Bool = false

    private var volumeView: MPVolumeView?
    private weak var mountedWindow: UIWindow?
    private var outputVolumeObservation: NSKeyValueObservation?
    private var rampTimer: Timer?

    private var rampStartDate: Date?
    private var rampStartVolume: Float = 0.01
    private var rampEndVolume: Float = 0.50
    private var rampDuration: TimeInterval = 30.0
    private var maxAllowedCap: Float = 0.50

    private init() {
        setupOutputVolumeKVO()
        ensureMountedInKeyWindow()
    }

    // MARK: - Window Mounting & Internal UISlider Extraction

    /// Ensures `MPVolumeView` is mounted inside the visible key `UIWindow` bounds (`alpha = 0.011`,
    /// never hidden, `isUserInteractionEnabled = false`) and immediately laid out so iOS 17–26
    /// instantiates and honors programmatic updates to its internal `UISlider`.
    func ensureMountedInKeyWindow() {
        let activeWindow = resolveKeyWindow()

        if volumeView == nil {
            let mpView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
            mpView.alpha = 0.011
            mpView.isHidden = false
            mpView.isUserInteractionEnabled = false
            mpView.clipsToBounds = true
            volumeView = mpView
        }

        guard let mpView = volumeView, let window = activeWindow else { return }

        if mpView.superview !== window {
            mpView.removeFromSuperview()
            mpView.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
            window.addSubview(mpView)
            mountedWindow = window
        }
        mpView.setNeedsLayout()
        mpView.layoutIfNeeded()
    }

    /// Computes a smooth perceptual logarithmic gain (`AVAudioPlayer.volume`) for a normalized
    /// loudness progress `0.0...1.0` so volume ramps remain clearly audible on iOS 26 alongside
    /// the hardware `UISlider`.
    static func logarithmicPlayerGain(normalizedProgress: Float, maxGain: Float = 1.0) -> Float {
        let clamped = max(0.0, min(1.0, normalizedProgress))
        guard clamped > 0.0001 else { return 0.0 }
        // Perceptual dB curve across -32 dB .. 0 dB mapped cleanly into (0.025 ... maxGain)
        let db = -32.0 * (1.0 - Double(clamped))
        let perceptual = Float(pow(10.0, db / 20.0))
        return max(0.025, min(maxGain, perceptual * maxGain))
    }

    private func resolveKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                let lhsActive = lhs.activationState == .foregroundActive
                let rhsActive = rhs.activationState == .foregroundActive
                return lhsActive && !rhsActive
            }

        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            if let first = scene.windows.first {
                return first
            }
        }
        return nil
    }

    private func findVolumeSlider() -> UISlider? {
        ensureMountedInKeyWindow()
        guard let mpView = volumeView else { return nil }
        if let direct = mpView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            return direct
        }
        return recursiveFindSlider(in: mpView)
    }

    private func recursiveFindSlider(in view: UIView) -> UISlider? {
        for subview in view.subviews {
            if let slider = subview as? UISlider {
                return slider
            }
            if let nested = recursiveFindSlider(in: subview) {
                return nested
            }
        }
        return nil
    }

    // MARK: - Real-Time Hardware Volume Ramp & Lock

    /// Smoothly ramps the hardware system volume from `from` to `to` over `duration` seconds,
    /// ticking every 0.15s and actively snapping back if the user presses Volume Down.
    func startRamp(from startVol: Float, to endVol: Float, duration: TimeInterval) {
        ensureMountedInKeyWindow()
        rampTimer?.invalidate()

        let clampedStart = max(0.0, min(1.0, startVol))
        let clampedEnd = max(0.0, min(1.0, endVol))

        rampStartVolume = clampedStart
        rampEndVolume = clampedEnd
        rampDuration = max(0.1, duration)
        maxAllowedCap = max(clampedStart, clampedEnd)
        rampStartDate = Date()

        isVolumeLockActive = true
        targetHardwareVolume = clampedStart
        applyHardwareVolume(clampedStart)

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickHardwareRamp()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
    }

    /// Immediately sets and locks a specific target hardware volume (useful for multi-phase escalations).
    func setLockedTargetVolume(_ target: Float) {
        ensureMountedInKeyWindow()
        let clamped = max(0.0, min(1.0, target))
        targetHardwareVolume = clamped
        isVolumeLockActive = true
        applyHardwareVolume(clamped)
    }

    /// Stops ramping and releases the hardware volume-button lock.
    func stopVolumeControl() {
        rampTimer?.invalidate()
        rampTimer = nil
        rampStartDate = nil
        isVolumeLockActive = false
        currentHardwareVolume = AVAudioSession.sharedInstance().outputVolume
    }

    private func tickHardwareRamp() {
        guard isVolumeLockActive, let startDate = rampStartDate else { return }
        ensureMountedInKeyWindow()

        let elapsed = Date().timeIntervalSince(startDate)
        let progress = Float(min(1.0, max(0.0, elapsed / rampDuration)))
        let interpolated = rampStartVolume + (rampEndVolume - rampStartVolume) * progress
        let clamped = min(maxAllowedCap, max(0.0, interpolated))

        targetHardwareVolume = clamped
        applyHardwareVolume(clamped)
    }

    private func applyHardwareVolume(_ value: Float) {
        let clamped = max(0.0, min(1.0, value))
        guard let slider = findVolumeSlider() else { return }
        slider.setValue(clamped, animated: false)
        slider.sendActions(for: .valueChanged)
        currentHardwareVolume = AVAudioSession.sharedInstance().outputVolume
    }

    // MARK: - Anti-Volume-Button KVO Correction

    private func setupOutputVolumeKVO() {
        let session = AVAudioSession.sharedInstance()
        outputVolumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            let observed = change.newValue ?? AVAudioSession.sharedInstance().outputVolume
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentHardwareVolume = observed

                // If an alarm or escalation is active and user pressed Volume Down / dragged Control Center down,
                // immediately snap the hardware slider right back up to the current expected target.
                if self.isVolumeLockActive && observed < (self.targetHardwareVolume - 0.015) {
                    self.applyHardwareVolume(self.targetHardwareVolume)
                }
            }
        }
    }
}
