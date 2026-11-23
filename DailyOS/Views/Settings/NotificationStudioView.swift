import SwiftUI

/// Daily Notification Studio: Adaptive Evening Momentum Check-In, 1-Tap Templates & Custom Notification Builder.
struct NotificationStudioView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = DailyNotificationManager.shared

    @State private var showingNewCustomSheet = false
    @State private var editingCustom: CustomDailyNotification?
    @State private var editingSample: SampleNotificationConfig?
    @State private var testBannerText: String?

    private var metrics: DailyProgressMetrics {
        manager.currentMetrics()
    }

    private var eveningSample: SampleNotificationConfig? {
        manager.sampleTemplates.first(where: { $0.isAdaptiveEvening })
    }

    private var otherSamples: [SampleNotificationConfig] {
        manager.sampleTemplates.filter { !$0.isAdaptiveEvening }
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header Bar
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 36) { dismiss() }
                    Spacer()
                    Text("Daily Notifications")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Spacer()
                    FrostedCircleButton(icon: "plus", size: 36, tint: DailyOSTheme.skyGlow) {
                        showingNewCustomSheet = true
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // Live Metrics Context Pill
                        HStack(spacing: 12) {
                            metricChip(label: "DONE", value: "\(metrics.done)/\(metrics.total)", color: DailyOSTheme.emerald)
                            metricChip(label: "SCORE", value: "\(metrics.percent)%", color: DailyOSTheme.skyGlow)
                            metricChip(label: "STREAK", value: "\(metrics.streak)d", color: Color(hex: "#FF8C42"))
                        }

                        if let testBannerText {
                            HStack(spacing: 8) {
                                Image(systemName: "bell.badge.fill")
                                    .foregroundStyle(DailyOSTheme.skyGlow)
                                Text(testBannerText)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.skyGlow)
                                Spacer()
                            }
                            .padding(12)
                            .background(DailyOSTheme.skyGlow.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        // 1. Adaptive Evening Momentum Check-In Hero Card
                        if let evening = eveningSample {
                            adaptiveEveningCard(evening)
                        }

                        // 2. Curated 1-Tap Sample Templates
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SAMPLE TEMPLATES")
                                .eyebrowStyle()
                                .padding(.horizontal, 2)

                            ForEach(otherSamples) { sample in
                                sampleTemplateCard(sample)
                            }
                        }

                        // 3. Custom User Notifications
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("CUSTOM NOTIFICATIONS")
                                    .eyebrowStyle()
                                Spacer()
                                Button {
                                    showingNewCustomSheet = true
                                } label: {
                                    Label("New Custom Notification", systemImage: "plus")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(DailyOSTheme.skyGlow)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 2)

                            if manager.customNotifications.isEmpty {
                                VStack(spacing: 8) {
                                    Text("No Custom Notifications Yet")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.white)
                                    Text("Tap + to build your own Lock Screen reminder with live {done}, {total}, {left}, {percent}, and {streak} variables.")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(DailyOSTheme.eyebrow)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(20)
                                .ambientCard(cornerRadius: 20)
                            } else {
                                ForEach(manager.customNotifications) { item in
                                    customNotificationCard(item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.calendar, ISOWeekCalendar.current)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .sheet(isPresented: $showingNewCustomSheet) {
            CustomNotificationEditorSheet(existing: nil)
        }
        .sheet(item: $editingCustom) { item in
            CustomNotificationEditorSheet(existing: item)
        }
        .sheet(item: $editingSample) { sample in
            SampleTemplateEditorSheet(sample: sample)
        }
    }

    // MARK: - Metrics Chip

    private func metricChip(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(DailyOSTheme.eyebrow)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .ambientCard(cornerRadius: 14)
    }

    // MARK: - Adaptive Evening Momentum Card

    private func adaptiveEveningCard(_ config: SampleNotificationConfig) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DailyOSTheme.skyGlow)
                    .frame(width: 36, height: 36)
                    .background(DailyOSTheme.skyGlow.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(config.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text("Adaptive 4-tier summary • Auto-updates live")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { config.isEnabled },
                        set: { newVal in
                            var copy = config
                            copy.isEnabled = newVal
                            manager.updateSample(copy)
                        }
                    )
                )
                .labelsHidden()
                .tint(DailyOSTheme.skyGlow)
            }

            // Live Rendered Lock Screen Preview
            VStack(alignment: .leading, spacing: 4) {
                Text("LIVE PREVIEW RIGHT NOW")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(DailyOSTheme.eyebrow)
                Text(manager.renderedPreview(for: config))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            // Time Picker (24-Hour)
            HStack {
                Text("Delivery Time (24h)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                Spacer()
                DatePicker(
                    "",
                    selection: Binding(
                        get: { dateFrom(hour: config.hour, minute: config.minute) },
                        set: { newDate in
                            let comps = ISOWeekCalendar.current.dateComponents([.hour, .minute], from: newDate)
                            var copy = config
                            copy.hour = comps.hour ?? 20
                            copy.minute = comps.minute ?? 30
                            manager.updateSample(copy)
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .tint(DailyOSTheme.skyGlow)
            }

            Divider().overlay(DailyOSTheme.hairline)

            Toggle("Stay silent when 100% done", isOn: Binding(
                get: { config.staySilentWhenComplete },
                set: { newVal in
                    var copy = config
                    copy.staySilentWhenComplete = newVal
                    manager.updateSample(copy)
                }
            ))
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white)
            .tint(DailyOSTheme.emerald)

            Button {
                triggerTest(title: config.title, body: config.bodyTemplate, isAdaptiveEvening: true)
            } label: {
                Label("Test (3s)", systemImage: "bell.and.waves.left.and.right")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DailyOSTheme.skyGlow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .ambientCard(accent: DailyOSTheme.skyGlow, cornerRadius: 22, washOpacity: 0.09)
    }

    // MARK: - Curated Sample Template Card

    private func sampleTemplateCard(_ sample: SampleNotificationConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(sample.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                        Text(sample.formattedTime)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DailyOSTheme.skyGlow)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
                    }
                    if sample.requiresStreakGuard {
                        Text("Fires only when streak ≥ 2 days & tasks remain")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(hex: "#FF8C42"))
                    }
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { sample.isEnabled },
                        set: { newVal in
                            var copy = sample
                            copy.isEnabled = newVal
                            manager.updateSample(copy)
                        }
                    )
                )
                .labelsHidden()
                .tint(DailyOSTheme.skyGlow)
            }

            Text(manager.renderedPreview(for: sample))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.75))

            HStack(spacing: 8) {
                Button {
                    editingSample = sample
                } label: {
                    Label("Customize", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(DailyOSTheme.inputSurface, in: Capsule())
                        .overlay(Capsule().stroke(DailyOSTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    triggerTest(title: sample.title, body: sample.bodyTemplate, isAdaptiveEvening: false)
                } label: {
                    Label("Test (3s)", systemImage: "bell.badge")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.skyGlow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(16)
        .ambientCard(accent: sample.isEnabled ? DailyOSTheme.skyGlow : nil, cornerRadius: 20, washOpacity: 0.06)
    }

    // MARK: - Custom Notification Card

    private func customNotificationCard(_ item: CustomDailyNotification) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                        Text(item.formattedTime)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DailyOSTheme.emerald)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DailyOSTheme.emerald.opacity(0.14), in: Capsule())
                    }
                    Text(Weekday.formatSummary(for: item.weekdays))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { item.isEnabled },
                        set: { newVal in
                            var copy = item
                            copy.isEnabled = newVal
                            manager.upsertCustom(copy)
                        }
                    )
                )
                .labelsHidden()
                .tint(DailyOSTheme.emerald)
            }

            Text(manager.resolvePlaceholders(item.bodyTemplate))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.78))

            HStack(spacing: 8) {
                Button {
                    editingCustom = item
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(DailyOSTheme.inputSurface, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    triggerTest(title: item.title, body: item.bodyTemplate, isAdaptiveEvening: false)
                } label: {
                    Label("Test (3s)", systemImage: "bell.badge")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DailyOSTheme.skyGlow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                FrostedCircleButton(icon: "trash", size: 32, tint: Color(hex: "#FF6B6B")) {
                    manager.deleteCustom(id: item.id)
                }
            }
        }
        .padding(16)
        .ambientCard(accent: item.isEnabled ? DailyOSTheme.emerald : nil, cornerRadius: 20, washOpacity: 0.06)
    }

    // MARK: - Helpers

    private func triggerTest(title: String, body: String, isAdaptiveEvening: Bool) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        testBannerText = "Preview notification scheduled — fires in 3 seconds!"
        Task {
            await manager.sendTestPreview(title: title, bodyTemplate: body, isAdaptiveEvening: isAdaptiveEvening)
        }
    }

    private func dateFrom(hour: Int, minute: Int) -> Date {
        let cal = ISOWeekCalendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return cal.date(from: comps) ?? Date()
    }
}

