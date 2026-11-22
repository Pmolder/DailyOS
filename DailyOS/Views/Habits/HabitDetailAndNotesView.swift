import SwiftUI
import SwiftData

// MARK: - Habit Detail & Interactive ISO-8601 Mon–Sun Calendar View

struct HabitDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let habit: HabitItem
    let allHabits: [HabitItem]
    let allLogs: [HabitLog]

    @State private var displayedMonthStart: Date = {
        let cal = ISOWeekCalendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        return cal.date(from: comps) ?? Date()
    }()

    @State private var showingNotesView = false
    @State private var showingEditSheet = false
    @State private var showingAnalyticsSheet = false
    @State private var noteEditorDate: IdentifiableDate?
    @State private var quantityEditorDate: IdentifiableDate?

    private var logMap: [String: HabitLog] {
        HabitMetricsEngine.logsByDayKey(for: habit.id, allLogs: allLogs)
    }

    private var accent: Color {
        habit.accentColor
    }

    private var monthYearTitle: String {
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "MMM yyyy"
        return f.string(from: displayedMonthStart)
    }

    /// Generates 42 calendar cells (6 ISO Monday–Sunday rows) covering `displayedMonthStart`.
    private var monthGridDays: [(date: Date, inDisplayedMonth: Bool)] {
        let cal = ISOWeekCalendar.current
        let firstWeekdayMondayIdx = ISOWeekCalendar.mondayBasedDayIndex(for: displayedMonthStart)
        guard let gridStart = cal.date(byAdding: .day, value: -firstWeekdayMondayIdx, to: displayedMonthStart) else {
            return []
        }
        let targetMonth = cal.component(.month, from: displayedMonthStart)
        return (0..<42).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return (d, cal.component(.month, from: d) == targetMonth)
        }
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    // Top Navigation Row
                    HStack(spacing: 10) {
                        FrostedCircleButton(icon: "chevron.left") {
                            dismiss()
                        }

                        Spacer()

                        FrostedCircleButton(icon: "note.text") {
                            showingNotesView = true
                        }
                        FrostedCircleButton(icon: "square.and.pencil") {
                            showingEditSheet = true
                        }
                        FrostedCircleButton(icon: "chart.xyaxis.line") {
                            showingAnalyticsSheet = true
                        }
                    }

                    // Identity Row
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(accent.opacity(0.18))
                            .frame(width: 48, height: 48)
                            .overlay(
                                Image(systemName: habit.iconName)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(accent)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(habit.title)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            if !habit.subtitle.isEmpty {
                                Text(habit.subtitle)
                                    .font(.system(size: 13, weight: .regular, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.eyebrow)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    // Full Heatmap Card
                    VStack(alignment: .leading, spacing: 6) {
                        HabitHeatmapGridView(
                            habit: habit,
                            logMap: logMap,
                            weeksCount: 24,
                            showAxes: true,
                            highlightNoteDays: true
                        )
                    }
                    .padding(14)
                    .ambientCard(accent: accent, cornerRadius: 20, washOpacity: 0.08)

                    // Quick Info Pills (Streak + Schedule)
                    HStack(spacing: 10) {
                        let streak = HabitMetricsEngine.currentStreak(for: habit, logMap: logMap)
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(accent)
                            Text("\(streak)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(accent.opacity(0.16), in: Capsule())
                        .overlay(Capsule().stroke(accent.opacity(0.28), lineWidth: 1))

                        HStack(spacing: 6) {
                            Image(systemName: "target")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(accent)
                            Text(habit.scheduleBadgeText)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(accent.opacity(0.14), in: Capsule())
                        .overlay(Capsule().stroke(accent.opacity(0.24), lineWidth: 1))

                        if habit.trackingMode == .quantity {
                            Text("\(Int(habit.effectiveDailyTarget)) \(habit.unitLabel)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(DailyOSTheme.eyebrow)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(DailyOSTheme.card, in: Capsule())
                                .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))
                        }

                        Spacer()
                    }

                    // Interactive Mon–Sun Monthly Calendar Card
                    VStack(spacing: 14) {
                        // Weekday Headers (ISO-8601 Monday–Sunday)
                        HStack(spacing: 6) {
                            ForEach(Weekday.allCases) { day in
                                Text(day.shortName)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.eyebrow)
                                    .frame(maxWidth: .infinity)
                            }
                        }

                        // 7-Column Calendar Grid
                        let cal = ISOWeekCalendar.current
                        let today = cal.startOfDay(for: Date())
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                            ForEach(monthGridDays, id: \.date) { item in
                                let key = HabitItem.dateKey(for: item.date)
                                let ratio = HabitMetricsEngine.progressRatio(for: habit, on: item.date, logMap: logMap)
                                let isDone = ratio >= 1.0
                                let hasPartial = ratio > 0.0 && ratio < 1.0
                                let hasNote = logMap[key]?.hasNote == true
                                let isToday = cal.isDate(item.date, inSameDayAs: today)
                                let isFuture = item.date > today
                                let dayNum = cal.component(.day, from: item.date)

                                VStack(spacing: 3) {
                                    Text("\(dayNum)")
                                        .font(.system(size: 14, weight: isToday || isDone ? .bold : .medium, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(
                                            item.inDisplayedMonth
                                                ? (isFuture ? Color.white.opacity(0.28) : Color.white)
                                                : Color.white.opacity(0.18)
                                        )

                                    HStack(spacing: 3) {
                                        if isDone || hasPartial {
                                            Circle()
                                                .fill(accent.opacity(isDone ? 1.0 : 0.55))
                                                .frame(width: 4.5, height: 4.5)
                                                .shadow(color: accent.opacity(0.7), radius: 3)
                                        }
                                        if hasNote {
                                            Circle()
                                                .fill(Color.white.opacity(0.9))
                                                .frame(width: 4, height: 4)
                                        }
                                    }
                                    .frame(height: 5)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(
                                            isDone
                                                ? accent.opacity(0.22)
                                                : (hasPartial ? accent.opacity(0.10) : Color.clear)
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(isToday ? accent : Color.clear, lineWidth: 1.5)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard !isFuture else { return }
                                    handleDayTap(item.date)
                                }
                                .onLongPressGesture(minimumDuration: 0.42) {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    noteEditorDate = IdentifiableDate(date: item.date)
                                }
                            }
                        }

                        Divider().overlay(DailyOSTheme.hairline)

                        // Calendar Footer Controls
                        HStack(spacing: 10) {
                            Menu {
                                ForEach(-6...6, id: \.self) { monthOffset in
                                    if let candidate = ISOWeekCalendar.current.date(byAdding: .month, value: monthOffset, to: startOfCurrentMonth()) {
                                        Button(formatMonthYear(candidate)) {
                                            withAnimation(.spring(response: 0.3)) {
                                                displayedMonthStart = candidate
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(monthYearTitle)
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(DailyOSTheme.inputSurface, in: Capsule())
                                .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))
                            }

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.spring(response: 0.3)) {
                                    displayedMonthStart = startOfCurrentMonth()
                                }
                            } label: {
                                Text("Today")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(DailyOSTheme.inputSurface, in: Capsule())
                                    .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            FrostedCircleButton(icon: "chevron.left", size: 34) {
                                shiftMonth(by: -1)
                            }
                            FrostedCircleButton(icon: "chevron.right", size: 34) {
                                shiftMonth(by: 1)
                            }
                        }

                        Text("Press and hold a day to add a note")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                            .padding(.top, 2)
                    }
                    .padding(16)
                    .ambientCard(cornerRadius: 22)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showingNotesView) {
            HabitNotesStoryView(habit: habit, allLogs: allLogs)
        }
        .sheet(isPresented: $showingEditSheet) {
            HabitEditorView(habitToEdit: habit)
        }
        .sheet(isPresented: $showingAnalyticsSheet) {
            HabitAnalyticsSheetView(habits: allHabits, allLogs: allLogs, selectedHabitID: habit.id)
        }
        .sheet(item: $noteEditorDate) { wrapped in
            HabitDayNoteSheet(habit: habit, date: wrapped.date, initialNote: logMap[HabitItem.dateKey(for: wrapped.date)]?.note ?? "")
        }
        .sheet(item: $quantityEditorDate) { wrapped in
            HabitQuantityAdjustSheet(
                habit: habit,
                date: wrapped.date,
                initialValue: HabitMetricsEngine.loggedValue(for: habit, on: wrapped.date, logMap: logMap)
            )
        }
    }

    private func handleDayTap(_ date: Date) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if habit.trackingMode == .quantity {
            quantityEditorDate = IdentifiableDate(date: date)
            return
        }

        let currentlyDone = HabitMetricsEngine.isDayComplete(for: habit, on: date, logMap: logMap)
        if habit.kind == .quit {
            // Toggle between clean (1.0) and slip (-1.0)
            let newVal: Double = currentlyDone ? -1.0 : 1.0
            SharedModelContainer.shared.setHabitLog(for: habit, on: date, value: newVal)
        } else {
            let newVal: Double = currentlyDone ? 0.0 : habit.effectiveDailyTarget
            SharedModelContainer.shared.setHabitLog(for: habit, on: date, value: newVal)
        }
        Task { await NotificationScheduler.shared.rescheduleAll() }
    }

    private func shiftMonth(by delta: Int) {
        if let updated = ISOWeekCalendar.current.date(byAdding: .month, value: delta, to: displayedMonthStart) {
            withAnimation(.spring(response: 0.28)) {
                displayedMonthStart = updated
            }
        }
    }

    private func startOfCurrentMonth() -> Date {
        let cal = ISOWeekCalendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        return cal.date(from: comps) ?? Date()
    }

    private func formatMonthYear(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }
}

// MARK: - Habit Notes / Story View ("Every day has a story.")

struct HabitNotesStoryView: View {
    @Environment(\.dismiss) private var dismiss
    let habit: HabitItem
    let allLogs: [HabitLog]

    @State private var highlightedDayKey: String?
    @State private var editingNoteDate: IdentifiableDate?

    private var logMap: [String: HabitLog] {
        HabitMetricsEngine.logsByDayKey(for: habit.id, allLogs: allLogs)
    }

    private var notedLogs: [HabitLog] {
        allLogs
            .filter { $0.habitID == habit.id && $0.hasNote }
            .sorted { $0.dayKey > $1.dayKey }
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    FrostedCircleButton(icon: "chevron.left") {
                        dismiss()
                    }

                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(habit.accentColor.opacity(0.18))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: habit.iconName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(habit.accentColor)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notes")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(habit.title)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }

                    Spacer()

                    FrostedCircleButton(icon: "plus") {
                        editingNoteDate = IdentifiableDate(date: Date())
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)

                // Note-Aware Heatmap Header + Scrollable Chronological Story Feed
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            HabitHeatmapGridView(
                                habit: habit,
                                logMap: logMap,
                                weeksCount: 24,
                                showAxes: true,
                                highlightNoteDays: true,
                                onSelectDay: { tappedKey in
                                    if logMap[tappedKey]?.hasNote == true {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        withAnimation(.spring(response: 0.35)) {
                                            highlightedDayKey = tappedKey
                                            proxy.scrollTo(tappedKey, anchor: .center)
                                        }
                                    } else if let dt = HabitItem.date(from: tappedKey) {
                                        editingNoteDate = IdentifiableDate(date: dt)
                                    }
                                }
                            )
                            .padding(14)
                            .ambientCard(accent: habit.accentColor, cornerRadius: 20, washOpacity: 0.06)

                            if notedLogs.isEmpty {
                                VStack(spacing: 10) {
                                    Image(systemName: "note.text")
                                        .font(.system(size: 32))
                                        .foregroundStyle(DailyOSTheme.eyebrow)
                                    Text("No journal notes yet")
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text("Tap + above or long-press any calendar day to capture a story for this habit.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(DailyOSTheme.eyebrow)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(28)
                                .frame(maxWidth: .infinity)
                                .ambientCard(cornerRadius: 20)
                            } else {
                                ForEach(Array(notedLogs.enumerated()), id: \.element.dayKey) { index, log in
                                    let isActive = (highlightedDayKey == log.dayKey) || (highlightedDayKey == nil && index == 0)

                                    Button {
                                        editingNoteDate = IdentifiableDate(date: log.date)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(spacing: 6) {
                                                Circle()
                                                    .fill(habit.accentColor)
                                                    .frame(width: 6, height: 6)
                                                Text(formattedMetadataLine(for: log.date))
                                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                                    .foregroundStyle(DailyOSTheme.eyebrow)
                                                Spacer()
                                            }

                                            Text(log.note ?? "")
                                                .font(.system(size: 15, weight: .regular, design: .rounded))
                                                .foregroundStyle(.white)
                                                .multilineTextAlignment(.leading)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(16)
                                        .background(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .fill(DailyOSTheme.card)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .stroke(
                                                    isActive ? habit.accentColor.opacity(0.65) : DailyOSTheme.hairline,
                                                    lineWidth: isActive ? 1.4 : 1
                                                )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .id(log.dayKey)
                                    .contextMenu {
                                        Button {
                                            editingNoteDate = IdentifiableDate(date: log.date)
                                        } label: {
                                            Label("Edit Note", systemImage: "pencil")
                                        }
                                        Button(role: .destructive) {
                                            SharedModelContainer.shared.updateHabitNote(for: habit, on: log.date, note: nil)
                                        } label: {
                                            Label("Delete Note", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 28)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editingNoteDate) { wrapped in
            HabitDayNoteSheet(
                habit: habit,
                date: wrapped.date,
                initialNote: logMap[HabitItem.dateKey(for: wrapped.date)]?.note ?? ""
            )
        }
    }

    private func formattedMetadataLine(for date: Date) -> String {
        let cal = ISOWeekCalendar.current
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE, MMM d, yyyy"
        let dateStr = f.string(from: date)

        let today = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: date)
        let diff = cal.dateComponents([.day], from: target, to: today).day ?? 0

        let rel: String
        if diff == 0 {
            rel = "Today"
        } else if diff == 1 {
            rel = "Yesterday"
        } else if diff > 1 {
            rel = "\(diff) days ago"
        } else {
            rel = "Upcoming"
        }
        return "\(dateStr) · \(rel)"
    }
}

// MARK: - Supporting Modals (Add/Edit Note & Quantity Adjuster)

struct IdentifiableDate: Identifiable {
    let id = UUID()
    let date: Date
}

struct HabitDayNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let habit: HabitItem
    let date: Date
    @State var noteText: String

    init(habit: HabitItem, date: Date, initialNote: String) {
        self.habit = habit
        self.date = date
        self._noteText = State(initialValue: initialNote)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(date.formatted(date: .complete, time: .omitted))
                    .eyebrowStyle()

                TextEditor(text: $noteText)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 160)
                    .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    SharedModelContainer.shared.updateHabitNote(for: habit, on: date, note: noteText)
                    dismiss()
                } label: {
                    Text("Save Note")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.canvas)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(habit.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(DailyOSTheme.canvas.ignoresSafeArea())
            .navigationTitle("Habit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct HabitQuantityAdjustSheet: View {
    @Environment(\.dismiss) private var dismiss
    let habit: HabitItem
    let date: Date
    @State var currentValue: Double

    init(habit: HabitItem, date: Date, initialValue: Double) {
        self.habit = habit
        self.date = date
        self._currentValue = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text(habit.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)

                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .eyebrowStyle()

                HStack(spacing: 24) {
                    FrostedCircleButton(icon: "minus", size: 48) {
                        currentValue = max(0, currentValue - 1)
                    }

                    VStack(spacing: 2) {
                        Text("\(Int(currentValue))")
                            .font(.system(size: 48, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(habit.accentColor)
                        Text("of \(Int(habit.effectiveDailyTarget)) \(habit.unitLabel)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                    .frame(minWidth: 100)

                    FrostedCircleButton(icon: "plus", size: 48, tint: habit.accentColor) {
                        currentValue += 1
                    }
                }

                Button {
                    SharedModelContainer.shared.setHabitLog(for: habit, on: date, value: currentValue)
                    Task { await NotificationScheduler.shared.rescheduleAll() }
                    dismiss()
                } label: {
                    Text("Save Progress")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.canvas)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(habit.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(DailyOSTheme.canvas.ignoresSafeArea())
            .navigationTitle("Update Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(320)])
        .preferredColorScheme(.dark)
    }
}
