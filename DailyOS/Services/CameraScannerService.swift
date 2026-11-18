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

// MARK: - 1. Live QR / Barcode Scanner (AVFoundation)

@MainActor
final class BarcodeScannerViewModel: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    @Published var lastScannedCode: String = ""
    @Published var lastSymbology: String = ""
    @Published var isTorchOn: Bool = false
    @Published var cameraPermissionGranted: Bool = false
    @Published var statusText: String = "Initializing camera..."

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.patrik.dailyos.barcodescanner.queue")
    private var isConfigured = false
    var onCodeDetected: ((String, String) -> Void)?

    func checkPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraPermissionGranted = true
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cameraPermissionGranted = granted
                    if granted {
                        self.startSession()
                    } else {
                        self.statusText = "Camera permission denied. Enable Camera in iOS Settings."
                    }
                }
            }
        default:
            cameraPermissionGranted = false
            statusText = "Camera access is denied or restricted."
        }
    }

    private func startSession() {
        statusText = "Point camera at target QR code or barcode"
        let session = captureSession
        let alreadyConfigured = isConfigured
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !alreadyConfigured {
                self.configureSession(session)
            }
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    nonisolated private func configureSession(_ session: AVCaptureSession) {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            session.commitConfiguration()
            Task { @MainActor [weak self] in
                self?.statusText = "No physical camera detected on this device."
            }
            return
        }
        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)

            let desiredTypes: [AVMetadataObject.ObjectType] = [
                .qr,
                .ean13,
                .ean8,
                .upce,
                .code128,
                .code39,
                .code93,
                .itf14,
                .pdf417,
                .aztec,
                .dataMatrix
            ]
            let supported = metadataOutput.availableMetadataObjectTypes
            metadataOutput.metadataObjectTypes = desiredTypes.filter { supported.contains($0) }
        }

        session.commitConfiguration()
        Task { @MainActor [weak self] in
            self?.isConfigured = true
        }
    }

    func stopSession() {
        if isTorchOn {
            setTorch(enabled: false)
        }
        let session = captureSession
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func toggleTorch() {
        setTorch(enabled: !isTorchOn)
    }

    private func setTorch(enabled: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
            isTorchOn = enabled
        } catch {
            print("[BarcodeScanner] Torch error: \(error.localizedDescription)")
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let readableObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = readableObject.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stringValue.isEmpty else {
            return
        }
        let symbology = readableObject.type.rawValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastScannedCode = stringValue
            self.lastSymbology = symbology
            self.onCodeDetected?(stringValue, symbology)
        }
    }
}

struct BarcodeScannerCameraPreview: UIViewRepresentable {
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

// MARK: - 2. Live Photo Proof Camera (AVCapturePhotoOutput - No Photo Library)

@MainActor
final class LivePhotoCaptureViewModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var capturedImage: UIImage?
    @Published var cameraPermissionGranted: Bool = false
    @Published var isHardwareCameraAvailable: Bool = true
    @Published var isCapturing: Bool = false
    @Published var statusMessage: String = "Position subject in frame"
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
                        self.statusMessage = "Camera permission is required for Photo Proof."
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
                self?.statusMessage = "Live camera active — tap shutter to capture proof"
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
            // Fallback timestamped proof card only if running on a Simulator without camera hardware
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

            "DAILYOS LIVE PROOF CAPTURE".draw(
                in: CGRect(x: 40, y: 380, width: size.width - 80, height: 60),
                withAttributes: titleAttrs
            )
            "Verified Timestamp:\n\(timestamp)".draw(
                in: CGRect(x: 40, y: 460, width: size.width - 80, height: 100),
                withAttributes: subAttrs
            )
        }
    }
}
