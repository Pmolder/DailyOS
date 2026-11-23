import SwiftUI
import SwiftData

/// "Your habits, your style." — Create / Edit Habit Sheet matching the Midnight Obsidian reference.
struct HabitEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let habitToEdit: HabitItem?

    @State private var name: String = ""
    @State private var subtitle: String = ""
    @State private var iconName: String = "drop.fill"
    @State private var colorHex: String = "#38BDF8"
    @State private var kind: HabitKind = .build
    @State private var trackingMode: HabitTrackingMode = .binary
    @State private var dailyTarget: Int = 8
    @State private var unitLabel: String = ""
    @State private var isDailyFrequency: Bool = true
    @State private var repeatDays: Set<Int> = [2, 3, 4, 5, 6, 7, 1]
    @State private var reminderEnabled: Bool = false
    @State private var reminderTime: Date = Date()
    @State private var soundOption: NotificationSoundOption = .chimeBell

    @State private var showingIconPicker = false
    @Namespace private var habitTypeNS
    @Namespace private var trackingModeNS

    private var selectedAccent: Color {
        Color(hex: colorHex)
    }

    private let decorativeBgIcons: [String] = [
        "figure.run", "drop.fill", "book.fill", "flame.fill", "brain.head.profile", "moon.stars.fill", "heart.fill",
        "dumbbell.fill", "cup.and.saucer.fill", "pencil", "bolt.fill", "leaf.fill", "sun.max.fill", "bicycle",
        "bed.double.fill", "music.note", "laptopcomputer", "figure.mind.and.body", "pills.fill", "target", "sparkles"
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header: Circular X Close Button + Centered Title
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 36) {
                        AlarmEngine.shared.stopPreview()
                        dismiss()
                    }
                    Spacer()
                    Text(habitToEdit == nil ? "New Habit" : "Edit Habit")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        // Hero Icon Selector with Radial Faint Decorative Background Grid
                        ZStack {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 7), spacing: 14) {
                                ForEach(Array(decorativeBgIcons.enumerated()), id: \.offset) { _, sym in
                                    Image(systemName: sym)
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(selectedAccent.opacity(0.08))
                                }
                            }
                            .mask(
                                RadialGradient(
                                    colors: [.white, .white.opacity(0.35), .clear],
                                    center: .center,
                                    startRadius: 10,
                                    endRadius: 155
                                )
                            )
                            .allowsHitTesting(false)

                            VStack(spacing: 10) {
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    showingIconPicker = true
                                } label: {
                                    ZStack(alignment: .bottomTrailing) {
                                        Circle()
                                            .fill(selectedAccent.opacity(0.20))
                                            .frame(width: 84, height: 84)
                                            .overlay(
                                                Circle().stroke(selectedAccent.opacity(0.35), lineWidth: 1.5)
                                            )
                                            .overlay(
                                                Image(systemName: iconName)
                                                    .font(.system(size: 34, weight: .semibold))
                                                    .foregroundStyle(selectedAccent)
                                            )

                                        Circle()
                                            .fill(selectedAccent)
                                            .frame(width: 26, height: 26)
                                            .overlay(
                                                Image(systemName: "pencil")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(DailyOSTheme.canvas)
                                            )
                                            .offset(x: 2, y: 2)
                                    }
                                }
                                .buttonStyle(.plain)

                                Button("Change icon") {
                                    showingIconPicker = true
                                }
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(selectedAccent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)

                        // NAME Input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("NAME").eyebrowStyle()
                            TextField("Habit name", text: $name)
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 14)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                        }

                        // DESCRIPTION Input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("DESCRIPTION").eyebrowStyle()
                            TextField("Short motivation or description", text: $subtitle)
                                .font(.system(size: 15, weight: .regular, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 14)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                        }

                        // Curated 21-Color Swatch Grid (3 x 7)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("COLOR").eyebrowStyle()
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7), spacing: 10) {
                                ForEach(DailyOSTheme.habitPaletteHex, id: \.self) { hex in
                                    let isSelected = colorHex.uppercased() == hex.uppercased()
                                    let swatchColor = Color(hex: hex)
                                    Button {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        colorHex = hex
                                    } label: {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(swatchColor)
                                                .frame(width: 36, height: 36)

                                            if isSelected {
                                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                                    .stroke(swatchColor, lineWidth: 2)
                                                    .frame(width: 44, height: 44)
                                            }
                                        }
                                        .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // HABIT TYPE Segmented Picker (Build A Habit vs Quit A Habit — 120Hz Matched-Geometry)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HABIT TYPE").eyebrowStyle()

                            HStack(spacing: 4) {
                                ForEach(HabitKind.allCases) { option in
                                    let selected = kind == option
                                    Button {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        withAnimation(ProMotionSpring.glide) {
                                            kind = option
                                            if option == .quit {
                                                trackingMode = .binary
                                            }
                                        }
                                    } label: {
                                        ZStack {
                                            if selected {
                                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                    .fill(DailyOSTheme.buttonSurface)
                                                    .matchedGeometryEffect(id: "habitKindPill", in: habitTypeNS)
                                            }
                                            Text(option.displayTitle)
                                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                .foregroundStyle(selected ? Color.white : DailyOSTheme.eyebrow)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 11)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(4)
                            .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))

                            Text(kind.helperCaption)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(DailyOSTheme.eyebrow)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        // TRACKING MODE (Simple Check-in vs Numeric Goal — 120Hz Matched-Geometry)
                        if kind == .build {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("TRACKING").eyebrowStyle()

                                HStack(spacing: 4) {
                                    ForEach(HabitTrackingMode.allCases) { mode in
                                        let selected = trackingMode == mode
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            withAnimation(ProMotionSpring.glide) {
                                                trackingMode = mode
                                            }
                                        } label: {
                                            ZStack {
                                                if selected {
                                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                        .fill(DailyOSTheme.buttonSurface)
                                                        .matchedGeometryEffect(id: "trackingModePill", in: trackingModeNS)
                                                }
                                                Text(mode.displayTitle)
                                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                    .foregroundStyle(selected ? Color.white : DailyOSTheme.eyebrow)
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.vertical, 11)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(4)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))

                                if trackingMode == .quantity {
                                    VStack(spacing: 12) {
                                        Stepper("Daily Goal: \(dailyTarget)", value: $dailyTarget, in: 1...500)
                                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white)

                                        TextField("Unit (e.g., glasses, pages, min)", text: $unitLabel)
                                            .font(.system(size: 14, weight: .medium, design: .rounded))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .background(DailyOSTheme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                                    }
                                    .padding(14)
                                    .ambientCard(cornerRadius: 14)
                                }
                            }
                        }

                        // FREQUENCY (Daily or ISO-8601 Monday–Sunday Pills)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("FREQUENCY").eyebrowStyle()
                                Spacer()
                                Toggle("Daily", isOn: $isDailyFrequency)
                                    .labelsHidden()
                                    .tint(selectedAccent)
                                    .onChange(of: isDailyFrequency) { _, isDaily in
                                        if isDaily {
                                            repeatDays = [2, 3, 4, 5, 6, 7, 1]
                                        }
                                    }
                            }

                            if !isDailyFrequency {
                                HStack(spacing: 6) {
                                    ForEach(Weekday.allCases) { day in
                                        let active = repeatDays.contains(day.rawValue)
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            if active && repeatDays.count > 1 {
                                                repeatDays.remove(day.rawValue)
                                            } else {
                                                repeatDays.insert(day.rawValue)
                                            }
                                        } label: {
                                            Text(day.singleLetter)
                                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 38)
                                                .background(
                                                    active ? selectedAccent : DailyOSTheme.inputSurface,
                                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                )
                                                .foregroundStyle(active ? DailyOSTheme.canvas : DailyOSTheme.eyebrow)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        // OPTIONAL REMINDER
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("REMINDER").eyebrowStyle()
                                Spacer()
                                Toggle("Reminder", isOn: $reminderEnabled)
                                    .labelsHidden()
                                    .tint(selectedAccent)
                            }

                            if reminderEnabled {
                                VStack(spacing: 12) {
                                    DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                                        .foregroundStyle(.white)
                                    HStack {
                                        Text("Sound")
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Picker("Sound", selection: $soundOption) {
                                            ForEach(NotificationSoundOption.allCases) { opt in
                                                Text(opt.displayName).tag(opt)
                                            }
                                        }
                                        .tint(selectedAccent)
                                    }
                                }
                                .padding(14)
                                .ambientCard(cornerRadius: 14)
                            }
                        }

                        // Subtle Delete Button when editing an existing habit
                        if habitToEdit != nil {
                            Button(role: .destructive) {
                                deleteHabit()
                            } label: {
                                Text("Delete Habit")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                        }

                        Spacer(minLength: 92)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                }
            }

            // Sticky Full-Width Pill Save CTA Tinted in Selected Habit Color
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [DailyOSTheme.canvas.opacity(0.0), DailyOSTheme.canvas],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 22)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    saveHabit()
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.canvas)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? selectedAccent.opacity(0.35)
                                : selectedAccent,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
                .background(DailyOSTheme.canvas)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.calendar, ISOWeekCalendar.current)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .onAppear(perform: loadInitialValues)
        .sheet(isPresented: $showingIconPicker) {
            CategorizedIconPickerSheet(selectedIcon: $iconName, accent: selectedAccent)
        }
    }

    private func loadInitialValues() {
        let cal = ISOWeekCalendar.current
        if let habit = habitToEdit {
            name = habit.title
            subtitle = habit.notes
            iconName = habit.iconName
            colorHex = habit.colorHex
            kind = habit.kind
            trackingMode = habit.trackingMode
            dailyTarget = max(1, Int(habit.dailyTarget))
            unitLabel = habit.unitLabel
            repeatDays = habit.repeatDays.isEmpty ? [2, 3, 4, 5, 6, 7, 1] : habit.repeatDays
            isDailyFrequency = repeatDays.count == 7
            reminderEnabled = habit.reminderEnabled
            soundOption = habit.soundOption

            var comps = cal.dateComponents([.year, .month, .day], from: Date())
            comps.hour = habit.reminderHour
            comps.minute = habit.reminderMinute
            reminderTime = cal.date(from: comps) ?? Date()
        } else {
            var comps = cal.dateComponents([.year, .month, .day], from: Date())
            comps.hour = 9
            comps.minute = 0
            reminderTime = cal.date(from: comps) ?? Date()
            name = ""
            subtitle = ""
            unitLabel = ""
        }
    }

    private func saveHabit() {
        let comps = ISOWeekCalendar.current.dateComponents([.hour, .minute], from: reminderTime)
        let hour = comps.hour ?? 9
        let minute = comps.minute ?? 0
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        let finalDays: Set<Int> = isDailyFrequency ? [2, 3, 4, 5, 6, 7, 1] : repeatDays
        let finalTarget = trackingMode == .quantity ? Double(max(1, dailyTarget)) : 1.0

        if let habit = habitToEdit {
            habit.title = cleanName
            habit.notes = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            habit.iconName = iconName
            habit.colorHex = colorHex
            habit.kind = kind
            habit.trackingMode = kind == .quit ? .binary : trackingMode
            habit.dailyTarget = finalTarget
            habit.unitLabel = unitLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            habit.repeatDays = finalDays
            habit.reminderEnabled = reminderEnabled
            habit.reminderHour = hour
            habit.reminderMinute = minute
            habit.soundOption = soundOption
        } else {
            let nextOrder = (SharedModelContainer.shared.fetchHabits().map(\.sortOrder).max() ?? -1) + 1
            let newHabit = HabitItem(
                title: cleanName,
                notes: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
                iconName: iconName,
                colorHex: colorHex,
                kind: kind,
                trackingMode: kind == .quit ? .binary : trackingMode,
                dailyTarget: finalTarget,
                unitLabel: unitLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                sortOrder: nextOrder,
                reminderEnabled: reminderEnabled,
                reminderHour: hour,
                reminderMinute: minute,
                repeatDays: finalDays,
                soundOption: soundOption
            )
            modelContext.insert(newHabit)
        }

        SharedModelContainer.shared.save()
        Task {
            _ = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
            await NotificationScheduler.shared.rescheduleAll()
        }
    }

    private func deleteHabit() {
        guard let habit = habitToEdit else { return }
        let logs = SharedModelContainer.shared.fetchHabitLogs(for: habit.id)
        for log in logs { modelContext.delete(log) }
        modelContext.delete(habit)
        SharedModelContainer.shared.save()
        Task { await NotificationScheduler.shared.rescheduleAll() }
        dismiss()
    }
}

