import SwiftUI
import AVFoundation
import AudioToolbox

// MARK: - Strictly Lazy QR / Barcode Scanner Controller (AVFoundation)

@MainActor
final class QRScannerController: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    @Published var isTorchOn: Bool = false
    @Published var cameraAuthorized: Bool = false
    @Published var statusMessage: String = "Point camera at QR code or barcode"

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.patrik.dailyos.qrscanner.session")
    private var isConfigured = false
    private var isActive = false
    private var lastEmitTimestamp: CFTimeInterval = 0

    var onPayloadScanned: ((String) -> Void)?

    override init() {
        super.init()
    }

    func startScanning() {
        isActive = true
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraAuthorized = true
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.cameraAuthorized = granted
                    if granted {
                        self.configureAndStart()
                    } else {
                        self.statusMessage = "Camera permission denied. Enable Camera in Settings."
                    }
                }
            }
        default:
            cameraAuthorized = false
            statusMessage = "Camera access denied or restricted."
        }
    }

    func stopScanning() {
        isActive = false
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
            print("[QRScannerController] Torch error: \(error.localizedDescription)")
        }
    }

    private func configureAndStart() {
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

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            Task { @MainActor [weak self] in
                self?.statusMessage = "No physical camera detected on this device."
            }
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            let wanted: [AVMetadataObject.ObjectType] = [.qr, .ean13, .ean8, .code128, .upce]
            let supported = output.availableMetadataObjectTypes
            output.metadataObjectTypes = wanted.filter { supported.contains($0) }
        }

        session.commitConfiguration()
        Task { @MainActor [weak self] in
            self?.isConfigured = true
            self?.statusMessage = "Align QR code or barcode inside frame"
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let raw = readable.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastEmitTimestamp >= 0.8 else { return }
            self.lastEmitTimestamp = now
            self.onPayloadScanned?(raw)
        }
    }
}

// MARK: - Stage-1 Wake Mission QR / Barcode Scanner SubView

struct QRMissionScannerSubView: View {
    let expectedCode: String
    let onComplete: (String) -> Void

    @StateObject private var scanner = QRScannerController()
    @State private var mismatchMessage: String?
    @State private var didComplete = false

    private var hasRegisteredTarget: Bool {
        !expectedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("QR / BARCODE SCAN")
                        .font(.headline.weight(.black))
                        .foregroundStyle(SolarTheme.solarBright)
                    Text(hasRegisteredTarget
                         ? "Scan your registered wake-up code"
                         : "No QR registered — scan any valid QR/barcode")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Button {
                    scanner.toggleTorch()
                } label: {
                    Image(systemName: scanner.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.headline)
                        .foregroundStyle(scanner.isTorchOn ? Color.black : Color.white)
                        .frame(width: 40, height: 40)
                        .background(
                            scanner.isTorchOn ? SolarTheme.solarBright : Color.white.opacity(0.14),
                            in: Circle()
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .solarCard(cornerRadius: 14)

            ZStack {
                CameraPreviewView(session: scanner.captureSession)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(SolarTheme.solarCore, lineWidth: 2)
                    )

                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                    .foregroundStyle(SolarTheme.solarGold)
                    .frame(width: 220, height: 150)

                VStack {
                    Spacer()
                    Text(mismatchMessage ?? scanner.statusMessage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(mismatchMessage == nil ? Color.white : Color.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.78))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .onAppear {
            scanner.onPayloadScanned = { payload in
                guard !didComplete else { return }
                let target = expectedCode.trimmingCharacters(in: .whitespacesAndNewlines)
                if target.isEmpty || payload == target {
                    didComplete = true
                    scanner.stopScanning()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onComplete("QR/Barcode verified")
                } else {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    mismatchMessage = "Wrong code scanned! Find your registered wake-up QR/barcode."
                }
            }
            scanner.startScanning()
        }
        .onDisappear {
            scanner.stopScanning()
        }
    }
}

// MARK: - Settings QR / Barcode Registration Modal

struct WakeQRRegistrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = QRScannerController()
    let onRegistered: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Scan any physical QR code or barcode (bathroom mirror, coffee machine, toothpaste) to register it for Wake missions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                ZStack {
                    CameraPreviewView(session: scanner.captureSession)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(SolarTheme.solarCore, lineWidth: 2)
                        )

                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .foregroundStyle(SolarTheme.solarGold)
                        .frame(width: 220, height: 150)
                }
                .padding(.horizontal)

                Text(scanner.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    scanner.toggleTorch()
                } label: {
                    Label(
                        scanner.isTorchOn ? "Turn Off Flashlight" : "Turn On Flashlight",
                        systemImage: scanner.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill"
                    )
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(SolarTheme.solarCore)
                .padding(.horizontal)
            }
            .padding(.vertical)
            .background(SolarTheme.obsidian.ignoresSafeArea())
            .navigationTitle("Register Wake QR / Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        scanner.stopScanning()
                        dismiss()
                    }
                }
            }
            .onAppear {
                scanner.onPayloadScanned = { payload in
                    scanner.stopScanning()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onRegistered(payload)
                    dismiss()
                }
                scanner.startScanning()
            }
            .onDisappear {
                scanner.stopScanning()
            }
        }
        .preferredColorScheme(.dark)
    }
}
