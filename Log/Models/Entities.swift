import Foundation
import SwiftData

// MARK: - Exercise & Set Templates

@Model
final class Exercise {
    @Attribute(.unique) var id: UUID
    var name: String
    var bodyPart: String?
    var notes: String?
    // Phase 10-E (2026-05-24): equipment + setup are now sourced
    // exclusively from `Exercise` here. The matching fields on
    // `SlotPrescription` were removed; the `PlannedPrescriptionSnapshot`
    // initializer reads `equipmentType` / `setupDefaults` from the
    // linked `Exercise` at session start (see `init(from:exercise:)`
    // below) so later edits to these fields never mutate already-
    // written workout snapshots or History rows.
    var equipmentType: String?
    var setupDefaults: String?
    var isCustom: Bool
    var isTimeBased: Bool = false

    /// Cardio is a *facet* of duration, not a sibling of it: an exercise is
    /// cardio only when it is also time-based. `isCardio == true` therefore
    /// implies `isTimeBased == true` — an invariant enforced at the write
    /// sites (`setTimeBased` / `setCardio`) rather than by the store, and read
    /// through the derived `trackingMode` which checks `isTimeBased` first so
    /// an impossible row degrades to `.strength` instead of crashing.
    ///
    /// Additive (default false) so existing rows migrate cleanly with no
    /// backfill: every exercise that exists today stays exactly what it is,
    /// and Plank stays a timed hold until the user opts it into cardio.
    var isCardio: Bool = false
    /// User-controlled display order on the Exercises tab. Additive (default 0)
    /// so existing rows migrate cleanly; backfill normalizes legacy data on
    /// first appear via `ExercisesView.backfillOrderIfNeeded`.
    var order: Int = 0

    /// When true, the user's bodyweight (from Settings) counts toward the
    /// effective load used in History strength metrics — bodyweight for pure
    /// movements (pull-ups), bodyweight + logged added weight for weighted
    /// ones (weighted pull-ups/dips). Independent of `equipmentType`: a
    /// weighted pull-up uses a non-"Bodyweight" equipment (so the active-workout
    /// weight field stays visible) yet still sets this true. Additive (default
    /// false) so existing rows migrate cleanly with no backfill.
    var includesBodyweightInLoad: Bool = false

    // Phase 9-E2 (2026-05-22): the former `defaultTemplates` relationship
    // was removed. Programming intent now lives entirely on
    // `RoutineExercise.setTemplates` (Tier 1) and `SlotPrescription`
    // (Tier 2). SwiftData performs lightweight migration for the property
    // drop; any pre-9-E `SetTemplate` rows that were children of this
    // relationship are swept by `BackfillService.purgeOrphanSetTemplates`
    // at bootstrap.

    // Exercise usages in routines and workouts
    @Relationship(deleteRule: .cascade)
    var routineUsages: [RoutineExercise] = []

    @Relationship(deleteRule: .nullify)
    var workoutItems: [WorkoutItem] = []

    init(
        name: String,
        bodyPart: String? = nil,
        notes: String? = nil,
        equipmentType: String? = nil,
        setupDefaults: String? = nil,
        isCustom: Bool = true,
        includesBodyweightInLoad: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.bodyPart = bodyPart
        self.notes = notes
        self.equipmentType = equipmentType
        self.setupDefaults = setupDefaults
        self.isCustom = isCustom
        self.includesBodyweightInLoad = includesBodyweightInLoad
    }
}

enum SetKind: String, Codable, CaseIterable {
    case warmup
    case working
    case dropset

    /// Localized label for an Active Workout set row. Returns `nil` for the
    /// default `.working` kind so normal working-set rows show no redundant
    /// label; non-default kinds return their localized name. Display-only —
    /// does not affect the persisted `rawValue`.
    var activeRowLabel: String? {
        switch self {
        case .working: return nil
        case .warmup:  return NSLocalizedString("Warmup", comment: "")
        case .dropset: return NSLocalizedString("Drop Set", comment: "")
        }
    }

