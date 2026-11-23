import Foundation
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit
import Combine

/// Floating Picture-in-Picture (PiP) Top Timer Pill for iPhone 13 Pro (notch display):
/// - Ultra-lightweight 1 fps CoreGraphics `AVSampleBufferDisplayLayer` pill (440×112)
/// - `canStartPictureInPictureAutomaticallyFromInline = true` + `requiresLinearPlayback = true`
/// - Uses `.playback` + `.mixWithOthers` only while active (never pauses Spotify / Apple Music / podcasts)
/// - Morphs smoothly into a glowing `📸 TAKE PHOTO • 29s` alert pill when Photo Proof triggers
@MainActor
final class FocusPiPManager: NSObject, ObservableObject {
    static let shared = FocusPiPManager()

    @Published private(set) var isPiPArmed: Bool = false
    @Published private(set) var isPiPActive: Bool = false

    private let frameSize = CGSize(width: 440, height: 112)
    private var hostView: UIView?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var silentMixPlayer: AVAudioPlayer?

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle (Strictly Lazy — Never Touched at App Launch)

    func armPiPIfNeeded() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard !isPiPArmed else { return }

        // Activate mixing playback session so PiP pops automatically on swipe-away without pausing music
        activateMixWithOthersAudioSession()

        guard let keyWindow = activeKeyWindow() else { return }

        let container = UIView(frame: CGRect(x: 4, y: 4, width: 1, height: 1))
        container.backgroundColor = .clear
        container.alpha = 0.011
        container.isUserInteractionEnabled = false
        keyWindow.addSubview(container)

        let layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(origin: .zero, size: frameSize)
        layer.videoGravity = .resizeAspect
        container.layer.addSublayer(layer)

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true

        self.hostView = container
        self.displayLayer = layer
        self.pipController = controller
        self.isPiPArmed = true

