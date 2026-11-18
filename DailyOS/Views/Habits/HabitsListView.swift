import SwiftUI
import SwiftData

struct SelectedProofContext: Identifiable {
    let id = UUID()
    let habitTitle: String
    let record: PhotoProofRecord
}

struct HabitsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\HabitItem.reminderHour, order: .forward),
            SortDescriptor(\HabitItem.reminderMinute, order: .forward),
            SortDescriptor(\HabitItem.createdAt, order: .forward)
        ]
    ) private var habits: [HabitItem]

    @ObservedObject private var notificationScheduler = NotificationScheduler.shared

    @State private var showingCreateSheet = false
    @State private var editingHabit: HabitItem?
    @State private var photoCaptureTargetHabit: HabitItem?
    @State private var viewingProofContext: SelectedProofContext?

    private var completedTodayCount: Int {
        let now = Date()
        return habits.filter { $0.isCompleted(on: now) }.count
    }

    var body: some View {
        NavigationStack {
            List {
                // Daily Progress & 64-Notification Scheduler Summary
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Today's Habits")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(completedTodayCount) of \(habits.count) completed today")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(HabitItem.dateKey(for: Date()))
                                .font(.caption.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.indigo.opacity(0.14), in: Capsule())
                                .foregroundStyle(.indigo)
                        }

                        ProgressView(
                            value: habits.isEmpty ? 0.0 : Double(completedTodayCount),
                            total: Double(max(1, habits.count))
                        )
                        .tint(.green)

                        Divider()

                        HStack {
                            Label(
                                "Notification Queue: \(notificationScheduler.totalPendingCount) / \(NotificationScheduler.maxPendingLimit)",
                                systemImage: "bell.badge.fill"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                            Spacer()

                            Text("Actions: Mark Done • Snooze 15m")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Habits Section
                Section("Daily Habits") {
                    if habits.isEmpty {
                        ContentUnavailableView(
                            "No Habits Yet",
                            systemImage: "checklist",
                            description: Text("Tap + to add daily habits with custom notification sounds and optional live camera Photo Proof.")
                        )
                    } else {
                        ForEach(habits) { habit in
                            HabitRowView(
                                habit: habit,
                                onToggleCheck: {
                                    handleHabitCheckToggle(habit)
                                },
                                onTapEdit: {
                                    editingHabit = habit
                                },
                                onViewProof: { record in
                                    viewingProofContext = SelectedProofContext(
                                        habitTitle: habit.title,
                                        record: record
                                    )
                                },
                                onSnooze15m: {
                                    snoozeHabit15Minutes(habit)
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteHabit(habit)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    snoozeHabit15Minutes(habit)
                                } label: {
                                    Label("Snooze 15m", systemImage: "clock.arrow.circlepath")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Habits")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Label("Add Habit", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingCreateSheet) {
                HabitEditorView(habitToEdit: nil)
            }
            .sheet(item: $editingHabit) { habit in
                HabitEditorView(habitToEdit: habit)
            }
            .sheet(item: $photoCaptureTargetHabit) { habit in
                LivePhotoProofCaptureView(habit: habit) { capturedImage in
                    let todayKey = HabitItem.dateKey(for: Date())
                    let savedFileName = SharedModelContainer.savePhotoProofImage(
                        capturedImage,
                        habitID: habit.id,
                        dateString: todayKey
                    )
                    habit.markCompleted(on: Date(), photoFileName: savedFileName)
                    SharedModelContainer.shared.save()
                    Task {
                        await notificationScheduler.rescheduleAll()
                    }
                }
            }
            .sheet(item: $viewingProofContext) { ctx in
                PhotoProofViewerSheet(habitTitle: ctx.habitTitle, record: ctx.record)
            }
        }
    }

    private func handleHabitCheckToggle(_ habit: HabitItem) {
        let now = Date()
        if habit.isCompleted(on: now) {
            habit.markIncomplete(on: now)
            SharedModelContainer.shared.save()
            Task {
                await notificationScheduler.rescheduleAll()
            }
        } else {
            if habit.requiresPhotoProof {
                photoCaptureTargetHabit = habit
            } else {
                habit.markCompleted(on: now)
                SharedModelContainer.shared.save()
                Task {
                    await notificationScheduler.rescheduleAll()
                }
            }
        }
    }

    private func snoozeHabit15Minutes(_ habit: HabitItem) {
        habit.snoozedUntil = Date().addingTimeInterval(15 * 60)
        SharedModelContainer.shared.save()
        Task {
            _ = await notificationScheduler.requestAuthorizationIfNeeded()
            await notificationScheduler.rescheduleAll()
        }
    }

    private func deleteHabit(_ habit: HabitItem) {
        modelContext.delete(habit)
        SharedModelContainer.shared.save()
        Task {
            await notificationScheduler.rescheduleAll()
        }
    }
}

private struct HabitRowView: View {
    let habit: HabitItem
    let onToggleCheck: () -> Void
    let onTapEdit: () -> Void
    let onViewProof: (PhotoProofRecord) -> Void
    let onSnooze15m: () -> Void

    private var completedToday: Bool {
        habit.isCompleted(on: Date())
    }

    private var todaysProof: PhotoProofRecord? {
        habit.photoProof(for: Date())
    }

    var body: some View {
        HStack(spacing: 12) {
            // Check-off or Camera Proof Button
            Button(action: onToggleCheck) {
                ZStack {
                    Circle()
                        .fill(completedToday ? Color.green : Color.secondary.opacity(0.14))
                        .frame(width: 40, height: 40)

                    if completedToday {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                    } else if habit.requiresPhotoProof {
                        Image(systemName: "camera.fill")
                            .font(.subheadline)
                            .foregroundStyle(.indigo)
                    } else {
                        Image(systemName: habit.iconName)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .buttonStyle(.plain)

            // Habit Details
            Button(action: onTapEdit) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(habit.title)
                            .font(.headline)
                            .strikethrough(completedToday, color: .secondary)
                            .foregroundStyle(completedToday ? .secondary : .primary)

                        if habit.requiresPhotoProof {
                            Label("Photo Proof", systemImage: "camera.badge.ellipsis")
                                .labelStyle(.iconOnly)
                                .font(.caption)
                                .foregroundStyle(.indigo)
                        }
                    }

                    if !habit.notes.isEmpty {
                        Text(habit.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        if habit.reminderEnabled {
                            Label(habit.formattedReminderTime, systemImage: "bell.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.indigo)
                        }

                        Text(habit.repeatSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if let snoozed = habit.snoozedUntil, snoozed > Date() {
                            Text("Snoozed → \(snoozed.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Streak Badge & Proof Thumbnail Button
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(.caption)
                        .foregroundStyle(habit.currentStreak > 0 ? .orange : .secondary)
                    Text("\(habit.currentStreak)d")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(habit.currentStreak > 0 ? .primary : .secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.14), in: Capsule())

                if let proof = todaysProof {
                    Button {
                        onViewProof(proof)
                    } label: {
                        Label("Proof", systemImage: "photo.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .contextMenu {
            Button(action: onToggleCheck) {
                Label(
                    completedToday
                        ? "Mark Incomplete"
                        : (habit.requiresPhotoProof ? "Take Photo Proof & Complete" : "Mark Completed"),
                    systemImage: completedToday ? "xmark.circle" : "checkmark.circle.fill"
                )
            }

            Button(action: onSnooze15m) {
                Label("Snooze Reminder 15m", systemImage: "clock.arrow.circlepath")
            }

            if let proof = todaysProof {
                Button {
                    onViewProof(proof)
                } label: {
                    Label("View Today's Photo Proof", systemImage: "photo")
                }
            }

            Button(action: onTapEdit) {
                Label("Edit Habit", systemImage: "pencil")
            }
        }
    }
}
