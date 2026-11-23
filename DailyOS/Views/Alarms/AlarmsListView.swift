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

    @State private var showingCreateSheet = false
    @State private var editingAlarm: AlarmItem?

    private var formattedTodaySubtitle: String {
        let f = DateFormatter()
        f.calendar = ISOWeekCalendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "EEEE, d MMM"
        return f.string(from: Date())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DailyOSTheme.canvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 1. Top Header Bar
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Alarms")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white)
                                Text(formattedTodaySubtitle)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.eyebrow)
                            }

                            Spacer()

                            FrostedCircleButton(icon: "plus", size: 38) {
                                showingCreateSheet = true
                            }
                        }
                        .padding(.top, 6)

                        // 2. Guided Access Anti-Cheat Status Pill
                        GuidedAccessBannerView(isLocked: alarmEngine.isGuidedAccessEnabled)

                        // 3. Solar Wake Engine Overnight Status Card
                        solarEngineStatusCard

                        // 4. Wake Alarms Feed (100% Empty on First Launch)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("WAKE ALARMS")
                                .eyebrowStyle()
                                .padding(.horizontal, 4)

                            if alarms.isEmpty {
                                emptyAlarmsCard
                            } else {
                                ForEach(Array(alarms.enumerated()), id: \.element.id) { idx, alarm in
                                    AlarmCardRowView(
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
                                        },
                                        onDelete: {
                                            deleteAlarm(alarm)
                                        }
                                    )
                                    .staggeredEntrance(index: idx)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 120)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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

    // MARK: - Solar Wake Engine Status Card

    private var solarEngineStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: audioManager.isSilentKeepAliveRunning ? "sun.max.fill" : "moon.zzz.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(audioManager.isSilentKeepAliveRunning ? DailyOSTheme.solarAccent : DailyOSTheme.eyebrow)
                    .frame(width: 40, height: 40)
                    .background(
                        (audioManager.isSilentKeepAliveRunning ? DailyOSTheme.solarAccent : DailyOSTheme.eyebrow).opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(audioManager.isSilentKeepAliveRunning
                         ? "Solar Wake Engine Armed"
                         : "Solar Wake Engine Standby")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)

                    Text(audioManager.isSilentKeepAliveRunning
                         ? "Silent keep-alive active • Max brightness wake ready"
                         : "Enable an alarm to arm overnight audio & idle lock")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                curveBadge("0–30s", "Vib Only 0%", DailyOSTheme.skyGlow)
                curveBadge("30–60s", "HW 1→15%", DailyOSTheme.solarAccent)
                curveBadge("60–90s", "HW 15→50%", Color(hex: "#FF6B6B"))
            }

            if let nextDate = alarmEngine.nextScheduledAlarmDate {
                Divider().overlay(DailyOSTheme.hairline)
                HStack {
                    Label(
                        "Next Wake: \(nextDate.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "bell.and.waves.left.and.right"
                    )
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DailyOSTheme.solarAccent)

                    Spacer()

                    Text("\(notificationScheduler.pendingAlarmBurstCount) burst alerts")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DailyOSTheme.eyebrow)
                }
            }
        }
        .padding(16)
        .ambientCard(
            accent: audioManager.isSilentKeepAliveRunning ? DailyOSTheme.solarAccent : nil,
            cornerRadius: 22,
            washOpacity: 0.085
        )
    }

    private var emptyAlarmsCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "alarm.waves.left.and.right")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(DailyOSTheme.solarAccent)
                .frame(width: 56, height: 56)
                .background(DailyOSTheme.solarAccent.opacity(0.14), in: Circle())

            Text("No Wake Alarms")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)

            Text("Tap + to create a wake alarm with Daily Random physical missions and Stage-2 brain games.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DailyOSTheme.eyebrow)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 18)
        .ambientCard(cornerRadius: 22)
    }

    private func curveBadge(_ time: String, _ detail: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(time)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(detail)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        )
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

    private var accent: Color {
        isLocked ? DailyOSTheme.emerald : Color(hex: "#FF6B6B")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLocked ? "lock.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)

            Text(isLocked
                 ? "GUIDED ACCESS: LOCKED"
                 : "GUIDED ACCESS: OFF — TRIPLE-CLICK SIDE BUTTON BEFORE SLEEP")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .ambientCard(accent: accent, cornerRadius: 16, washOpacity: 0.12)
    }
}

