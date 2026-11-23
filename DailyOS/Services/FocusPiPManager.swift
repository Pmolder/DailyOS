import Foundation
import SwiftUI
import AVFoundation
import AVKit
import AudioToolbox
import CoreMedia
import CoreVideo
import UIKit
import Combine

// MARK: - Active SwiftUI Root Window Host View (Never Hidden, Never 0×0)

/// Dedicated `UIView` whose backing layer IS the `AVSampleBufferDisplayLayer`.
/// Embedded at `2×2pt` with `.opacity(0.01)` & `.allowsHitTesting(false)` in `ContentView`
/// so iOS ALWAYS composites PiP frames reliably with ZERO black screen.
final class SampleBufferHostUIView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        // Safe force-cast guaranteed by `layerClass` override above.
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        sampleBufferLayer.videoGravity = .resizeAspect
        sampleBufferLayer.backgroundColor = UIColor(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 13.0 / 255.0, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct PiPHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> SampleBufferHostUIView {
        let view = SampleBufferHostUIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        FocusPiPManager.shared.attachDisplayLayer(view.sampleBufferLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferHostUIView, context: Context) {
        FocusPiPManager.shared.attachDisplayLayer(uiView.sampleBufferLayer)
    }
}

// MARK: - Thread-Safe Playback State Mirror (For Non-Isolated PiP Delegate Queries)

private final class PiPPlaybackStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _isPaused: Bool = false

    var isPaused: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isPaused
        }
        set {
            lock.lock()
            _isPaused = newValue
            lock.unlock()
        }
    }
}

// MARK: - Zero-Black-Screen Minimalistic Floating PiP Pill Manager (720×192 IOSurface-Backed)

/// Ultra-minimalistic notch-compact Floating PiP Pill (`720 × 192`, 3.75:1 aspect):
/// - ZERO words inside the pill:
///   - Normal mode: crisp vector timer icon (Emerald active / Amber paused), optional subtle camera + minutes (fixed interval only), bold white `2 / 180` pure numbers, and bottom `6px` progress bar
///   - Photo-Proof Alert mode: SOLID BRIGHT RED (`#DC2626`) pulsing background + oscillating white ringing bell (`-18° ↔ +18°` at 6 fps) with sound arcs + bold white `30..0` countdown + 2.5s vibration
/// - Zero manual PiP button: automatically activates on swipe-away, automatically dismisses on return to DailyOS
@MainActor
final class FocusPiPManager: NSObject, ObservableObject {
    static let shared = FocusPiPManager()

    struct PillSnapshot: Equatable {
        var elapsedMinutes: Int
        var totalMinutes: Int
        var progressFraction: Double
        var isActiveDeepWork: Bool
        /// Non-nil ONLY when Photo Proof is ON AND non-randomized fixed interval (`duration >= photoIntervalMinutes`).
        var fixedIntervalMinutesUntilNextPhoto: Int?
        /// Non-nil when a Photo-Proof check-in countdown (`30..0`) is actively alerting.
        var activePhotoCountdownSeconds: Int?
    }

    @Published private(set) var isPiPArmed: Bool = false
    @Published private(set) var isPiPActive: Bool = false

    private let frameSize = CGSize(width: 720, height: 192)
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var silentMixPlayer: AVAudioPlayer?
    private var framePumpTimer: Timer?
    private var currentFPS: Double = 2.0
    private var animTick: Int = 0
    private var lastVibrationDate: Date = .distantPast
    private let playbackStateBox = PiPPlaybackStateBox()

    private var currentSnapshot = PillSnapshot(
        elapsedMinutes: 0,
        totalMinutes: 45,
        progressFraction: 0.0,
        isActiveDeepWork: true,
        fixedIntervalMinutesUntilNextPhoto: nil,
        activePhotoCountdownSeconds: nil
    )

    private override init() {
        super.init()
    }

    // MARK: - Layer Attachment from SwiftUI Root `PiPHostView`