    /// Localized label for a **History** set row. Unlike `activeRowLabel`, every
    /// kind names itself: a History row is read long after the fact, out of the
    /// context of the workout that produced it, so the one that says nothing is
    /// the ambiguous one.
    ///
    /// The kind vocabulary, and nothing else: this reads the *stored set kind*
    /// and never the exercise. A timed hold's working set and a barbell working
    /// set are both working sets, and the app has no cardio-specific set kinds
    /// to distinguish. If cardio ever gains structured warm-up / cooldown sets,
    /// they arrive as `SetKind` cases here and every row label follows for free.
    ///
    /// The one exercise-dependent exception lives one level up, in
    /// `HistorySetRowLabel`: a cardio bout's `.working` set reads "Cardio Set",
    /// because a cardio row is one aggregate entry rather than a set in the
    /// strength sense and the Cardio Plan above it already spends the word
    /// *Work* on a planned segment. That is a naming decision about a rendered
    /// row, not a set kind, so it does not belong in this enum.
    ///
    /// Display-only — does not affect the persisted `rawValue`.
    var historyRowLabel: String {
        switch self {
        case .working: return NSLocalizedString("Working Set", comment: "")
        case .warmup:  return NSLocalizedString("Warm-up Set", comment: "")
        case .dropset: return NSLocalizedString("Drop Set", comment: "")
        }
    }
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
    /// User-controlled display order on the Routines tab. Additive (default 0)
    /// so existing rows migrate cleanly; backfill normalizes legacy data on
    /// first appear via `RoutinesView.backfillOrderIfNeeded`.
    var order: Int = 0

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

extension Routine {
    /// Phase 6.B shared variant selection rule. Used by both the start path
    /// (`StartWorkoutFromRoutineView.makePlan`) and the launch-time backfill
    /// (`BootstrapRoot.backfillPhase6B`) so a workout backfilled to a routine
    /// resolves to the same variant a newly-started workout would.
    ///
    /// Precedence:
    ///  1. A variant whose `name` case-insensitively equals "Default".
    ///  2. Otherwise the variant with the lowest `(order, name)`.
    ///  3. Otherwise nil (no variants exist — legacy / pre-Phase-1-backfill data).
    /// Read-only; never mutates the model.
    var preferredVariantID: UUID? {
        let vs = variants
        guard !vs.isEmpty else { return nil }
        if let named = vs.first(where: {
            $0.name.caseInsensitiveCompare("Default") == .orderedSame
        }) {
            return named.id
        }
        return vs.sorted { ($0.order, $0.name) < ($1.order, $1.name) }.first?.id
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
        case .dropset:       return NSLocalizedString("Drop Set", comment: "")
        case .partialReps:   return NSLocalizedString("Partial Reps", comment: "")
        case .restPause:     return NSLocalizedString("Rest-Pause", comment: "")
        case .amrap:         return NSLocalizedString("AMRAP", comment: "")
        case .toFailure:     return NSLocalizedString("To Failure", comment: "")
        case .cluster:       return NSLocalizedString("Cluster", comment: "")
        case .tempoOverride: return NSLocalizedString("Tempo Override", comment: "")
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
        case .lastWorkingSet:   return NSLocalizedString("Last working set", comment: "")
        case .allWorkingSets:   return NSLocalizedString("All working sets", comment: "")
        case .setNumber(let n): return String(localized: "Set \(n)")
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

/// Region of the range of motion a Partial Reps technique targets.
/// Stored as `TechniquePlan.partialRangeRaw` (a `String?`): `nil` raw means
/// "Not set". `.custom` pairs with the free-text `partialRangeNote`. Legacy
/// rows predate this enum — they have `nil` raw + a free-text note (e.g.
/// "top half"), which the resolver still surfaces verbatim.
enum PartialRange: String, CaseIterable {
    case lengthenedHalf
    case shortenedHalf
    case middleRange
    case stickingPoint
    case custom

    var displayName: String {
        switch self {
        case .lengthenedHalf: return NSLocalizedString("Lengthened half", comment: "")
        case .shortenedHalf:  return NSLocalizedString("Shortened half", comment: "")
        case .middleRange:    return NSLocalizedString("Middle range", comment: "")
        case .stickingPoint:  return NSLocalizedString("Sticking point", comment: "")
        case .custom:         return NSLocalizedString("Custom", comment: "")
        }
    }

    /// Resolved display label for a `(partialRangeRaw, partialRangeNote)` pair.
    /// Returns `nil` when nothing should be shown ("Not set"):
    ///   • known preset raw            → preset display name
    ///   • "custom" + non-empty note   → the note
    ///   • "custom" + empty/nil note   → "Custom"
    ///   • nil/unknown raw + note      → the note (legacy free text)
    ///   • nil/unknown raw + no note   → nil
    static func displayLabel(raw: String?, note: String?) -> String? {
        let cleanNote = (note?.isEmpty == false) ? note : nil
        if let raw, let preset = PartialRange(rawValue: raw) {
            return preset == .custom ? (cleanNote ?? NSLocalizedString("Custom", comment: "")) : preset.displayName
        }
        return cleanNote
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
    /// Target weight for fixed-weight warmup steps. nil for percentage/note-only steps.
    var weight: Double? = nil

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
        note: String? = nil,
        weight: Double? = nil
    ) {
        self.order = order
        self.kindRaw = kind.rawValue
        self.reps = reps
        self.percentOfWorking = percentOfWorking
        self.restSecondsAfter = restSecondsAfter
        self.note = note
        self.weight = weight
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
    /// Preset partial-range raw value (`PartialRange.rawValue`); nil = Not set.
    /// Additive (nil default) for migration safety. Pairs with `partialRangeNote`
    /// when set to `"custom"`. See `PartialRange`.
    var partialRangeRaw: String? = nil
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
        partialRangeRaw: String? = nil,
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
        self.partialRangeRaw = partialRangeRaw
        self.note = note
        self.appliesToRaw = appliesToRaw
        self.appliesToSetNumber = appliesToSetNumber
        self.appliesToSetIndicesRaw = appliesToSetIndicesRaw
        self.dropsetEffortRaw = dropsetEffortRaw
        self.dropsetEffortReps = dropsetEffortReps
    }
}

/// Effort target mode for a slot's autoregulation (RIR/RPE). Additive Slice A.
/// `none` = no effort target; `single` = one value across all sets;
/// `progression` = directional start → end target interpolated across sets.
enum EffortMode: String, CaseIterable {
    case none
    case single
    case progression
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

    // Effort target modes (additive — Slice A). All optional / nil-default so
    // SwiftData lightweight migration leaves existing rows unchanged. When
    // `effortModeRaw` is nil the mode is derived from legacy `rir`/`rpe` (see
    // `effortMode`), so pre-existing prescriptions behave exactly as before.
    // `single` reuses `rir`/`rpe` as its value; `progression` reads the
    // start/end pairs below.
    var effortModeRaw: String?
    var rirStart: Double?
    var rirEnd: Double?
    var rpeStart: Double?
    var rpeEnd: Double?

    // Duration targets
    var durationMinSeconds: Int?
    var durationMaxSeconds: Int?
    var usesDuration: Bool = false

    // Cardio Slice 5 — optional **target** distance for a cardio slot.
    //
    // A target, never a result: the distance actually covered is recorded on
    // `SetLog.distanceMeters`, and the two are deliberately separate fields on
    // separate types so a 5 km target logged as 4.2 km stays honest.
    //
    // Stored canonically in meters, so aggregation is correct by construction.
    // `targetDistanceUnitRaw` records the unit the target was *entered* in and
    // is kept for backward, transfer and import compatibility — it is **not** a
    // display override: a target renders in `AppSettings.distanceUnit`, which
    // is the only place the user picks a distance unit. (Contrast
    // `SetLog.distanceUnitRaw`, which *does* win: a performed bout is a record
    // of what was run.) Both optional / nil-default: every existing
    // prescription migrates lightweightly and a cardio slot with no distance
    // target is the normal case, not a degraded one.
    //
    // Pace and speed are deliberately absent here for the same reason they are
    // absent from `CardioMetrics`: both are distance ÷ duration and are derived
    // at render time.
    var targetDistanceMeters: Double? = nil
    var targetDistanceUnitRaw: String? = nil

    /// Structured Cardio Slice 12C — the slot's optional segment plan
    /// (warm-up / work / recovery / cool-down), JSON-encoded.
    ///
    /// A `Data?` column rather than a `@Model` + relationship, following
    /// `WorkoutItem.warmupStepsSnapshotData`: segments are never queried
    /// independently, so rows would buy nothing and cost cascade rules,
    /// ordering discipline, deep-copy, and an orphan sweep — the class of bug
    /// `BackfillService.purgeOrphanSetTemplates` exists to clean up.
    ///
    /// Read and written **only** through `structuredCardioPlan` /
    /// `setStructuredCardioPlan` (see `SlotPrescription+StructuredCardio.swift`),
    /// which normalize on both sides, so a corrupt payload degrades to "no
    /// plan" instead of reaching a view. Optional / nil-default: every existing
    /// prescription migrates lightweightly and reads as unstructured, which is
    /// what 100% of them are.
    var cardioSegmentsData: Data? = nil

    /// Alternative Exercises Phase C — the slot's prepared alternatives
    /// (replacement exercise + its own full prescription), JSON-encoded.
    ///
    /// Same `Data?`-column reasoning as `cardioSegmentsData` above, and for the
    /// same reasons (`ALTERNATIVE_EXERCISES_DESIGN.md` §5.1): alternatives are
    /// never queried independently, so a `@Model` graph would buy nothing and
    /// cost cascade rules across four levels, ordering discipline, deep-copy in
    /// `RoutineDuplicator`, and an orphan sweep. The payload is additionally
    /// *already* the value type the session plan will freeze, so there is no
    /// model → value mapping layer to write.
    ///
    /// Read and written **only** through `slotAlternatives` /
    /// `setSlotAlternatives` (see `SlotPrescription+Alternatives.swift`), which
    /// normalize on both sides through the Phase B codec, so a corrupt payload
    /// degrades to "no alternatives" instead of reaching a view. Optional /
    /// nil-default: every existing prescription migrates lightweightly and
    /// reads as having none, which is what 100% of them are.
    var alternativesData: Data? = nil

    /// The tempo this prescription may actually display.
    ///
    /// Tempo describes eccentric/concentric rep phases and is meaningless for a
    /// duration-based slot, so it resolves to nil there. Editors hide the field
    /// and clear the stored value when a slot flips to duration; this accessor
    /// is the read-side guarantee for **stale** values that predate that rule
    /// (imported routines, rows written before the flip). Mirrors
    /// `SessionPlan.effectiveTempo`.
    var effectiveTempo: String? {
        guard !usesDuration, let t = tempo, !t.isEmpty else { return nil }
        return t
    }

    // Phase 10-E (2026-05-24): the former `equipment` / `setupNotes`
    // slot fields were removed. Source of truth lives on `Exercise`
    // (`equipmentType` / `setupDefaults`); the session-start snapshot
    // reads from there via `PlannedPrescriptionSnapshot.init(from:exercise:)`.
    // SwiftData lightweight migration handles the property drop.

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
        effortModeRaw: String? = nil,
        rirStart: Double? = nil,
        rirEnd: Double? = nil,
        rpeStart: Double? = nil,
        rpeEnd: Double? = nil,
        durationMinSeconds: Int? = nil,
        durationMaxSeconds: Int? = nil,
        usesDuration: Bool = false,
        targetDistanceMeters: Double? = nil,
        targetDistanceUnitRaw: String? = nil
    ) {
        self.sets = sets
        self.repMin = repMin
        self.repMax = repMax
        self.restSecondsBetweenSets = restSecondsBetweenSets
        self.restSecondsAfterExercise = restSecondsAfterExercise
        self.rir = rir
        self.rpe = rpe
        self.tempo = tempo
        self.effortModeRaw = effortModeRaw
        self.rirStart = rirStart
        self.rirEnd = rirEnd
        self.rpeStart = rpeStart
        self.rpeEnd = rpeEnd
        self.durationMinSeconds = durationMinSeconds
        self.durationMaxSeconds = durationMaxSeconds
        self.usesDuration = usesDuration
        self.targetDistanceMeters = targetDistanceMeters
        self.targetDistanceUnitRaw = targetDistanceUnitRaw
        self.techniquePlans = []
    }
}

// MARK: - Prescription Helpers

extension SlotPrescription {
    /// Derived effort target mode. An explicit, valid `effortModeRaw` wins;
    /// when it is nil (legacy rows), the mode is derived so behavior is
    /// unchanged: any single value present (`rir`/`rpe`) ⇒ `.single`,
    /// otherwise `.none`. An unrecognized raw string falls through to the
    /// same derivation rather than crashing.
    var effortMode: EffortMode {
        if let raw = effortModeRaw, let mode = EffortMode(rawValue: raw) {
            return mode
        }
        return (rir != nil || rpe != nil) ? .single : .none
    }

