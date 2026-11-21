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
    @ObservedObject private var audioManager = AlarmAudioManager.shared
    @ObservedObject private var notificationScheduler = NotificationScheduler.shared

    let onOpenSettings: () -> Void

    @State private var showingCreateSheet = false
    @State private var editingAlarm: AlarmItem?

    var body: some View {
        NavigationStack {
            List {
                // 1. Guided Access Anti-Cheat Status Pill
                Section {
                    GuidedAccessBannerView(isLocked: alarmEngine.isGuidedAccessEnabled)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(Color.clear)
                }

                // 2. Overnight Hardware Volume Engine Status Card
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: audioManager.isSilentKeepAliveRunning
                                  ? "waveform.badge.checkmark"
                                  : "moon.zzz.fill")
                                .font(.title2)
                                .foregroundStyle(audioManager.isSilentKeepAliveRunning ? Color.green : Color.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(audioManager.isSilentKeepAliveRunning
                                     ? "Wake Engine Armed"
                                     : "Wake Engine Standby")
                                    .font(.subheadline.weight(.bold))

                                Text(audioManager.isSilentKeepAliveRunning
                                     ? "Silent .playback keep-alive active • Screen auto-lock disabled"
                                     : "Add and enable an alarm to arm overnight audio & idle lock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        // Exact Hardware Volume Curve Legend
                        HStack(spacing: 6) {
                            curveBadge("0–30s", "Vib Only 0%", .cyan)
                            curveBadge("30–60s", "HW 1→15%", .orange)
                            curveBadge("60–90s", "HW 15→50%", .red)
                        }

                        if let nextDate = alarmEngine.nextScheduledAlarmDate {
                            Divider()
                            HStack {
                                Label(
                                    "Next Wake: \(nextDate.formatted(date: .abbreviated, time: .shortened))",
                                    systemImage: "bell.and.waves.left.and.right"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)

                                Spacer()

                                Text("\(notificationScheduler.pendingAlarmBurstCount) burst alerts")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                // 3. Alarms List (100% Empty on First Launch)
                Section("Wake Alarms") {
                    if alarms.isEmpty {
                        ContentUnavailableView(
                            "No Wake Alarms",
                            systemImage: "alarm.waves.left.and.right",
                            description: Text("Tap + to create a wake alarm with Squats or Steps challenge dismissal.")
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
                                    Label("Test Wake", systemImage: "flame.fill")
                                }
                                .tint(.red)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Wake")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings and Backup")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("Add Wake Alarm")
                }
            }
            .onAppear {
                alarmEngine.refreshGuidedAccessStatus()
            }
            .sheet(isPresented: $showingCreateSheet) {
                AlarmEditorView(alarmToEdit: nil)
            }
            .sheet(item: $editingAlarm) { alarm in
                AlarmEditorView(alarmToEdit: alarm)
            }
        }
    }

    private func curveBadge(_ time: String, _ detail: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(time)
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func deleteAlarm(_ alarm: AlarmItem) {
        NotificationScheduler.shared.cancelAlarmBurstNotifications(for: alarm.id)
        modelContext.delete(alarm)
        SharedModelContainer.shared.save()
        alarmEngine.syncWithAlarms()
    }
}

// MARK: - Guided Access Status Pill Banner

private struct GuidedAccessBannerView: View {
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLocked ? "lock.shield.fill" : "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(isLocked ? Color.green : Color.red)

            Text(isLocked
                 ? "GUIDED ACCESS: LOCKED"
                 : "GUIDED ACCESS: OFF — TRIPLE-CLICK SIDE BUTTON BEFORE SLEEP")
                .font(.caption.weight(.heavy))
                .foregroundStyle(isLocked ? Color.green : Color.red)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            (isLocked ? Color.green : Color.red).opacity(0.16),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke((isLocked ? Color.green : Color.red).opacity(0.55), lineWidth: 1.5)
        )
    }
}

// MARK: - Alarm Row

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
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(alarm.isEnabled ? Color.white : Color.secondary)

                        Text(alarm.displayLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(alarm.isEnabled ? Color.white.opacity(0.9) : Color.secondary)
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
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
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
            .tint(.orange)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(action: onTestRing) {
                Label("Test Alarm & Challenge Now", systemImage: "flame.fill")
            }
            Button(action: onTapEdit) {
                Label("Edit Alarm", systemImage: "pencil")
            }
        }
    }
}
