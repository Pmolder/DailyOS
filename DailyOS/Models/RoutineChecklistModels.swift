import Foundation
import SwiftUI
import SwiftData

// MARK: - Morning & Night Routine Type

enum RoutineType: String, CaseIterable, Codable, Identifiable {
    case morning
    case night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .morning: return "Morning Routine"
        case .night: return "Night Routine"
        }
    }

    var shortLabel: String {
        switch self {
        case .morning: return "Morning"
        case .night: return "Night"
        }
    }

    var iconName: String {
        switch self {
        case .morning: return "sun.max.fill"
        case .night: return "moon.stars.fill"
        }
    }

    var accentHex: String {
        switch self {
        case .morning: return "#FFB020" // Solar Gold
        case .night: return "#8B7CFF"   // Indigo / Periwinkle
        }
    }

    var accentColor: Color {
        Color(hex: accentHex)
    }

    /// Time-aware subtle highlight window (Morning 05:00-12:00, Night 20:00-03:00).
    var isCurrentlyPrimeWindow: Bool {
        let hour = ISOWeekCalendar.current.component(.hour, from: Date())
        switch self {
        case .morning: return (5..<12).contains(hour)
        case .night: return hour >= 20 || hour < 3
        }
    }
}

// MARK: - SwiftData Routine Checklist Models

@Model
final class RoutineChecklistItem {
    var id: UUID = UUID()
    var routineTypeRaw: String = RoutineType.morning.rawValue
    var title: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        routineType: RoutineType = .morning,
        title: String,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.routineTypeRaw = routineType.rawValue
        self.title = title
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    var routineType: RoutineType {
        get { RoutineType(rawValue: routineTypeRaw) ?? .morning }
        set { routineTypeRaw = newValue.rawValue }
    }
}

@Model
final class RoutineChecklistLog {
    var id: UUID = UUID()
    var itemID: UUID = UUID()
    var dayKey: String = ""
    var completedAt: Date = Date()

    init(
        id: UUID = UUID(),
        itemID: UUID,
        dayKey: String,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.dayKey = dayKey
        self.completedAt = completedAt
    }
}

// MARK: - One-Time Starter Seeder

@MainActor
enum RoutineChecklistSeeder {
    private static let seededKey = "com.patrik.dailyos.routineDefaultsSeeded"

    static let defaultMorningTitles: [String] = [
        "Take cold shower",
        "Brush teeth",
        "Make bed",
        "Drink glass of water"
    ]

    static let defaultNightTitles: [String] = [
        "Put gym clothes ready",
        "Get water ready",
        "Phone on charger away from bed",
        "Review tomorrow's plan"
    ]

    static func seedDefaultsIfNeeded(in modelContext: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }

        let existing = SharedModelContainer.shared.fetchRoutineItems()
        guard existing.isEmpty else {
            UserDefaults.standard.set(true, forKey: seededKey)
            return
        }

        for (idx, title) in defaultMorningTitles.enumerated() {
            modelContext.insert(RoutineChecklistItem(routineType: .morning, title: title, sortOrder: idx))
        }
        for (idx, title) in defaultNightTitles.enumerated() {
            modelContext.insert(RoutineChecklistItem(routineType: .night, title: title, sortOrder: idx))
        }

        UserDefaults.standard.set(true, forKey: seededKey)
        try? modelContext.save()
        SharedModelContainer.shared.save()
    }
}
