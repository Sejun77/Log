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

    var displayName: String {
        switch self {
        case .dropset:       return "Drop Set"
        case .partialReps:   return "Partial Reps"
        case .restPause:     return "Rest-Pause"
        case .amrap:         return "AMRAP"
        case .toFailure:     return "To Failure"
        case .cluster:       return "Cluster"
        case .tempoOverride: return "Tempo Override"
        }
    }
}

/// Which set(s) within a working-set sequence a technique applies to.
enum TechniqueAppliesTo: Equatable {
    case lastWorkingSet   // default — final working set only
    case allWorkingSets   // every working set
    case setNumber(Int)   // specific 1-based set number

    var rawValue: String {
        switch self {
        case .lastWorkingSet: return "lastWorkingSet"
        case .allWorkingSets: return "allWorkingSets"
        case .setNumber:      return "setNumber"
        }
    }

    static func from(raw: String, setNumber: Int?) -> TechniqueAppliesTo {
        switch raw {
        case "allWorkingSets": return .allWorkingSets
        case "setNumber":      return .setNumber(setNumber ?? 1)
        default:               return .lastWorkingSet
        }
    }

    var displayLabel: String {
        switch self {
        case .lastWorkingSet:   return "Last working set"
        case .allWorkingSets:   return "All working sets"
        case .setNumber(let n): return "Set \(n)"
        }
    }
}

/// Effort mode for each drop in a Dropset.
enum DropsetEffort: Equatable {
    case amrap          // as many reps as possible (default)
    case fixedReps(Int) // specific rep count

    var rawValue: String {
        switch self {
        case .amrap:     return "amrap"
        case .fixedReps: return "fixedReps"
        }
    }

    static func from(raw: String?, reps: Int?) -> DropsetEffort {
        switch raw {
        case "fixedReps": return .fixedReps(reps ?? 8)
        default:          return .amrap
        }
    }
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

    // appliesTo targeting (additive; default "lastWorkingSet" is migration-safe)
    var appliesToRaw: String = "lastWorkingSet"
    var appliesToSetNumber: Int? = nil

    // Explicit 0-based working-set indices (CSV). Empty = not set; runtime falls back to appliesTo.
    var appliesToSetIndicesRaw: String = ""

    // Dropset effort mode (nil raw == amrap default)
    var dropsetEffortRaw: String? = nil
    var dropsetEffortReps: Int? = nil

    var type: TechniqueType {
        get { TechniqueType(rawValue: typeRaw) ?? .dropset }
        set { typeRaw = newValue.rawValue }
    }

    var appliesTo: TechniqueAppliesTo {
        get { TechniqueAppliesTo.from(raw: appliesToRaw, setNumber: appliesToSetNumber) }
        set {
            appliesToRaw = newValue.rawValue
            if case .setNumber(let n) = newValue { appliesToSetNumber = n } else { appliesToSetNumber = nil }
        }
    }

    /// Parsed 0-based set indices from the CSV field.
    /// Empty set means "not yet set" — runtime must resolve using setCount (last by default).
    var appliesToSetIndices: Set<Int> {
        get {
            guard !appliesToSetIndicesRaw.isEmpty else {
                // Migration: setNumber(n) → {n-1}; others return {} for runtime handling.
                if appliesToRaw == "setNumber", let n = appliesToSetNumber { return [n - 1] }
                return []
            }
            return Set(appliesToSetIndicesRaw.split(separator: ",").compactMap { Int($0) })
        }
        set {
            appliesToSetIndicesRaw = newValue.sorted().map(String.init).joined(separator: ",")
        }
    }