// MARK: - Customize Sample Template Sheet

private struct SampleTemplateEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sample: SampleNotificationConfig

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var time: Date = Date()

    private let chips = ["{done}", "{total}", "{left}", "{percent}", "{streak}"]

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 36) { dismiss() }
                    Spacer()
                    Text("Customize Template")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TITLE").eyebrowStyle()
                            TextField("Notification Title", text: $title)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white)
                                .padding(13)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("MESSAGE BODY").eyebrowStyle()
                            TextEditor(text: $bodyText)
                                .scrollContentBackground(.hidden)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white)
                                .frame(minHeight: 88)
                                .padding(10)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(chips, id: \.self) { chip in
                                        Button {
                                            bodyText += (bodyText.isEmpty || bodyText.hasSuffix(" ") ? "" : " ") + chip
                                        } label: {
                                            Text(chip)
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .foregroundStyle(DailyOSTheme.skyGlow)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        HStack {
                            Text("Delivery Time (24h)")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white)
                            Spacer()
                            DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .tint(DailyOSTheme.skyGlow)
                        }
                        .padding(16)
                        .ambientCard(cornerRadius: 16)
                    }
                    .padding(.horizontal, 18)
                }

                Button {
                    let comps = ISOWeekCalendar.current.dateComponents([.hour, .minute], from: time)
                    var updated = sample
                    updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sample.title : title
                    updated.bodyTemplate = bodyText
                    updated.hour = comps.hour ?? sample.hour
                    updated.minute = comps.minute ?? sample.minute
                    DailyNotificationManager.shared.updateSample(updated)
                    dismiss()
                } label: {
                    Text("Save Template")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(DailyOSTheme.skyGlow, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(18)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .onAppear {
            title = sample.title
            bodyText = sample.bodyTemplate
            let cal = ISOWeekCalendar.current
            var comps = cal.dateComponents([.year, .month, .day], from: Date())
            comps.hour = sample.hour
            comps.minute = sample.minute
            time = cal.date(from: comps) ?? Date()
        }
    }
}

