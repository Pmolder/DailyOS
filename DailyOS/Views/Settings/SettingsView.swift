import SwiftUI
import AVFoundation
import CoreMotion
import UserNotifications

struct SettingsView: View {
    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var notificationScheduler = NotificationScheduler.shared

    @AppStorage(SharedModelContainer.registeredBarcodeKey)
    private var registeredBarcode: String = "DAILYOS-WAKE-QR"

    @AppStorage(SharedModelContainer.registeredBarcodeLabelKey)
    private var registeredBarcodeLabel: String = "Bathroom Mirror QR"

    @State private var showingBarcodeScanner = false
    @State private var cameraAuthStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var showingQueueInspector = false

    var body: some View {
        NavigationStack {
            Form {
                // 1. Registered Target QR / Barcode Section
                Section {
                    TextField("Location Label (e.g., Toothpaste / Mirror)", text: $registeredBarcodeLabel)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Registered Code Value")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Target Barcode / QR Payload", text: $registeredBarcode)
                            .font(.subheadline.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button {
                        showingBarcodeScanner = true
                    } label: {
                        Label("Scan & Register Target Code with Camera", systemImage: "qrcode.viewfinder")
                            .fontWeight(.semibold)
                    }
                } header: {
                    Text("QR / Barcode Dismissal Target")
                } footer: {
                    Text("Register a physical barcode (e.g., toothpaste tube) or QR code in another room. Alarms using the QR/Barcode Mission require scanning this exact code to stop ringing.")
                }

                // 2. Quick Mission & Alarm Engine Sandbox
                Section("Test Dismissal Missions & Audio Engine") {
                    Button {
                        triggerSandboxMission(.steps)
                    } label: {
                        Label("Test Step Counter Mission (20 Steps)", systemImage: "figure.walk")
                    }

                    Button {
                        triggerSandboxMission(.qrBarcode)
                    } label: {
                        Label("Test QR / Barcode Scanner Mission", systemImage: "qrcode.viewfinder")
                    }

                    Button {
                        triggerSandboxMission(.math)
                    } label: {
                        Label("Test Math Challenge Mission (3 Problems)", systemImage: "function")
                    }
                }

                // 3. 64-Pending-Notification Queue Management
                Section {
                    HStack {
                        Text("Total Queued Notifications")
                        Spacer()
                        Text("\(notificationScheduler.totalPendingCount) / \(NotificationScheduler.maxPendingLimit)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.indigo)
                    }

                    HStack {
                        Text("Alarm Fallback Burst (20x @ 5s)")
                        Spacer()
                        Text("\(notificationScheduler.pendingAlarmBurstCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Upcoming Habit Reminders")
                        Spacer()
                        Text("\(notificationScheduler.pendingHabitCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task {
                            await notificationScheduler.rescheduleAll()
                        }
                    } label: {
                        Label("Rebuild 64-Notification Queue Now", systemImage: "arrow.clockwise")
                    }

                    if !notificationScheduler.queuedSummaries.isEmpty {
                        DisclosureGroup("Inspect Queued Notifications (\(notificationScheduler.queuedSummaries.count))", isExpanded: $showingQueueInspector) {
                            ForEach(notificationScheduler.queuedSummaries.prefix(30)) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(item.title)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(item.fireDate.formatted(date: .abbreviated, time: .standard))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(item.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(item.isAlarmBurst ? .orange : .indigo)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } header: {
                    Text("Notification Queue (64-Slot Manager)")
                }

                // 4. Hardware & Permissions Diagnostics
                Section("Hardware & Permissions") {
                    HStack {
                        Label("Overnight Silent Audio Loop", systemImage: "waveform")
                        Spacer()
                        Text(alarmEngine.isSilentKeepAliveRunning ? "Active" : "Standby")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(alarmEngine.isSilentKeepAliveRunning ? .green : .secondary)
                    }

                    HStack {
                        Label("Notifications", systemImage: "bell.badge")
                        Spacer()
                        Text(notificationStatusString)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(notificationScheduler.authorizationStatus == .authorized ? .green : .orange)
                    }

                    if notificationScheduler.authorizationStatus != .authorized {
                        Button("Request Notification Permission") {
                            Task {
                                _ = await notificationScheduler.requestAuthorizationIfNeeded()
                            }
                        }
                    }

                    HStack {
                        Label("Camera (QR & Photo Proof)", systemImage: "camera")
                        Spacer()
                        Text(cameraStatusString)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(cameraAuthStatus == .authorized ? .green : .orange)
                    }

                    if cameraAuthStatus == .notDetermined {
                        Button("Request Camera Permission") {
                            AVCaptureDevice.requestAccess(for: .video) { _ in
                                Task { @MainActor in
                                    cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
                                }
                            }
                        }
                    }

                    HStack {
                        Label("CoreMotion Step Counter", systemImage: "figure.walk.motion")
                        Spacer()
                        Text(CMPedometer.isStepCountingAvailable() ? "CMPedometer Ready" : "Accelerometer Fallback")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CMPedometer.isStepCountingAvailable() ? .green : .orange)
                    }
                }

                // 5. Apple Shortcuts (AppIntents) Info
                Section("Apple Shortcuts Integration (AppIntents)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Complete Habit", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                        Text("Marks any habit completed for today directly from the iOS Shortcuts app or Siri.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Arm Morning Alarm", systemImage: "alarm.waves.left.and.right.fill")
                            .font(.subheadline.weight(.semibold))
                        Text("Arms your morning alarm, starts the overnight silent audio loop, and schedules the 20-notification fallback burst.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
                Task {
                    await notificationScheduler.refreshAuthorizationStatus()
                }
            }
            .sheet(isPresented: $showingBarcodeScanner) {
                RegisterBarcodeScannerModal { scannedCode in
                    registeredBarcode = scannedCode
                }
            }
        }
    }

    private var notificationStatusString: String {
        switch notificationScheduler.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "Authorized"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        @unknown default: return "Unknown"
        }
    }

    private var cameraStatusString: String {
        switch cameraAuthStatus {
        case .authorized: return "Authorized"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not Requested"
        @unknown default: return "Unknown"
        }
    }

    private func triggerSandboxMission(_ mission: MissionType) {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let sandboxAlarm = AlarmItem(
            label: "Sandbox Test (\(mission.shortBadge))",
            hour: now.hour ?? 7,
            minute: now.minute ?? 0,
            isEnabled: true,
            repeatDays: [],
            tone: .synthEngine,
            missionType: mission,
            stepGoal: 20,
            mathDifficulty: .medium,
            mathProblemCount: 3,
            customTargetBarcode: registeredBarcode
        )
        alarmEngine.triggerAlarm(sandboxAlarm)
    }
}