    /// True when the prescription carries enough info to generate working sets.
    ///
    /// A cardio distance target is deliberately **not** counted here, even
    /// though a distance-only cardio slot is a perfectly valid prescription.
    /// This property answers one narrow question — "can `generateTemplates()`
    /// produce meaningful `SetTemplate`s?" — and for a distance-only slot the
    /// answer is no: `SetTemplate` has no distance field, so the generator
    /// would fall through to its hardcoded `?? 60` and manufacture a 60-second
    /// duration target the user never programmed, which would then prefill the
    /// active-workout row. An empty template list is the honest answer; the
    /// row still renders, because `SessionPlanResolver.effectiveSetCount`
    /// reads `sets` from the snapshot rather than counting templates.
    ///
    /// The one place that must *not* treat a distance-only slot as empty is
    /// `BackfillService.hydrateEmptySlotPrescriptions`, which uses
    /// `hasHydratableContent` below instead.
    var hasContent: Bool {
        if usesDuration {
            return (durationMinSeconds ?? durationMaxSeconds) != nil
        }
        return sets != nil
    }

    /// True when the slot has been **authored** — the question
    /// `BackfillService.hydrateEmptySlotPrescriptions` actually needs answered
    /// before it overwrites a prescription with `AppSettings` defaults.
    ///
    /// Wider than `hasContent` by exactly one case: a cardio slot programmed
    /// with a distance target and no duration ("run 5k, however long it
    /// takes"). Such a slot generates no templates, so `hasContent` is false —
    /// but it is emphatically not empty, and hydrating it would silently
    /// rewrite the user's routine on the next launch, replacing the cardio
    /// defaults with three sets, 90 seconds of rest, and an invented 60-second
    /// duration target.
    ///
    /// Kept separate from `hasContent` on purpose. Widening `hasContent`
    /// instead would route the same slot into `generateTemplates()`, whose
    /// `?? 60` fallback is the very duration this guard exists to prevent, and
    /// would change `resolvedTemplates()` and the routine editor's
    /// template-vs-prescription comparison as collateral. Backfill is the only
    /// caller that wants the wider reading.
    var hasHydratableContent: Bool {
        hasContent || targetDistanceMeters != nil
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
    /// Canonical 2-tier template resolution:
    /// 1) Explicit per-set overrides (`setTemplates` non-empty)
    /// 2) Prescription-generated templates (`prescription.hasContent == true`)
    /// Else: `[]`. Legacy slots without prescription content are
    /// hydrated at bootstrap by `BackfillService.hydrateEmptySlotPrescriptions`.
    func resolvedTemplates() -> [SetTemplate] {
        // Tier 1: explicit overrides
        if !setTemplates.isEmpty {
            return setTemplates.sorted { $0.order < $1.order }
        }

        // Tier 2: prescription-generated
        if let p = prescription, p.hasContent {
            return p.generateTemplates()
        }

        return []
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

    // Effort target modes (Slice E1). Additive / nil-default snapshot of the
    // source `SlotPrescription`'s effort fields so a running workout can later
    // render per-set targets from this immutable snapshot — never from the live
    // template. Old snapshot rows migrate with nil values and derive `.single`
    // (legacy rir/rpe) or `.none` exactly as `SlotPrescription.effortMode` does.
    var effortModeRaw: String?
    var rirStart: Double?
    var rirEnd: Double?
    var rpeStart: Double?
    var rpeEnd: Double?

    // Duration
    var durationMinSeconds: Int?
    var durationMaxSeconds: Int?
    var usesDuration: Bool = false

    // Cardio Slice 5 — frozen copy of the slot's target distance, so a running
    // or completed workout renders the target it was started with even after
    // the routine is edited. Optional / nil-default: existing snapshot rows
    // migrate lightweightly and read as "no distance target".
    var targetDistanceMeters: Double? = nil
    var targetDistanceUnitRaw: String? = nil

    /// Structured Cardio Slice 12C — frozen copy of the slot's segment plan.
    ///
    /// The column landed with the editor (12C) rather than with its first
    /// reader (12D) on purpose: 12C was the one schema-touching slice in the
    /// structured cardio plan, and adding this later would have made a second
    /// one. **Slice 12D is what fills it**: session start now freezes the
    /// slot's plan here, so the in-workout checklist keeps showing the plan the
    /// session was started with even after the routine is edited.
    ///
    /// Stored as the encoded payload, never re-encoded from a decoded value:
    /// a plan this build would normalize survives the session byte-for-byte,
    /// exactly as `RoutineDuplicator` copies it.
    var cardioSegmentsData: Data? = nil

    /// The tempo History / session detail may display for this frozen snapshot.
    /// Nil for a duration-based row, so an already-completed workout that
    /// captured a stale tempo never renders one. Mirrors
    /// `SlotPrescription.effectiveTempo` / `SessionPlan.effectiveTempo`.
    /// Read-only: the stored value stays untouched, so old History rows are not
    /// rewritten.
    var effectiveTempo: String? {
        guard !usesDuration, let t = tempo, !t.isEmpty else { return nil }
        return t
    }

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
        effortModeRaw: String? = nil,
        rirStart: Double? = nil,
        rirEnd: Double? = nil,
        rpeStart: Double? = nil,
        rpeEnd: Double? = nil,
        durationMinSeconds: Int? = nil,
        durationMaxSeconds: Int? = nil,
        usesDuration: Bool = false,
        targetDistanceMeters: Double? = nil,
        targetDistanceUnitRaw: String? = nil,
        cardioSegmentsData: Data? = nil,
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
        self.effortModeRaw = effortModeRaw
        self.rirStart = rirStart
        self.rirEnd = rirEnd
        self.rpeStart = rpeStart
        self.rpeEnd = rpeEnd
        self.durationMinSeconds = durationMinSeconds
        self.durationMaxSeconds = durationMaxSeconds
        self.usesDuration = usesDuration
        self.targetDistanceMeters = targetDistanceMeters
        self.targetDistanceUnitRaw = targetDistanceUnitRaw
        self.cardioSegmentsData = cardioSegmentsData
        self.equipment = equipment
        self.setupNotes = setupNotes
    }

    /// Build a snapshot by copying fields from a live `SlotPrescription`
    /// (programming surface) plus the linked `Exercise` (equipment + setup
    /// source after Phase 10-E). The copy is taken once at session start
    /// and is durable on the snapshot row: later edits to
    /// `exercise.equipmentType` / `setupDefaults` do not mutate it.
    convenience init(from source: SlotPrescription, exercise: Exercise?) {
        self.init(
            sets: source.sets,
            repMin: source.repMin,
            repMax: source.repMax,
            restSecondsBetweenSets: source.restSecondsBetweenSets,
            restSecondsAfterExercise: source.restSecondsAfterExercise,
            rir: source.rir,
            rpe: source.rpe,
            tempo: source.tempo,
            effortModeRaw: source.effortModeRaw,
            rirStart: source.rirStart,
            rirEnd: source.rirEnd,
            rpeStart: source.rpeStart,
            rpeEnd: source.rpeEnd,
            durationMinSeconds: source.durationMinSeconds,
            durationMaxSeconds: source.durationMaxSeconds,
            usesDuration: source.usesDuration,
            targetDistanceMeters: source.targetDistanceMeters,
            targetDistanceUnitRaw: source.targetDistanceUnitRaw,
            // Raw, not decode → re-encode: see the property's note.
            cardioSegmentsData: source.cardioSegmentsData,
            equipment: exercise?.equipmentType,
            setupNotes: exercise?.setupDefaults
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

    // Cardio Slice 3: the optional metrics describing one performed cardio
    // bout. They live here, next to `durationSeconds`, because they describe a
    // *performed* set — not a prescription and not a definition.
    //
    // All optional with nil defaults, so every existing `SetLog` row migrates
    // lightweightly and keeps rendering exactly as it does today. Strength and
    // timed-hold sets simply leave them nil; nothing requires them, and a
    // cardio bout carrying only a duration is still a complete, valid set.
    //
    // Read them through `cardioMetrics` rather than individually — that
    // accessor runs every value through `CardioMetrics`' normalizing
    // initializer, so an out-of-range or unparseable stored value resolves to
    // nil instead of reaching the UI.
    //
    // Pace and speed are deliberately absent: both are distance ÷ duration and
    // are derived at render time by `CardioDerived`. A stored pace that
    // disagreed with the stored distance and duration would be unresolvable.

    /// Canonical distance in **meters**, always, regardless of entry unit.
    var distanceMeters: Double? = nil

    /// The `DistanceUnit` symbol the distance was entered in ("km" / "mi"),
    /// preserved so History reads back the way the user typed it rather than
    /// shifting when the global preference changes.
    var distanceUnitRaw: String? = nil

    var avgHeartRate: Int? = nil
    var calories: Int? = nil

    /// Grade in percent, signed — negative values are treadmill decline.
    var inclinePercent: Double? = nil

    /// Machine resistance setting. Unitless — equipment numbers its own levels.
    var resistanceLevel: Double? = nil

    /// `HRZone` raw value ("z1"…"z5").
    var hrZoneRaw: String? = nil

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

    // Phase 6.C1: source-block snapshot fields driving future History
    // superset grouping (Phase 6.C2). All optional / nil-default — legacy
    // WorkoutItem rows migrate cleanly with nil values and the future
    // display path treats nil as "render flat" (current behavior).
    // Populated at session start by `populateSnapshotFields(on:from:)`.
    // - sourceBlockSlotID: `RoutineBlock.slotID` of the source block;
    //   grouping identity. Two items with the same value belong to the
    //   same source block.
    // - sourceBlockIsSuperset: `RoutineBlock.isSuperset` snapshot.
    // - sourceBlockOrder: `RoutineBlock.order` in the source variant;
    //   stable sort key across the workout's items regardless of
    //   SwiftData @Relationship insertion order.
    // - sourceExerciseOrderInBlock: `RoutineExercise.order` within the
    //   source block; stable intra-superset display order.
    var sourceBlockSlotID: UUID? = nil
    var sourceBlockIsSuperset: Bool? = nil
    var sourceBlockOrder: Int? = nil
    var sourceExerciseOrderInBlock: Int? = nil

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
    /// Phase 6.B: stable per-variant identity, additive (default nil). Linked by
    /// UUID rather than relationship to mirror `routineID` and to remain tolerant
    /// of variant deletion (orphan UUIDs survive harmlessly; display path falls
    /// back to live routine name then to `routineName` snapshot).
    var routineVariantID: UUID?
    var completedAt: Date?
    @Relationship(deleteRule: .cascade)
    var items: [WorkoutItem]
    var notes: String?
    /// When true, this completed workout is kept in History but is NOT used as
    /// a source for last-performance prefill in future workouts (e.g. recovery
    /// / deload sessions whose reduced loads would otherwise become the next
    /// prefill baseline). Additive: defaults to `false` so all existing and new
    /// workouts behave exactly as before. Read only by
    /// `LastPerformancePrefillService`; History charts, PRs, volume, e1RM,
    /// bodyweight, and analytics ignore it.
    var excludedFromPrefill: Bool = false

    init(
        date: Date = .now,
        routineName: String? = nil,
        routineID: UUID? = nil,
        routineVariantID: UUID? = nil,
        items: [WorkoutItem],
        notes: String? = nil,
        excludedFromPrefill: Bool = false
    ) {
        self.id = UUID()
        self.date = date
        self.routineName = routineName
        self.routineID = routineID
        self.routineVariantID = routineVariantID
        self.items = items
        self.notes = notes
        self.excludedFromPrefill = excludedFromPrefill
    }
}
