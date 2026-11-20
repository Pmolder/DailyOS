import SwiftUI
import SwiftData

struct HabitEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let habitToEdit: HabitItem?

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var iconName: String = "checkmark.seal.fill"
    @State private var timeOfDay: HabitTimeOfDay = .morning
    @State private var reminderEnabled: Bool = false
    @State private var reminderTime: Date = Date()
    @State private var repeatDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    @State private var soundOption: NotificationSoundOption = .chimeBell

    private let availableIcons: [String] = [
        "drop.fill",
        "sun.max.fill",
        "figure.strengthtraining.traditional",
        "book.fill",
        "brain.head.profile",
        "lock.shield.fill",
        "pills.fill",
        "leaf.fill",
        "checkmark.seal.fill",
        "flame.fill"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Habit Details") {
                    TextField("Habit Title", text: $title)
                    TextField("Notes (Optional)", text: $notes)

                    Picker("Time of Day", selection: $timeOfDay) {
                        ForEach(HabitTimeOfDay.allCases) { segment in
                            Label(segment.displayName, systemImage: segment.iconName)
                                .tag(segment)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Icon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(availableIcons, id: \.self) { icon in
                                    let selected = iconName == icon
                                    Button {
                                        iconName = icon
                                    } label: {
                                        Image(systemName: icon)
                                            .font(.title3)
                                            .frame(width: 40, height: 40)
                                            .background(
                                                selected ? Color.green : Color.secondary.opacity(0.18),
                                                in: RoundedRectangle(cornerRadius: 10)
                                            )
                                            .foregroundStyle(selected ? .black : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Schedule & Optional Reminder") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Scheduled Days")
                                .font(.subheadline)
                            Spacer()
                            Text(Weekday.formatSummary(for: repeatDays))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }

                        HStack(spacing: 6) {
                            ForEach(Weekday.allCases) { day in
                                let isSelected = repeatDays.contains(day.rawValue)
                                Button {
                                    if isSelected && repeatDays.count > 1 {
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
                                            isSelected ? Color.green : Color.secondary.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                        .foregroundStyle(isSelected ? .black : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Toggle("Local Reminder Notification", isOn: $reminderEnabled)

                    if reminderEnabled {
                        DatePicker(
                            "Reminder Time",
                            selection: $reminderTime,
                            displayedComponents: .hourAndMinute
                        )

                        Picker("Notification Sound", selection: $soundOption) {
                            ForEach(NotificationSoundOption.allCases) { sound in
                                Text(sound.displayName).tag(sound)
                            }
                        }

                        Button {
                            AlarmEngine.shared.previewNotificationSound(soundOption)
                        } label: {
                            Label("Preview Sound", systemImage: "speaker.wave.2.fill")
                        }
                    }
                }
            }
            .navigationTitle(habitToEdit == nil ? "New Habit" : "Edit Habit")
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
                        saveHabit()
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
        let calendar = Calendar.current
        if let habit = habitToEdit {
            title = habit.title
            notes = habit.notes
            iconName = habit.iconName
            timeOfDay = habit.timeOfDay
            reminderEnabled = habit.reminderEnabled
            repeatDays = habit.repeatDays.isEmpty ? Set(1...7) : habit.repeatDays
            soundOption = habit.soundOption

            var comps = calendar.dateComponents([.year, .month, .day], from: Date())
            comps.hour = habit.reminderHour
            comps.minute = habit.reminderMinute
            reminderTime = calendar.date(from: comps) ?? Date()
        } else {
            var comps = calendar.dateComponents([.year, .month, .day], from: Date())
            comps.hour = 9
            comps.minute = 0
            reminderTime = calendar.date(from: comps) ?? Date()
        }
    }

    private func saveHabit() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        let hour = comps.hour ?? 9
        let minute = comps.minute ?? 0
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Daily Habit"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let habit = habitToEdit {
            habit.title = cleanTitle
            habit.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            habit.iconName = iconName
            habit.timeOfDay = timeOfDay
            habit.reminderEnabled = reminderEnabled
            habit.reminderHour = hour
            habit.reminderMinute = minute
            habit.repeatDays = repeatDays
            habit.soundOption = soundOption
            habit.requiresPhotoProof = false
        } else {
            let existingInSegment = SharedModelContainer.shared.fetchHabits()
                .filter { $0.timeOfDay == timeOfDay }
            let nextOrder = (existingInSegment.map(\.sortOrder).max() ?? -1) + 1

            let newHabit = HabitItem(
                title: cleanTitle,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                iconName: iconName,
                timeOfDay: timeOfDay,
                sortOrder: nextOrder,
                reminderEnabled: reminderEnabled,
                reminderHour: hour,
                reminderMinute: minute,
                repeatDays: repeatDays,
                soundOption: soundOption,
                requiresPhotoProof: false
            )
            modelContext.insert(newHabit)
        }

        SharedModelContainer.shared.save()
        Task {
            _ = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
            await NotificationScheduler.shared.rescheduleAll()
        }
    }
}
