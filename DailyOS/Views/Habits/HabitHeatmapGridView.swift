import SwiftUI

/// High-craft GitHub-style ISO-8601 (Mon–Sun) contribution heatmap rendered cleanly
/// across Habit Feed Cards, Habit Detail, Notes Story view, and Full-Year Analytics.
struct HabitHeatmapGridView: View {
    let habit: HabitItem
    let logMap: [String: HabitLog]
    var weeksCount: Int = 28
    var yearFilter: Int? = nil
    var showAxes: Bool = false
    var highlightNoteDays: Bool = false
    var onSelectDay: ((String) -> Void)? = nil

    private let daysPerWeek = 7

    /// Builds column-major week columns (Row 0 = Monday ... Row 6 = Sunday).
    private var columns: [[Date?]] {
        let cal = ISOWeekCalendar.current
        let today = cal.startOfDay(for: Date())

        if let year = yearFilter {
            guard let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let dec31 = cal.date(from: DateComponents(year: year, month: 12, day: 31)) else {
                return []
            }
            let firstMonday = ISOWeekCalendar.startOfMondayWeek(for: jan1)
            let lastMonday = ISOWeekCalendar.startOfMondayWeek(for: dec31)
            let totalWeeks = max(1, ((cal.dateComponents([.day], from: firstMonday, to: lastMonday).day ?? 0) / 7) + 1)

            var result: [[Date?]] = []
            for w in 0..<totalWeeks {
                var col: [Date?] = []
                for d in 0..<daysPerWeek {
                    if let dt = cal.date(byAdding: .day, value: w * 7 + d, to: firstMonday),
                       cal.component(.year, from: dt) == year {
                        col.append(dt)
                    } else {
                        col.append(nil)
                    }
                }
                result.append(col)
            }
            return result
        }

        let currentMonday = ISOWeekCalendar.startOfMondayWeek(for: today)
        guard let firstMonday = cal.date(byAdding: .day, value: -(weeksCount - 1) * 7, to: currentMonday) else {
            return []
        }

        var result: [[Date?]] = []
        for w in 0..<weeksCount {
            var col: [Date?] = []
            for d in 0..<daysPerWeek {
                if let dt = cal.date(byAdding: .day, value: w * 7 + d, to: firstMonday), dt <= today {
                    col.append(dt)
                } else {
                    col.append(nil)
                }
            }
            result.append(col)
        }
        return result
    }

    /// Computes approximate month label positions across columns when `showAxes == true`.
    private var monthMarkers: [(weekIndex: Int, label: String)] {
        let cal = ISOWeekCalendar.current
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM"

        var markers: [(Int, String)] = []
        var lastMonth: Int = -1
        for (wIdx, col) in columns.enumerated() {
            guard let firstValid = col.compactMap({ $0 }).first else { continue }
            let m = cal.component(.month, from: firstValid)
            if m != lastMonth {
                lastMonth = m
                // Avoid crowding adjacent labels on the first 2 columns
                if let prev = markers.last, wIdx - prev.0 < 3 { continue }
                markers.append((wIdx, formatter.string(from: firstValid)))
            }
        }
        return markers
    }

