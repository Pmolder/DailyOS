import SwiftUI
import SwiftData

struct AlarmEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var audioManager = AlarmAudioManager.shared

    let alarmToEdit: AlarmItem?

    @State private var selectedTime: Date = Date()
    @State private var label: String = ""
    @State private var repeatDays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var selectedTone: AlarmTone = .nuclearSiren
    @State private var selectedSoundscape: AlarmSoundscape = .goldenHour
    @State private var expandedSoundPicker: Bool = false

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

    // Sleep-Cycle Bedtime Planner
    @State private var sleepCycleCount: Int = 5
    @State private var windDownMinutes: Int = 15
    @State private var bedtimeReminderEnabled: Bool = true
    @Namespace private var sleepCycleNamespace

    // Stage-3 Morning Activation Checklist
    @State private var stage3Enabled: Bool = true
    @State private var stage3TimeLimitSeconds: Int = 120
    @State private var stage3ChecklistItems: [String] = AlarmItem.defaultStage3ChecklistItems
    @State private var newStage3StepText: String = ""

    private let stepPresets: [Int] = [200, 500, 1000, 2000]
    private let timeLimitMinutePresets: [Int] = [2, 5, 10, 15, 20]
    private let windDownPresets: [Int] = [10, 15, 20, 30]
    private let stage3LimitPresets: [(label: String, seconds: Int)] = [
        ("1m", 60), ("2m", 120), ("3m", 180), ("5m", 300)
    ]

    private var liveBedtimePreview: (windDownText: String, lightsOutText: String) {
        let comps = ISOWeekCalendar.current.dateComponents([.hour, .minute], from: selectedTime)
        let bed = AlarmItem.computeBedtime(
            wakeHour: comps.hour ?? 7,
            wakeMinute: comps.minute ?? 0,
            cycles: sleepCycleCount,
            windDownMinutes: windDownMinutes
        )
        return (bed.windDownText, bed.lightsOutText)
    }

    private var totalStepsLimitSeconds: Int {
        max(30, min(3600, (stepsLimitMinutes * 60) + stepsLimitExtraSeconds))
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Sheet Header
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 38) {
                        AlarmEngine.shared.stopPreview()
                        dismiss()
                    }
                    Spacer()
                    Text(alarmToEdit == nil ? "New Wake Alarm" : "Edit Wake Alarm")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        // 1. TIME
                        VStack(alignment: .leading, spacing: 10) {
                            Text("TIME")
                                .eyebrowStyle()

                            DatePicker(
                                "Alarm Time",
                                selection: $selectedTime,
                                displayedComponents: .hourAndMinute
                            )
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)
                            .ambientCard(accent: DailyOSTheme.indigoGlow, cornerRadius: 22, washOpacity: 0.08)
                        }

                        // 1b. SLEEP CYCLES & BEDTIME PLANNER
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SLEEP CYCLES & BEDTIME")
                                .eyebrowStyle()

                            VStack(alignment: .leading, spacing: 14) {
                                // Live Reverse-Engineered Bedtime Display
                                HStack(spacing: 12) {
                                    Image(systemName: "moon.stars.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(DailyOSTheme.indigoGlow)
                                        .frame(width: 40, height: 40)
                                        .background(DailyOSTheme.indigoGlow.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("OPTIMAL BEDTIME TARGET")
                                            .eyebrowStyle()
                                        HStack(spacing: 6) {
                                            Text("Wind-Down \(liveBedtimePreview.windDownText)")
                                                .contentTransition(.numericText())
                                            Text("•")
                                                .foregroundStyle(DailyOSTheme.eyebrow)
                                            Text("Lights Out \(liveBedtimePreview.lightsOutText)")
                                                .contentTransition(.numericText())
                                        }
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(Color.white)
                                        .animation(ProMotionSpring.glide, value: liveBedtimePreview.windDownText)
                                    }
                                    Spacer(minLength: 0)
                                }

                                // 4 / 5 / 6 Sleep Cycles Matched-Geometry Selector
                                HStack(spacing: 4) {
                                    ForEach([4, 5, 6], id: \.self) { count in
                                        let active = sleepCycleCount == count
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            withAnimation(ProMotionSpring.glide) {
                                                sleepCycleCount = count
                                            }
                                        } label: {
                                            VStack(spacing: 1) {
                                                Text("\(count) cycles")
                                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                                Text(AlarmItem.sleepDurationText(forCycles: count))
                                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                                    .monospacedDigit()
                                            }
                                            .foregroundStyle(active ? Color.black : Color.white.opacity(0.8))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 9)
                                            .background {
                                                if active {
                                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                        .fill(DailyOSTheme.indigoGlow)
                                                        .matchedGeometryEffect(id: "sleepCyclePill", in: sleepCycleNamespace)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(4)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))

                                // Wind-Down Fall-Asleep Buffer Chips
                                HStack(spacing: 8) {
                                    Text("Wind-Down")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.85))
                                    Spacer()
                                    ForEach(windDownPresets, id: \.self) { mins in
                                        let selected = windDownMinutes == mins
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            windDownMinutes = mins
                                        } label: {
                                            Text("\(mins)m")
                                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                                .monospacedDigit()
                                                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(selected ? DailyOSTheme.skyGlow : DailyOSTheme.inputSurface, in: Capsule())
                                        }
                                        .buttonStyle(MidnightPressButtonStyle())
                                    }
                                }

                                Divider().overlay(DailyOSTheme.hairline)

                                Toggle("Bedtime Lock-In Reminder", isOn: $bedtimeReminderEnabled)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.white)
                                    .tint(DailyOSTheme.indigoGlow)
                            }
                            .padding(16)
                            .ambientCard(accent: DailyOSTheme.indigoGlow, cornerRadius: 20, washOpacity: 0.08)
                        }

                        // 2. LABEL & SCHEDULE
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("LABEL & SCHEDULE")
                                    .eyebrowStyle()
                                Spacer()
                                Text(Weekday.formatSummary(for: repeatDays))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.indigoGlow)
                            }

                            VStack(spacing: 14) {
                                TextField("Alarm Label", text: $label)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.white)
                                    .padding(14)
                                    .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))

                                HStack(spacing: 6) {
                                    ForEach(Weekday.allCases) { day in
                                        let isSelected = repeatDays.contains(day.rawValue)
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            if isSelected {
                                                repeatDays.remove(day.rawValue)
                                            } else {
                                                repeatDays.insert(day.rawValue)
                                            }
                                        } label: {
                                            Text(day.shortName)
                                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(
                                                    isSelected ? DailyOSTheme.indigoGlow : DailyOSTheme.inputSurface,
                                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                        .stroke(isSelected ? DailyOSTheme.indigoGlow : DailyOSTheme.hairline, lineWidth: 1)
                                                )
                                                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.8))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(16)
                            .ambientCard(cornerRadius: 20)
                        }

                        // 3. PROCEDURAL ALARM SOUNDSCAPES (12 Categorized Sounds + Live Preview)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("ALARM SOUNDSCAPE")
                                    .eyebrowStyle()
                                Spacer()
                                Text(selectedSoundscape.displayName)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.indigoGlow)
                            }

                            VStack(spacing: 12) {
                                // Current selection header + expand/collapse
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(selectedSoundscape.displayName)
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color.white)
                                        Text(selectedSoundscape.vibeDescription)
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(DailyOSTheme.eyebrow)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    soundPreviewCircleButton(for: selectedSoundscape)
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            expandedSoundPicker.toggle()
                                        }
                                    } label: {
                                        Image(systemName: expandedSoundPicker ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(DailyOSTheme.eyebrow)
                                            .frame(width: 32, height: 32)
                                            .background(DailyOSTheme.inputSurface, in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                }

                                if expandedSoundPicker {
                                    Divider().overlay(DailyOSTheme.hairline)

                                    VStack(alignment: .leading, spacing: 16) {
                                        ForEach(AlarmSoundCategory.allCases) { category in
                                            VStack(alignment: .leading, spacing: 8) {
                                                HStack {
                                                    Text(category.rawValue)
                                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                                        .tracking(0.8)
                                                        .textCase(.uppercase)
                                                        .foregroundStyle(DailyOSTheme.indigoGlow)
                                                    Spacer()
                                                    Text(category.subtitle)
                                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                                        .foregroundStyle(DailyOSTheme.eyebrow)
                                                }

                                                VStack(spacing: 6) {
                                                    ForEach(category.sounds) { sound in
                                                        let isSelected = selectedSoundscape == sound
                                                        HStack(spacing: 10) {
                                                            Button {
                                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                                selectedSoundscape = sound
                                                            } label: {
                                                                HStack(spacing: 10) {
                                                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                                        .font(.system(size: 16, weight: .semibold))
                                                                        .foregroundStyle(isSelected ? DailyOSTheme.indigoGlow : DailyOSTheme.eyebrow)

                                                                    VStack(alignment: .leading, spacing: 2) {
                                                                        Text(sound.displayName)
                                                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                                            .foregroundStyle(Color.white)
                                                                        Text(sound.vibeDescription)
                                                                            .font(.system(size: 11, weight: .regular, design: .rounded))
                                                                            .foregroundStyle(DailyOSTheme.eyebrow)
                                                                            .lineLimit(2)
                                                                    }
                                                                    Spacer(minLength: 4)
                                                                }
                                                                .contentShape(Rectangle())
                                                            }
                                                            .buttonStyle(.plain)

                                                            soundPreviewCircleButton(for: sound)
                                                        }
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 10)
                                                        .background(
                                                            isSelected ? DailyOSTheme.indigoGlow.opacity(0.12) : DailyOSTheme.inputSurface,
                                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        )
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                                .stroke(isSelected ? DailyOSTheme.indigoGlow.opacity(0.45) : DailyOSTheme.hairline, lineWidth: 1)
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    }
                                } else {
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            expandedSoundPicker = true
                                        }
                                    } label: {
                                        Label("Browse 12 Procedural Soundscapes", systemImage: "waveform")
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                            .foregroundStyle(DailyOSTheme.indigoGlow)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(DailyOSTheme.indigoGlow.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(16)
                            .ambientCard(cornerRadius: 20)
                        }

                        // 4. PHYSICAL MISSION (Stage 1)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PHYSICAL MISSION")
                                .eyebrowStyle()

                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("Stage-1 Mission")
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.white)
                                    Spacer()
                                    Picker("Stage-1 Physical Mission", selection: $selectedMission) {
                                        ForEach(MissionType.allCases) { mission in
                                            Label(mission.displayName, systemImage: mission.iconName)
                                                .tag(mission)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(DailyOSTheme.indigoGlow)
                                }

                                if selectedMission == .random {
                                    Text("Rolls daily among Squats, Steps\(WakeQRStorage.isRegistered ? ", and QR Scan" : " (register a QR in Settings to include QR Scan)") without repeating yesterday's mission.")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(DailyOSTheme.eyebrow)
                                }

                                // Squats Settings
                                if selectedMission == .squats || selectedMission == .random {
                                    Divider().overlay(DailyOSTheme.hairline)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Stepper("Squats Target: \(repGoal) reps", value: $repGoal, in: 5...60, step: 5)
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.white)
                                        Text("30s initial grace for Rep 1 → 5s per rep thereafter with stateful resume-volume penalty.")
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(DailyOSTheme.eyebrow)
                                    }
                                }

                                // Steps Settings
                                if selectedMission == .steps || selectedMission == .random {
                                    Divider().overlay(DailyOSTheme.hairline)
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            Text("Steps Target")
                                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                .foregroundStyle(Color.white)
                                            Spacer()
                                            TextField("500", text: $customStepsText)
                                                .keyboardType(.numberPad)
                                                .multilineTextAlignment(.trailing)
                                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                                .monospacedDigit()
                                                .foregroundStyle(DailyOSTheme.indigoGlow)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .frame(width: 78)
                                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                .onChange(of: customStepsText) { _, newValue in
                                                    if let parsed = Int(newValue) {
                                                        stepGoal = max(50, min(5000, parsed))
                                                    }
                                                }
                                            Text("steps")
                                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                                .foregroundStyle(DailyOSTheme.eyebrow)
                                        }

                                        HStack(spacing: 6) {
                                            ForEach(stepPresets, id: \.self) { preset in
                                                let active = stepGoal == preset
                                                Button {
                                                    stepGoal = preset
                                                    customStepsText = "\(preset)"
                                                } label: {
                                                    Text("\(preset)")
                                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                                        .monospacedDigit()
                                                        .frame(maxWidth: .infinity)
                                                        .padding(.vertical, 7)
                                                        .background(
                                                            active ? DailyOSTheme.indigoGlow : DailyOSTheme.inputSurface,
                                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
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
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.85))

                                        Divider().overlay(DailyOSTheme.hairline)

                                        HStack {
                                            Text("Steps Time Limit")
                                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                .foregroundStyle(Color.white)
                                            Spacer()
                                            Text(formattedLimitLabel)
                                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                                .monospacedDigit()
                                                .foregroundStyle(DailyOSTheme.indigoGlow)
                                        }

                                        HStack(spacing: 6) {
                                            ForEach(timeLimitMinutePresets, id: \.self) { mins in
                                                let active = stepsLimitMinutes == mins && stepsLimitExtraSeconds == 0
                                                Button {
                                                    stepsLimitMinutes = mins
                                                    stepsLimitExtraSeconds = 0
                                                } label: {
                                                    Text("\(mins)m")
                                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                                        .monospacedDigit()
                                                        .frame(maxWidth: .infinity)
                                                        .padding(.vertical, 7)
                                                        .background(
                                                            active ? DailyOSTheme.indigoGlow : DailyOSTheme.inputSurface,
                                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                        )
                                                        .foregroundStyle(active ? Color.black : Color.white)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }

                                        Stepper("Minutes: \(stepsLimitMinutes) min", value: $stepsLimitMinutes, in: 0...60, step: 1)
                                            .font(.system(size: 13, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color.white.opacity(0.85))
                                        Stepper("Seconds: \(stepsLimitExtraSeconds) sec", value: $stepsLimitExtraSeconds, in: 0...55, step: 5)
                                            .font(.system(size: 13, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color.white.opacity(0.85))
                                    }
                                }

                                // QR / Barcode Settings
                                if selectedMission == .qrBarcode || selectedMission == .random {
                                    Divider().overlay(DailyOSTheme.hairline)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Stepper("QR Walk Grace: \(qrGraceSeconds)s", value: $qrGraceSeconds, in: 20...180, step: 10)
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.white)
                                        HStack {
                                            Text("Wake QR Code Status")
                                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                                .foregroundStyle(DailyOSTheme.eyebrow)
                                            Spacer()
                                            Text(WakeQRStorage.isRegistered ? "Registered" : "Not Set (Settings)")
                                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                                .foregroundStyle(WakeQRStorage.isRegistered ? DailyOSTheme.emerald : DailyOSTheme.indigoGlow)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .ambientCard(cornerRadius: 20)
                        }

                        // 5. BRAIN GAME (Stage 2)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("BRAIN GAME")
                                .eyebrowStyle()

                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Stage-2 Activation")
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.white)
                                    Spacer()
                                    Picker("Stage-2 Brain Game", selection: $selectedBrainGame) {
                                        ForEach(BrainGameMode.allCases) { mode in
                                            Label(mode.displayName, systemImage: mode.iconName)
                                                .tag(mode)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(DailyOSTheme.indigoGlow)
                                }

                                if selectedBrainGame == .random || selectedBrainGame == .reflexStrike {
                                    Divider().overlay(DailyOSTheme.hairline)
                                    Stepper("Reflex Strike Threshold: \(reflexThresholdMs) ms", value: $reflexThresholdMs, in: 180...350, step: 10)
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.white)
                                }

                                if selectedBrainGame == .random {
                                    Text("Rotates daily across Reflex Strike, Memory Grid, Math Sprint, and Node Connect without repeating yesterday's game.")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(DailyOSTheme.eyebrow)
                                }
                            }
                            .padding(16)
                            .ambientCard(cornerRadius: 20)
                        }

                        // 6. STAGE 3 • MORNING ACTIVATION CHECKLIST
                        VStack(alignment: .leading, spacing: 10) {
                            Text("STAGE 3 • MORNING ACTIVATION")
                                .eyebrowStyle()

                            VStack(alignment: .leading, spacing: 14) {
                                Toggle(isOn: $stage3Enabled) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Anti-Grogginess Wake Checklist")
                                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.white)
                                        Text("Runs right after Stage 2 before alarm permanently dismisses")
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(DailyOSTheme.eyebrow)
                                    }
                                }
                                .tint(DailyOSTheme.emerald)

                                if stage3Enabled {
                                    Divider().overlay(DailyOSTheme.hairline)

                                    // Time-limit preset pills
                                    HStack(spacing: 8) {
                                        Text("Countdown")
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.white.opacity(0.85))
                                        Spacer()
                                        ForEach(stage3LimitPresets, id: \.seconds) { preset in
                                            let active = stage3TimeLimitSeconds == preset.seconds
                                            Button {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                stage3TimeLimitSeconds = preset.seconds
                                            } label: {
                                                Text(preset.label)
                                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                                    .monospacedDigit()
                                                    .foregroundStyle(active ? Color.black : Color.white.opacity(0.8))
                                                    .padding(.horizontal, 11)
                                                    .padding(.vertical, 6)
                                                    .background(active ? DailyOSTheme.emerald : DailyOSTheme.inputSurface, in: Capsule())
                                            }
                                            .buttonStyle(MidnightPressButtonStyle())
                                        }
                                    }

                                    // Editable checklist steps (up to 5 items)
                                    VStack(spacing: 8) {
                                        ForEach(stage3ChecklistItems.indices, id: \.self) { idx in
                                            HStack(spacing: 8) {
                                                Text("\(idx + 1).")
                                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                                    .monospacedDigit()
                                                    .foregroundStyle(DailyOSTheme.emerald)
                                                    .frame(width: 18)

                                                TextField(
                                                    "Wake step",
                                                    text: Binding(
                                                        get: { stage3ChecklistItems[idx] },
                                                        set: { stage3ChecklistItems[idx] = $0 }
                                                    )
                                                )
                                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                                .foregroundStyle(Color.white)

                                                if stage3ChecklistItems.count > 1 {
                                                    Button {
                                                        stage3ChecklistItems.remove(at: idx)
                                                    } label: {
                                                        Image(systemName: "minus.circle.fill")
                                                            .font(.system(size: 16))
                                                            .foregroundStyle(Color(hex: "#FF6B6B").opacity(0.85))
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                        }
                                    }

                                    if stage3ChecklistItems.count < 5 {
                                        HStack(spacing: 8) {
                                            TextField(
                                                "",
                                                text: $newStage3StepText,
                                                prompt: Text("Add activation step...").foregroundStyle(Color.white.opacity(0.32))
                                            )
                                            .font(.system(size: 13, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color.white)

                                            Button("Add Step") {
                                                let clean = newStage3StepText.trimmingCharacters(in: .whitespacesAndNewlines)
                                                guard !clean.isEmpty, stage3ChecklistItems.count < 5 else { return }
                                                stage3ChecklistItems.append(clean)
                                                newStage3StepText = ""
                                            }
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color.black)
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 6)
                                            .background(DailyOSTheme.emerald, in: Capsule())
                                            .buttonStyle(MidnightPressButtonStyle())
                                            .disabled(newStage3StepText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                                    }

                                    Button("Reset Defaults") {
                                        stage3ChecklistItems = AlarmItem.defaultStage3ChecklistItems
                                        stage3TimeLimitSeconds = 120
                                    }
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.eyebrow)
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(16)
                            .ambientCard(accent: stage3Enabled ? DailyOSTheme.emerald : nil, cornerRadius: 20, washOpacity: 0.06)
                        }

                        // Delete Button when editing existing alarm
                        if let existing = alarmToEdit {
                            Button {
                                AlarmEngine.shared.stopPreview()
                                NotificationScheduler.shared.cancelAlarmBurstNotifications(for: existing.id)
                                modelContext.delete(existing)
                                SharedModelContainer.shared.save()
                                AlarmEngine.shared.syncWithAlarms()
                                dismiss()
                            } label: {
                                Text("Delete Alarm")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(hex: "#FF6B6B"))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color(hex: "#FF6B6B").opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                }

                // Sticky Full-Width Pill Save Button
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    AlarmEngine.shared.stopPreview()
                    saveAlarm()
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(DailyOSTheme.indigoGlow, in: Capsule())
                }
                .buttonStyle(MidnightPressStyle())
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.calendar, ISOWeekCalendar.current)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .onAppear(perform: loadInitialValues)
        .onDisappear {
            AlarmEngine.shared.stopPreview()
        }
    }

    private func soundPreviewCircleButton(for sound: AlarmSoundscape) -> some View {
        let isPlaying = audioManager.previewingSoundID == sound.rawValue
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AlarmEngine.shared.togglePreview(soundscape: sound)
        } label: {
            Image(systemName: isPlaying ? "stop.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isPlaying ? Color.black : DailyOSTheme.indigoGlow)
                .frame(width: 34, height: 34)
                .background(
                    isPlaying ? DailyOSTheme.indigoGlow : DailyOSTheme.indigoGlow.opacity(0.16),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Stop Preview" : "Play Live Preview")
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
            selectedSoundscape = alarm.soundscape
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
            sleepCycleCount = max(4, min(6, alarm.sleepCycleCount))
            windDownMinutes = alarm.windDownMinutes
            bedtimeReminderEnabled = alarm.bedtimeReminderEnabled
            stage3Enabled = alarm.stage3Enabled
            stage3TimeLimitSeconds = alarm.stage3TimeLimitSeconds
            stage3ChecklistItems = alarm.stage3ChecklistItems
        } else {
            var comps = calendar.dateComponents([.year, .month, .day], from: Date())
            comps.hour = 7
            comps.minute = 0
            selectedTime = calendar.date(from: comps) ?? Date()
            label = ""
            selectedSoundscape = .goldenHour
            selectedMission = .random
            selectedBrainGame = .random
            repGoal = 15
            stepGoal = 500
            customStepsText = "500"
            stepsLimitMinutes = 10
            stepsLimitExtraSeconds = 0
            qrGraceSeconds = 60
            reflexThresholdMs = WakeQRStorage.defaultReflexThresholdMs
            sleepCycleCount = 5
            windDownMinutes = 15
            bedtimeReminderEnabled = true
            stage3Enabled = true
            stage3TimeLimitSeconds = 120
            stage3ChecklistItems = AlarmItem.defaultStage3ChecklistItems
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
            alarm.soundscape = selectedSoundscape
            alarm.missionType = selectedMission
            alarm.repGoal = repGoal
            alarm.stepGoal = clampedSteps
            alarm.stepsTimeLimitSeconds = clampedTimeLimit
            alarm.qrGraceSeconds = qrGraceSeconds
            alarm.brainGameMode = selectedBrainGame
            alarm.reflexThresholdMs = reflexThresholdMs
            alarm.sleepCycleCount = sleepCycleCount
            alarm.windDownMinutes = windDownMinutes
            alarm.bedtimeReminderEnabled = bedtimeReminderEnabled
            alarm.stage3Enabled = stage3Enabled
            alarm.stage3TimeLimitSeconds = stage3TimeLimitSeconds
            alarm.stage3ChecklistItems = stage3ChecklistItems
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
                soundID: selectedSoundscape.rawValue,
                missionType: selectedMission,
                repGoal: repGoal,
                stepGoal: clampedSteps,
                stepsTimeLimitSeconds: clampedTimeLimit,
                qrGraceSeconds: qrGraceSeconds,
                brainGameMode: selectedBrainGame,
                reflexThresholdMs: reflexThresholdMs,
                sleepCycleCount: sleepCycleCount,
                windDownMinutes: windDownMinutes,
                bedtimeReminderEnabled: bedtimeReminderEnabled,
                stage3Enabled: stage3Enabled,
                stage3TimeLimitSeconds: stage3TimeLimitSeconds,
                stage3ChecklistItems: stage3ChecklistItems
            )
            modelContext.insert(newAlarm)
        }

        SharedModelContainer.shared.save()
        AlarmEngine.shared.syncWithAlarms()
    }
}
