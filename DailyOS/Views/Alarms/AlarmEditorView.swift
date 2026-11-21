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
    @State private var selectedMission: MissionType = .squats
    @State private var repGoal: Int = 20
    @State private var stepGoal: Int = 50

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
                            .foregroundStyle(.orange)
                    }

                    Text("Hardware escalation: 0–30s vibration only → 30–60s ramp 1%–15% → 60–90s ramp 15%–50% with volume-button correction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Wake Mission Selection (Squats + Steps Only)
                Section("Wake Challenge Mission") {
                    Picker("Mission", selection: $selectedMission) {
                        ForEach(MissionType.allCases) { mission in
                            Label(mission.displayName, systemImage: mission.iconName)
                                .tag(mission)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch selectedMission {
                    case .squats:
                        Stepper("Target Squats: \(repGoal) reps", value: $repGoal, in: 5...60, step: 5)
                        Text("On-device Apple Vision front-camera pose tracking. 20s initial grace for Rep 1, then 3.0s per rep.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    case .steps:
                        Stepper("Target Steps: \(stepGoal) steps", value: $stepGoal, in: 20...200, step: 10)
                        Text("Live CoreMotion CMPedometer step tracking. 20s initial grace to start stepping, then 3.0s between steps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        }
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
            stepGoal = max(20, alarm.stepGoal)
        } else {
            var comps = calendar.dateComponents([.year, .month, .day], from: Date())
            comps.hour = 7
            comps.minute = 0
            selectedTime = calendar.date(from: comps) ?? Date()
            label = ""
        }
    }

    private func saveAlarm() {
        let comps = ISOWeekCalendar.current.dateComponents([.hour, .minute], from: selectedTime)
        let hour = comps.hour ?? 7
        let minute = comps.minute ?? 0
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)

        if let alarm = alarmToEdit {
            alarm.label = cleanLabel
            alarm.hour = hour
            alarm.minute = minute
            alarm.repeatDays = repeatDays
            alarm.tone = selectedTone
            alarm.missionType = selectedMission
            alarm.repGoal = repGoal
            alarm.stepGoal = stepGoal
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
                stepGoal: stepGoal
            )
            modelContext.insert(newAlarm)
        }

        SharedModelContainer.shared.save()
        AlarmEngine.shared.syncWithAlarms()
    }
}