    var dropsetEffort: DropsetEffort {
        get { DropsetEffort.from(raw: dropsetEffortRaw, reps: dropsetEffortReps) }
        set {
            dropsetEffortRaw = newValue.rawValue
            if case .fixedReps(let n) = newValue { dropsetEffortReps = n } else { dropsetEffortReps = nil }
        }
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
        note: String? = nil,
        appliesToRaw: String = "lastWorkingSet",
        appliesToSetNumber: Int? = nil,
        appliesToSetIndicesRaw: String = "",
        dropsetEffortRaw: String? = nil,
        dropsetEffortReps: Int? = nil
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
        self.appliesToRaw = appliesToRaw
        self.appliesToSetNumber = appliesToSetNumber
        self.appliesToSetIndicesRaw = appliesToSetIndicesRaw
        self.dropsetEffortRaw = dropsetEffortRaw
        self.dropsetEffortReps = dropsetEffortReps
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

// MARK: - Prescription Helpers

extension SlotPrescription {
    /// True when the prescription carries enough info to generate working sets.
    var hasContent: Bool {
        if usesDuration {
            return (durationMinSeconds ?? durationMaxSeconds) != nil
        }
        return sets != nil
    }

    /// Deterministic generator: produces [SetTemplate] from prescription fields.
    /// Does NOT insert into a model context — callers decide lifecycle.
    func generateTemplates() -> [SetTemplate] {
        let count = max(1, sets ?? 3)

        return (0..<count).map { i in
            let tpl: SetTemplate
            if usesDuration {
                let dur = durationMaxSeconds ?? durationMinSeconds ?? 60
                tpl = SetTemplate(
                    kind: .working,
                    targetReps: 0,
                    targetWeight: nil,
                    restSecondsAfter: restSecondsBetweenSets
                )
                tpl.durationSeconds = dur
            } else {
                let reps = repMax ?? repMin ?? 8
                tpl = SetTemplate(
                    kind: .working,
                    targetReps: reps,
                    targetWeight: nil,
                    restSecondsAfter: restSecondsBetweenSets
                )
            }
            tpl.order = i
            return tpl
        }
    }
}

// MARK: - Template Resolution

extension RoutineExercise {
    /// Canonical 3-tier template resolution:
    /// 1) Explicit per-set overrides (setTemplates non-empty)
    /// 2) Prescription-generated templates (prescription with content)
    /// 3) Exercise default templates (fallback)
    func resolvedTemplates() -> [SetTemplate] {
        // Tier 1: explicit overrides
        if !setTemplates.isEmpty {
            return setTemplates.sorted { $0.order < $1.order }
        }

        // Tier 2: prescription-generated
        if let p = prescription, p.hasContent {
            return p.generateTemplates()
        }

        // Tier 3: exercise defaults
        guard let ex = exercise else { return [] }
        return ex.defaultTemplates.sorted { $0.order < $1.order }
    }
}

// MARK: - Session Snapshots

@Model
final class PlannedPrescriptionSnapshot {
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

    // Duration
    var durationMinSeconds: Int?
    var durationMaxSeconds: Int?
    var usesDuration: Bool = false

    // Context
    var equipment: String?
    var setupNotes: String?

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
    }

    /// Build a snapshot by copying fields from a live SlotPrescription.
    convenience init(from source: SlotPrescription) {
        self.init(
            sets: source.sets,
            repMin: source.repMin,
            repMax: source.repMax,
            restSecondsBetweenSets: source.restSecondsBetweenSets,
            restSecondsAfterExercise: source.restSecondsAfterExercise,
            rir: source.rir,
            rpe: source.rpe,
            tempo: source.tempo,
            durationMinSeconds: source.durationMinSeconds,
            durationMaxSeconds: source.durationMaxSeconds,
            usesDuration: source.usesDuration,
            equipment: source.equipment,
            setupNotes: source.setupNotes
        )
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
    /// 1-based sub-index for drop sub-sets logged under a parent working set.
    /// nil = main set (working / warmup / legacy template-based dropset).
    var subIndex: Int? = nil

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
        durationSeconds: Int? = nil,
        subIndex: Int? = nil
    ) {
        self.indexInExercise = indexInExercise
        self.kindRaw = kind.rawValue
        self.reps = reps
        self.weight = weight
        self.restSeconds = restSeconds
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.subIndex = subIndex
    }
}

@Model
final class WorkoutItem {
    // Define the inverse ON THIS SIDE ONLY
    @Relationship(inverse: \Exercise.workoutItems)
    var exercise: Exercise?

    @Relationship(deleteRule: .cascade)
    var setLogs: [SetLog]

    // Phase 3.3: session snapshot fields (nil for pre-existing items)
    var routineSlotID: UUID?
    var templateNotesSnapshot: String?

    @Relationship(deleteRule: .cascade)
    var plannedPrescriptionSnapshot: PlannedPrescriptionSnapshot?

    // Phase 4b: readable history after exercise deletion
    var exerciseNameSnapshot: String?

    // Warmup steps snapshotted at session start; used to restore the warmup
    // section on cold resume when the routine may no longer be available.
    // Optional / nil-default — fully additive, no migration required.
    var warmupStepsSnapshotData: Data? = nil
    var techniquePlansSnapshotData: Data? = nil

    init(exercise: Exercise, setLogs: [SetLog]) {
        self.exercise = exercise
        self.setLogs = setLogs
        self.exerciseNameSnapshot = exercise.name
    }
}

@Model
final class Workout {
    @Attribute(.unique) var id: UUID
    var date: Date
    var routineName: String?
    var routineID: UUID?
    var completedAt: Date?
    @Relationship(deleteRule: .cascade)
    var items: [WorkoutItem]
    var notes: String?

    init(
        date: Date = .now,
        routineName: String? = nil,
        routineID: UUID? = nil,
        items: [WorkoutItem],
        notes: String? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.routineName = routineName
        self.routineID = routineID
        self.items = items
        self.notes = notes
    }
}
