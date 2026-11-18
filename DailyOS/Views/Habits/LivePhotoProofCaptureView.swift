import SwiftUI
import UIKit

struct LivePhotoProofCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    let habit: HabitItem
    let onProofCompleted: (UIImage) -> Void

    @StateObject private var cameraVM = LivePhotoCaptureViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Header Info Banner
                HStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder")
                        .font(.title3)
                        .foregroundStyle(.indigo)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Photo Proof Required")
                            .font(.subheadline.weight(.bold))
                        Text("Take a live camera snapshot to complete '\(habit.title)'. Photo library uploads are disabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                // Camera Viewport or Captured Image Confirmation
                ZStack {
                    if let captured = cameraVM.capturedImage {
                        Image(uiImage: captured)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.green, lineWidth: 3)
                            )
                    } else {
                        BarcodeScannerCameraPreview(session: cameraVM.captureSession)
                            .frame(maxWidth: .infinity, maxHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.indigo.opacity(0.6), lineWidth: 2)
                            )
                    }
                }
                .padding(.horizontal)

                Text(cameraVM.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Shutter or Confirmation Controls
                if let captured = cameraVM.capturedImage {
                    HStack(spacing: 14) {
                        Button(role: .cancel) {
                            cameraVM.retakePhoto()
                        } label: {
                            Label("Retake", systemImage: "arrow.counterclockwise")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            cameraVM.stopSession()
                            onProofCompleted(captured)
                            dismiss()
                        } label: {
                            Label("Use Proof & Complete", systemImage: "checkmark.seal.fill")
                                .font(.headline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                    .padding(.horizontal)
                } else {
                    HStack(spacing: 36) {
                        Color.clear
                            .frame(width: 48, height: 48)

                        Button {
                            cameraVM.takeLivePhoto()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(Color.primary, lineWidth: 4)
                                    .frame(width: 76, height: 76)
                                Circle()
                                    .fill(Color.indigo)
                                    .frame(width: 62, height: 62)
                                Image(systemName: "camera.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                            }
                        }
                        .disabled(cameraVM.isCapturing)

                        Button {
                            cameraVM.switchCamera()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.title3)
                                .frame(width: 48, height: 48)
                                .background(Color.secondary.opacity(0.15), in: Circle())
                        }
                    }
                }
            }
            .padding(.vertical)
            .navigationTitle("Photo Proof")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cameraVM.stopSession()
                        dismiss()
                    }
                }
            }
            .onAppear {
                cameraVM.checkPermissionAndStart()
            }
            .onDisappear {
                cameraVM.stopSession()
            }
        }
    }
}

// MARK: - Captured Photo Proof Viewer Modal

struct PhotoProofViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let habitTitle: String
    let record: PhotoProofRecord

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = SharedModelContainer.loadPhotoProofImage(fileName: record.fileName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .padding(.horizontal)
                } else {
                    ContentUnavailableView(
                        "Proof Image Not Found",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("File: \(record.fileName)")
                    )
                }

                VStack(spacing: 4) {
                    Text(habitTitle)
                        .font(.headline)
                    Text("Captured on \(record.capturedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Verified Photo Proof")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
