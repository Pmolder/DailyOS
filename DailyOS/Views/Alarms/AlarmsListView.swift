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

                // 2. Solar-Orange Overnight Engine Status Card
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: audioManager.isSilentKeepAliveRunning
                                  ? "sun.max.fill"
                                  : "moon.zzz.fill")
                                .font(.title2)
                                .foregroundStyle(audioManager.isSilentKeepAliveRunning ? SolarTheme.solarBright : Color.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(audioManager.isSilentKeepAliveRunning
                                     ? "Solar Wake Engine Armed"
                                     : "Solar Wake Engine Standby")
                                    .font(.subheadline.weight(.bold))

                                Text(audioManager.isSilentKeepAliveRunning
                                     ? "Silent keep-alive active • Max brightness wake ready"
                                     : "Enable an alarm to arm overnight audio & idle lock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        HStack(spacing: 6) {
                            curveBadge("0–30s", "Vib Only 0%", .cyan)
                            curveBadge("30–60s", "HW 1→15%", SolarTheme.solarBright)
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
                                .foregroundStyle(SolarTheme.solarBright)

                                Spacer()

                                Text("\(notificationScheduler.pendingAlarmBurstCount) burst alerts")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(SolarTheme.charcoal)
                }

                // 3. Wake Alarms List (100% Empty on First Launch)
                Section("Wake Alarms") {
                    if alarms.isEmpty {
                        ContentUnavailableView(
                            "No Wake Alarms",
                            systemImage: "alarm.waves.left.and.right",
                            description: Text("Tap + to create a Solar-Orange alarm with Daily Random physical & brain challenges.")
                        )
                        .listRowBackground(SolarTheme.charcoal)
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
                            .listRowBackground(SolarTheme.charcoal)
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
                                    Label("Test Wake", systemImage: "sun.max.fill")
                                }
                                .tint(SolarTheme.solarCore)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SolarTheme.obsidian)
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
        .padding(.vertical, 6)
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
            (isLocked ? Color.green : Color.red).opacity(0.15),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke((isLocked ? Color.green : Color.red).opacity(0.55), lineWidth: 1.5)
        )
    }
}

// MARK: - Obsidian & Solar-Orange Alarm Card Row

private struct AlarmRowView: View {
    let alarm: AlarmItem
    let onToggle: (Bool) -> Void
    let onTapEdit: () -> Void
    let onTestRing: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onTapEdit) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(alarm.formattedTime)
                            .font(.system(size: 38, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(alarm.isEnabled ? Color.white : Color.secondary)

                        Text(alarm.displayLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(alarm.isEnabled ? Color.white.opacity(0.88) : Color.secondary)
                            .lineLimit(1)
                    }

                    Text(alarm.repeatSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Stage-1 Physical + Stage-2 Brain Pill Badges
                    HStack(spacing: 6) {
                        Label(alarm.missionSummary, systemImage: alarm.missionType.iconName)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(SolarTheme.solarCore.opacity(0.18), in: Capsule())
                            .foregroundStyle(SolarTheme.solarBright)

                        if alarm.brainGameMode != .off {
                            Label(alarm.brainGameMode.shortBadge, systemImage: alarm.brainGameMode.iconName)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08), in: Capsule())
                                .foregroundStyle(.white.opacity(0.85))
                        }
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
            .tint(SolarTheme.solarCore)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(action: onTestRing) {
                Label("Test Solar Wake & Challenges", systemImage: "sun.max.fill")
            }
            Button(action: onTapEdit) {
                Label("Edit Alarm", systemImage: "pencil")
            }
        }
    }
}
