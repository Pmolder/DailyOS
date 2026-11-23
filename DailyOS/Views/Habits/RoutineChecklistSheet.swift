import SwiftUI
import SwiftData
import UIKit

/// Lightweight local persistence for the Night Routine "Phone on charger away from bed" Dock Proof badge (zero API calls).
enum NightDockProofStore {
    private static let key = "com.patrik.dailyos.nightDockProofDayKeys"

    static func isDocked(dayKey: String) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        return map[dayKey] ?? false
    }

    static func markDocked(dayKey: String) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        map[dayKey] = true
        UserDefaults.standard.set(map, forKey: key)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Sleek Midnight Obsidian Morning (Sun) & Night (Moon) Routine Checklist Sheet.
struct RoutineChecklistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let routineType: RoutineType

    @Query(
        sort: [
            SortDescriptor(\RoutineChecklistItem.sortOrder, order: .forward),
            SortDescriptor(\RoutineChecklistItem.createdAt, order: .forward)
        ]
    ) private var allItems: [RoutineChecklistItem]

    @Query private var allLogs: [RoutineChecklistLog]
    @Query private var allAlarms: [AlarmItem]

    @State private var newItemText: String = ""
    @State private var showingQuickAddField: Bool = false
    @State private var editingItem: RoutineChecklistItem?
    @State private var editTitleDraft: String = ""
    @State private var editMode: EditMode = .inactive
    @State private var dockProofItem: RoutineChecklistItem? = nil
    @State private var dockProofRevision: Int = 0
    @State private var burstTriggerByItem: [UUID: Int] = [:]
    @State private var shimmerTrigger: Int = 0

    private var todayKey: String {
        HabitItem.dateKey(for: Date())
    }

    private var items: [RoutineChecklistItem] {
        allItems.filter { $0.routineType == routineType }
    }

    private var completedIDsToday: Set<UUID> {
        Set(allLogs.filter { $0.dayKey == todayKey }.map(\.itemID))
    }

    private var completedCount: Int {
        items.filter { completedIDsToday.contains($0.id) }.count
    }

    private var progressRatio: Double {
        guard !items.isEmpty else { return 0 }
        return Double(completedCount) / Double(items.count)
    }

    private var accent: Color {
        routineType.accentColor
    }

    /// Night Sheet Bonus: Next enabled alarm + estimated sleep window if locking in now.
    private var sleepWindowText: String? {
        guard routineType == .night else { return nil }
        let now = Date()
        let enabled = allAlarms.filter(\.isEnabled)
        guard let nextMatch = enabled
            .compactMap({ alarm -> (alarm: AlarmItem, date: Date)? in
                guard let d = alarm.nextTriggerDate(after: now) else { return nil }
                return (alarm, d)
            })
            .min(by: { $0.date < $1.date }) else {
            return nil
        }

        let totalMins = Int(nextMatch.date.timeIntervalSince(now) / 60.0)
        guard totalMins >= 30 && totalMins <= 18 * 60 else { return nil }
        let hours = totalMins / 60
        let mins = totalMins % 60
        let durationText = mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
        return "Next alarm \(nextMatch.alarm.formattedTime) • ~\(durationText) sleep if you lock in now"
    }

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            // Subtle top ambient wash in Solar Gold (Morning) or Indigo (Night)
            VStack {
                LinearGradient(
                    colors: [accent.opacity(0.18), accent.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
                .ignoresSafeArea()
                Spacer()
            }
            .allowsHitTesting(false)

            VStack(spacing: 14) {
                // Header Row
                HStack(spacing: 12) {
                    FrostedCircleButton(icon: "xmark", size: 36) {
                        dismiss()
                    }

                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(accent.opacity(0.18))
                                .frame(width: 40, height: 40)
                                .overlay(Circle().stroke(accent.opacity(0.45), lineWidth: 1.5))
                            Image(systemName: routineType.iconName)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(accent)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(routineType.title)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white)
                            Text("\(completedCount) / \(items.count) done")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(completedCount == items.count && !items.isEmpty ? accent : DailyOSTheme.eyebrow)
                        }
                    }

                    Spacer()

                    if items.count > 1 {
                        FrostedCircleButton(
                            icon: editMode == .active ? "checkmark" : "arrow.up.arrow.down",
                            size: 36,
                            tint: editMode == .active ? accent : Color.white
                        ) {
                            withAnimation(.spring(response: 0.25)) {
                                editMode = (editMode == .active) ? .inactive : .active
                            }
                        }
                    }

                    FrostedCircleButton(icon: "plus", size: 36, tint: accent) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            showingQuickAddField.toggle()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)

                // Slim Progress Bar (100% Milestone Shimmer Sweep)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 5)
                        Capsule()
                            .fill(accent)
                            .frame(width: max(0, geo.size.width * progressRatio), height: 5)
                            .shadow(color: accent.opacity(0.45), radius: 6)
                            .animation(ProMotionSpring.ringFill, value: progressRatio)
                    }
                }
                .frame(height: 5)
                .midnightShimmer(trigger: shimmerTrigger, color: accent)
                .padding(.horizontal, 18)

                // Inline Quick-Add Bar
                if showingQuickAddField {
                    HStack(spacing: 10) {
                        TextField(
                            "",
                            text: $newItemText,
                            prompt: Text("Add \(routineType.shortLabel.lowercased()) step...").foregroundStyle(Color.white.opacity(0.32))
                        )
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white)
                        .submitLabel(.done)
                        .onSubmit(addNewItem)

                        Button("Add") {
                            addNewItem()
                        }
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(newItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DailyOSTheme.emptyCell : accent, in: Capsule())
                        .buttonStyle(.plain)
                        .disabled(newItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(DailyOSTheme.inputSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
                    .padding(.horizontal, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Checklist Rows (Native Swipe-to-Delete + Drag-to-Reorder + Tap-to-Edit)
                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: routineType.iconName)
                            .font(.system(size: 28))
                            .foregroundStyle(accent.opacity(0.8))
                        Text("No \(routineType.title) Items")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                        Text("Tap + to build your daily \(routineType.shortLabel.lowercased()) checklist.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DailyOSTheme.eyebrow)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            let isDone = completedIDsToday.contains(item.id)
                            routineRow(item: item, isDone: isDone)
                                .staggeredEntrance(index: idx)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteItem(item)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .onMove(perform: moveItems)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, $editMode)
                }

                // Night Sheet Bonus: Sleep Window Chip
                if let sleepWindowText {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(sleepWindowText)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.88))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .ambientCard(accent: accent, cornerRadius: 16, washOpacity: 0.14)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onChange(of: completedCount) { oldVal, newVal in
            if !items.isEmpty && newVal == items.count && oldVal < newVal {
                shimmerTrigger += 1
            }
        }
        .fullScreenCover(item: $dockProofItem) { item in
            NightPhoneDockProofSheet(stepTitle: item.title) {
                NightDockProofStore.markDocked(dayKey: todayKey)
                dockProofRevision += 1
                if !completedIDsToday.contains(item.id) {
                    _ = SharedModelContainer.shared.toggleRoutineLog(itemID: item.id, dayKey: todayKey)
                    burstTriggerByItem[item.id] = (burstTriggerByItem[item.id] ?? 0) + 1
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        .alert("Edit Checklist Step", isPresented: Binding(
            get: { editingItem != nil },
            set: { if !$0 { editingItem = nil } }
        )) {
            TextField("Step title", text: $editTitleDraft)
            Button("Cancel", role: .cancel) { editingItem = nil }
            Button("Save") {
                if let item = editingItem {
                    let clean = editTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        item.title = clean
                        try? modelContext.save()
                        SharedModelContainer.shared.save()
                    }
                }
                editingItem = nil
            }
        }
    }

    // MARK: - Interactive Checklist Row (with Quick Local Dock Proof for Night Charger Step)

    private func isNightChargerStep(_ item: RoutineChecklistItem) -> Bool {
        guard routineType == .night else { return false }
        let low = item.title.lowercased()
        return low.contains("charger") || low.contains("phone")
    }

    private func routineRow(item: RoutineChecklistItem, isDone: Bool) -> some View {
        let _ = dockProofRevision
        let supportsDockProof = isNightChargerStep(item)
        let isDockedToday = supportsDockProof && NightDockProofStore.isDocked(dayKey: todayKey)
        let burstCount = burstTriggerByItem[item.id] ?? 0

        return HStack(spacing: 14) {
            Button {
                let completed = SharedModelContainer.shared.toggleRoutineLog(itemID: item.id, dayKey: todayKey)
                if completed {
                    burstTriggerByItem[item.id] = burstCount + 1
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } label: {
                ZStack {
                    CompletionBurstView(trigger: burstCount, color: accent, size: 46)
                    Circle()
                        .fill(isDone ? accent : Color.clear)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(isDone ? accent : Color.white.opacity(0.28), lineWidth: 2)
                        )
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(DailyOSTheme.canvas)
                    }
                }
            }
            .buttonStyle(MidnightPressButtonStyle())

            Button {
                editTitleDraft = item.title
                editingItem = item
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .strikethrough(isDone, color: DailyOSTheme.eyebrow)
                        .foregroundStyle(isDone ? DailyOSTheme.eyebrow : Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isDockedToday {
                        Text("Docked ✓")
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundStyle(DailyOSTheme.emerald)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DailyOSTheme.emerald.opacity(0.16), in: Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if supportsDockProof {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    dockProofItem = item
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isDockedToday ? "checkmark.seal.fill" : "camera.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(isDockedToday ? "Docked" : "Snap")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(isDockedToday ? DailyOSTheme.emerald : accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        (isDockedToday ? DailyOSTheme.emerald : accent).opacity(0.16),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(
                            (isDockedToday ? DailyOSTheme.emerald : accent).opacity(0.45),
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(MidnightPressButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .ambientCard(accent: isDone ? accent : nil, cornerRadius: 16, washOpacity: 0.06)
    }

    // MARK: - Actions

    private func addNewItem() {
        let clean = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let nextOrder = (items.map(\.sortOrder).max() ?? -1) + 1
        let newItem = RoutineChecklistItem(routineType: routineType, title: clean, sortOrder: nextOrder)
        modelContext.insert(newItem)
        try? modelContext.save()
        SharedModelContainer.shared.save()
        newItemText = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func deleteItem(_ item: RoutineChecklistItem) {
        let logs = allLogs.filter { $0.itemID == item.id }
        for log in logs { modelContext.delete(log) }
        modelContext.delete(item)
        try? modelContext.save()
        SharedModelContainer.shared.save()
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        for (idx, item) in reordered.enumerated() {
            item.sortOrder = idx
        }
        try? modelContext.save()
        SharedModelContainer.shared.save()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Lightweight Local 2-Second Phone Dock Proof Camera Sheet (Zero API Cost)

private struct NightPhoneDockProofSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cameraVM = LivePhotoCaptureViewModel()

    let stepTitle: String
    let onConfirmed: () -> Void

    var body: some View {
        ZStack {
            DailyOSTheme.canvas.ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    FrostedCircleButton(icon: "xmark", size: 38) {
                        cameraVM.stopSession()
                        dismiss()
                    }
                    Spacer()
                    Text("Night Dock Proof")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                VStack(spacing: 4) {
                    Text(stepTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                    Text("Snap your charger spot away from bed — instant local check-off (no AI wait).")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DailyOSTheme.eyebrow)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 22)

                ZStack {
                    if let captured = cameraVM.capturedImage {
                        Image(uiImage: captured)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 400)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(DailyOSTheme.emerald, lineWidth: 2)
                            )
                    } else {
                        CameraPreviewView(session: cameraVM.captureSession)
                            .frame(maxWidth: .infinity, maxHeight: 400)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(DailyOSTheme.indigoGlow.opacity(0.65), lineWidth: 2)
                            )
                    }
                }
                .padding(.horizontal, 18)

                Spacer(minLength: 0)

                if cameraVM.capturedImage != nil {
                    HStack(spacing: 12) {
                        Button {
                            cameraVM.retakePhoto()
                        } label: {
                            Label("Retake", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(DailyOSTheme.buttonSurface, in: Capsule())
                        }
                        .buttonStyle(MidnightPressButtonStyle())

                        Button {
                            cameraVM.stopSession()
                            onConfirmed()
                            dismiss()
                        } label: {
                            Label("Confirm Docked ✓", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 15, weight: .black, design: .rounded))
                                .foregroundStyle(Color.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(DailyOSTheme.emerald, in: Capsule())
                        }
                        .buttonStyle(MidnightPressButtonStyle())
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                } else {
                    HStack(spacing: 36) {
                        Color.clear.frame(width: 48, height: 48)

                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            cameraVM.takeLivePhoto()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(Color.white, lineWidth: 4)
                                    .frame(width: 74, height: 74)
                                Circle()
                                    .fill(DailyOSTheme.indigoGlow)
                                    .frame(width: 60, height: 60)
                                Image(systemName: "camera.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.white)
                            }
                        }
                        .buttonStyle(MidnightPressButtonStyle())
                        .disabled(cameraVM.isCapturing)

                        Button {
                            cameraVM.switchCamera()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.title3)
                                .foregroundStyle(Color.white)
                                .frame(width: 48, height: 48)
                                .background(DailyOSTheme.buttonSurface, in: Circle())
                        }
                        .buttonStyle(MidnightPressButtonStyle())
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            cameraVM.checkPermissionAndStart()
        }
        .onDisappear {
            cameraVM.stopSession()
        }
    }
}
