import Foundation
import AVFoundation
import Vision
import SwiftUI
import UIKit

enum VisionExerciseMode: String, CaseIterable {
    case pushups
    case squats

    var title: String {
        switch self {
        case .pushups: return "AI PUSHUPS"
        case .squats: return "AI SQUATS"
        }
    }

    var instructionText: String {
        switch self {
        case .pushups:
            return "Prop phone facing you. Drop elbow angle below 95° with straight torso, then press above 155°."
        case .squats:
            return "Stand in front camera view. Drop hip-knee angle below 100°, then stand fully upright."
        }
    }
}

enum RepPhase: String {
    case up = "UP"
    case down = "DOWN"
}

struct PoseOverlayState {
    var joints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
    var bones: [(CGPoint, CGPoint)] = []
    var activeAngleDegrees: Double = 180.0
    var torsoAngleDegrees: Double = 180.0
    var torsoAligned: Bool = true
    var postureHint: String = "Position your body in front camera frame"
}

private final class FrameThrottle: @unchecked Sendable {
    var lastTimestamp: CFTimeInterval = 0
}

private let visionSkeletonBonePairs: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
    (.neck, .root),
    (.neck, .leftShoulder),
    (.neck, .rightShoulder),
    (.leftShoulder, .leftElbow),
    (.leftElbow, .leftWrist),
    (.rightShoulder, .rightElbow),
    (.rightElbow, .rightWrist),
    (.root, .leftHip),
    (.root, .rightHip),
    (.leftHip, .leftKnee),
    (.leftKnee, .leftAnkle),
    (.rightHip, .rightKnee),
    (.rightKnee, .rightAnkle),
    (.leftShoulder, .leftHip),
    (.rightShoulder, .rightHip)
]