// MARK: - Create / Edit Custom Notification Sheet

private struct CustomNotificationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: CustomDailyNotification?

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var time: Date = Date()
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6, 7, 1]

    private let variableChips = ["{done}", "{total}", "{left}", "{percent}", "{streak}"]

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 36) { dismiss() }
                    Spacer()
                    Text(existing == nil ? "New Custom Notification" : "Edit Notification")
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
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TITLE").eyebrowStyle()
                            TextField("e.g., Nightly Check-In", text: $title)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white)
                                .padding(14)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("MESSAGE BODY").eyebrowStyle()
                            TextEditor(text: $bodyText)
                                .scrollContentBackground(.hidden)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white)
                                .frame(minHeight: 96)
                                .padding(10)
                                .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DailyOSTheme.hairline, lineWidth: 1))

                            Text("INSERT LIVE VARIABLES").eyebrowStyle()
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(variableChips, id: \.self) { chip in
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            bodyText += (bodyText.isEmpty || bodyText.hasSuffix(" ") ? "" : " ") + chip
                                        } label: {
                                            Text(chip)
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .foregroundStyle(DailyOSTheme.skyGlow)
                                                .padding(.horizontal, 11)
                                                .padding(.vertical, 7)
                                                .background(DailyOSTheme.skyGlow.opacity(0.14), in: Capsule())
                                                .overlay(Capsule().stroke(DailyOSTheme.skyGlow.opacity(0.35), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            if !bodyText.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("LIVE PREVIEW").eyebrowStyle()
                                    Text(DailyNotificationManager.shared.resolvePlaceholders(bodyText))
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(DailyOSTheme.emerald)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DailyOSTheme.emerald.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("SCHEDULE (24H • MON–SUN)").eyebrowStyle()

                            HStack {
                                Text("Time")
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.white)
                                Spacer()
                                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                    .tint(DailyOSTheme.skyGlow)
                            }

                            HStack(spacing: 6) {
                                ForEach(Weekday.allCases) { day in
                                    let active = weekdays.contains(day.rawValue)
                                    Button {
                                        if active {
                                            weekdays.remove(day.rawValue)
                                        } else {
                                            weekdays.insert(day.rawValue)
                                        }
                                    } label: {
                                        Text(String(day.shortName.prefix(1)))
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(
                                                active ? DailyOSTheme.skyGlow : DailyOSTheme.inputSurface,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            )
                                            .foregroundStyle(active ? Color.black : Color.white.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(16)
                        .ambientCard(cornerRadius: 18)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                }

                Button {
                    let comps = ISOWeekCalendar.current.dateComponents([.hour, .minute], from: time)
                    let finalDays = weekdays.isEmpty ? Set(Weekday.allCases.map(\.rawValue)) : weekdays
                    let item = CustomDailyNotification(
                        id: existing?.id ?? UUID(),
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        bodyTemplate: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                        hour: comps.hour ?? 20,
                        minute: comps.minute ?? 0,
                        weekdays: finalDays,
                        isEnabled: existing?.isEnabled ?? true
                    )
                    DailyNotificationManager.shared.upsertCustom(item)
                    dismiss()
                } label: {
                    Text("Save Notification")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(canSave ? DailyOSTheme.skyGlow : DailyOSTheme.emptyCell, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.calendar, ISOWeekCalendar.current)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .onAppear {
            let cal = ISOWeekCalendar.current
            if let existing {
                title = existing.title
                bodyText = existing.bodyTemplate
                weekdays = existing.weekdays
                var comps = cal.dateComponents([.year, .month, .day], from: Date())
                comps.hour = existing.hour
                comps.minute = existing.minute
                time = cal.date(from: comps) ?? Date()
            } else {
                var comps = cal.dateComponents([.year, .month, .day], from: Date())
                comps.hour = 20
                comps.minute = 0
                time = cal.date(from: comps) ?? Date()
            }
        }
    }
}
