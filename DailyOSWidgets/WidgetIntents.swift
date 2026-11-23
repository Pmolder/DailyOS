import Foundation
import AppIntents
import WidgetKit

// MARK: - Configurable Habit Matrix Cell Shape

enum WidgetCellShape: String, AppEnum {
    case dots
    case hearts

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Cell Shape"
    static var caseDisplayRepresentations: [WidgetCellShape: DisplayRepresentation] = [
        .dots: DisplayRepresentation(title: "Dots"),
        .hearts: DisplayRepresentation(title: "Hearts")
    ]
}

// MARK: - Widget Habit Entity (Reads Crash-Proof Shared Snapshot)

struct WidgetHabitEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Habit"
    static var defaultQuery = WidgetHabitEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct WidgetHabitEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetHabitEntity] {
        let habits = WidgetBridge.loadSnapshot().habits
        return habits
            .filter { identifiers.contains($0.id) }
            .map { WidgetHabitEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [WidgetHabitEntity] {
        WidgetBridge.loadSnapshot().habits.map {
            WidgetHabitEntity(id: $0.id, name: $0.name)
        }
    }

    func defaultResult() async -> WidgetHabitEntity? {
        guard let first = WidgetBridge.loadSnapshot().habits.first else { return nil }
        return WidgetHabitEntity(id: first.id, name: first.name)
    }
}

// MARK: - Configurable Small Habit Matrix Widget Intent

struct SelectHabitWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configure Habit Matrix"
    static var description = IntentDescription("Choose which habit and grid shape to display on your Home Screen.")

    @Parameter(title: "Habit")
    var habit: WidgetHabitEntity?

    @Parameter(title: "Grid Shape", default: .dots)
    var cellShape: WidgetCellShape

    init() {
        self.habit = nil
        self.cellShape = .dots
    }

    init(habit: WidgetHabitEntity?, cellShape: WidgetCellShape = .dots) {
        self.habit = habit
        self.cellShape = cellShape
    }
}
