import SwiftUI
import SwiftData

struct AlarmEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let alarmToEdit: AlarmItem?

    @State private var selectedTime: Date = Date()
    @State private var label: String = "Nuclear Wake Up"
    @State private var repeatDays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var selectedTone: AlarmTone = .nuclearSiren
    @State private var selectedMission: MissionType = .pushups
    @State private var repGoal: Int = 15
    @State private var customTargetBarcode: String = ""
    @State private var showingBarcodeScannerSheet: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                // Time Wheel Picker
                Section {
                    DatePicker(
                        "Alarm Time",
                        selection: $selectedTime,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                // Label & Repeat Schedule
                Section("Label & Schedule") {
                    TextField("Alarm Label", text: $label)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Repeat Days")
                                .font(.subheadline)
                            Spacer()
                            Text(Weekday.formatSummary(for: repeatDays))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }

                        HStack(spacing: 6) {
                            ForEach(Weekday.allCases) { day in
                                let isSelected = repeatDays.contains(day.rawValue)
                                Button {
                                    if isSelected {
                                        repeatDays.remove(day.rawValue)
                                    } else {
                                        repeatDays.insert(day.rawValue)
                                    }
                                } label: {
                                    Text(day.shortName)
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(
                                            isSelected ? Color.orange : Color.secondary.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                        .foregroundStyle(isSelected ? .black : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Nuclear Alarm Tone Selection
                Section("Escalating Alarm Siren") {
                    Picker("Siren Tone", selection: $selectedTone) {
                        ForEach(AlarmTone.allCases) { tone in
                            Text(tone.displayName).tag(tone)
                        }
                    }

                    Button {
                        AlarmEngine.shared.previewAlarmTone(selectedTone)
                    } label: {
                        Label("Preview Siren (2.5s)", systemImage: "speaker.wave.3.fill")
                            .foregroundStyle(.orange)
                    }

                    Text("Escalation curve: 0:00–0:30 haptic pulses (0% volume) → 0:30–1:00 ramp to 30% → 1:00–1:30 ramp to 100%.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Anti-Cheat Dismissal Mission
                Section("Anti-Cheat Dismissal Mission") {
                    Picker("Mission Mode", selection: $selectedMission) {
                        ForEach(MissionType.wakeModes) { mission in
                            Label(mission.displayName, systemImage: mission.iconName)
                                .tag(mission)
                        }
                    }
                    .onChange(of: selectedMission) { _, newMission in
                        if newMission == .pushups && repGoal == 20 {
                            repGoal = 15
                        } else if newMission == .squats && repGoal == 15 {
                            repGoal = 20
                        }
                    }

                    switch selectedMission {
                    case .pushups:
                        Stepper("Target Pushups: \(repGoal) reps", value: $repGoal, in: 5...50, step: 5)
                        Text("100% on-device Apple Vision front-camera body pose. Counts a rep when elbow angle drops < 95° with straight torso and extends > 155°.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    case .squats:
                        Stepper("Target Squats: \(repGoal) reps", value: $repGoal, in: 5...60, step: 5)
                        Text("100% on-device Apple Vision front-camera body pose. Counts a rep when hip-knee angle drops < 100° and returns upright.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    case .qrBarcode:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Default Target Code: \(SharedModelContainer.shared.registeredBarcode)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            TextField("Optional Per-Alarm Target Code", text: $customTargetBarcode)
                                .font(.subheadline.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            Button {
                                showingBarcodeScannerSheet = true
                            } label: {
                                Label("Scan Barcode / QR with Camera", systemImage: "qrcode.viewfinder")
                                    .foregroundStyle(.orange)
                            }
                        }

                    default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle(alarmToEdit == nil ? "New Wake Alarm" : "Edit Wake Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        AlarmEngine.shared.stopPreview()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        AlarmEngine.shared.stopPreview()
                        saveAlarm()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear(perform: loadInitialValues)
            .onDisappear {
                AlarmEngine.shared.stopPreview()
            }
            .sheet(isPresented: $showingBarcodeScannerSheet) {
                RegisterBarcodeScannerModal { scannedCode in
                    customTargetBarcode = scannedCode
                }
            }
        }
    }

    private func loadInitialValues() {
        let calendar = Calendar.current
        if let alarm = alarmToEdit {
            var comps = calendar.dateComponents([.year, .month, .day], from: Date())
            comps.hour = alarm.hour
            comps.minute = alarm.minute
            selectedTime = calendar.date(from: comps) ?? Date()
            label = alarm.label
            repeatDays = alarm.repeatDays
            selectedTone = alarm.tone
            selectedMission = MissionType.wakeModes.contains(alarm.missionType) ? alarm.missionType : .pushups
            repGoal = max(5, alarm.repGoal)
            customTargetBarcode = alarm.customTargetBarcode
        } else {
            var comps = calendar.dateComponents([.year, .month, .day], from: Date())
            comps.hour = 7
            comps.minute = 0
            selectedTime = calendar.date(from: comps) ?? Date()
        }
    }

    private func saveAlarm() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
        let hour = comps.hour ?? 7
        let minute = comps.minute ?? 0
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Nuclear Wake Up"
            : label.trimmingCharacters(in: .whitespacesAndNewlines)

        if let alarm = alarmToEdit {
            alarm.label = cleanLabel
            alarm.hour = hour
            alarm.minute = minute
            alarm.repeatDays = repeatDays
            alarm.tone = selectedTone
            alarm.missionType = selectedMission
            alarm.repGoal = repGoal
            alarm.customTargetBarcode = customTargetBarcode.trimmingCharacters(in: .whitespacesAndNewlines)
            alarm.lastTriggeredMinuteKey = ""
            alarm.isEnabled = true
        } else {
            let newAlarm = AlarmItem(
                label: cleanLabel,
                hour: hour,
                minute: minute,
                isEnabled: true,
                repeatDays: repeatDays,
                tone: selectedTone,
                missionType: selectedMission,
                repGoal: repGoal,
                customTargetBarcode: customTargetBarcode.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            modelContext.insert(newAlarm)
        }

        SharedModelContainer.shared.save()
        AlarmEngine.shared.syncWithAlarms()
    }
}

// MARK: - Reusable Live QR/Barcode Registration Scanner Modal

struct RegisterBarcodeScannerModal: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scannerVM = BarcodeScannerViewModel()
    let onScanned: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Aim camera at any QR code or barcode (e.g. bathroom/kitchen item) to register it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                ZStack {
                    BarcodeScannerCameraPreview(session: scannerVM.captureSession)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .foregroundStyle(.orange)
                        .frame(width: 220, height: 150)
                }
                .padding(.horizontal)

                Text(scannerVM.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    scannerVM.toggleTorch()
                } label: {
                    Label(
                        scannerVM.isTorchOn ? "Turn Off Flashlight" : "Turn On Flashlight",
                        systemImage: scannerVM.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationTitle("Register Target Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        scannerVM.stopSession()
                        dismiss()
                    }
                }
            }
            .onAppear {
                scannerVM.onCodeDetected = { code, _ in
                    scannerVM.stopSession()
                    onScanned(code)
                    dismiss()
                }
                scannerVM.checkPermissionAndStart()
            }
            .onDisappear {
                scannerVM.stopSession()
            }
        }
    }
}