// MARK: - 80+ Searchable & Categorized SF Symbol Picker Sheet

private struct CategorizedIconPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedIcon: String
    let accent: Color

    @State private var searchText: String = ""
    @State private var selectedCategory: HabitIconCategory = .all

    private var filteredIcons: [HabitIconEntry] {
        HabitIconLibrary.filtered(category: selectedCategory, query: searchText)
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 14) {
                // Header
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 36) {
                        dismiss()
                    }
                    Spacer()
                    Text("Choose Icon")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Spacer()
                    Text("\(filteredIcons.count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DailyOSTheme.eyebrow)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)

                // Search Bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DailyOSTheme.eyebrow)

                    TextField(
                        "",
                        text: $searchText,
                        prompt: Text("Search 80+ icons...").foregroundStyle(Color.white.opacity(0.32))
                    )
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(DailyOSTheme.eyebrow)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                .padding(.horizontal, 18)

                // Scrollable Category Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(HabitIconCategory.allCases) { cat in
                            let active = selectedCategory == cat
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                selectedCategory = cat
                            } label: {
                                Text(cat.rawValue)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(active ? Color.black : Color.white.opacity(0.8))
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 8)
                                    .background(
                                        active ? accent : DailyOSTheme.inputSurface,
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().stroke(active ? accent : DailyOSTheme.hairline, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                }

                // 6-Column Icon Grid
                ScrollView(showsIndicators: false) {
                    if filteredIcons.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 28))
                                .foregroundStyle(DailyOSTheme.eyebrow)
                            Text("No icons match \"\(searchText)\"")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(DailyOSTheme.eyebrow)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    } else {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6),
                            spacing: 10
                        ) {
                            ForEach(filteredIcons) { entry in
                                let isSelected = selectedIcon == entry.symbol
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    selectedIcon = entry.symbol
                                    dismiss()
                                } label: {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .fill(isSelected ? accent.opacity(0.24) : DailyOSTheme.card)
                                        .frame(height: 50)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                                .stroke(isSelected ? accent : DailyOSTheme.hairline, lineWidth: isSelected ? 1.8 : 1)
                                        )
                                        .shadow(color: isSelected ? accent.opacity(0.35) : Color.clear, radius: 8)
                                        .overlay(
                                            Image(systemName: entry.symbol)
                                                .font(.system(size: 20, weight: .semibold))
                                                .foregroundStyle(isSelected ? accent : Color.white.opacity(0.85))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 26)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
