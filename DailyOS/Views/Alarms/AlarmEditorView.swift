import SwiftUI
import SwiftData

struct AlarmEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let alarmToEdit: AlarmItem?

    @State private var selectedTime: Date = Date()
    @State private var label: String = ""
    @State private var repeatDays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var selectedTone: AlarmTone = .nuclearSiren

    // Stage-1 Physical Mission (defaults to Daily Random)
    @State private var selectedMission: MissionType = .random
    @State private var repGoal: Int = 15
    @State private var stepGoal: Int = 500
    @State private var customStepsText: String = "500"
    @State private var stepsLimitMinutes: Int = 10
    @State private var stepsLimitExtraSeconds: Int = 0
    @State private var qrGraceSeconds: Int = 60

    // Stage-2 Cognitive Brain Game (defaults to Daily Random)
    @State private var selectedBrainGame: BrainGameMode = .random
    @State private var reflexThresholdMs: Int = WakeQRStorage.defaultReflexThresholdMs

    private let stepPresets: [Int] = [200, 500, 1000, 2000]
    private let timeLimitMinutePresets: [Int] = [2, 5, 10, 15, 20]

    private var totalStepsLimitSeconds: Int {
        max(30, min(3600, (stepsLimitMinutes * 60) + stepsLimitExtraSeconds))
    }

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

                // Label & ISO-8601 Monday-First Repeat Schedule
                Section("Label & Schedule (Mon–Sun)") {
                    TextField("Alarm Label", text: $label)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Repeat Days")
                                .font(.subheadline)
                            Spacer()
                            Text(Weekday.formatSummary(for: repeatDays))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SolarTheme.solarBright)
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
                                            isSelected ? SolarTheme.solarCore : Color.secondary.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                        .foregroundStyle(isSelected ? Color.black : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Escalating Alarm Siren
                Section("Hardware Volume Alarm Siren") {
                    Picker("Siren Tone", selection: $selectedTone) {
                        ForEach(AlarmTone.allCases) { tone in
                            Text(tone.displayName).tag(tone)
                        }
                    }

                    Button {
                        AlarmEngine.shared.previewAlarmTone(selectedTone)
                    } label: {
                        Label("Preview Siren (2.5s)", systemImage: "speaker.wave.3.fill")
                            .foregroundStyle(SolarTheme.solarBright)
                    }
                }

                // Stage-1 Physical Challenge Configuration
                Section {
                    Picker("Stage-1 Physical Mission", selection: $selectedMission) {
                        ForEach(MissionType.allCases) { mission in
                            Label(mission.displayName, systemImage: mission.iconName)
                                .tag(mission)
                        }
                    }

                    if selectedMission == .random {
                        Text("Rolls daily among Squats, Steps\(WakeQRStorage.isRegistered ? ", and QR Scan" : " (register a QR in Settings to include QR Scan)") without repeating yesterday's mission. Configure each pool mission's targets below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Squats Settings (shown for .squats and .random)
                    if selectedMission == .squats || selectedMission == .random {
                        VStack(alignment: .leading, spacing: 6) {
                            Stepper("Squats Target: \(repGoal) reps", value: $repGoal, in: 5...60, step: 5)
                            Text("30s initial grace for Rep 1 → 5s per rep thereafter with stateful resume-volume penalty.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Steps Settings (shown for .steps and .random)
                    if selectedMission == .steps || selectedMission == .random {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Steps Target")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                TextField("500", text: $customStepsText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .font(.subheadline.monospacedDigit().weight(.bold))
                                    .foregroundStyle(SolarTheme.solarBright)
                                    .frame(width: 72)
                                    .onChange(of: customStepsText) { _, newValue in
                                        if let parsed = Int(newValue) {
                                            stepGoal = max(50, min(5000, parsed))
                                        }
                                    }
                                Text("steps")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 6) {
                                ForEach(stepPresets, id: \.self) { preset in
                                    let active = stepGoal == preset
                                    Button {
                                        stepGoal = preset
                                        customStepsText = "\(preset)"
                                    } label: {
                                        Text("\(preset)")
                                            .font(.caption2.weight(.bold).monospacedDigit())
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 6)
                                            .background(
                                                active ? SolarTheme.solarCore : Color.white.opacity(0.08),
                                                in: RoundedRectangle(cornerRadius: 8)
                                            )
                                            .foregroundStyle(active ? Color.black : Color.white)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Stepper("Adjust Steps (±50)", value: Binding(
                                get: { stepGoal },
                                set: { newVal in
                                    stepGoal = max(50, min(5000, newVal))
                                    customStepsText = "\(stepGoal)"
                                }
                            ), in: 50...5000, step: 50)

                            Divider()

                            HStack {
                                Text("Steps Time Limit")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(formattedLimitLabel)
                                    .font(.subheadline.monospacedDigit().weight(.bold))
                                    .foregroundStyle(SolarTheme.solarGold)
                            }

                            HStack(spacing: 6) {
                                ForEach(timeLimitMinutePresets, id: \.self) { mins in
                                    let active = stepsLimitMinutes == mins && stepsLimitExtraSeconds == 0
                                    Button {
                                        stepsLimitMinutes = mins
                                        stepsLimitExtraSeconds = 0
                                    } label: {
                                        Text("\(mins)m")
                                            .font(.caption2.weight(.bold).monospacedDigit())
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 6)
                                            .background(
                                                active ? SolarTheme.solarCore : Color.white.opacity(0.08),
                                                in: RoundedRectangle(cornerRadius: 8)
                                            )
                                            .foregroundStyle(active ? Color.black : Color.white)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Stepper("Minutes: \(stepsLimitMinutes) min", value: $stepsLimitMinutes, in: 0...60, step: 1)
                            Stepper("Seconds: \(stepsLimitExtraSeconds) sec", value: $stepsLimitExtraSeconds, in: 0...55, step: 5)
                        }
                        .padding(.vertical, 4)
                    }

                    // QR / Barcode Settings (shown for .qrBarcode and .random)
                    if selectedMission == .qrBarcode || selectedMission == .random {
                        VStack(alignment: .leading, spacing: 6) {
                            Stepper("QR Walk Grace: \(qrGraceSeconds)s", value: $qrGraceSeconds, in: 20...180, step: 10)
                            HStack {
                                Text("Wake QR Code Status")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(WakeQRStorage.isRegistered ? "Registered ✅" : "Not Set (Settings)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(WakeQRStorage.isRegistered ? Color.green : Color.orange)
                            }
                        }
                    }
                } header: {
                    Text("Stage 1 • Physical Mission")
                }

                // Stage-2 Cognitive Brain Game Configuration
                Section {
                    Picker("Stage-2 Brain Game", selection: $selectedBrainGame) {
                        ForEach(BrainGameMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.iconName)
                                .tag(mode)
                        }
                    }

                    if selectedBrainGame == .random || selectedBrainGame == .reflexStrike {
                        Stepper("Reflex Strike Threshold: \(reflexThresholdMs) ms", value: $reflexThresholdMs, in: 180...350, step: 10)
                    }

                    if selectedBrainGame == .random {
                        Text("Rotates daily across Reflex Strike, Memory Grid, Math Sprint, and Node Connect without repeating yesterday's game.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Stage 2 • Brain Activation Game")
                }
            }
            .scrollContentBackground(.hidden)
            .background(SolarTheme.obsidian)
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
        }
        .preferredColorScheme(.dark)
        .environment(\.calendar, ISOWeekCalendar.current)
        .environment(\.locale, Locale(identifier: "en_GB"))
    }

    private var formattedLimitLabel: String {
        let secs = totalStepsLimitSeconds
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func loadInitialValues() {
        let calendar = ISOWeekCalendar.current
        if let alarm = alarmToEdit {
            var comps = calendar.dateComponents([.year, .month, .day], from: Date())
            comps.hour = alarm.hour
            comps.minute = alarm.minute
            selectedTime = calendar.date(from: comps) ?? Date()
            label = alarm.label
            repeatDays = alarm.repeatDays
            selectedTone = alarm.tone
            selectedMission = alarm.missionType
            repGoal = max(5, alarm.repGoal)
            stepGoal = max(50, min(5000, alarm.stepGoal))
            customStepsText = "\(stepGoal)"
            let limit = max(30, min(3600, alarm.stepsTimeLimitSeconds))
            stepsLimitMinutes = limit / 60
            stepsLimitExtraSeconds = limit % 60
            qrGraceSeconds = max(20, min(180, alarm.qrGraceSeconds))
            selectedBrainGame = alarm.brainGameMode
            reflexThresholdMs = max(180, min(350, alarm.reflexThresholdMs))
        } else {
            var comps = calendar.dateComponents([.year, .month, .day], from: Date())
            comps.hour = 7
            comps.minute = 0
            selectedTime = calendar.date(from: comps) ?? Date()
            label = ""
            selectedMission = .random
            selectedBrainGame = .random
            repGoal = 15
            stepGoal = 500
            customStepsText = "500"
            stepsLimitMinutes = 10
            stepsLimitExtraSeconds = 0
            qrGraceSeconds = 60
            reflexThresholdMs = WakeQRStorage.defaultReflexThresholdMs
        }
    }

    private func saveAlarm() {
        let comps = ISOWeekCalendar.current.dateComponents([.hour, .minute], from: selectedTime)
        let hour = comps.hour ?? 7
        let minute = comps.minute ?? 0
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedSteps = max(50, min(5000, stepGoal))
        let clampedTimeLimit = totalStepsLimitSeconds

        if let alarm = alarmToEdit {
            alarm.label = cleanLabel
            alarm.hour = hour
            alarm.minute = minute
            alarm.repeatDays = repeatDays
            alarm.tone = selectedTone
            alarm.missionType = selectedMission
            alarm.repGoal = repGoal
            alarm.stepGoal = clampedSteps
            alarm.stepsTimeLimitSeconds = clampedTimeLimit
            alarm.qrGraceSeconds = qrGraceSeconds
            alarm.brainGameMode = selectedBrainGame
            alarm.reflexThresholdMs = reflexThresholdMs
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
                stepGoal: clampedSteps,
                stepsTimeLimitSeconds: clampedTimeLimit,
                qrGraceSeconds: qrGraceSeconds,
                brainGameMode: selectedBrainGame,
                reflexThresholdMs: reflexThresholdMs
            )
            modelContext.insert(newAlarm)
        }

        SharedModelContainer.shared.save()
        AlarmEngine.shared.syncWithAlarms()
    }
}
