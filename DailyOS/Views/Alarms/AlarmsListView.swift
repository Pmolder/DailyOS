import SwiftUI
import SwiftData

struct AlarmsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\AlarmItem.hour, order: .forward),
            SortDescriptor(\AlarmItem.minute, order: .forward)
        ]
    ) private var alarms: [AlarmItem]

    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var notificationScheduler = NotificationScheduler.shared

    @State private var showingCreateSheet = false
    @State private var editingAlarm: AlarmItem?

    var body: some View {
        NavigationStack {
            List {
                // Overnight Engine Telemetry Section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: alarmEngine.isSilentKeepAliveRunning
                                  ? "waveform.badge.checkmark"
                                  : "moon.zzz.fill")
                                .font(.title3)
                                .foregroundStyle(alarmEngine.isSilentKeepAliveRunning ? .green : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(alarmEngine.isSilentKeepAliveRunning
                                     ? "Overnight Keep-Alive Armed"
                                     : "No Active Alarms Armed")
                                    .font(.subheadline.weight(.semibold))

                                Text(alarmEngine.isSilentKeepAliveRunning
                                     ? "Silent AVAudioSession (.playback + .mixWithOthers) active"
                                     : "Enable an alarm to arm background silent loop")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        if let nextDate = alarmEngine.nextScheduledAlarmDate {
                            Divider()
                            HStack {
                                Label(
                                    "Next ring: \(nextDate.formatted(date: .abbreviated, time: .shortened))",
                                    systemImage: "bell.and.waves.left.and.right"
                                )
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.indigo)

                                Spacer()

                                Text("\(notificationScheduler.pendingAlarmBurstCount) burst alerts queued")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Alarms List Section
                Section("Alarms") {
                    if alarms.isEmpty {
                        ContentUnavailableView(
                            "No Alarms Configured",
                            systemImage: "alarm",
                            description: Text("Tap + to create an alarm with Step, QR/Barcode, or Math dismissal missions.")
                        )
                    } else {
                        ForEach(alarms) { alarm in
                            AlarmRowView(
                                alarm: alarm,
                                onToggle: { isOn in
                                    alarm.isEnabled = isOn
                                    if isOn {
                                        alarm.lastTriggeredMinuteKey = ""
                                    }
                                    SharedModelContainer.shared.save()
                                    alarmEngine.syncWithAlarms()
                                },
                                onTapEdit: {
                                    editingAlarm = alarm
                                },
                                onTestRing: {
                                    alarmEngine.triggerAlarm(alarm)
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteAlarm(alarm)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    alarmEngine.triggerAlarm(alarm)
                                } label: {
                                    Label("Test Ring", systemImage: "play.fill")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Alarms")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Label("Add Alarm", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingCreateSheet) {
                AlarmEditorView(alarmToEdit: nil)
            }
            .sheet(item: $editingAlarm) { alarm in
                AlarmEditorView(alarmToEdit: alarm)
            }
        }
    }

    private func deleteAlarm(_ alarm: AlarmItem) {
        NotificationScheduler.shared.cancelAlarmBurstNotifications(for: alarm.id)
        modelContext.delete(alarm)
        SharedModelContainer.shared.save()
        alarmEngine.syncWithAlarms()
    }
}

private struct AlarmRowView: View {
    let alarm: AlarmItem
    let onToggle: (Bool) -> Void
    let onTapEdit: () -> Void
    let onTestRing: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onTapEdit) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(alarm.formattedTime)
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(alarm.isEnabled ? .primary : .secondary)

                        Text(alarm.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(alarm.isEnabled ? .primary : .secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        Text(alarm.repeatSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Label(alarm.missionSummary, systemImage: alarm.missionType.iconName)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.14), in: Capsule())
                            .foregroundStyle(.indigo)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { alarm.isEnabled },
                    set: { onToggle($0) }
                )
            )
            .labelsHidden()
        }
        .contextMenu {
            Button {
                onTapEdit()
            } label: {
                Label("Edit Alarm", systemImage: "pencil")
            }

            Button {
                onTestRing()
            } label: {
                Label("Test Ring & Mission Now", systemImage: "bell.and.waves.left.and.right.fill")
            }
        }
    }
}
