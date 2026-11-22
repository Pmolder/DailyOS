import SwiftUI
import AVFoundation
import CoreMotion
import EventKit
import UniformTypeIdentifiers
import UIKit

/// Compact Settings, Google OAuth Integration & SideStore JSON Backup sheet.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var notificationScheduler = NotificationScheduler.shared
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared
    @ObservedObject private var googleAuth = GoogleAuthService.shared

    // Google Integration State
    @State private var googleClientIDInput: String = ""

    // Gemini Keychain State
    @State private var geminiKeyInput: String = ""
    @State private var revealGeminiKey: Bool = false
    @State private var offlineFallbackEnabled: Bool = KeychainService.offlineVisionFallbackEnabled
    @State private var keyStatusMessage: String?

    // Backup Export/Import State
    @State private var backupStatusMessage: String?
    @State private var backupStatusIsError: Bool = false
    @State private var showingFileExporter: Bool = false
    @State private var showingFileImporter: Bool = false
    @State private var exportDocument = DailyOSBackupDocument()

    // Permissions (populated lazily in .onAppear so no hardware APIs run at init time)
    @State private var cameraAuthStatus: AVAuthorizationStatus = .notDetermined
    @State private var motionStatusText: String = "Not Requested"
    @State private var motionAuthStatus: CMAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            Form {
                // 1. Direct Google Calendar & Google Tasks Integration (OAuth 2.0 + PKCE)
                Section {
                    TextField("Google OAuth iOS Client ID", text: $googleClientIDInput)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: googleClientIDInput) { _, newValue in
                            googleAuth.updateClientID(newValue)
                        }

                    HStack {
                        Text("Connection Status")
                        Spacer()
                        Text(googleAuth.isConnected ? "Connected" : "Not Connected")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(googleAuth.isConnected ? Color.green : Color.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            googleAuth.updateClientID(googleClientIDInput)
                            Task {
                                await googleAuth.connectGoogle()
                                if googleAuth.isConnected {
                                    await focusManager.syncAllSources()
                                }
                            }
                        } label: {
                            HStack {
                                if googleAuth.isAuthenticating {
                                    ProgressView()
                                }
                                Text(googleAuth.isConnected ? "Reconnect Google" : "Connect Google Calendar & Tasks")
                                    .font(.subheadline.weight(.bold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(googleAuth.isAuthenticating || googleClientIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if googleAuth.isConnected {
                            Button("Disconnect", role: .destructive) {
                                googleAuth.signOut()
                                Task { await focusManager.syncAllSources() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if let status = googleAuth.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }

                    Toggle("Sync Google Calendar (v3)", isOn: Binding(
                        get: { googleAuth.syncGoogleCalendarEnabled },
                        set: { newVal in
                            googleAuth.setGoogleCalendarSync(newVal)
                            Task { await focusManager.syncAllSources() }
                        }
                    ))

                    Toggle("Sync Google Tasks (v1)", isOn: Binding(
                        get: { googleAuth.syncGoogleTasksEnabled },
                        set: { newVal in
                            googleAuth.setGoogleTasksSync(newVal)
                            Task { await focusManager.syncAllSources() }
                        }
                    ))

                    Toggle("Optional: Sync Apple Calendar (EventKit)", isOn: Binding(
                        get: { focusManager.appleCalendarSyncEnabled },
                        set: { enabled in
                            if enabled && !focusManager.isAppleCalendarAuthorized {
                                Task { await focusManager.requestAppleCalendarAccess() }
                            } else {
                                focusManager.setAppleCalendarSyncEnabled(enabled)
                            }
                        }
                    ))
                } header: {
                    Text("Google Integration & Calendar Sources")
                } footer: {
                    Text("Uses native ASWebAuthenticationSession + OAuth 2.0 PKCE with calendar.readonly and tasks.readonly scopes. Tokens are stored securely in iOS Keychain.")
                }

                // 2. Gemini 2.5 Flash API Key (Keychain)
                Section {
                    HStack(spacing: 8) {
                        Group {
                            if revealGeminiKey {
                                TextField("Gemini API Key", text: $geminiKeyInput)
                            } else {
                                SecureField("Gemini API Key", text: $geminiKeyInput)
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
                                ? (geminiKeyInput.isEmpty ? "Cleared Gemini API key." : "Saved Gemini API key in Keychain.")
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
                }

                // 3. 1-Tap SideStore JSON Backup & Restore
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
                            .foregroundStyle(backupStatusIsError ? Color.red : Color.green)
                    }
                } header: {
                    Text("1-Tap JSON Backup (SideStore Protection)")
                } footer: {
                    Text("Export alarms, habits, 12-week heatmap history, and scheduled focus tasks to Clipboard or Files before weekly SideStore re-installs.")
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
                        title: "Camera (Squats & Proof)",
                        value: cameraAuthStatus == .authorized ? "Authorized" : "Pending",
                        color: cameraAuthStatus == .authorized ? .green : .orange
                    )
                    HStack {
                        Text("Motion & Fitness (Steps)")
                        Spacer()
                        Text(motionStatusText)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(motionAuthStatus == .authorized ? Color.green : Color.orange)
                    }
                    if motionAuthStatus == .notDetermined {
                        Button("Request Motion & Fitness Permission") {
                            StepCounterManager.requestMotionPermission()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                motionAuthStatus = CMPedometer.authorizationStatus()
                                motionStatusText = StepCounterManager.authorizationStatusText
                            }
                        }
                    }

                    HStack {
                        Text("Installed Version")
                        Spacer()
                        Text(installedVersionDisplay)
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(.cyan)
                    }
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
                googleClientIDInput = googleAuth.clientID
                geminiKeyInput = KeychainService.loadGeminiAPIKey()
                offlineFallbackEnabled = KeychainService.offlineVisionFallbackEnabled
                cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
                motionAuthStatus = CMPedometer.authorizationStatus()
                motionStatusText = StepCounterManager.authorizationStatusText
                alarmEngine.refreshGuidedAccessStatus()
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
        .environment(\.calendar, ISOWeekCalendar.current)
        .environment(\.locale, Locale(identifier: "en_GB"))
    }

    private var installedVersionDisplay: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "10"
        return "v\(short) (Build \(build))"
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
