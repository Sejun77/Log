import Foundation
import SwiftData

// MARK: - Exercise & Set Templates

@Model
final class Exercise {
    @Attribute(.unique) var id: UUID
    var name: String
    var bodyPart: String?
    var notes: String?
    var isCustom: Bool
    var isTimeBased: Bool = false

    // Exercise owns its default templates
    @Relationship(deleteRule: .cascade)
    var defaultTemplates: [SetTemplate] = []

    // Exercise usages in routines and workouts
    @Relationship(deleteRule: .cascade)
    var routineUsages: [RoutineExercise] = []

    @Relationship(deleteRule: .nullify)
    var workoutItems: [WorkoutItem] = []

    init(
        name: String,
        bodyPart: String? = nil,
        notes: String? = nil,
        isCustom: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.bodyPart = bodyPart
        self.notes = notes
        self.isCustom = isCustom
    }
}

enum SetKind: String, Codable, CaseIterable {
    case warmup
    case working
    case dropset
}

@Model
final class SetTemplate {
    var order: Int = 0
    var kindRaw: String
    var targetReps: Int
    var targetWeight: Double?
    var restSecondsAfter: Int?
    var durationSeconds: Int? = nil

    var kind: SetKind {
        get { SetKind(rawValue: kindRaw) ?? .working }
        set { kindRaw = newValue.rawValue }
    }

    init(
        kind: SetKind = .working,
        targetReps: Int,
        targetWeight: Double? = nil,
        restSecondsAfter: Int? = nil
    ) {
        self.kindRaw = kind.rawValue
        self.targetReps = targetReps
        self.targetWeight = targetWeight
        self.restSecondsAfter = restSecondsAfter
    }

    /// Used to enforce a consistent order: warmup → working → dropset
    var kindSortKey: Int {
        switch kind {
        case .warmup: return 0
        case .working: return 1
        case .dropset: return 2
        }
    }
}

// MARK: - Routines

@Model
final class RoutineExercise {
    var slotID: UUID = UUID()

    // Define the inverse ON THIS SIDE ONLY to avoid circular macro resolution
    @Relationship(inverse: \Exercise.routineUsages)
    var exercise: Exercise?

    var order: Int
    @Relationship(deleteRule: .cascade)
    var setTemplates: [SetTemplate]

    init(exercise: Exercise, order: Int, setTemplates: [SetTemplate]) {
        self.exercise = exercise
        self.order = order
        self.setTemplates = setTemplates
    }
}

@Model
final class RoutineBlock {
    var slotID: UUID = UUID()
    var isSuperset: Bool
    var order: Int
    var restAfterSeconds: Int?
    var supersetRoundRestSeconds: Int?

    @Relationship(deleteRule: .cascade)
    var exercises: [RoutineExercise]

    init(
        isSuperset: Bool = false,
        order: Int,
        restAfterSeconds: Int? = nil,
        exercises: [RoutineExercise]
    ) {
        self.isSuperset = isSuperset
        self.order = order
        self.restAfterSeconds = restAfterSeconds
        self.exercises = exercises
    }
}

@Model
final class RoutineVariant {
    @Attribute(.unique) var id: UUID
    var name: String
    var order: Int

    @Relationship(deleteRule: .cascade)
    var blocks: [RoutineBlock]

    init(name: String, order: Int = 0, blocks: [RoutineBlock] = []) {
        self.id = UUID()
        self.name = name
        self.order = order
        self.blocks = blocks
    }
}

@Model
final class Routine {
    @Attribute(.unique) var id: UUID
    var name: String
    var notes: String?

    @Relationship(deleteRule: .cascade)
    var blocks: [RoutineBlock]

    @Relationship(deleteRule: .cascade)
    var variants: [RoutineVariant]

    init(name: String, notes: String? = nil, blocks: [RoutineBlock]) {
        self.id = UUID()
        self.name = name
        self.notes = notes
        self.blocks = blocks
        self.variants = []
    }
}

// MARK: - Workout Logs

@Model
final class SetLog {
    var indexInExercise: Int
    var kindRaw: String
    var reps: Int
    var weight: Double?
    var restSeconds: Int?
    var durationSeconds: Int? = nil
    var timestamp: Date

    var kind: SetKind {
        get { SetKind(rawValue: kindRaw) ?? .working }
        set { kindRaw = newValue.rawValue }
    }

    init(
        indexInExercise: Int,
        kind: SetKind = .working,
        reps: Int,
        weight: Double?,
        restSeconds: Int? = nil,
        timestamp: Date = .now,
        durationSeconds: Int? = nil
    ) {
        self.indexInExercise = indexInExercise
        self.kindRaw = kind.rawValue
        self.reps = reps
        self.weight = weight
        self.restSeconds = restSeconds
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
    }
}

@Model
final class WorkoutItem {
    // Define the inverse ON THIS SIDE ONLY
    @Relationship(inverse: \Exercise.workoutItems)
    var exercise: Exercise?

    @Relationship(deleteRule: .cascade)
    var setLogs: [SetLog]

    init(exercise: Exercise, setLogs: [SetLog]) {
        self.exercise = exercise
        self.setLogs = setLogs
    }
}

@Model
final class Workout {
    @Attribute(.unique) var id: UUID
    var date: Date
    var routineName: String?
    @Relationship(deleteRule: .cascade)
    var items: [WorkoutItem]
    var notes: String?

    init(
        date: Date = .now,
        routineName: String? = nil,
        items: [WorkoutItem],
        notes: String? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.routineName = routineName
        self.items = items
        self.notes = notes
    }
}