    var body: some View {
        let cols = columns
        let colCount = max(1, cols.count)
        let accent = habit.accentColor
        let spacing: CGFloat = yearFilter != nil ? 2.0 : 2.5

        VStack(alignment: .leading, spacing: 4) {
            if showAxes {
                HStack(spacing: 0) {
                    Spacer().frame(width: 24)
                    GeometryReader { geo in
                        let stepX = geo.size.width / CGFloat(colCount)
                        ZStack(alignment: .leading) {
                            ForEach(monthMarkers, id: \.weekIndex) { marker in
                                Text(marker.label)
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(DailyOSTheme.eyebrow)
                                    .offset(x: CGFloat(marker.weekIndex) * stepX)
                            }
                        }
                    }
                    .frame(height: 12)
                }
            }

            HStack(alignment: .top, spacing: 4) {
                if showAxes {
                    GeometryReader { geo in
                        let rowH = (geo.size.height - spacing * 6) / 7.0
                        ZStack(alignment: .topLeading) {
                            axisLabel("Tue", y: (rowH + spacing) * 1)
                            axisLabel("Thu", y: (rowH + spacing) * 3)
                            axisLabel("Sat", y: (rowH + spacing) * 5)
                        }
                    }
                    .frame(width: 20, height: gridHeight(forColumns: colCount))
                }

                GeometryReader { geo in
                    let totalSpacingX = spacing * CGFloat(max(0, colCount - 1))
                    let cellW = max(2.0, (geo.size.width - totalSpacingX) / CGFloat(colCount))
                    let cellSize = min(cellW, yearFilter != nil ? 7.5 : 10.5)
                    let actualGridW = (cellSize * CGFloat(colCount)) + totalSpacingX
                    let xOffset = max(0, (geo.size.width - actualGridW) / 2.0)

                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            let corner = max(1.5, cellSize * 0.28)
                            for w in 0..<cols.count {
                                let x = xOffset + CGFloat(w) * (cellSize + spacing)
                                for d in 0..<daysPerWeek {
                                    let y = CGFloat(d) * (cellSize + spacing)
                                    let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)

                                    guard let date = cols[w][d] else {
                                        continue
                                    }

                                    let ratio = HabitMetricsEngine.progressRatio(for: habit, on: date, logMap: logMap)
                                    let fill = cellColor(for: ratio, accent: accent)
                                    let rounded = Path(roundedRect: rect, cornerRadius: corner)
                                    context.fill(rounded, with: .color(fill))

                                    if highlightNoteDays {
                                        let key = HabitItem.dateKey(for: date)
                                        if logMap[key]?.hasNote == true {
                                            // Hollow dark center dot indicating a written story note on this day
                                            let dotSize = max(2.4, cellSize * 0.42)
                                            let dotRect = CGRect(
                                                x: rect.midX - dotSize / 2,
                                                y: rect.midY - dotSize / 2,
                                                width: dotSize,
                                                height: dotSize
                                            )
                                            context.fill(Path(ellipseIn: dotRect), with: .color(DailyOSTheme.canvas))
                                            context.stroke(
                                                Path(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4), cornerRadius: corner),
                                                with: .color(Color.white.opacity(0.65)),
                                                lineWidth: 0.8
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        if let onSelectDay {
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    SpatialTapGesture()
                                        .onEnded { value in
                                            let localX = value.location.x - xOffset
                                            let localY = value.location.y
                                            let w = Int(localX / (cellSize + spacing))
                                            let d = Int(localY / (cellSize + spacing))
                                            if w >= 0 && w < cols.count && d >= 0 && d < daysPerWeek,
                                               let tappedDate = cols[w][d] {
                                                onSelectDay(HabitItem.dateKey(for: tappedDate))
                                            }
                                        }
                                )
                        }
                    }
                }
                .frame(height: gridHeight(forColumns: colCount))
            }
        }
    }

    private func gridHeight(forColumns colCount: Int) -> CGFloat {
        let cell: CGFloat = yearFilter != nil ? 6.5 : 9.5
        let spacing: CGFloat = yearFilter != nil ? 2.0 : 2.5
        return (cell * 7.0) + (spacing * 6.0)
    }

    private func axisLabel(_ text: String, y: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium, design: .rounded))
            .foregroundStyle(DailyOSTheme.eyebrow)
            .offset(y: y - 1)
    }

    private func cellColor(for ratio: Double, accent: Color) -> Color {
        switch ratio {
        case ..<0.01:
            return DailyOSTheme.emptyCell
        case 0.01..<0.34:
            return accent.opacity(0.30)
        case 0.34..<0.67:
            return accent.opacity(0.55)
        case 0.67..<0.99:
            return accent.opacity(0.80)
        default:
            return accent
        }
    }
}