/// 100% on-device Vision body-pose rep counter using front camera `AVCaptureSession`
/// + `VNDetectHumanBodyPoseRequest` with live skeleton overlay coordinates.
@MainActor
final class VisionPoseDetector: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var repCount: Int = 0
    @Published var phase: RepPhase = .up
    @Published var overlayState = PoseOverlayState()
    @Published var cameraAuthorized: Bool = false
    @Published var isHardwareCameraAvailable: Bool = true
    @Published var statusMessage: String = "Initializing front camera Vision engine..."

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.patrik.dailyos.visionpose.session")
    private let videoOutputQueue = DispatchQueue(label: "com.patrik.dailyos.visionpose.video", qos: .userInteractive)
    nonisolated private let frameThrottle = FrameThrottle()

    private var exerciseMode: VisionExerciseMode = .pushups
    private var isConfigured = false
    private var isRunningDetector = false
    private var lastReportedAngleForMovement: Double = 180.0

    /// Fires whenever a rep is completed, phase switches, or continuous exercise motion is registered.
    var onProgressDetected: (() -> Void)?

    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)

    func start(mode: VisionExerciseMode) {
        exerciseMode = mode
        repCount = 0
        phase = .up
        lastReportedAngleForMovement = 180.0
        overlayState = PoseOverlayState(postureHint: mode.instructionText)
        isRunningDetector = true

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraAuthorized = true
            configureAndStartSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cameraAuthorized = granted
                    if granted {
                        self.configureAndStartSession()
                    } else {
                        self.statusMessage = "Camera permission denied. Enable Camera in Settings."
                    }
                }
            }
        default:
            cameraAuthorized = false
            statusMessage = "Camera permission required for AI Pose Mission."
        }
    }

    func stop() {
        isRunningDetector = false
        let session = captureSession
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureAndStartSession() {
        let session = captureSession
        let alreadyConfigured = isConfigured
        let outputQueue = videoOutputQueue

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !alreadyConfigured {
                session.beginConfiguration()
                session.sessionPreset = .vga640x480

                let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                    ?? AVCaptureDevice.default(for: .video)

                guard let device = frontCamera,
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    session.commitConfiguration()
                    Task { @MainActor [weak self] in
                        self?.isHardwareCameraAvailable = false
                        self?.statusMessage = "No front camera detected on this device."
                    }
                    return
                }
                session.addInput(input)

                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

                if session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                    if let connection = videoOutput.connection(with: .video) {
                        if connection.isVideoRotationAngleSupported(90) {
                            connection.videoRotationAngle = 90
                        }
                        if connection.isVideoMirroringSupported {
                            connection.isVideoMirrored = true
                        }
                    }
                }

                session.commitConfiguration()
                Task { @MainActor [weak self] in
                    self?.isConfigured = true
                    self?.isHardwareCameraAvailable = true
                    self?.statusMessage = "Vision Pose active (100% on-device)"
                }
            }

            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        // Process up to ~15 FPS for smooth skeleton tracking with minimal battery/thermal impact
        guard now - frameThrottle.lastTimestamp >= 0.065 else { return }
        frameThrottle.lastTimestamp = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([request])
            guard let observation = request.results?.first,
                  let recognized = try? observation.recognizedPoints(.all) else {
                Task { @MainActor [weak self] in
                    guard let self, self.isRunningDetector else { return }
                    self.overlayState.joints = [:]
                    self.overlayState.bones = []
                    self.overlayState.postureHint = "No body detected — step into front camera view"
                }
                return
            }

            // Convert Vision normalized coordinates (origin bottom-left) to SwiftUI normalized (origin top-left)
            var mappedJoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
            var confidences: [VNHumanBodyPoseObservation.JointName: Float] = [:]

            for (name, point) in recognized where point.confidence >= 0.25 {
                mappedJoints[name] = CGPoint(x: point.location.x, y: 1.0 - point.location.y)
                confidences[name] = point.confidence
            }

            var bones: [(CGPoint, CGPoint)] = []
            for (a, b) in visionSkeletonBonePairs {
                if let ptA = mappedJoints[a], let ptB = mappedJoints[b] {
                    bones.append((ptA, ptB))
                }
            }

            Task { @MainActor [weak self] in
                guard let self, self.isRunningDetector else { return }
                self.evaluateBodyPose(joints: mappedJoints, confidences: confidences, bones: bones)
            }
        } catch {
            // Skip failed frame cleanly
        }
    }

    // MARK: - Angle & Rep Evaluation

    private func evaluateBodyPose(
        joints: [VNHumanBodyPoseObservation.JointName: CGPoint],
        confidences: [VNHumanBodyPoseObservation.JointName: Float],
        bones: [(CGPoint, CGPoint)]
    ) {
        overlayState.joints = joints
        overlayState.bones = bones

        switch exerciseMode {
        case .pushups:
            evaluatePushup(joints: joints, confidences: confidences)
        case .squats:
            evaluateSquat(joints: joints, confidences: confidences)
        }
    }

    private func evaluatePushup(
        joints: [VNHumanBodyPoseObservation.JointName: CGPoint],
        confidences: [VNHumanBodyPoseObservation.JointName: Float]
    ) {
        let leftElbowAngle = computeJointAngle(
            a: joints[.leftShoulder],
            vertex: joints[.leftElbow],
            c: joints[.leftWrist]
        )
        let rightElbowAngle = computeJointAngle(
            a: joints[.rightShoulder],
            vertex: joints[.rightElbow],
            c: joints[.rightWrist]
        )

        let leftConf = (confidences[.leftShoulder] ?? 0) + (confidences[.leftElbow] ?? 0) + (confidences[.leftWrist] ?? 0)
        let rightConf = (confidences[.rightShoulder] ?? 0) + (confidences[.rightElbow] ?? 0) + (confidences[.rightWrist] ?? 0)

        let activeElbowAngle: Double?
        if let l = leftElbowAngle, let r = rightElbowAngle {
            activeElbowAngle = leftConf >= rightConf ? l : r
        } else {
            activeElbowAngle = leftElbowAngle ?? rightElbowAngle
        }

        guard let elbowAngle = activeElbowAngle else {
            overlayState.postureHint = "Show shoulders, elbows & wrists clearly in frame"
            return
        }

        // Torso alignment verification (shoulder - hip - knee/ankle >= 135 deg when visible)
        let leftTorso = computeJointAngle(
            a: joints[.leftShoulder],
            vertex: joints[.leftHip],
            c: joints[.leftKnee] ?? joints[.leftAnkle]
        )
        let rightTorso = computeJointAngle(
            a: joints[.rightShoulder],
            vertex: joints[.rightHip],
            c: joints[.rightKnee] ?? joints[.rightAnkle]
        )

        let torsoAngle = leftTorso ?? rightTorso ?? 170.0
        let torsoAligned = torsoAngle >= 135.0

        overlayState.activeAngleDegrees = elbowAngle
        overlayState.torsoAngleDegrees = torsoAngle
        overlayState.torsoAligned = torsoAligned

        if abs(elbowAngle - lastReportedAngleForMovement) >= 18.0 {
            lastReportedAngleForMovement = elbowAngle
            onProgressDetected?()
        }

        if !torsoAligned {
            overlayState.postureHint = "Straighten torso! Keep plank alignment (current: \(Int(torsoAngle))°)"
            return
        }

        switch phase {
        case .up:
            overlayState.postureHint = "Lower chest until elbow < 95° (now \(Int(elbowAngle))°)"
            if elbowAngle < 95.0 {
                phase = .down
                overlayState.postureHint = "Good depth! Now push back up > 155°"
                onProgressDetected?()
            }
        case .down:
            overlayState.postureHint = "Push up past 155° to count rep (now \(Int(elbowAngle))°)"
            if elbowAngle > 155.0 {
                phase = .up
                repCount += 1
                impactFeedback.impactOccurred()
                overlayState.postureHint = "Rep \(repCount) counted! Keep going!"
                onProgressDetected?()
            }
        }
    }

    private func evaluateSquat(
        joints: [VNHumanBodyPoseObservation.JointName: CGPoint],
        confidences: [VNHumanBodyPoseObservation.JointName: Float]
    ) {
        let leftKneeAngle = computeJointAngle(
            a: joints[.leftHip],
            vertex: joints[.leftKnee],
            c: joints[.leftAnkle]
        )
        let rightKneeAngle = computeJointAngle(
            a: joints[.rightHip],
            vertex: joints[.rightKnee],
            c: joints[.rightAnkle]
        )

        let leftConf = (confidences[.leftHip] ?? 0) + (confidences[.leftKnee] ?? 0) + (confidences[.leftAnkle] ?? 0)
        let rightConf = (confidences[.rightHip] ?? 0) + (confidences[.rightKnee] ?? 0) + (confidences[.rightAnkle] ?? 0)

        let activeKneeAngle: Double?
        if let l = leftKneeAngle, let r = rightKneeAngle {
            activeKneeAngle = leftConf >= rightConf ? l : r
        } else {
            activeKneeAngle = leftKneeAngle ?? rightKneeAngle
        }

        guard let kneeAngle = activeKneeAngle else {
            overlayState.postureHint = "Step back so hips, knees & ankles are visible"
            return
        }

        overlayState.activeAngleDegrees = kneeAngle
        overlayState.torsoAligned = true

        if abs(kneeAngle - lastReportedAngleForMovement) >= 18.0 {
            lastReportedAngleForMovement = kneeAngle
            onProgressDetected?()
        }

        switch phase {
        case .up:
            overlayState.postureHint = "Squat down until knee < 100° (now \(Int(kneeAngle))°)"
            if kneeAngle < 100.0 {
                phase = .down
                overlayState.postureHint = "Good squat depth! Stand back upright > 155°"
                onProgressDetected?()
            }
        case .down:
            overlayState.postureHint = "Stand upright past 155° to count rep (now \(Int(kneeAngle))°)"
            if kneeAngle > 155.0 {
                phase = .up
                repCount += 1
                impactFeedback.impactOccurred()
                overlayState.postureHint = "Squat \(repCount) counted! Keep moving!"
                onProgressDetected?()
            }
        }
    }

    private func computeJointAngle(a: CGPoint?, vertex: CGPoint?, c: CGPoint?) -> Double? {
        guard let a, let v = vertex, let c else { return nil }
        let v1 = CGVector(dx: a.x - v.x, dy: a.y - v.y)
        let v2 = CGVector(dx: c.x - v.x, dy: c.y - v.y)

        let mag1 = hypot(v1.dx, v1.dy)
        let mag2 = hypot(v2.dx, v2.dy)
        guard mag1 > 0.001, mag2 > 0.001 else { return nil }

        let dot = (v1.dx * v2.dx) + (v1.dy * v2.dy)
        let cosine = max(-1.0, min(1.0, dot / (mag1 * mag2)))
        return acos(cosine) * (180.0 / Double.pi)
    }
}

// MARK: - Live Neon Skeleton Overlay View

struct PoseSkeletonOverlayView: View {
    let state: PoseOverlayState

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Canvas { context, _ in
                // Draw bone connections
                for (ptA, ptB) in state.bones {
                    var path = Path()
                    path.move(to: CGPoint(x: ptA.x * w, y: ptA.y * h))
                    path.addLine(to: CGPoint(x: ptB.x * w, y: ptB.y * h))
                    context.stroke(
                        path,
                        with: .color(state.torsoAligned ? .green : .orange),
                        lineWidth: 4
                    )
                }

                // Draw joint dots
                for (_, pt) in state.joints {
                    let center = CGPoint(x: pt.x * w, y: pt.y * h)
                    let circle = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
                    context.fill(circle, with: .color(.cyan))
                    context.stroke(circle, with: .color(.white), lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
