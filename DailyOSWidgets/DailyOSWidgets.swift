import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Shared Midnight Obsidian Palette for Widgets

private enum WidgetPalette {
    static let canvas = Color.dailyHex("#09090D")
    static let card = Color.dailyHex("#141419")
    static let emptyCell = Color.dailyHex("#22222A")
    static let eyebrow = Color.dailyHex("#7D7E8A")
    static let hairline = Color.white.opacity(0.08)
    static let skyGlow = Color.dailyHex("#60A5FA")
    static let flameOrange = Color.dailyHex("#FF8C42")
}

// MARK: - 1. Daily Check-In Widget (.systemMedium)

struct DailyCheckInEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct DailyCheckInProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailyCheckInEntry {
        DailyCheckInEntry(date: Date(), snapshot: Self.sampleSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyCheckInEntry) -> Void) {
        let snap = context.isPreview ? Self.sampleSnapshot : WidgetBridge.loadSnapshot()
        completion(DailyCheckInEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyCheckInEntry>) -> Void) {
        let entry = DailyCheckInEntry(date: Date(), snapshot: WidgetBridge.loadSnapshot())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    static var sampleSnapshot: WidgetSnapshot {
        WidgetSnapshot(
            updatedAt: Date(),
            todayKey: WidgetBridge.todayDateKey(),
            todayScore: 78,
            scoreHeadline: "Dialed in.",
            globalStreak: 17,
            streakFreezes: 1,
            habits: [
                WidgetHabitItem(id: "sample-1", name: "Meditate", iconName: "figure.mind.and.body", colorHex: "#34D399", kind: "build", trackingMode: "binary", dailyTarget: 1, todayValue: 1, streak: 12, last7Days: [1, 1, 1, 0, 1, 1, 1], currentMonthDays: [:]),
                WidgetHabitItem(id: "sample-2", name: "Read", iconName: "book.fill", colorHex: "#A78BFA", kind: "build", trackingMode: "quantity", dailyTarget: 20, todayValue: 12, streak: 9, last7Days: [1, 1, 0, 1, 0, 1, 0.6], currentMonthDays: [:]),
                WidgetHabitItem(id: "sample-3", name: "Drink Water", iconName: "drop.fill", colorHex: "#38BDF8", kind: "build", trackingMode: "binary", dailyTarget: 1, todayValue: 0, streak: 5, last7Days: [1, 1, 1, 1, 1, 0, 0], currentMonthDays: [:])
            ]
        )
    }
}

struct DailyCheckInWidgetView: View {
    let entry: DailyCheckInEntry

    private var displayedHabits: [WidgetHabitItem] {
        Array(entry.snapshot.habits.prefix(3))
    }

    var body: some View {
        if displayedHabits.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(WidgetPalette.skyGlow)
                Text("No Habits Yet")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                Text("Add habits in DailyOS to check in from your Home Screen.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(WidgetPalette.eyebrow)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(WidgetPalette.canvas, for: .widget)
        } else {
            VStack(spacing: 11) {
                ForEach(displayedHabits) { habit in
                    WidgetHabitCheckRow(habit: habit)
                }
                if displayedHabits.count < 3 {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .containerBackground(WidgetPalette.canvas, for: .widget)
        }
    }
}

private struct WidgetHabitCheckRow: View {
    let habit: WidgetHabitItem

    private var accent: Color { Color.dailyHex(habit.colorHex) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: habit.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(habit.name)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { idx in
                        let ratio = idx < habit.last7Days.count ? habit.last7Days[idx] : 0.0
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(cellColor(ratio: ratio))
                            .frame(width: 8.5, height: 8.5)
                    }
                }
            }

            Spacer(minLength: 4)

            Button(intent: ToggleHabitWidgetIntent(habitID: habit.id)) {
                WidgetInteractiveCheckBadge(habit: habit, size: 32)
            }
            .buttonStyle(.plain)
        }
    }

    private func cellColor(ratio: Double) -> Color {
        if ratio >= 1.0 { return accent }
        if ratio > 0.0 { return accent.opacity(0.45) }
        return WidgetPalette.emptyCell
    }
}

