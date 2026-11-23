import SwiftUI
import SwiftData

/// Fast, frictionless sheet to create or edit a Focus Task / Time Block for any ISO-8601 day.
struct FocusTaskEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var googleAuth = GoogleAuthService.shared

    let existingTask: FocusTaskItem?
    let initialDate: Date

    @State private var title: String = ""
    @State private var location: String = ""
    @State private var notes: String = ""
    @State private var selectedDate: Date = Date()
    @State private var hasSpecificTime: Bool = true
    @State private var startTime: Date = Date()
    @State private var durationMinutes: Int = 60
    @State private var showingCustomDurationStepper: Bool = false
    @State private var requiresPhotoProof: Bool = false
    @State private var syncToGoogleCalendar: Bool = GoogleCalendarService.isAutoSyncEnabled
    @Namespace private var scheduleModeNS

    private let durationPresets: [(label: String, mins: Int)] = [
        ("30m", 30),
        ("1h", 60),
        ("1.5h", 90),
        ("2h", 120),
        ("3h", 180)
    ]

    private let quickPlaces: [String] = ["Library", "Office", "Gym", "Home", "Cafe"]

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 36) { dismiss() }
                    Spacer()
                    Text(existingTask == nil ? "New Focus Task" : "Edit Focus Task")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // 1. TITLE
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TITLE").eyebrowStyle()
                            TextField(
                                "",
                                text: $title,
                                prompt: Text("Work on project").foregroundStyle(Color.white.opacity(0.30))
                            )
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(14)
                            .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                        }

                        // 2. PLACE / LOCATION (Optional)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("PLACE / LOCATION (OPTIONAL)").eyebrowStyle()
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(DailyOSTheme.skyGlow)
                                TextField(
                                    "",
                                    text: $location,
                                    prompt: Text("Library, Gym, Office...").foregroundStyle(Color.white.opacity(0.30))
                                )
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white)
                            }
                            .padding(14)
                            .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(quickPlaces, id: \.self) { place in
                                        let active = location.caseInsensitiveCompare(place) == .orderedSame
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            location = active ? "" : place
                                        } label: {
                                            Text(place)
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .foregroundStyle(active ? Color.black : Color.white.opacity(0.78))
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(active ? DailyOSTheme.skyGlow : DailyOSTheme.inputSurface, in: Capsule())
                                                .overlay(Capsule().stroke(active ? DailyOSTheme.skyGlow : DailyOSTheme.hairline, lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        // 3. DATE
                        VStack(alignment: .leading, spacing: 8) {
                            Text("DATE (MON–SUN)").eyebrowStyle()
                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundStyle(DailyOSTheme.skyGlow)
                                DatePicker(
                                    "Task Date",
                                    selection: $selectedDate,
                                    displayedComponents: .date
                                )
                                .tint(DailyOSTheme.skyGlow)
                            }
                            .padding(14)
                            .ambientCard(cornerRadius: 16)
                        }

                        // 4. TIME & DURATION
                        VStack(alignment: .leading, spacing: 10) {
                            Text("TIME & DURATION").eyebrowStyle()

                            VStack(spacing: 14) {
                                // Anytime vs Specific Time segmented pill (Matched-Geometry 120Hz glide)
                                HStack(spacing: 4) {
                                    scheduleModeButton("Specific Time", active: hasSpecificTime) {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        withAnimation(ProMotionSpring.glide) { hasSpecificTime = true }
                                    }
                                    scheduleModeButton("Anytime", active: !hasSpecificTime) {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        withAnimation(ProMotionSpring.glide) { hasSpecificTime = false }
                                    }
                                }
                                .padding(4)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))

                                if hasSpecificTime {
                                    HStack {
                                        Text("Start Time (24h)")
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.white)
                                        Spacer()
                                        DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                                            .labelsHidden()
                                            .tint(DailyOSTheme.skyGlow)
                                    }
                                }

                                Divider().overlay(DailyOSTheme.hairline)

                                // Fast Duration Preset Chips (30m, 1h, 1.5h, 2h, 3h, Custom)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Duration")
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.white)
                                        Spacer()
                                        Text(formattedDuration(durationMinutes))
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                            .monospacedDigit()
                                            .foregroundStyle(DailyOSTheme.skyGlow)
                                    }

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(durationPresets, id: \.mins) { preset in
                                                let selected = durationMinutes == preset.mins && !showingCustomDurationStepper
                                                Button {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    durationMinutes = preset.mins
                                                    showingCustomDurationStepper = false
                                                } label: {
                                                    Text(preset.label)
                                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                                        .monospacedDigit()
                                                        .foregroundStyle(selected ? Color.black : Color.white.opacity(0.84))
                                                        .padding(.horizontal, 13)
                                                        .padding(.vertical, 8)
                                                        .background(selected ? DailyOSTheme.skyGlow : DailyOSTheme.inputSurface, in: Capsule())
                                                        .overlay(Capsule().stroke(selected ? DailyOSTheme.skyGlow : DailyOSTheme.hairline, lineWidth: 1))
                                                }
                                                .buttonStyle(.plain)
                                            }

                                            let isCustom = showingCustomDurationStepper || !durationPresets.contains(where: { $0.mins == durationMinutes })
                                            Button {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                withAnimation(.spring(response: 0.25)) {
                                                    showingCustomDurationStepper.toggle()
                                                }
                                            } label: {
                                                Text("Custom")
                                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                                    .foregroundStyle(isCustom ? Color.black : Color.white.opacity(0.84))
                                                    .padding(.horizontal, 13)
                                                    .padding(.vertical, 8)
                                                    .background(isCustom ? DailyOSTheme.skyGlow : DailyOSTheme.inputSurface, in: Capsule())
                                                    .overlay(Capsule().stroke(isCustom ? DailyOSTheme.skyGlow : DailyOSTheme.hairline, lineWidth: 1))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }

                                    if showingCustomDurationStepper {
                                        Stepper("Minutes: \(durationMinutes)m", value: $durationMinutes, in: 10...480, step: 15)
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.white)
                                            .padding(.top, 4)
                                    }
                                }
                            }
                            .padding(16)
                            .ambientCard(cornerRadius: 18)
                        }

                        // 5. SMART PHOTO PROOF OPT-IN
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ACCOUNTABILITY").eyebrowStyle()

                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $requiresPhotoProof) {
                                    HStack(spacing: 10) {
                                        Image(systemName: requiresPhotoProof ? "camera.fill" : "camera")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(requiresPhotoProof ? DailyOSTheme.skyGlow : DailyOSTheme.eyebrow)
                                            .frame(width: 30, height: 30)
                                            .background(
                                                (requiresPhotoProof ? DailyOSTheme.skyGlow : DailyOSTheme.eyebrow).opacity(0.14),
                                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            )
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("Require Photo Proof")
                                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                .foregroundStyle(Color.white)
                                            let interval = PhotoProofSettings.photoIntervalMinutes
                                            Text(durationMinutes >= interval
                                                 ? "Start photo + every \(interval)m check-in"
                                                 : "Start photo + 1 hidden random mid-task check")
                                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                                .foregroundStyle(DailyOSTheme.eyebrow)
                                        }
                                    }
                                }
                                .tint(DailyOSTheme.skyGlow)

                                if googleAuth.isConnected && googleAuth.syncGoogleCalendarEnabled {
                                    Divider().overlay(DailyOSTheme.hairline)

                                    Toggle(isOn: $syncToGoogleCalendar) {
                                        HStack(spacing: 10) {
                                            Image(systemName: "g.circle.fill")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(syncToGoogleCalendar ? DailyOSTheme.indigoGlow : DailyOSTheme.eyebrow)
                                                .frame(width: 30, height: 30)
                                                .background(
                                                    (syncToGoogleCalendar ? DailyOSTheme.indigoGlow : DailyOSTheme.eyebrow).opacity(0.14),
                                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                )
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text("Sync to Google Calendar")
                                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                    .foregroundStyle(Color.white)
                                                Text("Mirrors changes & reschedules automatically")
                                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                                    .foregroundStyle(DailyOSTheme.eyebrow)
                                            }
                                        }
                                    }
                                    .tint(DailyOSTheme.indigoGlow)
                                }
                            }
                            .padding(14)
                            .ambientCard(accent: requiresPhotoProof ? DailyOSTheme.skyGlow : nil, cornerRadius: 16, washOpacity: 0.08)
                        }

                        // 6. NOTES (Optional)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("NOTES (OPTIONAL)").eyebrowStyle()
                            TextField(
                                "",
                                text: $notes,
                                prompt: Text("Key outcome or focus cue...").foregroundStyle(Color.white.opacity(0.30)),
                                axis: .vertical
                            )
                            .lineLimit(2...4)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(14)
                            .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                        }

                        if let existingTask {
                            Button {
                                let linkedID = existingTask.googleCalendarEventID
                                let taskID = existingTask.id.uuidString
                                PhotoProofScheduler.shared.cancelProofs(for: taskID)
                                FocusNudgeScheduler.shared.acknowledgeAndClear(taskID: taskID)
                                modelContext.delete(existingTask)
                                try? modelContext.save()
                                SharedModelContainer.shared.save()
                                FocusAutoSessionEngine.shared.evaluateAutoStartSchedule()
                                if let linkedID {
                                    Task { await GoogleCalendarService.deleteLinkedEvent(eventID: linkedID) }
                                }
                                dismiss()
                            } label: {
                                Text("Delete Task")
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

                // Sticky Full-Width Save Pill
                Button {
                    saveTask()
                    dismiss()
                } label: {
                    Text("Save Task")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(canSave ? DailyOSTheme.skyGlow : DailyOSTheme.emptyCell, in: Capsule())
                }
                .buttonStyle(MidnightPressStyle())
                .disabled(!canSave)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.calendar, ISOWeekCalendar.current)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .onAppear(perform: loadInitial)
    }

    private func scheduleModeButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if active {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DailyOSTheme.buttonSurface)
                        .matchedGeometryEffect(id: "scheduleModePill", in: scheduleModeNS)
                }
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(active ? Color.white : DailyOSTheme.eyebrow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
        }
        .buttonStyle(.plain)
    }

    private func formattedDuration(_ mins: Int) -> String {
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        let r = mins % 60
        if r == 0 { return "\(h)h" }
        if r == 30 { return "\(h).5h" }
        return "\(h)h \(r)m"
    }

    private func loadInitial() {
        if let task = existingTask {
            title = task.title
            location = task.location
            notes = task.notes
            selectedDate = HabitItem.date(from: task.dayKey) ?? initialDate
            if let st = task.startTime {
                hasSpecificTime = true
                startTime = st
            } else {
                hasSpecificTime = false
                startTime = defaultRoundedStartTime(for: selectedDate)
            }
            durationMinutes = task.durationMinutes
            requiresPhotoProof = task.requiresPhotoProof
            syncToGoogleCalendar = task.syncToGoogleCalendar
        } else {
            selectedDate = initialDate
            hasSpecificTime = true
            startTime = defaultRoundedStartTime(for: initialDate)
            durationMinutes = 60
            requiresPhotoProof = false
            syncToGoogleCalendar = GoogleCalendarService.isAutoSyncEnabled
        }
    }

    /// Rounds up to the next clean 15-minute slot (e.g., 14:52 → 15:00, 14:05 → 14:15).
    private func defaultRoundedStartTime(for date: Date) -> Date {
        let cal = ISOWeekCalendar.current
        let now = Date()
        let nowComps = cal.dateComponents([.hour, .minute], from: now)
        let nowHour = nowComps.hour ?? 9
        let nowMinute = nowComps.minute ?? 0
        let totalMins = nowHour * 60 + nowMinute
        let roundedMins = ((totalMins / 15) + 1) * 15
        let clampedMins = min(23 * 60 + 45, roundedMins)

        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.hour = clampedMins / 60
        comps.minute = clampedMins % 60
        comps.second = 0
        return cal.date(from: comps) ?? date
    }

    private func combine(date: Date, time: Date) -> Date {
        let cal = ISOWeekCalendar.current
        let d = cal.dateComponents([.year, .month, .day], from: date)
        let t = cal.dateComponents([.hour, .minute], from: time)
        var merged = DateComponents()
        merged.year = d.year
        merged.month = d.month
        merged.day = d.day
        merged.hour = t.hour
        merged.minute = t.minute
        merged.second = 0
        return cal.date(from: merged) ?? date
    }

    private func saveTask() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let cleanLoc = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = HabitItem.dateKey(for: selectedDate)
        let resolvedStart: Date? = hasSpecificTime ? combine(date: selectedDate, time: startTime) : nil

        let savedTask: FocusTaskItem
        if let task = existingTask {
            task.title = cleanTitle
            task.location = cleanLoc
            task.notes = cleanNotes
            task.dayKey = key
            task.startTime = resolvedStart
            task.durationMinutes = durationMinutes
            task.requiresPhotoProof = requiresPhotoProof
            task.syncToGoogleCalendar = syncToGoogleCalendar
            savedTask = task
        } else {
            let newTask = FocusTaskItem(
                title: cleanTitle,
                location: cleanLoc,
                notes: cleanNotes,
                dayKey: key,
                startTime: resolvedStart,
                durationMinutes: durationMinutes,
                requiresPhotoProof: requiresPhotoProof,
                syncToGoogleCalendar: syncToGoogleCalendar
            )
            modelContext.insert(newTask)
            savedTask = newTask
        }

        let savedTaskID = savedTask.id.uuidString
        try? modelContext.save()
        SharedModelContainer.shared.save()

        if requiresPhotoProof, let scheduledStart = resolvedStart {
            PhotoProofScheduler.shared.scheduleProofs(
                taskID: savedTaskID,
                taskTitle: cleanTitle,
                taskNotes: cleanNotes,
                taskStart: scheduledStart,
                durationMinutes: durationMinutes
            )
        } else if !requiresPhotoProof {
            PhotoProofScheduler.shared.cancelProofs(for: savedTaskID)
        }

        if syncToGoogleCalendar {
            Task { await GoogleCalendarService.pushTask(savedTask) }
        }

        FocusAutoSessionEngine.shared.evaluateAutoStartSchedule()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
