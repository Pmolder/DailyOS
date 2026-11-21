import SwiftUI
import SwiftData

struct HabitsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\HabitItem.sortOrder, order: .forward),
            SortDescriptor(\HabitItem.createdAt, order: .forward)
        ]
    ) private var habits: [HabitItem]

    @ObservedObject private var notificationScheduler = NotificationScheduler.shared

    let onOpenSettings: () -> Void

    @State private var showingCreateSheet = false
    @State private var editingHabit: HabitItem?
    @State private var selectedHeatmapDate: Date?

    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)

    private var todaySummary: (completed: Int, scheduled: Int, ratio: Double) {
        HabitItem.dailyCompletionSummary(habits: habits, on: Date())
    }

    private var overall7DayAccuracy: Double {
        averageAccuracy(days: 7)
    }

    private var overall30DayAccuracy: Double {
        averageAccuracy(days: 30)
    }

    var body: some View {
        NavigationStack {
            List {
                // 1. Daily Accuracy Ring & Analytics Header
                Section {
                    VStack(spacing: 14) {
                        HStack(spacing: 18) {
                            // Animated Daily Accuracy Ring
                            ZStack {
                                Circle()
                                    .stroke(Color.white.opacity(0.12), lineWidth: 10)
                                    .frame(width: 78, height: 78)

                                Circle()
                                    .trim(from: 0, to: todaySummary.ratio)
                                    .stroke(
                                        AngularGradient(
                                            colors: [.mint, .green, .emeraldAccent],
                                            center: .center
                                        ),
                                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                                    )
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 78, height: 78)
                                    .animation(.spring(response: 0.35), value: todaySummary.ratio)

                                Text("\(Int(round(todaySummary.ratio * 100)))%")
                                    .font(.headline.weight(.black).monospacedDigit())
                                    .foregroundStyle(.white)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Daily Accuracy")
                                    .font(.headline.weight(.bold))

                                Text("\(todaySummary.completed) of \(todaySummary.scheduled) scheduled habits completed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 8) {
                                    accuracyPill(label: "7D", value: overall7DayAccuracy, color: .cyan)
                                    accuracyPill(label: "30D", value: overall30DayAccuracy, color: .green)
                                }
                            }
                            Spacer(minLength: 0)
                        }

                        Divider()

                        // 12-Week GitHub-Style Consistency Heatmap Grid
                        ConsistencyHeatmapView(
                            habits: habits,
                            selectedDate: $selectedHeatmapDate
                        )
                    }
                    .padding(.vertical, 6)
                }

                // 2. Time-of-Day Segmented Habit Lists (Morning, Day, Evening)
                ForEach(HabitTimeOfDay.allCases) { segment in
                    let segmentHabits = habitsForSegment(segment)

                    Section {
                        if segmentHabits.isEmpty {
                            HStack {
                                Text("No \(segment.displayName.lowercased()) habits yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Add") {
                                    showingCreateSheet = true
                                }
                                .font(.caption.weight(.bold))
                            }
                        } else {
                            ForEach(segmentHabits) { habit in
                                SegmentedHabitRowView(
                                    habit: habit,
                                    onQuickCheck: {
                                        impactFeedback.impactOccurred()
                                        habit.toggleCompletion(on: Date())
                                        SharedModelContainer.shared.save()
                                        Task {
                                            await notificationScheduler.rescheduleAll()
                                        }
                                    },
                                    onTapEdit: {
                                        editingHabit = habit
                                    }
                                )
                            }
                            .onMove { source, destination in
                                moveHabits(in: segment, from: source, to: destination)
                            }
                            .onDelete { offsets in
                                deleteHabits(in: segment, at: offsets)
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: segment.iconName)
                                .foregroundStyle(colorForSegment(segment))
                            Text(segment.displayName)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            Spacer()
                            let doneCount = segmentHabits.filter { $0.isCompleted(on: Date()) }.count
                            Text("\(doneCount)/\(segmentHabits.count)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Habits")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings and Backup")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("Add Habit")
                }
            }
            .sheet(isPresented: $showingCreateSheet) {
                HabitEditorView(habitToEdit: nil)
            }
            .sheet(item: $editingHabit) { habit in
                HabitEditorView(habitToEdit: habit)
            }
        }
    }

    private func habitsForSegment(_ segment: HabitTimeOfDay) -> [HabitItem] {
        habits
            .filter { $0.timeOfDay == segment }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.createdAt < $1.createdAt
            }
    }

    private func moveHabits(in segment: HabitTimeOfDay, from source: IndexSet, to destination: Int) {
        var reordered = habitsForSegment(segment)
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in reordered.enumerated() {
            item.sortOrder = index
        }
        SharedModelContainer.shared.save()
    }

    private func deleteHabits(in segment: HabitTimeOfDay, at offsets: IndexSet) {
        let items = habitsForSegment(segment)
        for index in offsets where index < items.count {
            modelContext.delete(items[index])
        }
        SharedModelContainer.shared.save()
        Task {
            await notificationScheduler.rescheduleAll()
        }
    }

    private func averageAccuracy(days: Int) -> Double {
        guard !habits.isEmpty else { return 0 }
        let sum = habits.reduce(0.0) { $0 + $1.completionRate(lastDays: days) }
        return sum / Double(habits.count)
    }

    private func accuracyPill(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text("\(Int(round(value * 100)))%")
                .font(.caption2.weight(.black).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }

    private func colorForSegment(_ segment: HabitTimeOfDay) -> Color {
        switch segment {
        case .morning: return .orange
        case .day: return .cyan
        case .evening: return .indigo
        }
    }
}

// MARK: - Segmented Habit Row (One-Tap Checkoff + 7d / 30d / All-Time Accuracy)

