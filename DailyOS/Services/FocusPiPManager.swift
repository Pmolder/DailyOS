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
/// - Displays calm Elapsed-of-Total Time (`0:42 / 45m` → `35m / 45m` → `1h 05m / 1h 30m`) + bottom `0%→100%` micro-progress bar
/// - Morphs cleanly into:
///   1. `📸 TAKE PHOTO • 29s` (exact seconds during Photo-Proof checks)
///   2. `✓ GOOD JOB! • 42m focused` (6s emerald celebration card on completion)
///   3. `NEXT: Gym — Upper Body • in 30m` / `✓ ALL CLEAR TODAY` (20s calm Next Up preview)
@MainActor
final class FocusPiPManager: NSObject, ObservableObject {
    static let shared = FocusPiPManager()

    enum PiPPillMode {
        case activeFocus(
            title: String,
            elapsedOfTotalText: String,
            progressFraction: Double,
            isActiveDeepWork: Bool,
            activeMinutesLogged: Int
        )
        case photoProofAlert(title: String, secondsLeft: Int)
        case celebration(focusedMinutes: Int, completedTitle: String, shimmerPhase: Double)
        case nextUpPreview(headline: String, subtitle: String, isAllClear: Bool)
    }

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

        renderFrame(
            mode: .activeFocus(
                title: "Deep Work",
                elapsedOfTotalText: "0:00 / 45m",
                progressFraction: 0.0,
                isActiveDeepWork: true,
                activeMinutesLogged: 0
            )
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

    // MARK: - 1 fps Frame Renderer

    func renderFrame(mode: PiPPillMode) {
        guard isPiPArmed, let layer = displayLayer else { return }
        if layer.status == .failed {
            layer.flush()
        }
        guard let pixelBuffer = drawPillPixelBuffer(mode: mode),
              let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else {
            return
        }
        layer.enqueue(sampleBuffer)
    }

    // MARK: - CoreGraphics Midnight Obsidian Pill Drawing

    private func drawPillPixelBuffer(mode: PiPPillMode) -> CVPixelBuffer? {
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

        // Flip to UIKit top-left coordinates
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        // 1. Background Fill & Accent Glow
        let bgColor: UIColor
        let glowColor: UIColor
        let borderColor: UIColor

        switch mode {
        case .photoProofAlert:
            bgColor = UIColor(red: 0.16, green: 0.06, blue: 0.04, alpha: 1.0)
            glowColor = UIColor(red: 1.0, green: 0.42, blue: 0.25, alpha: 0.36)
            borderColor = UIColor(red: 1.0, green: 0.42, blue: 0.32, alpha: 0.88)
        case .celebration:
            bgColor = UIColor(red: 0.04, green: 0.12, blue: 0.09, alpha: 1.0)
            glowColor = UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 0.40)
            borderColor = UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 0.78)
        case .nextUpPreview(_, _, let isAllClear):
            bgColor = UIColor(red: 0.04, green: 0.045, blue: 0.075, alpha: 1.0)
            glowColor = isAllClear
                ? UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 0.28)
                : UIColor(red: 0.545, green: 0.486, blue: 1.0, alpha: 0.30)
            borderColor = isAllClear
                ? UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 0.50)
                : UIColor(red: 0.545, green: 0.486, blue: 1.0, alpha: 0.52)
        case .activeFocus(_, _, _, let isActiveDeepWork, _):
            bgColor = UIColor(red: 0.035, green: 0.035, blue: 0.051, alpha: 1.0)
            glowColor = isActiveDeepWork
                ? UIColor(red: 0.376, green: 0.647, blue: 0.980, alpha: 0.28)
                : UIColor(red: 1.0, green: 0.69, blue: 0.125, alpha: 0.22)
            borderColor = UIColor.white.withAlphaComponent(0.12)
        }

        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(rect)

        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [glowColor.cgColor, glowColor.withAlphaComponent(0.0).cgColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: 60, y: CGFloat(height) * 0.5),
                startRadius: 4,
                endCenter: CGPoint(x: 60, y: CGFloat(height) * 0.5),
                endRadius: 210,
                options: []
            )
        }

        // Subtle celebratory shimmer sweep in Phase 1
        if case .celebration(_, _, let shimmerPhase) = mode {
            let sweepX = CGFloat(shimmerPhase) * CGFloat(width + 120) - 60
            let shimmerColors = [
                UIColor.clear.cgColor,
                UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 0.22).cgColor,
                UIColor.white.withAlphaComponent(0.18).cgColor,
                UIColor.clear.cgColor
            ] as CFArray
            if let shimmer = CGGradient(colorsSpace: colorSpace, colors: shimmerColors, locations: [0, 0.4, 0.6, 1]) {
                ctx.drawLinearGradient(
                    shimmer,
                    start: CGPoint(x: sweepX - 65, y: 0),
                    end: CGPoint(x: sweepX + 65, y: CGFloat(height)),
                    options: []
                )
            }
        }

        // 2. Border Stroke
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(3.0)
        ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))

        // 3. Mode-Specific Text & Bottom Micro-Progress Bar
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        switch mode {
        case .photoProofAlert(let title, let secsLeft):
            let alertAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .black),
                .foregroundColor: UIColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 1.0)
            ]
            let subAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.88)
            ]
            "📸 TAKE PHOTO • \(secsLeft)s".draw(in: CGRect(x: 24, y: 20, width: width - 48, height: 38), withAttributes: alertAttr)
            "Tap pill now for \"\(title)\"".draw(in: CGRect(x: 24, y: 64, width: width - 48, height: 26), withAttributes: subAttr)

        case .celebration(let focusedMinutes, let completedTitle, _):
            let headStyle = NSMutableParagraphStyle()
            headStyle.lineBreakMode = .byTruncatingTail
            let headAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 25, weight: .black),
                .foregroundColor: UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 1.0),
                .paragraphStyle: headStyle
            ]
            let subStyle = NSMutableParagraphStyle()
            subStyle.lineBreakMode = .byTruncatingTail
            let subAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.86),
                .paragraphStyle: subStyle
            ]
            let minsLabel = max(1, focusedMinutes)
            "✓ GOOD JOB! • \(minsLabel)m focused".draw(in: CGRect(x: 22, y: 22, width: width - 44, height: 34), withAttributes: headAttr)
            "Completed \(completedTitle)".draw(in: CGRect(x: 22, y: 62, width: width - 44, height: 24), withAttributes: subAttr)

            // Full emerald bottom bar
            ctx.setFillColor(UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 0.95).cgColor)
            ctx.fill(CGRect(x: 16, y: height - 10, width: width - 32, height: 5))

        case .nextUpPreview(let headline, let subtitle, let isAllClear):
            let headStyle = NSMutableParagraphStyle()
            headStyle.lineBreakMode = .byTruncatingTail
            let headAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 21, weight: .bold),
                .foregroundColor: isAllClear
                    ? UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 1.0)
                    : UIColor.white,
                .paragraphStyle: headStyle
            ]
            let subStyle = NSMutableParagraphStyle()
            subStyle.lineBreakMode = .byTruncatingTail
            let subAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: isAllClear
                    ? UIColor.white.withAlphaComponent(0.75)
                    : UIColor(red: 0.545, green: 0.486, blue: 1.0, alpha: 1.0),
                .paragraphStyle: subStyle
            ]
            headline.draw(in: CGRect(x: 22, y: 24, width: width - 44, height: 32), withAttributes: headAttr)
            subtitle.draw(in: CGRect(x: 22, y: 62, width: width - 44, height: 24), withAttributes: subAttr)

        case .activeFocus(let title, let elapsedOfTotalText, let progressFraction, let isActiveDeepWork, let activeMinutesLogged):
            let dotColor: UIColor = isActiveDeepWork
                ? UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 1.0)
                : UIColor(red: 1.0, green: 0.69, blue: 0.125, alpha: 1.0)
            ctx.setFillColor(dotColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: 22, y: 38, width: 16, height: 16))

            let titleStyle = NSMutableParagraphStyle()
            titleStyle.lineBreakMode = .byTruncatingTail
            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 21, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: titleStyle
            ]
            let statusAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12.5, weight: .bold),
                .foregroundColor: dotColor
            ]

            let timerFontSize: CGFloat = elapsedOfTotalText.count > 12 ? 21 : (elapsedOfTotalText.count > 9 ? 25 : 28)
            let timerStyle = NSMutableParagraphStyle()
            timerStyle.alignment = .right
            timerStyle.lineBreakMode = .byClipping
            let timerAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: timerFontSize, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: timerStyle
            ]

            let cleanTitle = title.isEmpty ? "Deep Work" : title
            cleanTitle.draw(in: CGRect(x: 48, y: 18, width: 184, height: 28), withAttributes: titleAttr)

            let statusText = isActiveDeepWork
                ? "ACTIVE • \(activeMinutesLogged)m logged"
                : "PAUSED • \(activeMinutesLogged)m logged"
            statusText.draw(in: CGRect(x: 48, y: 52, width: 184, height: 20), withAttributes: statusAttr)

            elapsedOfTotalText.draw(in: CGRect(x: 234, y: 30, width: 188, height: 38), withAttributes: timerAttr)

            // Sleek Horizontal Micro-Progress Bar Along Bottom Edge (0% -> 100%)
            let trackRect = CGRect(x: 18, y: height - 13, width: width - 36, height: 6)
            let clampedProgress = max(0.0, min(1.0, progressFraction))
            let fillWidth = max(6.0, trackRect.width * CGFloat(clampedProgress))
            let fillRect = CGRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height)

            let trackPath = UIBezierPath(roundedRect: trackRect, cornerRadius: 3)
            ctx.addPath(trackPath.cgPath)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.12).cgColor)
            ctx.fillPath()

            let barColor: UIColor = isActiveDeepWork
                ? UIColor(red: 0.376, green: 0.647, blue: 0.980, alpha: 1.0)
                : UIColor(red: 1.0, green: 0.69, blue: 0.125, alpha: 0.92)
            let fillPath = UIBezierPath(roundedRect: fillRect, cornerRadius: 3)
            ctx.addPath(fillPath.cgPath)
            ctx.setFillColor(barColor.cgColor)
            ctx.fillPath()
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
            if PhotoProofScheduler.shared.activeCaptureRequest == nil {
                FocusAutoSessionEngine.shared.handleRestoreFromPiPTap()
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
