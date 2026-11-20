import SwiftUI
import AVFoundation
import EventKit
import UniformTypeIdentifiers
import UIKit

/// Compact Settings & SideStore Backup sheet accessible from the top bar across all 3 tabs.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var notificationScheduler = NotificationScheduler.shared
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared

    @AppStorage(SharedModelContainer.registeredBarcodeKey)
    private var registeredBarcode: String = "DAILYOS-WAKE-QR"

    @AppStorage(SharedModelContainer.registeredBarcodeLabelKey)
    private var registeredBarcodeLabel: String = "Bathroom Mirror QR"

    // Gemini Keychain state
    @State private var geminiKeyInput: String = ""
    @State private var revealGeminiKey: Bool = false
    @State private var offlineFallbackEnabled: Bool = KeychainService.offlineVisionFallbackEnabled
    @State private var keyStatusMessage: String?

    // Backup Export/Import state
    @State private var backupStatusMessage: String?
    @State private var backupStatusIsError: Bool = false
    @State private var showingFileExporter: Bool = false
    @State private var showingFileImporter: Bool = false
    @State private var exportDocument = DailyOSBackupDocument()

    // Barcode Scanner & Permissions
    @State private var showingBarcodeScanner = false
    @State private var cameraAuthStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Form {
                // 1. 1-Tap SideStore JSON Backup & Restore
                Section {
                    HStack(spacing: 10) {
                        Button {
                            copyBackupToClipboard()
                        } label: {
                            Label("Copy JSON", systemImage: "doc.on.clipboard")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)

                        Button {
                            prepareFileExport()
                        } label: {
                            Label("Save File", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 10) {
                        Button {
                            importBackupFromClipboard()
                        } label: {
                            Label("Paste JSON", systemImage: "arrow.down.doc")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("Load File", systemImage: "folder")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let backupStatusMessage {
                        Text(backupStatusMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(backupStatusIsError ? .red : .green)
                    }
                } header: {
                    Text("1-Tap JSON Backup (SideStore Protection)")
                } footer: {
                    Text("Export all alarms, habits, 12-week heatmap history, and focus logs to Clipboard or Files before weekly SideStore re-installs.")
                }

                // 2. Gemini API Key (Keychain) for Tab 3 AI Verification
                Section {
                    HStack(spacing: 8) {
                        Group {
                            if revealGeminiKey {
                                TextField("AIza... (Gemini API Key)", text: $geminiKeyInput)
                            } else {
                                SecureField("AIza... (Gemini API Key)", text: $geminiKeyInput)
                            }
                        }
                        .font(.subheadline.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            revealGeminiKey.toggle()
                        } label: {
                            Image(systemName: revealGeminiKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 10) {
                        Button("Save to Keychain") {
                            let ok = KeychainService.saveGeminiAPIKey(geminiKeyInput)
                            keyStatusMessage = ok
                                ? (geminiKeyInput.isEmpty ? "Cleared Gemini API key from Keychain." : "Saved Gemini API key securely in Keychain.")
                                : "Failed to save key in Keychain."
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        if KeychainService.hasGeminiAPIKey {
                            Button("Clear", role: .destructive) {
                                KeychainService.deleteGeminiAPIKey()
                                geminiKeyInput = ""
                                keyStatusMessage = "Gemini API key removed."
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if let keyStatusMessage {
                        Text(keyStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Toggle("Offline / No-Key Verification Fallback", isOn: $offlineFallbackEnabled)
                        .onChange(of: offlineFallbackEnabled) { _, newValue in
                            KeychainService.offlineVisionFallbackEnabled = newValue
                        }
                } header: {
                    Text("Gemini 2.5 Flash AI Vision (Tab 3 Focus)")
                } footer: {
                    Text("Stored locally in iOS Keychain. Enable Offline Fallback if you want to test the Focus photo check-in loop without a Gemini API key.")
                }

                // 3. QR / Barcode Dismissal Target Registration
                Section("Wake QR / Barcode Mission Target") {
                    TextField("Location Label (e.g., Bathroom Toothpaste)", text: $registeredBarcodeLabel)
                    TextField("Registered Code Payload", text: $registeredBarcode)
                        .font(.subheadline.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        showingBarcodeScanner = true
                    } label: {
                        Label("Scan & Register Target Barcode", systemImage: "qrcode.viewfinder")
                            .foregroundStyle(.orange)
                    }
                }

                // 4. Permissions & Diagnostics
                Section("Permissions & System Status") {
                    statusRow(
                        title: "Guided Access",
                        value: alarmEngine.isGuidedAccessEnabled ? "LOCKED" : "OFF",
                        color: alarmEngine.isGuidedAccessEnabled ? .green : .red
                    )
                    statusRow(
                        title: "Notifications",
                        value: notificationScheduler.authorizationStatus == .authorized
                            ? "Authorized (\(notificationScheduler.totalPendingCount)/64)"
                            : "Not Authorized",
                        color: notificationScheduler.authorizationStatus == .authorized ? .green : .orange
                    )
                    statusRow(
                        title: "Camera (Vision & Proof)",
                        value: cameraAuthStatus == .authorized ? "Authorized" : "Pending",
                        color: cameraAuthStatus == .authorized ? .green : .orange
                    )
                    statusRow(
                        title: "Calendars (EventKit)",
                        value: focusManager.isCalendarAuthorized ? "Full Access" : "Not Connected",
                        color: focusManager.isCalendarAuthorized ? .green : .orange
                    )
                }
            }
            .navigationTitle("Settings & Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.bold)
                }
            }
            .onAppear {
                geminiKeyInput = KeychainService.loadGeminiAPIKey()
                offlineFallbackEnabled = KeychainService.offlineVisionFallbackEnabled
                cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
                alarmEngine.refreshGuidedAccessStatus()
            }
            .sheet(isPresented: $showingBarcodeScanner) {
                RegisterBarcodeScannerModal { scannedCode in
                    registeredBarcode = scannedCode
                }
            }
            .fileExporter(
                isPresented: $showingFileExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "DailyOS_Backup_\(HabitItem.dateKey())"
            ) { result in
                switch result {
                case .success:
                    backupStatusIsError = false
                    backupStatusMessage = "Exported JSON backup file successfully."
                case .failure(let error):
                    backupStatusIsError = true
                    backupStatusMessage = "Export failed: \(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let fileURL = urls.first else { return }
                    let accessing = fileURL.startAccessingSecurityScopedResource()
                    defer {
                        if accessing { fileURL.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        let data = try Data(contentsOf: fileURL)
                        let summary = try BackupService.importJSONData(data)
                        backupStatusIsError = false
                        backupStatusMessage = summary
                    } catch {
                        backupStatusIsError = true
                        backupStatusMessage = "Import failed: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    backupStatusIsError = true
                    backupStatusMessage = "Could not open file: \(error.localizedDescription)"
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func statusRow(title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
        }
    }

    private func copyBackupToClipboard() {
        do {
            let json = try BackupService.exportJSONString()
            UIPasteboard.general.string = json
            backupStatusIsError = false
            backupStatusMessage = "Copied full JSON backup to Clipboard (\(json.count) chars)."
        } catch {
            backupStatusIsError = true
            backupStatusMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    private func prepareFileExport() {
        do {
            let data = try BackupService.exportJSONData()
            exportDocument = DailyOSBackupDocument(jsonData: data)
            showingFileExporter = true
        } catch {
            backupStatusIsError = true
            backupStatusMessage = "Export preparation failed: \(error.localizedDescription)"
        }
    }

    private func importBackupFromClipboard() {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8) else {
            backupStatusIsError = true
            backupStatusMessage = "Clipboard does not contain a valid DailyOS JSON backup."
            return
        }
        do {
            let summary = try BackupService.importJSONData(data)
            backupStatusIsError = false
            backupStatusMessage = summary
        } catch {
            backupStatusIsError = true
            backupStatusMessage = "Clipboard import failed: \(error.localizedDescription)"
        }
    }
}