private struct SegmentedHabitRowView: View {
    let habit: HabitItem
    let onQuickCheck: () -> Void
    let onTapEdit: () -> Void

    private var completedToday: Bool {
        habit.isCompleted(on: Date())
    }

    var body: some View {
        HStack(spacing: 12) {
            // Simple 1-tap checkoff circle (no camera proof required on Habits tab)
            Button(action: onQuickCheck) {
                ZStack {
                    Circle()
                        .fill(completedToday ? Color.green : Color.white.opacity(0.08))
                        .frame(width: 38, height: 38)
                        .overlay(
                            Circle()
                                .stroke(completedToday ? Color.green : Color.white.opacity(0.25), lineWidth: 1.5)
                        )

                    if completedToday {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.black))
                            .foregroundStyle(.black)
                    } else {
                        Image(systemName: habit.iconName)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .buttonStyle(.plain)

            // Habit Details + Accuracy Metrics
            Button(action: onTapEdit) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(habit.title)
                            .font(.subheadline.weight(.semibold))
                            .strikethrough(completedToday, color: .secondary)
                            .foregroundStyle(completedToday ? Color.secondary : Color.white)

                        Spacer()

                        HStack(spacing: 2) {
                            Image(systemName: "flame.fill")
                                .font(.caption2)
                                .foregroundStyle(habit.currentStreak > 0 ? Color.orange : Color.secondary)
                            Text("\(habit.currentStreak)d")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(habit.currentStreak > 0 ? Color.orange : Color.secondary)
                        }
                    }

                    // Per-habit 7-day, 30-day, and all-time completion percentages
                    HStack(spacing: 8) {
                        statTag("7d", habit.completionRate(lastDays: 7))
                        statTag("30d", habit.completionRate(lastDays: 30))
                        statTag("All", habit.allTimeCompletionRate)

                        if habit.reminderEnabled {
                            Spacer()
                            Label(habit.formattedReminderTime, systemImage: "bell.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.indigo)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }

    private func statTag(_ title: String, _ ratio: Double) -> some View {
        Text("\(title) \(Int(round(ratio * 100)))%")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(ratio >= 0.8 ? Color.green : (ratio >= 0.4 ? Color.cyan : Color.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - 12-Week GitHub-Style Consistency Heatmap Grid

private struct ConsistencyHeatmapView: View {
    let habits: [HabitItem]
    @Binding var selectedDate: Date?

    private let weeksCount = 12
    private let daysPerWeek = 7

    /// Builds a 12x7 grid of dates ending on today (column-major: 12 weeks, 7 days per week).
    private var gridWeeks: [[Date?]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayWeekday = calendar.component(.weekday, from: today) // 1 = Sun ... 7 = Sat
        let daysFromStartOfCurrentWeek = todayWeekday - 1
        let totalDaysBack = (weeksCount - 1) * 7 + daysFromStartOfCurrentWeek

        guard let gridStart = calendar.date(byAdding: .day, value: -totalDaysBack, to: today) else {
            return []
        }

        var weeks: [[Date?]] = []
        for weekIdx in 0..<weeksCount {
            var weekDays: [Date?] = []
            for dayIdx in 0..<daysPerWeek {
                let offset = weekIdx * 7 + dayIdx
                if let cellDate = calendar.date(byAdding: .day, value: offset, to: gridStart),
                   cellDate <= today {
                    weekDays.append(cellDate)
                } else {
                    weekDays.append(nil)
                }
            }
            weeks.append(weekDays)
        }
        return weeks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("12-Week Consistency Grid")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if let selected = selectedDate {
                    let info = HabitItem.dailyCompletionSummary(habits: habits, on: selected)
                    Text("\(selected.formatted(date: .abbreviated, time: .omitted)): \(info.completed)/\(info.scheduled) (\(Int(round(info.ratio * 100)))%)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Text("Tap a square for day details")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 4) {
                // Weekday labels column
                VStack(spacing: 4) {
                    ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, letter in
                        Text(letter)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 10, height: 14)
                    }
                }

                // 12 Week Columns
                HStack(spacing: 4) {
                    ForEach(0..<gridWeeks.count, id: \.self) { weekIndex in
                        VStack(spacing: 4) {
                            ForEach(0..<daysPerWeek, id: \.self) { dayIndex in
                                if let cellDate = gridWeeks[weekIndex][dayIndex] {
                                    let summary = HabitItem.dailyCompletionSummary(habits: habits, on: cellDate)
                                    let isSelected = selectedDate.map { Calendar.current.isDate($0, inSameDayAs: cellDate) } ?? false

                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(intensityColor(for: summary.ratio))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 14)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 3)
                                                .stroke(isSelected ? Color.white : Color.clear, lineWidth: 1.5)
                                        )
                                        .onTapGesture {
                                            selectedDate = cellDate
                                        }
                                } else {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.clear)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 14)
                                }
                            }
                        }
                    }
                }
            }

            // Legend
            HStack(spacing: 5) {
                Spacer()
                Text("Less")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(intensityColor(for: level))
                        .frame(width: 10, height: 10)
                }
                Text("More")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func intensityColor(for ratio: Double) -> Color {
        switch ratio {
        case ..<0.01:
            return Color.white.opacity(0.08)
        case 0.01..<0.35:
            return Color.green.opacity(0.30)
        case 0.35..<0.65:
            return Color.green.opacity(0.55)
        case 0.65..<0.90:
            return Color.green.opacity(0.78)
        default:
            return Color.green
        }
    }
}

private extension Color {
    static let emeraldAccent = Color(red: 0.12, green: 0.85, blue: 0.55)
}