// MARK: - Midnight Obsidian Alarm Card Row (Warm Ambient Wash When Enabled)

private struct AlarmCardRowView: View {
    let alarm: AlarmItem
    let onToggle: (Bool) -> Void
    let onTapEdit: () -> Void
    let onTestRing: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onTapEdit) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(alarm.formattedTime)
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(alarm.isEnabled ? Color.white : Color.white.opacity(0.36))

                            Text(alarm.displayLabel)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(alarm.isEnabled ? Color.white.opacity(0.84) : DailyOSTheme.eyebrow)
                                .lineLimit(1)
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
                .tint(DailyOSTheme.indigoGlow)
            }

            // ISO-8601 Mon–Sun Mini Weekday Indicator Pills
            HStack(spacing: 5) {
                ForEach(Weekday.allCases) { day in
                    let active = alarm.repeatDays.contains(day.rawValue)
                    Text(String(day.shortName.prefix(1)))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .frame(width: 24, height: 22)
                        .background(
                            active
                                ? (alarm.isEnabled ? DailyOSTheme.indigoGlow.opacity(0.22) : Color.white.opacity(0.08))
                                : DailyOSTheme.inputSurface,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .foregroundStyle(
                            active
                                ? (alarm.isEnabled ? DailyOSTheme.indigoGlow : Color.white.opacity(0.55))
                                : DailyOSTheme.eyebrow.opacity(0.6)
                        )
                }

                Spacer()

                Button(action: onTestRing) {
                    HStack(spacing: 4) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("Test")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color(hex: "#FFB020"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(hex: "#FFB020").opacity(0.14), in: Capsule())
                }
                .buttonStyle(MidnightPressStyle())
            }

            // Stage-1 Physical Mission + Stage-2 Brain Game + Stage-3 / Bedtime Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Label(alarm.missionSummary, systemImage: alarm.missionType.iconName)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            (alarm.isEnabled ? DailyOSTheme.indigoGlow : DailyOSTheme.eyebrow).opacity(0.15),
                            in: Capsule()
                        )
                        .foregroundStyle(alarm.isEnabled ? DailyOSTheme.periwinkle : Color.white.opacity(0.55))

                    if alarm.brainGameMode != .off {
                        Label(alarm.brainGameMode.shortBadge, systemImage: alarm.brainGameMode.iconName)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(DailyOSTheme.inputSurface, in: Capsule())
                            .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))
                            .foregroundStyle(alarm.isEnabled ? Color.white.opacity(0.85) : DailyOSTheme.eyebrow)
                    }

                    if alarm.stage3Enabled {
                        Label("Stage 3", systemImage: "checklist")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(DailyOSTheme.solarAccent.opacity(alarm.isEnabled ? 0.14 : 0.06), in: Capsule())
                            .foregroundStyle(alarm.isEnabled ? DailyOSTheme.solarAccent : DailyOSTheme.eyebrow)
                    }

                    if alarm.bedtimeReminderEnabled {
                        let bed = alarm.bedtimeSchedule()
                        Label("Bed \(bed.lightsOutText)", systemImage: "moon.zzz.fill")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(DailyOSTheme.indigoGlow.opacity(alarm.isEnabled ? 0.14 : 0.06), in: Capsule())
                            .foregroundStyle(alarm.isEnabled ? DailyOSTheme.periwinkle : DailyOSTheme.eyebrow)
                    }
                }
            }
        }
        .padding(16)
        .background {
            if alarm.isEnabled {
                OrganicBreathingAura(color: Color(hex: "#FFB020"), diameter: 180)
                    .offset(x: -90, y: -30)
                    .opacity(0.28)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .ambientCard(
            accent: alarm.isEnabled ? Color(hex: "#FFB020") : nil,
            cornerRadius: 22,
            washOpacity: 0.065
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTapEdit()
        }
        .contextMenu {
            Button(action: onTestRing) {
                Label("Test Solar Wake & Challenges", systemImage: "sun.max.fill")
            }
            Button(action: onTapEdit) {
                Label("Edit Alarm", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete Alarm", systemImage: "trash")
            }
        }
    }
}
