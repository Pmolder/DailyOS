import SwiftUI
import Combine
import UIKit

/// Midnight Obsidian live camera spot-check sheet with 30s glowing countdown ring,
/// rhythmic 1.5s haptic buzz (with mute-buzz toggle), and Gemini 3.5 Flash-Lite verification.
struct PhotoProofCaptureSheet: View {
    let request: ActivePhotoProofRequest

    @ObservedObject private var scheduler = PhotoProofScheduler.shared
    @StateObject private var cameraVM = LivePhotoCaptureViewModel()

    @State private var remainingSeconds: Int
    @State private var totalWindowSeconds: Int
    @State private var isBuzzMuted: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var statusFeedback: String? = nil
    @State private var statusIsError: Bool = false
    @State private var statusIsVerified: Bool = false

    private let countdownTick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private let hapticTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init(request: ActivePhotoProofRequest) {
        self.request = request
        let secsLeft = max(1, Int(ceil(request.deadline.timeIntervalSinceNow)))
        let configured = max(secsLeft, PhotoProofSettings.photoCaptureSeconds)
        _remainingSeconds = State(initialValue: secsLeft)
        _totalWindowSeconds = State(initialValue: configured)
    }

    private var ringProgress: Double {
        guard totalWindowSeconds > 0 else { return 0 }
        return max(0.0, min(1.0, Double(remainingSeconds) / Double(totalWindowSeconds)))
    }

    private var countdownAccent: Color {
        if statusIsVerified { return DailyOSTheme.emerald }
        return remainingSeconds <= 10 ? Color(hex: "#FF6B6B") : DailyOSTheme.skyGlow
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 16) {
                // Top Bar: Countdown Ring + Task Header + Mute Buzz Toggle
                HStack(spacing: 12) {
                    // Glowing Circular Countdown Ring
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.09), lineWidth: 3.5)
                            .frame(width: 52, height: 52)
                        Circle()
                            .trim(from: 0, to: ringProgress)
                            .stroke(countdownAccent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 52, height: 52)
                            .shadow(color: countdownAccent.opacity(0.55), radius: 6)
                            .animation(.linear(duration: 0.9), value: ringProgress)
                        Text("\(remainingSeconds)s")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(countdownAccent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.isInitialCheck ? "INITIAL PHOTO PROOF" : "SPOT-CHECK PHOTO PROOF")
                            .eyebrowStyle()
                        Text(request.taskTitle)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Mute Buzz Button so user can steady their shot
                    FrostedCircleButton(
                        icon: isBuzzMuted ? "bell.slash.fill" : "bell.and.waves.left.and.right",
                        size: 38,
                        tint: isBuzzMuted ? DailyOSTheme.eyebrow : countdownAccent
                    ) {
                        isBuzzMuted.toggle()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                // Feedback Status Banner
                if let statusFeedback {
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView().tint(DailyOSTheme.skyGlow)
                        } else {
                            Image(systemName: statusIsVerified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(statusIsVerified ? DailyOSTheme.emerald : Color(hex: "#FF6B6B"))
                        }
                        Text(statusFeedback)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(statusIsVerified ? DailyOSTheme.emerald : (statusIsError ? Color(hex: "#FF6B6B") : Color.white))
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .ambientCard(
                        accent: statusIsVerified ? DailyOSTheme.emerald : (statusIsError ? Color(hex: "#FF6B6B") : DailyOSTheme.skyGlow),
                        cornerRadius: 14,
                        washOpacity: 0.14
                    )
                    .padding(.horizontal, 18)
                }

                // Live Rounded Camera Viewfinder
                ZStack {
                    if let captured = cameraVM.capturedImage {
                        Image(uiImage: captured)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(countdownAccent, lineWidth: 2)
                            )
                    } else {
                        CameraPreviewView(session: cameraVM.captureSession)
                            .frame(maxWidth: .infinity, maxHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(countdownAccent.opacity(0.7), lineWidth: 2)
                            )
                    }
                }
                .padding(.horizontal, 18)

                Text("Live camera only • Snap a clear shot showing your task in progress.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DailyOSTheme.eyebrow)

                Spacer(minLength: 0)

                // Bottom Action Controls
                if let captured = cameraVM.capturedImage {
                    HStack(spacing: 12) {
                        Button {
                            statusFeedback = nil
                            statusIsError = false
                            cameraVM.retakePhoto()
                        } label: {
                            Label("Retake", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(DailyOSTheme.buttonSurface, in: Capsule())
                                .overlay(Capsule().stroke(DailyOSTheme.buttonStroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)

                        Button {
                            submitPhoto(captured)
                        } label: {
                            HStack(spacing: 8) {
                                if isSubmitting {
                                    ProgressView().tint(.black)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isSubmitting ? "Verifying..." : "Verify Proof")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(DailyOSTheme.emerald, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                } else {
                    HStack(spacing: 36) {
                        Button {
                            cameraVM.stopSession()
                            scheduler.markMissedAndDismiss(request)
                        } label: {
                            Text("Skip")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(DailyOSTheme.eyebrow)
                                .frame(width: 52, height: 52)
                                .background(DailyOSTheme.buttonSurface, in: Circle())
                        }
                        .buttonStyle(.plain)

                        // Large Tactile Shutter Button
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            cameraVM.takeLivePhoto()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(Color.white, lineWidth: 4)
                                    .frame(width: 78, height: 78)
                                Circle()
                                    .fill(countdownAccent)
                                    .frame(width: 64, height: 64)
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(Color.black)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(cameraVM.isCapturing)

                        FrostedCircleButton(icon: "arrow.triangle.2.circlepath.camera", size: 52) {
                            cameraVM.switchCamera()
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .onAppear {
            cameraVM.checkPermissionAndStart()
            fireHapticBuzz()
        }
        .onDisappear {
            cameraVM.stopSession()
        }
        .onReceive(countdownTick) { _ in
            guard !isSubmitting && !statusIsVerified else { return }
            let left = Int(ceil(request.deadline.timeIntervalSinceNow))
            if left > 0 {
                remainingSeconds = left
            } else {
                remainingSeconds = 0
                cameraVM.stopSession()
                scheduler.markMissedAndDismiss(request)
            }
        }
        .onReceive(hapticTick) { _ in
            guard !isBuzzMuted && !isSubmitting && !statusIsVerified && cameraVM.capturedImage == nil else { return }
            fireHapticBuzz()
        }
    }

    private func fireHapticBuzz() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func submitPhoto(_ image: UIImage) {
        isSubmitting = true
        statusIsError = false
        statusFeedback = "Verifying live photo..."

        Task {
            let result = await GeminiVisionService.verifyFocusPhoto(
                image: image,
                taskTitle: request.taskTitle,
                taskDescription: request.taskNotes
            )

            await MainActor.run {
                isSubmitting = false
                if result.verified {
                    statusIsVerified = true
                    statusIsError = false
                    statusFeedback = "Verified ✓ — \(result.reason)"
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    cameraVM.stopSession()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        scheduler.markVerifiedAndDismiss(request)
                    }
                } else if result.noAPIKeyConfigured {
                    // Graceful local confirmation when no Gemini key is set yet
                    statusIsVerified = true
                    statusIsError = false
                    statusFeedback = "Photo Saved ✓ — Add a free Google AI Studio key in Settings for AI verification."
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    cameraVM.stopSession()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        scheduler.markVerifiedAndDismiss(request)
                    }
                } else {
                    statusIsError = true
                    statusFeedback = result.reason
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    cameraVM.retakePhoto()
                }
            }
        }
    }
}