        // Enqueue an initial frame so the display layer is ready immediately
        renderFrame(
            title: "Deep Work",
            countdownText: "45:00",
            isActiveDeepWork: true,
            activeMinutesLogged: 0,
            photoProofSecondsLeft: nil
        )
    }

    func startPiPManuallyIfSupported() {
        armPiPIfNeeded()
        guard let pip = pipController, !pip.isPictureInPictureActive else { return }
        pip.startPictureInPicture()
    }

    func stopAndDisarmPiP() {
        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        pipController?.delegate = nil
        pipController = nil
        displayLayer?.flushAndRemoveImage()
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        hostView?.removeFromSuperview()
        hostView = nil
        silentMixPlayer?.stop()
        silentMixPlayer = nil
        isPiPArmed = false
        isPiPActive = false
    }

    // MARK: - 1 fps Frame Renderer (Normal Midnight Pill OR Unified Photo-Proof Morph Pill)

    func renderFrame(
        title: String,
        countdownText: String,
        isActiveDeepWork: Bool,
        activeMinutesLogged: Int,
        photoProofSecondsLeft: Int?
    ) {
        guard isPiPArmed, let layer = displayLayer else { return }
        if layer.status == .failed {
            layer.flush()
        }
        guard let pixelBuffer = drawPillPixelBuffer(
            title: title,
            countdownText: countdownText,
            isActiveDeepWork: isActiveDeepWork,
            activeMinutesLogged: activeMinutesLogged,
            photoProofSecondsLeft: photoProofSecondsLeft
        ),
        let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else {
            return
        }
        layer.enqueue(sampleBuffer)
    }

    // MARK: - CoreGraphics Midnight Obsidian Pill Drawing

    private func drawPillPixelBuffer(
        title: String,
        countdownText: String,
        isActiveDeepWork: Bool,
        activeMinutesLogged: Int,
        photoProofSecondsLeft: Int?
    ) -> CVPixelBuffer? {
        let width = Int(frameSize.width)
        let height = Int(frameSize.height)
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // Flip to UIKit top-left coordinates for clean NSAttributedString drawing
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let isPhotoAlert = (photoProofSecondsLeft != nil)

        // 1. Background Fill
        if isPhotoAlert {
            ctx.setFillColor(UIColor(red: 0.16, green: 0.06, blue: 0.04, alpha: 1.0).cgColor)
        } else {
            ctx.setFillColor(UIColor(red: 0.035, green: 0.035, blue: 0.051, alpha: 1.0).cgColor)
        }
        ctx.fill(rect)

        // 2. Subtle Radial Accent Glow on Left
        let glowColor: UIColor = isPhotoAlert
            ? UIColor(red: 1.0, green: 0.42, blue: 0.25, alpha: 0.34)
            : (isActiveDeepWork
               ? UIColor(red: 0.376, green: 0.647, blue: 0.980, alpha: 0.28)
               : UIColor(red: 1.0, green: 0.69, blue: 0.125, alpha: 0.22))

        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [glowColor.cgColor, glowColor.withAlphaComponent(0.0).cgColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: 56, y: CGFloat(height) * 0.5),
                startRadius: 4,
                endCenter: CGPoint(x: 56, y: CGFloat(height) * 0.5),
                endRadius: 190,
                options: []
            )
        }

        // 3. Border Stroke
        let borderColor: UIColor = isPhotoAlert
            ? UIColor(red: 1.0, green: 0.42, blue: 0.32, alpha: 0.85)
            : UIColor.white.withAlphaComponent(0.12)
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(3.0)
        ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))

        // 4. Text Rendering via UIGraphicsPushContext
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        if let secsLeft = photoProofSecondsLeft {
            // Unified Morphed Photo-Proof Alert Pill
            let alertAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .black),
                .foregroundColor: UIColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 1.0)
            ]
            let subAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.88)
            ]
            let headline = "📸 TAKE PHOTO • \(secsLeft)s"
            headline.draw(in: CGRect(x: 24, y: 20, width: width - 48, height: 38), withAttributes: alertAttr)

            let subtitle = "Tap pill now for \"\(title)\""
            subtitle.draw(in: CGRect(x: 24, y: 64, width: width - 48, height: 26), withAttributes: subAttr)
        } else {
            // Normal Midnight Obsidian Focus Pill
            let dotColor: UIColor = isActiveDeepWork
                ? UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 1.0)
                : UIColor(red: 1.0, green: 0.69, blue: 0.125, alpha: 1.0)
            ctx.setFillColor(dotColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: 24, y: 46, width: 18, height: 18))

            let titleStyle = NSMutableParagraphStyle()
            titleStyle.lineBreakMode = .byTruncatingTail
            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: titleStyle
            ]
            let statusAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: dotColor
            ]
            let timerStyle = NSMutableParagraphStyle()
            timerStyle.alignment = .right
            let timerAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 36, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: timerStyle
            ]

            let cleanTitle = title.isEmpty ? "Deep Work" : title
            cleanTitle.draw(in: CGRect(x: 54, y: 24, width: 220, height: 30), withAttributes: titleAttr)

            let statusText = isActiveDeepWork
                ? "ACTIVE • \(activeMinutesLogged)m logged"
                : "PAUSED • \(activeMinutesLogged)m logged"
            statusText.draw(in: CGRect(x: 54, y: 60, width: 220, height: 22), withAttributes: statusAttr)

            countdownText.draw(in: CGRect(x: 274, y: 34, width: 146, height: 46), withAttributes: timerAttr)
        }

        return buffer
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let format = formatDesc else { return nil }

        let now = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: 1.0, preferredTimescale: 600),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr else { return nil }
        return sampleBuffer
    }

    private func activateMixWithOthersAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if silentMixPlayer == nil {
                let wav = WavFileSynthesizer.makeSilentWavData(durationSeconds: 2.0)
                let player = try AVAudioPlayer(data: wav)
                player.numberOfLoops = -1
                player.volume = 0.005
                player.prepareToPlay()
                player.play()
                silentMixPlayer = player
            } else if !(silentMixPlayer?.isPlaying ?? false) {
                silentMixPlayer?.play()
            }
        } catch {
            print("[FocusPiPManager] Mix audio session notice: \(error.localizedDescription)")
        }
    }

    private func activeKeyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive else { continue }
            if let key = windowScene.windows.first(where: \.isKeyWindow) {
                return key
            }
            if let first = windowScene.windows.first {
                return first
            }
        }
        return nil
    }
}

// MARK: - AVPictureInPictureControllerDelegate & SampleBufferPlaybackDelegate

extension FocusPiPManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            self.isPiPActive = false
            // If Photo-Proof check-in is pending, it is already presented as highest-priority Focus cover
            if PhotoProofScheduler.shared.activeCaptureRequest == nil {
                FocusAutoSessionEngine.shared.shouldPresentTimerSheet = true
            }
            completionHandler(true)
        }
    }
}

extension FocusPiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
