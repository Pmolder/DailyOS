import SwiftUI
import AVFoundation
import CoreMotion
import EventKit
import UniformTypeIdentifiers
import UIKit

/// Midnight Obsidian Settings Tab: Wake QR, Solar Wake & Brain Game Sandbox, Google OAuth, Gemini Keychain & 1-Tap JSON Backup.
struct SettingsView: View {
    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var notificationScheduler = NotificationScheduler.shared
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared
    @ObservedObject private var googleAuth = GoogleAuthService.shared

    // Wake QR / Barcode State
    @State private var isWakeQRRegistered: Bool = WakeQRStorage.isRegistered
    @State private var wakeQRTruncated: String = WakeQRStorage.truncatedDisplay
    @State private var showingQRRegistrationSheet: Bool = false

    // Reflex Strike Threshold & Brain Game Practice Sandbox
    @State private var defaultReflexThresholdMs: Int = WakeQRStorage.defaultReflexThresholdMs
    @State private var practiceBrainGame: BrainGameMode?
    @State private var lastPracticeSummary: String?

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
            ZStack {
                DailyOSTheme.canvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // Top Header
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Settings")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white)
                            Text("Integrations, Missions & Backup")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(DailyOSTheme.eyebrow)
                        }
                        .padding(.top, 6)

                        // 1. Wake-Up QR / Barcode Registration
                        wakeQRCard

                        // 2. Test Solar-Orange Wake Screen & Stage-2 Brain Games
                        wakeAndBrainSandboxCard

                        // 3. Direct Google Calendar & Google Tasks Integration (OAuth 2.0 + PKCE)
                        googleIntegrationCard

                        // 4. Gemini 2.5 Flash AI Vision Keychain
                        geminiKeychainCard

                        // 5. 1-Tap SideStore JSON Backup & Restore
                        jsonBackupCard

