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

    // Phase 3.1: slot-level notes (distinct from global Exercise.notes)
    var templateNotes: String?

    // Phase 3.1: structured prescription (replaces setTemplates long-term)
    @Relationship(deleteRule: .cascade)
    var prescription: SlotPrescription?

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

// MARK: - Prescription & Techniques

enum WarmupStepKind: String, Codable, CaseIterable {
    case percentage
    case fixedReps
    case noteOnly
}

enum TechniqueType: String, Codable, CaseIterable {
    case dropset
    case partialReps
    case restPause
    case amrap
    case toFailure
    case cluster
    case tempoOverride
}

@Model
final class WarmupStep {
    var order: Int
    var kindRaw: String
    var reps: Int?
    var percentOfWorking: Double?
    var restSecondsAfter: Int?
    var note: String?

    var kind: WarmupStepKind {
        get { WarmupStepKind(rawValue: kindRaw) ?? .fixedReps }
        set { kindRaw = newValue.rawValue }
    }

    init(
        order: Int,
        kind: WarmupStepKind = .fixedReps,
        reps: Int? = nil,
        percentOfWorking: Double? = nil,
        restSecondsAfter: Int? = nil,
        note: String? = nil
    ) {
        self.order = order
        self.kindRaw = kind.rawValue
        self.reps = reps
        self.percentOfWorking = percentOfWorking
        self.restSecondsAfter = restSecondsAfter
        self.note = note
    }
}

@Model
final class WarmupScheme {
    var name: String

    @Relationship(deleteRule: .cascade)
    var steps: [WarmupStep]

    init(name: String, steps: [WarmupStep] = []) {
        self.name = name
        self.steps = steps
    }
}

@Model
final class TechniquePlan {
    var order: Int
    var typeRaw: String

    var repMin: Int?
    var repMax: Int?
    var reps: Int?
    var durationSeconds: Int?
    var restSeconds: Int?
    var rounds: Int?
    var dropPercent: Double?
    var dropCount: Int?
    var partialRangeNote: String?
    var note: String?

    var type: TechniqueType {
        get { TechniqueType(rawValue: typeRaw) ?? .dropset }
        set { typeRaw = newValue.rawValue }
    }

    init(
        order: Int,
        type: TechniqueType,
        repMin: Int? = nil,
        repMax: Int? = nil,
        reps: Int? = nil,
        durationSeconds: Int? = nil,
        restSeconds: Int? = nil,
        rounds: Int? = nil,
        dropPercent: Double? = nil,
        dropCount: Int? = nil,
        partialRangeNote: String? = nil,
        note: String? = nil
    ) {
        self.order = order
        self.typeRaw = type.rawValue
        self.repMin = repMin
        self.repMax = repMax
        self.reps = reps
        self.durationSeconds = durationSeconds
        self.restSeconds = restSeconds
        self.rounds = rounds
        self.dropPercent = dropPercent
        self.dropCount = dropCount
        self.partialRangeNote = partialRangeNote
        self.note = note
    }
}

@Model
final class SlotPrescription {
    // Core
    var sets: Int?
    var repMin: Int?
    var repMax: Int?
    var restSecondsBetweenSets: Int?
    var restSecondsAfterExercise: Int?

    // Autoregulation
    var rir: Double?
    var rpe: Double?
    var tempo: String?

    // Duration targets
    var durationMinSeconds: Int?
    var durationMaxSeconds: Int?
    var usesDuration: Bool = false

    // Context overrides
    var equipment: String?
    var setupNotes: String?

    // Warmup: reusable across slots (.nullify preserves scheme when prescription deleted)
    @Relationship(deleteRule: .nullify)
    var warmupScheme: WarmupScheme?

    // Techniques: owned by this prescription
    @Relationship(deleteRule: .cascade)
    var techniquePlans: [TechniquePlan]

    init(
        sets: Int? = nil,
        repMin: Int? = nil,
        repMax: Int? = nil,
        restSecondsBetweenSets: Int? = nil,
        restSecondsAfterExercise: Int? = nil,
        rir: Double? = nil,
        rpe: Double? = nil,
        tempo: String? = nil,
        durationMinSeconds: Int? = nil,
        durationMaxSeconds: Int? = nil,
        usesDuration: Bool = false,
        equipment: String? = nil,
        setupNotes: String? = nil
    ) {
        self.sets = sets
        self.repMin = repMin
        self.repMax = repMax
        self.restSecondsBetweenSets = restSecondsBetweenSets
        self.restSecondsAfterExercise = restSecondsAfterExercise
        self.rir = rir
        self.rpe = rpe
        self.tempo = tempo
        self.durationMinSeconds = durationMinSeconds
        self.durationMaxSeconds = durationMaxSeconds
        self.usesDuration = usesDuration
        self.equipment = equipment
        self.setupNotes = setupNotes
        self.techniquePlans = []
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