private struct WidgetInteractiveCheckBadge: View {
    let habit: WidgetHabitItem
    var size: CGFloat = 32

    private var accent: Color { Color.dailyHex(habit.colorHex) }
    private var ratio: Double { habit.todayProgressRatio }

    var body: some View {
        ZStack {
            if habit.isCompletedToday {
                Circle()
                    .fill(accent)
                    .frame(width: size, height: size)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.44, weight: .black))
                    .foregroundStyle(WidgetPalette.canvas)
            } else if habit.trackingMode == "quantity" && ratio > 0 {
                Circle()
                    .fill(accent.opacity(0.20))
                    .frame(width: size, height: size)
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 2.5)
                    .frame(width: size, height: size)
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size, height: size)
                Text("\(Int(habit.todayValue))")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 2.2)
                    .frame(width: size, height: size)
            }
        }
    }
}

struct DailyCheckInWidget: Widget {
    let kind: String = "DailyCheckInWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailyCheckInProvider()) { entry in
            DailyCheckInWidgetView(entry: entry)
        }
        .configurationDisplayName("Daily Check-In")
        .description("Check off your top 3 habits directly from the Home Screen.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - 2. Configurable Habit Matrix Widget (.systemSmall)

struct HabitMatrixEntry: TimelineEntry {
    let date: Date
    let habit: WidgetHabitItem?
    let cellShape: WidgetCellShape
}

struct HabitMatrixProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HabitMatrixEntry {
        HabitMatrixEntry(date: Date(), habit: Self.sampleHabit, cellShape: .dots)
    }

    func snapshot(for configuration: SelectHabitWidgetIntent, in context: Context) async -> HabitMatrixEntry {
        if context.isPreview {
            return HabitMatrixEntry(date: Date(), habit: Self.sampleHabit, cellShape: configuration.cellShape)
        }
        return makeEntry(for: configuration)
    }

    func timeline(for configuration: SelectHabitWidgetIntent, in context: Context) async -> Timeline<HabitMatrixEntry> {
        let entry = makeEntry(for: configuration)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func makeEntry(for configuration: SelectHabitWidgetIntent) -> HabitMatrixEntry {
        let snapshot = WidgetBridge.loadSnapshot()
        let selected: WidgetHabitItem?
        if let wantedID = configuration.habit?.id {
            selected = snapshot.habits.first(where: { $0.id == wantedID }) ?? snapshot.habits.first
        } else {
            selected = snapshot.habits.first
        }
        return HabitMatrixEntry(date: Date(), habit: selected, cellShape: configuration.cellShape)
    }

    static var sampleHabit: WidgetHabitItem {
        var monthMap: [Int: Double] = [:]
        for d in 1...23 {
            monthMap[d] = (d % 4 == 0) ? 0.0 : 1.0
        }
        return WidgetHabitItem(
            id: "sample-matrix",
            name: "Stretch",
            iconName: "figure.cooldown",
            colorHex: "#A3E635",
            kind: "build",
            trackingMode: "binary",
            dailyTarget: 1,
            todayValue: 1,
            streak: 14,
            last7Days: [1, 1, 1, 1, 1, 1, 1],
            currentMonthDays: monthMap
        )
    }
}

struct HabitMatrixWidgetView: View {
    let entry: HabitMatrixEntry

    private var monthSubtitle: String {
        let f = DateFormatter()
        f.calendar = WidgetBridge.isoCalendar
        f.dateFormat = "MMM yyyy"
        return f.string(from: entry.date)
    }

    private var monthGridDays: [Int?] {
        let cal = WidgetBridge.isoCalendar
        let comps = cal.dateComponents([.year, .month], from: entry.date)
        guard let monthStart = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: monthStart) else {
            return []
        }
        let leadingOffset = WidgetBridge.mondayBasedDayIndex(for: monthStart)
        var cells: [Int?] = Array(repeating: nil, count: leadingOffset)
        for day in range {
            cells.append(day)
        }
        return cells
    }

    var body: some View {
        if let habit = entry.habit {
            let accent = Color.dailyHex(habit.colorHex)
            VStack(alignment: .leading, spacing: 6) {
                // Header Row
                HStack(spacing: 6) {
                    Image(systemName: habit.iconName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 22, height: 22)
                        .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Text(habit.name)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    Button(intent: ToggleHabitWidgetIntent(habitID: habit.id)) {
                        WidgetInteractiveCheckBadge(habit: habit, size: 22)
                    }
                    .buttonStyle(.plain)
                }

                Text(monthSubtitle)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.eyebrow)

                // Monthly 7-column Mon-Sun Matrix (Dots or Hearts)
                let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
                LazyVGrid(columns: columns, spacing: 3.5) {
                    ForEach(Array(monthGridDays.enumerated()), id: \.offset) { _, maybeDay in
                        if let day = maybeDay {
                            let ratio = habit.currentMonthDays[day] ?? 0.0
                            matrixCell(ratio: ratio, accent: accent)
                        } else {
                            Color.clear.frame(height: 12)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(WidgetPalette.canvas, for: .widget)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(WidgetPalette.skyGlow)
                Text("Select Habit")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                Text("Long-press → Edit Widget")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(WidgetPalette.eyebrow)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(WidgetPalette.canvas, for: .widget)
        }
    }

    @ViewBuilder
    private func matrixCell(ratio: Double, accent: Color) -> some View {
        let color: Color = {
            if ratio >= 1.0 { return accent }
            if ratio >= 0.5 { return accent.opacity(0.62) }
            if ratio > 0.0 { return accent.opacity(0.32) }
            return WidgetPalette.emptyCell
        }()

        if entry.cellShape == .hearts {
            Image(systemName: "heart.fill")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(color)
                .frame(height: 12)
        } else {
            Circle()
                .fill(color)
                .frame(width: 11, height: 11)
                .frame(height: 12)
        }
    }
}

struct HabitMatrixWidget: Widget {
    let kind: String = "HabitMatrixWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectHabitWidgetIntent.self, provider: HabitMatrixProvider()) { entry in
            HabitMatrixWidgetView(entry: entry)
        }
        .configurationDisplayName("Habit Matrix")
        .description("Monthly dot or heart consistency grid with 1-tap check-in.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - 3. Today's Score & Streak Widget (.systemSmall)

struct TodayScoreEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct TodayScoreProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayScoreEntry {
        TodayScoreEntry(date: Date(), snapshot: DailyCheckInProvider.sampleSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayScoreEntry) -> Void) {
        let snap = context.isPreview ? DailyCheckInProvider.sampleSnapshot : WidgetBridge.loadSnapshot()
        completion(TodayScoreEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayScoreEntry>) -> Void) {
        let entry = TodayScoreEntry(date: Date(), snapshot: WidgetBridge.loadSnapshot())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct TodayScoreWidgetView: View {
    let entry: TodayScoreEntry

    private var progress: Double {
        Double(max(0, min(100, entry.snapshot.todayScore))) / 100.0
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 9)
                    .frame(width: 82, height: 82)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(WidgetPalette.skyGlow, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 82, height: 82)
                    .blur(radius: 5)
                    .opacity(0.45)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(WidgetPalette.skyGlow, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 82, height: 82)

                Text("\(entry.snapshot.todayScore)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
            }

            Text(entry.snapshot.scoreHeadline)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)

            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(WidgetPalette.flameOrange)
                Text("\(entry.snapshot.globalStreak)d")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(WidgetPalette.card, in: Capsule())
            .overlay(Capsule().stroke(WidgetPalette.hairline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(WidgetPalette.canvas, for: .widget)
    }
}

struct TodayScoreWidget: Widget {
    let kind: String = "TodayScoreWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayScoreProvider()) { entry in
            TodayScoreWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's Score")
        .description("Live daily completion score ring and streak flame.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Widget Bundle Entry Point

@main
struct DailyOSWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DailyCheckInWidget()
        HabitMatrixWidget()
        TodayScoreWidget()
        FocusLiveActivityWidget()
    }
}
