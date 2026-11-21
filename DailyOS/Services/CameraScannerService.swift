import SwiftUI
import UIKit
import AVFoundation

// MARK: - Preview UIView Subclass

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }
}

// MARK: - Live Photo Proof Camera (AVCapturePhotoOutput - No Photo Library)

@MainActor
final class LivePhotoCaptureViewModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var capturedImage: UIImage?
    @Published var cameraPermissionGranted: Bool = false
    @Published var isHardwareCameraAvailable: Bool = true
    @Published var isCapturing: Bool = false
    @Published var statusMessage: String = "Position task workspace in frame"
    @Published var usingFrontCamera: Bool = false

    let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.patrik.dailyos.photoproof.queue")

    func checkPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraPermissionGranted = true
            configureAndStartSession(frontCamera: usingFrontCamera)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cameraPermissionGranted = granted
                    if granted {
                        self.configureAndStartSession(frontCamera: self.usingFrontCamera)
                    } else {
                        self.statusMessage = "Camera permission is required for live photo proof."
                    }
                }
            }
        default:
            cameraPermissionGranted = false
            statusMessage = "Camera permission denied. Enable Camera in iOS Settings."
        }
    }

    private func configureAndStartSession(frontCamera: Bool) {
        let session = captureSession
        let output = photoOutput
        sessionQueue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()
            session.sessionPreset = .photo

            for input in session.inputs {
                session.removeInput(input)
            }

            let position: AVCaptureDevice.Position = frontCamera ? .front : .back
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video)

            guard let captureDevice = device,
                  let input = try? AVCaptureDeviceInput(device: captureDevice),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                Task { @MainActor [weak self] in
                    self?.isHardwareCameraAvailable = false
                    self?.statusMessage = "Hardware camera unavailable on this device."
                }
                return
            }

            session.addInput(input)

            if !session.outputs.contains(output) && session.canAddOutput(output) {
                session.addOutput(output)
            }

            session.commitConfiguration()

            if !session.isRunning {
                session.startRunning()
            }

            Task { @MainActor [weak self] in
                self?.isHardwareCameraAvailable = true
                self?.statusMessage = "Live camera active — tap shutter to submit proof"
            }
        }
    }

    func switchCamera() {
        usingFrontCamera.toggle()
        configureAndStartSession(frontCamera: usingFrontCamera)
    }

    func takeLivePhoto() {
        guard !isCapturing else { return }

        if !isHardwareCameraAvailable {
            capturedImage = renderTimestampedFallbackImage()
            return
        }

        isCapturing = true
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func retakePhoto() {
        capturedImage = nil
        isCapturing = false
    }

    func stopSession() {
        let session = captureSession
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            Task { @MainActor [weak self] in
                self?.isCapturing = false
                self?.statusMessage = "Capture failed: \(error.localizedDescription)"
            }
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            Task { @MainActor [weak self] in
                self?.isCapturing = false
                self?.statusMessage = "Could not decode captured photo."
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.isCapturing = false
            self?.capturedImage = image
        }
    }

    private func renderTimestampedFallbackImage() -> UIImage {
        let size = CGSize(width: 720, height: 960)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(red: 0.08, green: 0.11, blue: 0.18, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 34),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .medium),
                .foregroundColor: UIColor.systemCyan,
                .paragraphStyle: paragraph
            ]

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let timestamp = formatter.string(from: Date())

            "DAILYOS LIVE PROOF".draw(
                in: CGRect(x: 40, y: 380, width: size.width - 80, height: 60),
                withAttributes: titleAttrs
            )
            "Timestamp:\n\(timestamp)".draw(
                in: CGRect(x: 40, y: 460, width: size.width - 80, height: 100),
                withAttributes: subAttrs
            )
        }
    }
}