                        // 6. Permissions & System Status
                        permissionsStatusCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 34)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                refreshQRState()
                defaultReflexThresholdMs = WakeQRStorage.defaultReflexThresholdMs
                googleClientIDInput = googleAuth.clientID
                geminiKeyInput = KeychainService.loadGeminiAPIKey()
                offlineFallbackEnabled = KeychainService.offlineVisionFallbackEnabled
                cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
                motionAuthStatus = CMPedometer.authorizationStatus()
                motionStatusText = StepCounterManager.authorizationStatusText
                alarmEngine.refreshGuidedAccessStatus()
            }
            .sheet(isPresented: $showingQRRegistrationSheet) {
                WakeQRRegistrationSheet { scannedPayload in
                    WakeQRStorage.registeredCode = scannedPayload
                    refreshQRState()
                }
            }
            .fullScreenCover(item: $practiceBrainGame) { game in
                BrainGameContainerView(
                    game: game,
                    reflexThresholdMs: defaultReflexThresholdMs,
                    isPracticeMode: true,
                    onCompleted: { summary in
                        lastPracticeSummary = summary
                        practiceBrainGame = nil
                    },
                    onCancelPractice: {
                        practiceBrainGame = nil
                    }
                )
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
                        refreshQRState()
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

    // MARK: - 1. Wake-Up QR Card

    private var wakeQRCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WAKE-UP QR / BARCODE")
                .eyebrowStyle()

            HStack(spacing: 12) {
                iconBadge("qrcode.viewfinder", color: DailyOSTheme.solarAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Target QR / Barcode")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text(isWakeQRRegistered ? wakeQRTruncated : "Scan bathroom mirror or coffee code")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(isWakeQRRegistered ? DailyOSTheme.solarAccent : DailyOSTheme.eyebrow)
                        .lineLimit(1)
                }
                Spacer()
                Text(isWakeQRRegistered ? "Registered" : "Not Set")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isWakeQRRegistered ? DailyOSTheme.emerald : DailyOSTheme.eyebrow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (isWakeQRRegistered ? DailyOSTheme.emerald : DailyOSTheme.eyebrow).opacity(0.14),
                        in: Capsule()
                    )
            }

            HStack(spacing: 10) {
                Button {
                    showingQRRegistrationSheet = true
                } label: {
                    Label(
                        isWakeQRRegistered ? "Re-Scan QR / Barcode" : "Scan & Register QR / Barcode",
                        systemImage: "camera.viewfinder"
                    )
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(DailyOSTheme.solarAccent, in: Capsule())
                }
                .buttonStyle(.plain)

                if isWakeQRRegistered {
                    Button {
                        WakeQRStorage.clear()
                        refreshQRState()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: "#FF6B6B"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color(hex: "#FF6B6B").opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .ambientCard(cornerRadius: 22)
    }

    // MARK: - 2. Test Wake Screen & Brain Games Card

    private var wakeAndBrainSandboxCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TEST WAKE SCREEN & BRAIN GAMES")
                .eyebrowStyle()

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                alarmEngine.triggerTestWakeAlarm(mission: .random, brainGame: .random)
            } label: {
                HStack(spacing: 12) {
                    iconBadge("sun.max.fill", color: DailyOSTheme.solarAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preview Solar-Orange Wake Screen")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(DailyOSTheme.solarAccent)
                        Text("Tests Stage-1 physical mission + Stage-2 brain game")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                }
            }
            .buttonStyle(.plain)

            Divider().overlay(DailyOSTheme.hairline)

            Stepper("Default Reflex Threshold: \(defaultReflexThresholdMs) ms", value: $defaultReflexThresholdMs, in: 180...350, step: 10)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .onChange(of: defaultReflexThresholdMs) { _, newValue in
                    WakeQRStorage.defaultReflexThresholdMs = newValue
                }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(BrainGameMode.playableGames) { game in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        practiceBrainGame = game
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: game.iconName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DailyOSTheme.solarAccent)
                            Text(game.displayName)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(DailyOSTheme.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let lastPracticeSummary {
                Text("Last Practice: \(lastPracticeSummary)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DailyOSTheme.emerald)
            }
        }
        .padding(18)
        .ambientCard(accent: DailyOSTheme.solarAccent, cornerRadius: 22, washOpacity: 0.06)
    }

    // MARK: - 3. Google Integration & Calendar Sources Card

    private var googleIntegrationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GOOGLE INTEGRATION & CALENDARS")
                .eyebrowStyle()

            HStack(spacing: 12) {
                iconBadge("g.circle.fill", color: DailyOSTheme.skyGlow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Calendar & Tasks")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text("Direct OAuth 2.0 + PKCE")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                }
                Spacer()
                Text(googleAuth.isConnected ? "Connected" : "Not Connected")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(googleAuth.isConnected ? DailyOSTheme.emerald : DailyOSTheme.eyebrow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (googleAuth.isConnected ? DailyOSTheme.emerald : DailyOSTheme.eyebrow).opacity(0.14),
                        in: Capsule()
                    )
            }

            TextField("Google OAuth iOS Client ID", text: $googleClientIDInput)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                .onChange(of: googleClientIDInput) { _, newValue in
                    googleAuth.updateClientID(newValue)
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
                    HStack(spacing: 8) {
                        if googleAuth.isAuthenticating {
                            ProgressView()
                                .tint(.black)
                        }
                        Text(googleAuth.isConnected ? "Reconnect Google" : "Connect Google Calendar & Tasks")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        googleClientIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? DailyOSTheme.emptyCell
                            : DailyOSTheme.skyGlow,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(googleAuth.isAuthenticating || googleClientIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if googleAuth.isConnected {
                    Button {
                        googleAuth.signOut()
                        Task { await focusManager.syncAllSources() }
                    } label: {
                        Text("Disconnect")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: "#FF6B6B"))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(hex: "#FF6B6B").opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let status = googleAuth.statusMessage {
                Text(status)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DailyOSTheme.skyGlow)
            }

            Divider().overlay(DailyOSTheme.hairline)

            Toggle("Sync Google Calendar (v3)", isOn: Binding(
                get: { googleAuth.syncGoogleCalendarEnabled },
                set: { newVal in
                    googleAuth.setGoogleCalendarSync(newVal)
                    Task { await focusManager.syncAllSources() }
                }
            ))
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white)
            .tint(DailyOSTheme.skyGlow)

            Toggle("Sync Google Tasks (v1)", isOn: Binding(
                get: { googleAuth.syncGoogleTasksEnabled },
                set: { newVal in
                    googleAuth.setGoogleTasksSync(newVal)
                    Task { await focusManager.syncAllSources() }
                }
            ))
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white)
            .tint(DailyOSTheme.skyGlow)

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
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white)
            .tint(Color(hex: "#A78BFA"))
        }
        .padding(18)
        .ambientCard(cornerRadius: 22)
    }

    // MARK: - 4. Gemini 2.5 Flash AI Vision Card

    private var geminiKeychainCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GEMINI 2.5 FLASH AI VISION")
                .eyebrowStyle()

            HStack(spacing: 12) {
                iconBadge("sparkles", color: DailyOSTheme.emerald)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Focus Photo Proof Key")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text("Stored securely in iOS Keychain")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Group {
                    if revealGeminiKey {
                        TextField("Gemini API Key", text: $geminiKeyInput)
                    } else {
                        SecureField("Gemini API Key", text: $geminiKeyInput)
                    }
                }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button {
                    revealGeminiKey.toggle()
                } label: {
                    Image(systemName: revealGeminiKey ? "eye.slash" : "eye")
                        .foregroundStyle(DailyOSTheme.eyebrow)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))

            HStack(spacing: 10) {
                Button {
                    let ok = KeychainService.saveGeminiAPIKey(geminiKeyInput)
                    keyStatusMessage = ok
                        ? (geminiKeyInput.isEmpty ? "Cleared Gemini API key." : "Saved Gemini API key in Keychain.")
                        : "Failed to save key in Keychain."
                } label: {
                    Text("Save to Keychain")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DailyOSTheme.emerald, in: Capsule())
                }
                .buttonStyle(.plain)

                if KeychainService.hasGeminiAPIKey {
                    Button {
                        KeychainService.deleteGeminiAPIKey()
                        geminiKeyInput = ""
                        keyStatusMessage = "Gemini API key removed."
                    } label: {
                        Text("Clear")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: "#FF6B6B"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color(hex: "#FF6B6B").opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let keyStatusMessage {
                Text(keyStatusMessage)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DailyOSTheme.emerald)
            }

            Divider().overlay(DailyOSTheme.hairline)

            Toggle("Offline / No-Key Verification Fallback", isOn: $offlineFallbackEnabled)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white)
                .tint(DailyOSTheme.skyGlow)
                .onChange(of: offlineFallbackEnabled) { _, newValue in
                    KeychainService.offlineVisionFallbackEnabled = newValue
                }
        }
        .padding(18)
        .ambientCard(cornerRadius: 22)
    }

    // MARK: - 5. 1-Tap JSON Backup Card

    private var jsonBackupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1-TAP JSON BACKUP (SIDESTORE)")
                .eyebrowStyle()

            HStack(spacing: 12) {
                iconBadge("externaldrive.badge.checkmark", color: Color(hex: "#A78BFA"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alarms, Habits, Logs & Focus Tasks")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text("Instant JSON export & restore")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button(action: copyBackupToClipboard) {
                    Label("Copy JSON", systemImage: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DailyOSTheme.solarAccent, in: Capsule())
                }
                .buttonStyle(.plain)

                Button(action: prepareFileExport) {
                    Label("Save File", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DailyOSTheme.inputSurface, in: Capsule())
                        .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Button(action: importBackupFromClipboard) {
                    Label("Paste JSON", systemImage: "arrow.down.doc")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DailyOSTheme.inputSurface, in: Capsule())
                        .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    showingFileImporter = true
                } label: {
                    Label("Load File", systemImage: "folder")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DailyOSTheme.inputSurface, in: Capsule())
                        .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if let backupStatusMessage {
                Text(backupStatusMessage)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(backupStatusIsError ? Color(hex: "#FF6B6B") : DailyOSTheme.emerald)
            }
        }
        .padding(18)
        .ambientCard(cornerRadius: 22)
    }

    // MARK: - 6. Permissions & System Status Card

    private var permissionsStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PERMISSIONS & SYSTEM STATUS")
                .eyebrowStyle()

            statusRow(
                icon: "lock.shield.fill",
                iconColor: alarmEngine.isGuidedAccessEnabled ? DailyOSTheme.emerald : Color(hex: "#FF6B6B"),
                title: "Guided Access",
                value: alarmEngine.isGuidedAccessEnabled ? "LOCKED" : "OFF",
                valueColor: alarmEngine.isGuidedAccessEnabled ? DailyOSTheme.emerald : Color(hex: "#FF6B6B")
            )

            Divider().overlay(DailyOSTheme.hairline)

            statusRow(
                icon: "bell.badge.fill",
                iconColor: DailyOSTheme.skyGlow,
                title: "Notifications",
                value: notificationScheduler.authorizationStatus == .authorized
                    ? "Authorized (\(notificationScheduler.totalPendingCount)/64)"
                    : "Not Authorized",
                valueColor: notificationScheduler.authorizationStatus == .authorized ? DailyOSTheme.emerald : DailyOSTheme.solarAccent
            )

            Divider().overlay(DailyOSTheme.hairline)

            statusRow(
                icon: "camera.fill",
                iconColor: DailyOSTheme.solarAccent,
                title: "Camera (Squats, QR & Proof)",
                value: cameraAuthStatus == .authorized ? "Authorized" : "Pending",
                valueColor: cameraAuthStatus == .authorized ? DailyOSTheme.emerald : DailyOSTheme.solarAccent
            )

            Divider().overlay(DailyOSTheme.hairline)

            statusRow(
                icon: "figure.walk",
                iconColor: Color(hex: "#2DD4BF"),
                title: "Motion & Fitness (Steps)",
                value: motionStatusText,
                valueColor: motionAuthStatus == .authorized ? DailyOSTheme.emerald : DailyOSTheme.solarAccent
            )

            if motionAuthStatus == .notDetermined {
                Button {
                    StepCounterManager.requestMotionPermission()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        motionAuthStatus = CMPedometer.authorizationStatus()
                        motionStatusText = StepCounterManager.authorizationStatusText
                    }
                } label: {
                    Text("Request Motion & Fitness Permission")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.skyGlow)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(DailyOSTheme.hairline)

            statusRow(
                icon: "app.badge.checkmark.fill",
                iconColor: Color(hex: "#A78BFA"),
                title: "Installed Version",
                value: installedVersionDisplay,
                valueColor: DailyOSTheme.solarAccent
            )
        }
        .padding(18)
        .ambientCard(cornerRadius: 22)
    }

    // MARK: - Helpers

    private func iconBadge(_ icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusRow(icon: String, iconColor: Color, title: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 12) {
            iconBadge(icon, color: iconColor)
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
    }

    private func refreshQRState() {
        isWakeQRRegistered = WakeQRStorage.isRegistered
        wakeQRTruncated = WakeQRStorage.truncatedDisplay
    }

    private var installedVersionDisplay: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.4.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "14"
        return "v\(short) (Build \(build))"
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
            refreshQRState()
            backupStatusIsError = false
            backupStatusMessage = summary
        } catch {
            backupStatusIsError = true
            backupStatusMessage = "Clipboard import failed: \(error.localizedDescription)"
        }
    }
}