    func attachDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        if displayLayer !== layer {
            displayLayer = layer
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = UIColor(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 13.0 / 255.0, alpha: 1.0).cgColor
            if isPiPArmed {
                rebuildPiPController(on: layer)
            }
        }
    }

    // MARK: - Arm / Update / Disarm Lifecycle (Strictly Active Only During Live Focus Sessions)

    func armAndWarmPiP(with snapshot: PillSnapshot) {
        currentSnapshot = snapshot
        playbackStateBox.isPaused = !snapshot.isActiveDeepWork

        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        // Activate mixing playback session + silent PCM loop ONLY while Focus session is live
        activateSilentMixAudioSession()

        guard let layer = displayLayer else { return }

        // Pump an immediate warm frame BEFORE initializing/arming AVPictureInPictureController!
        enqueueCurrentFrame()

        if pipController == nil || !isPiPArmed {
            rebuildPiPController(on: layer)
        } else {
            pipController?.invalidatePlaybackState()
        }

        isPiPArmed = true
        ensureFramePumpRunning(targetFPS: snapshot.activePhotoCountdownSeconds != nil ? 6.0 : 2.0)
    }

    func updateSnapshot(_ snapshot: PillSnapshot) {
        let wasPaused = playbackStateBox.isPaused
        let newPaused = !snapshot.isActiveDeepWork
        currentSnapshot = snapshot
        playbackStateBox.isPaused = newPaused

        guard isPiPArmed else { return }

        if wasPaused != newPaused {
            pipController?.invalidatePlaybackState()
        }

        let desiredFPS: Double = (snapshot.activePhotoCountdownSeconds != nil) ? 6.0 : 2.0
        ensureFramePumpRunning(targetFPS: desiredFPS)
        enqueueCurrentFrame()

        // Trigger rhythmic 2.5s vibration pulses while RED pill alert is active in PiP
        if snapshot.activePhotoCountdownSeconds != nil && isPiPActive {
            let now = Date()
            if now.timeIntervalSince(lastVibrationDate) >= 2.5 {
                lastVibrationDate = now
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }

    /// Automatically dismisses PiP when returning to DailyOS, and keeps it warmed for next swipe-away if session is live.
    func handleAppBecameActive() {
        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        isPiPActive = false
        if isPiPArmed {
            enqueueCurrentFrame()
        }
    }

    func stopAndDisarmPiP() {
        framePumpTimer?.invalidate()
        framePumpTimer = nil
        currentFPS = 2.0
        lastVibrationDate = .distantPast

        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        pipController?.delegate = nil
        pipController = nil
        displayLayer?.flushAndRemoveImage()

        silentMixPlayer?.stop()
        silentMixPlayer = nil
        deactivateMixAudioSessionIfIdle()

        isPiPArmed = false
        isPiPActive = false
    }

    // MARK: - Internal PiP Setup & Dynamic 2 fps / 6 fps Frame Pump

    private func rebuildPiPController(on layer: AVSampleBufferDisplayLayer) {
        if let existing = pipController, existing.isPictureInPictureActive {
            existing.stopPictureInPicture()
        }
        pipController?.delegate = nil

        // Always warm the layer with a fresh IOSurface frame before creating the controller
        enqueueCurrentFrame()

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        self.pipController = controller
    }

    private func ensureFramePumpRunning(targetFPS: Double) {
        if framePumpTimer != nil && abs(currentFPS - targetFPS) < 0.05 {
            return
        }
        framePumpTimer?.invalidate()
        currentFPS = targetFPS
        let interval = 1.0 / max(1.0, targetFPS)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pumpTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        framePumpTimer = timer
    }

    private func pumpTick() {
        guard isPiPArmed else { return }
        animTick &+= 1
        enqueueCurrentFrame()

        if currentSnapshot.activePhotoCountdownSeconds != nil && isPiPActive {
            let now = Date()
            if now.timeIntervalSince(lastVibrationDate) >= 2.5 {
                lastVibrationDate = now
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }

    private func enqueueCurrentFrame() {
        guard let layer = displayLayer else { return }
        if layer.status == .failed {
            layer.flush()
        }
        guard let pixelBuffer = drawPillPixelBuffer(snapshot: currentSnapshot, tick: animTick),
              let sampleBuffer = makeImmediateSampleBuffer(from: pixelBuffer) else {
            return
        }
        layer.enqueue(sampleBuffer)
    }

    // MARK: - IOSurface-Backed 720×192 CoreGraphics Ultra-Minimalistic Renderer (ZERO Words!)

    private func drawPillPixelBuffer(snapshot: PillSnapshot, tick: Int) -> CVPixelBuffer? {
        let width = Int(frameSize.width)
        let height = Int(frameSize.height)
        var pixelBuffer: CVPixelBuffer?

        // MANDATORY kCVPixelBufferIOSurfacePropertiesKey prevents black frames in iOS PiP!
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
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

        // Flip to top-left UIKit coordinates
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        if let countdownSecs = snapshot.activePhotoCountdownSeconds {
            drawRedPhotoAlertPill(in: ctx, rect: rect, countdownSeconds: max(0, countdownSecs), tick: tick)
        } else {
            drawMinimalNormalPill(in: ctx, rect: rect, snapshot: snapshot)
        }

        return buffer
    }

    private func drawMinimalNormalPill(in ctx: CGContext, rect: CGRect, snapshot: PillSnapshot) {
        let width = rect.width
        let height = rect.height

        // 1. Solid Opaque Deep Midnight Obsidian (#09090D)
        ctx.setFillColor(UIColor(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 13.0 / 255.0, alpha: 1.0).cgColor)
        ctx.fill(rect)

        // Subtle inner hairline border (rgba(255,255,255,0.10))
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(2.0)
        ctx.stroke(rect.insetBy(dx: 1.0, dy: 1.0))

        // 2. Left: Crisp Vector Timer/Clock Icon (Emerald #34D399 active / Amber #F59E0B paused)
        let iconColor = snapshot.isActiveDeepWork
            ? UIColor(red: 52.0 / 255.0, green: 211.0 / 255.0, blue: 153.0 / 255.0, alpha: 1.0)
            : UIColor(red: 245.0 / 255.0, green: 158.0 / 255.0, blue: 11.0 / 255.0, alpha: 0.78)

        let iconCenter = CGPoint(x: 84, y: height * 0.48)
        let clockRadius: CGFloat = 38

        // Soft glow behind timer icon
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let glow = CGGradient(
            colorsSpace: colorSpace,
            colors: [iconColor.withAlphaComponent(0.32).cgColor, iconColor.withAlphaComponent(0.0).cgColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawRadialGradient(
                glow,
                startCenter: iconCenter,
                startRadius: 6,
                endCenter: iconCenter,
                endRadius: 72,
                options: []
            )
        }

        ctx.saveGState()
        ctx.setStrokeColor(iconColor.cgColor)
        ctx.setLineWidth(7.0)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Clock body circle
        ctx.strokeEllipse(in: CGRect(
            x: iconCenter.x - clockRadius,
            y: iconCenter.y - clockRadius,
            width: clockRadius * 2,
            height: clockRadius * 2
        ))
        // Top stopwatch crown
        ctx.move(to: CGPoint(x: iconCenter.x - 14, y: iconCenter.y - clockRadius - 12))
        ctx.addLine(to: CGPoint(x: iconCenter.x + 14, y: iconCenter.y - clockRadius - 12))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: iconCenter.x, y: iconCenter.y - clockRadius - 12))
        ctx.addLine(to: CGPoint(x: iconCenter.x, y: iconCenter.y - clockRadius))
        ctx.strokePath()

        if snapshot.isActiveDeepWork {
            // Crisp timer hands (pointing 12 & 2 o'clock)
            ctx.move(to: iconCenter)
            ctx.addLine(to: CGPoint(x: iconCenter.x, y: iconCenter.y - 20))
            ctx.strokePath()
            ctx.move(to: iconCenter)
            ctx.addLine(to: CGPoint(x: iconCenter.x + 15, y: iconCenter.y - 8))
            ctx.strokePath()
        } else {
            // Subtle pause bars inside circle when paused
            ctx.move(to: CGPoint(x: iconCenter.x - 10, y: iconCenter.y - 14))
            ctx.addLine(to: CGPoint(x: iconCenter.x - 10, y: iconCenter.y + 14))
            ctx.move(to: CGPoint(x: iconCenter.x + 10, y: iconCenter.y - 14))
            ctx.addLine(to: CGPoint(x: iconCenter.x + 10, y: iconCenter.y + 14))
            ctx.strokePath()
        }
        ctx.restoreGState()

        // 3. Center (ONLY when Photo Proof is ON & fixed non-randomized interval): Minimal camera glyph + pure minutes
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        if let nextMins = snapshot.fixedIntervalMinutesUntilNextPhoto {
            let subtleTint = UIColor.white.withAlphaComponent(0.55)
            // Crisp minimal camera glyph at x = 200
            ctx.saveGState()
            ctx.setStrokeColor(subtleTint.cgColor)
            ctx.setLineWidth(4.5)
            ctx.setLineJoin(.round)
            let camBody = CGRect(x: 194, y: height * 0.48 - 17, width: 46, height: 34)
            let camPath = UIBezierPath(roundedRect: camBody, cornerRadius: 7)
            ctx.addPath(camPath.cgPath)
            ctx.strokePath()
            // Lens circle
            ctx.strokeEllipse(in: CGRect(x: camBody.midX - 9, y: camBody.midY - 9, width: 18, height: 18))
            ctx.restoreGState()

            let camNumAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 38, weight: .bold),
                .foregroundColor: subtleTint
            ]
            "\(max(1, nextMins))".draw(in: CGRect(x: 252, y: height * 0.48 - 24, width: 88, height: 48), withAttributes: camNumAttr)
        }

        // 4. Right: Pure Bold White Monospaced Numbers ONLY (`0 / 45`, `2 / 180`, `35 / 45`) — ZERO words!
        let numbersText = "\(max(0, snapshot.elapsedMinutes)) / \(max(1, snapshot.totalMinutes))"
        let numFontSize: CGFloat = numbersText.count >= 8 ? 64 : 74
        let numStyle = NSMutableParagraphStyle()
        numStyle.alignment = .right
        numStyle.lineBreakMode = .byClipping
        let numAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: numFontSize, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: numStyle
        ]
        numbersText.draw(in: CGRect(x: 320, y: (height - numFontSize - 16) * 0.5, width: width - 356, height: numFontSize + 18), withAttributes: numAttr)

        // 5. Bottom Edge: Clean 6px Progress Bar Filling Proportionally (0% -> 100%)
        let barHeight: CGFloat = 6.0
        let barY = height - barHeight - 8.0
        let barX: CGFloat = 24.0
        let barMaxW = width - 48.0
        let trackRect = CGRect(x: barX, y: barY, width: barMaxW, height: barHeight)
        ctx.addPath(UIBezierPath(roundedRect: trackRect, cornerRadius: 3).cgPath)
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.12).cgColor)
        ctx.fillPath()

        let clampedProgress = max(0.0, min(1.0, snapshot.progressFraction))
        let fillW = max(10.0, barMaxW * CGFloat(clampedProgress))
        let fillRect = CGRect(x: barX, y: barY, width: fillW, height: barHeight)
        let barTint = snapshot.isActiveDeepWork
            ? UIColor(red: 52.0 / 255.0, green: 211.0 / 255.0, blue: 153.0 / 255.0, alpha: 1.0)
            : UIColor(red: 245.0 / 255.0, green: 158.0 / 255.0, blue: 11.0 / 255.0, alpha: 0.90)
        ctx.addPath(UIBezierPath(roundedRect: fillRect, cornerRadius: 3).cgPath)
        ctx.setFillColor(barTint.cgColor)
        ctx.fillPath()
    }

    private func drawRedPhotoAlertPill(in ctx: CGContext, rect: CGRect, countdownSeconds: Int, tick: Int) {
        let width = rect.width
        let height = rect.height

        // 1. SOLID BRIGHT RED (#DC2626) with crisp pulsing brightness
        let pulse = 0.5 + 0.5 * sin(Double(tick) * 0.9)
        let redVal = CGFloat(220.0 + pulse * 22.0) / 255.0
        let greenVal = CGFloat(38.0 + pulse * 14.0) / 255.0
        let blueVal = CGFloat(38.0 + pulse * 14.0) / 255.0
        ctx.setFillColor(UIColor(red: redVal, green: greenVal, blue: blueVal, alpha: 1.0).cgColor)
        ctx.fill(rect)

        // Subtle bright white edge highlight
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(3.0)
        ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))

        // 2. Left/Center: Animated Pure WHITE Ringing Bell (-18° <-> +18° at 6 fps) + Sound Wave Arcs
        let bellCenter = CGPoint(x: 210, y: height * 0.5)
        let angleDeg = sin(Double(tick) * 1.45) * 18.0
        let angleRad = CGFloat(angleDeg * Double.pi / 180.0)

        // Animated Sound Wave Arcs pulsing on both sides of the bell
        let arcAlpha = CGFloat(0.45 + 0.55 * abs(sin(Double(tick) * 1.45)))
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(arcAlpha).cgColor)
        ctx.setLineWidth(6.5)
        ctx.setLineCap(.round)

        // Left sound wave arcs
        ctx.addArc(center: CGPoint(x: bellCenter.x - 16, y: bellCenter.y - 6), radius: 58, startAngle: CGFloat(145 * Double.pi / 180), endAngle: CGFloat(215 * Double.pi / 180), clockwise: false)
        ctx.strokePath()
        ctx.addArc(center: CGPoint(x: bellCenter.x - 18, y: bellCenter.y - 6), radius: 78, startAngle: CGFloat(152 * Double.pi / 180), endAngle: CGFloat(208 * Double.pi / 180), clockwise: false)
        ctx.strokePath()

        // Right sound wave arcs
        ctx.addArc(center: CGPoint(x: bellCenter.x + 16, y: bellCenter.y - 6), radius: 58, startAngle: CGFloat(-35 * Double.pi / 180), endAngle: CGFloat(35 * Double.pi / 180), clockwise: false)
        ctx.strokePath()
        ctx.addArc(center: CGPoint(x: bellCenter.x + 18, y: bellCenter.y - 6), radius: 78, startAngle: CGFloat(-28 * Double.pi / 180), endAngle: CGFloat(28 * Double.pi / 180), clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()

        // Rotating Pure WHITE Bell Silhouette
        ctx.saveGState()
        ctx.translateBy(x: bellCenter.x, y: bellCenter.y - 30)
        ctx.rotate(by: angleRad)
        ctx.setFillColor(UIColor.white.cgColor)

        let bellPath = UIBezierPath()
        // Bell crown knob
        bellPath.append(UIBezierPath(ovalIn: CGRect(x: -9, y: -12, width: 18, height: 18)))
        // Bell dome & flared skirt
        bellPath.move(to: CGPoint(x: 0, y: 0))
        bellPath.addCurve(to: CGPoint(x: -36, y: 42), controlPoint1: CGPoint(x: -26, y: 2), controlPoint2: CGPoint(x: -34, y: 20))
        bellPath.addLine(to: CGPoint(x: -46, y: 66))
        bellPath.addQuadCurve(to: CGPoint(x: -40, y: 74), controlPoint: CGPoint(x: -48, y: 74))
        bellPath.addLine(to: CGPoint(x: 40, y: 74))
        bellPath.addQuadCurve(to: CGPoint(x: 46, y: 66), controlPoint: CGPoint(x: 48, y: 74))
        bellPath.addLine(to: CGPoint(x: 36, y: 42))
        bellPath.addCurve(to: CGPoint(x: 0, y: 0), controlPoint1: CGPoint(x: 34, y: 20), controlPoint2: CGPoint(x: 26, y: 2))
        bellPath.close()
        ctx.addPath(bellPath.cgPath)
        ctx.fillPath()

        // Clapper ball at bottom
        ctx.fillEllipse(in: CGRect(x: -12, y: 78, width: 24, height: 18))
        ctx.restoreGState()

        // 3. Right: Large Bold Pure WHITE Countdown Number (`30` .. `0`) — ZERO Words!
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let countText = "\(countdownSeconds)"
        let countStyle = NSMutableParagraphStyle()
        countStyle.alignment = .right
        let countAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 108, weight: .black),
            .foregroundColor: UIColor.white,
            .paragraphStyle: countStyle
        ]
        countText.draw(in: CGRect(x: 380, y: (height - 122) * 0.5, width: width - 436, height: 126), withAttributes: countAttr)
    }

    // MARK: - CMSampleBuffer Creation with Immediate Display Attachment

    private func makeImmediateSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr, let format = formatDesc else { return nil }

        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 4),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let buffer = sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return buffer
    }

    // MARK: - Background Silent PCM Mix Session (Never Interrupts Spotify / Apple Music)

    private func activateSilentMixAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if silentMixPlayer == nil {
                let wav = WavFileSynthesizer.makeSilentWavData(durationSeconds: 1.0)
                let player = try AVAudioPlayer(data: wav)
                player.numberOfLoops = -1
                player.volume = 0.0
                player.prepareToPlay()
                player.play()
                silentMixPlayer = player
            } else if !(silentMixPlayer?.isPlaying ?? false) {
                silentMixPlayer?.play()
            }
        } catch {
            print("[FocusPiPManager] Audio session notice: \(error.localizedDescription)")
        }
    }

    private func deactivateMixAudioSessionIfIdle() {
        // Never deactivate if a morning Wake Alarm or Focus Warning audio is actively playing
        if AlarmAudioManager.shared.isSilentKeepAliveRunning || AlarmAudioManager.shared.isFocusWarningActive {
            return
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// MARK: - AVPictureInPictureControllerDelegate & SampleBufferPlaybackDelegate

extension FocusPiPManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
            self.enqueueCurrentFrame()
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
            if PhotoProofScheduler.shared.hasActiveCheckIn {
                // Immediately route straight into PhotoProofCaptureSheet (already published as activeCaptureRequest)
                FocusAutoSessionEngine.shared.shouldPresentTimerSheet = false
            } else {
                FocusAutoSessionEngine.shared.shouldPresentTimerSheet = true
            }
            completionHandler(true)
        }
    }
}

extension FocusPiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in
            FocusAutoSessionEngine.shared.setActiveTracking(playing)
            self.playbackStateBox.isPaused = !playing
            pictureInPictureController.invalidatePlaybackState()
            self.enqueueCurrentFrame()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        playbackStateBox.isPaused
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
