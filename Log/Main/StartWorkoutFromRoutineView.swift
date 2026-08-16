import SwiftData
import SwiftUI

// MARK: - Value snapshot used by the workout UI (no live SwiftData references)

struct PlanSetTemplate: Identifiable {
    var id: String  // stable composite key
    var kind: SetKind
    var targetReps: Int
    var targetWeight: Int?
    var restSecondsAfter: Int?
    var durationSeconds: Int?
}

/// Value-type snapshot of one warmup step — no live SwiftData references.
///
/// `Equatable` is synthesized (Alternative Exercises Phase B): the snapshot is
/// carried inside `AlternativePrescriptionPayload`, which is `Equatable` so the
/// editor and a future session-plan dirty check can compare prepared plans by
/// value. Declared here rather than in an extension because synthesis requires
/// the conformance to sit with the declaration. Behavior-neutral — it adds a
/// `==`, it changes no existing code path.
struct WarmupStepSnapshot: Codable, Equatable {
    var order: Int
    var kind: WarmupStepKind
    var reps: Int?
    var percentOfWorking: Double?
    var note: String?
    var restSecondsAfter: Int?
    /// Target weight for fixed-weight steps; nil for other kinds.
    /// Nil default is Codable-safe for snapshots created before this field was added.
    var weight: Double? = nil
}

/// Value-type snapshot of one technique plan — no live SwiftData references.
///
/// `Equatable` synthesized for the same reason as `WarmupStepSnapshot` above,
/// and with the same behavior-neutrality.
struct TechniquePlanSnapshot: Codable, Equatable {
    var order: Int
    var type: TechniqueType       // Codable via RawRepresentable
    var dropPercent: Double?      // stored as percentage, e.g. 20.0 = 20%
    var dropCount: Int?
    var rounds: Int?
    var restSeconds: Int?
    var partialRangeNote: String?
    /// Preset partial-range raw (`PartialRange.rawValue`); nil = Not set.
    /// Optional for backward-compatible JSON decoding of pre-existing snapshots.
    var partialRangeRaw: String? = nil
    var note: String?
    var reps: Int?

    // New fields — optional for backward-compatible JSON decoding of existing data.
    // nil decodes as the appropriate default (lastWorkingSet / amrap).
    var appliesToRaw: String?
    var appliesToSetNumber: Int?
    // Explicit 0-based indices CSV (nil = not set; fall back to appliesTo).
    var appliesToSetIndicesRaw: String? = nil
    var dropsetEffortRaw: String?
    var dropsetEffortReps: Int?

    var appliesTo: TechniqueAppliesTo {
        TechniqueAppliesTo.from(raw: appliesToRaw ?? "lastWorkingSet", setNumber: appliesToSetNumber)
    }

    /// Parsed 0-based set indices. Empty = not set; runtime resolves using setCount.
    var appliesToSetIndices: Set<Int> {
        if let raw = appliesToSetIndicesRaw, !raw.isEmpty {
            return Set(raw.split(separator: ",").compactMap { Int($0) })
        }
        // Migration from old appliesTo: only setNumber can be statically resolved here.
        switch appliesTo {
        case .setNumber(let n): return [n - 1]
        default: return []
        }
    }

    var dropsetEffort: DropsetEffort {
        DropsetEffort.from(raw: dropsetEffortRaw, reps: dropsetEffortReps)
    }

    /// Payload-only label — no applies-to suffix.
    /// Used when the chip is already attached to the relevant set row.
    var setAttachedLabel: String {
        switch type {
        case .dropset:
            var parts: [String] = []
            if let pct = dropPercent, pct > 0 { parts.append("−\(Int(pct))%") }
            if let n = dropCount { parts.append("×\(n)") }
            switch dropsetEffort {
            case .amrap:            parts.append("(AMRAP)")
            case .fixedReps(let n): parts.append("(\(n) reps)")
            }
            if let r = restSeconds, r > 0 { parts.append("\(r)s") }
            let tail = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
            return "\(String(localized: "Drop Set"))\(tail)"
        case .restPause:
            var s = String(localized: "Rest-Pause")
            if let r = restSeconds, r > 0 { s += " \(r)s" }
            if let n = rounds, n > 0 { s += " ×\(n)" }
            return s
        case .tempoOverride:
            return (note.flatMap { $0.isEmpty ? nil : $0 }).map { String(localized: "Tempo \($0)") } ?? String(localized: "Tempo")
        case .partialReps:
            var s = String(localized: "Partials")
            if let region = PartialRange.displayLabel(
                raw: partialRangeRaw, note: partialRangeNote
            ) {
                s += " \(region)"
            }
            if let n = reps, n > 0 { s += " (\(n))" }
            return s
        case .amrap:    return String(localized: "AMRAP")
        case .toFailure: return String(localized: "To Failure")
        case .cluster:
            var s = String(localized: "Cluster")
            if let n = reps, n > 0 { s += " \(n)r" }
            if let c = rounds, c > 0 { s += " ×\(c)" }
            if let r = restSeconds, r > 0 { s += " (\(r)s)" }
            return s
        }
    }

    /// Full label with applies-to suffix — used in header overview and editors.
    var summaryLabel: String {
        var label = setAttachedLabel
        // Append set qualifier. Prefer explicit indices when available.
        let indices = appliesToSetIndices
        if !indices.isEmpty {
            let nums = indices.sorted().map { String($0 + 1) }.joined(separator: ",")
            label += indices.count == 1 ? " [set \(nums)]" : " [sets \(nums)]"
        } else {
            switch appliesTo {
            case .lastWorkingSet: break
            case .allWorkingSets:   label += " [all]"
            case .setNumber(let n): label += " [set \(n)]"
            }
        }
        return label
    }
}

/// Lightweight value-type copy of SlotPrescription fields, carried in the plan
/// and converted to @Model PlannedPrescriptionSnapshot at WorkoutItem creation.
struct PrescriptionSnapshotPayload {
    var sets: Int?
    var repMin: Int?
    var repMax: Int?
    var restSecondsBetweenSets: Int?
    var restSecondsAfterExercise: Int?
    var rir: Double?
    var rpe: Double?
    var tempo: String?
    // Effort target modes (Slice E1) — carried from the source prescription
    // through the snapshot so the active workout can render per-set targets
    // later. All optional / nil-default for backward compatibility.
    var effortModeRaw: String?
    var rirStart: Double?
    var rirEnd: Double?
    var rpeStart: Double?
    var rpeEnd: Double?
    /// Custom per-set effort targets, carried in the same comma-separated form
    /// the model columns store (see `SlotPrescription.customRIRTargetsRaw`), so
    /// a `.custom` slot's authored list is frozen into the session and renders
    /// on the active-workout rows unchanged by later routine edits.
    var customRIRTargetsRaw: String? = nil
    var customRPETargetsRaw: String? = nil
    var durationMinSeconds: Int?
    var durationMaxSeconds: Int?
    var usesDuration: Bool
    // Cardio Slice 5 — the slot's target distance, carried through the plan so
    // the active workout can show and seed it. Optional / nil-default: every
    // non-cardio slot, and every cardio slot without a distance target,
    // carries nil and behaves exactly as before.
    var targetDistanceMeters: Double? = nil
    var targetDistanceUnitRaw: String? = nil
    // Structured Cardio Slice 12D — the slot's segment plan, carried through
    // the session plan as the **encoded** payload rather than a decoded value
    // type. Two reasons: a payload this build would normalize (or cannot parse)
    // rides through the session unchanged, exactly as `RoutineDuplicator`
    // copies it; and the decode happens once per read site, through the single
    // tolerant accessor below, so a corrupt column can never throw into the
    // plan-build path. nil for every non-cardio slot and for every cardio slot
    // without a structured plan — the overwhelming majority.
    var cardioSegmentsData: Data? = nil
    var equipment: String?
    var setupNotes: String?

    /// The frozen structured cardio plan, decoded, or nil when this slot has
    /// none.
    ///
    /// Mirrors `SlotPrescription.structuredCardioPlan` field-for-field,
    /// including its "one representation of no structure" rule: a nil column,
    /// an empty plan, and an unreadable payload all read as nil. A corrupt
    /// payload therefore costs the checklist, never the session.
    var structuredCardioPlan: CardioSegmentPlan? {
        guard let cardioSegmentsData else { return nil }
        guard
            let plan = try? JSONDecoder().decode(
                CardioSegmentPlan.self, from: cardioSegmentsData),
            !plan.isEmpty
        else { return nil }
        return plan
    }

    /// Phase 10-E: equipment + setup are sourced from the linked
    /// `Exercise` rather than from the slot. The captured values are
    /// durable on the snapshot row — later edits to
    /// `exercise.equipmentType` / `setupDefaults` do not mutate already-
    /// written workout snapshots or History rows.
    init(from source: SlotPrescription, exercise: Exercise?) {
        self.sets = source.sets
        self.repMin = source.repMin
        self.repMax = source.repMax
        self.restSecondsBetweenSets = source.restSecondsBetweenSets
        self.restSecondsAfterExercise = source.restSecondsAfterExercise
        self.rir = source.rir
        self.rpe = source.rpe
        // `effectiveTempo`, not `tempo`: a duration-based slot must not freeze
        // a stale tempo into a NEW session snapshot (and from there into
        // History). Already-written snapshots are untouched — this is the
        // capture point only, so completed workouts keep whatever they froze.
        self.tempo = source.effectiveTempo
        self.effortModeRaw = source.effortModeRaw
        self.rirStart = source.rirStart
        self.rirEnd = source.rirEnd
        self.rpeStart = source.rpeStart
        self.rpeEnd = source.rpeEnd
        self.customRIRTargetsRaw = source.customRIRTargetsRaw
        self.customRPETargetsRaw = source.customRPETargetsRaw
        self.durationMinSeconds = source.durationMinSeconds
        self.durationMaxSeconds = source.durationMaxSeconds
        self.usesDuration = source.usesDuration
        self.targetDistanceMeters = source.targetDistanceMeters
        self.targetDistanceUnitRaw = source.targetDistanceUnitRaw
        self.cardioSegmentsData = source.cardioSegmentsData
        self.equipment = exercise?.equipmentType
        self.setupNotes = exercise?.setupDefaults
    }

    func toModel() -> PlannedPrescriptionSnapshot {
        PlannedPrescriptionSnapshot(
            sets: sets,
            repMin: repMin,
            repMax: repMax,
            restSecondsBetweenSets: restSecondsBetweenSets,
            restSecondsAfterExercise: restSecondsAfterExercise,
            rir: rir,
            rpe: rpe,
            tempo: tempo,
            effortModeRaw: effortModeRaw,
            rirStart: rirStart,
            rirEnd: rirEnd,
            rpeStart: rpeStart,
            rpeEnd: rpeEnd,
            customRIRTargetsRaw: customRIRTargetsRaw,
            customRPETargetsRaw: customRPETargetsRaw,
            durationMinSeconds: durationMinSeconds,
            durationMaxSeconds: durationMaxSeconds,
            usesDuration: usesDuration,
            targetDistanceMeters: targetDistanceMeters,
            targetDistanceUnitRaw: targetDistanceUnitRaw,
            cardioSegmentsData: cardioSegmentsData,
            equipment: equipment,
            setupNotes: setupNotes
        )
    }
}

extension PrescriptionSnapshotPayload {
    /// An all-nil payload with no tracking type asserted.
    ///
    /// Base for `ExerciseSwitchPlanAdapter.adaptedSnapshot` when a switched slot
    /// had no prior snapshot to carry effort-progression fields over from.
    static var empty: PrescriptionSnapshotPayload {
        PrescriptionSnapshotPayload(usesDuration: false)
    }

    /// Memberwise-style init used by `.empty` and the switch adapter. Every
    /// field defaults to nil so callers only state what they mean to set.
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
        customRIRTargetsRaw: String? = nil,
        customRPETargetsRaw: String? = nil,
        durationMinSeconds: Int? = nil,
        durationMaxSeconds: Int? = nil,
        usesDuration: Bool = false,
        // Slice 6 note: the exercise-switch adapter builds payloads through
        // this init and lets the target distance default to nil, so a switched
        // slot simply has no distance target. Deciding when a target should be
        // *preserved* or *cleared* across a switch is Slice 6's job — nil is
        // the conservative reading until then.
        targetDistanceMeters: Double? = nil,
        targetDistanceUnitRaw: String? = nil,
        // Slice 12D note: the exercise-switch adapter builds payloads through
        // this init too, and `adaptedSnapshot` writes the field explicitly from
        // the adapted plan — so a switched slot never inherits the replaced
        // exercise's segments by omission.
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
        self.customRIRTargetsRaw = customRIRTargetsRaw
        self.customRPETargetsRaw = customRPETargetsRaw
        self.durationMinSeconds = durationMinSeconds
        self.durationMaxSeconds = durationMaxSeconds
        self.usesDuration = usesDuration
        self.targetDistanceMeters = targetDistanceMeters
        self.targetDistanceUnitRaw = targetDistanceUnitRaw
        self.cardioSegmentsData = cardioSegmentsData
        self.equipment = equipment
        self.setupNotes = setupNotes
    }

    /// Reconstruct a payload from a persisted snapshot (for resume path).
    init(from snapshot: PlannedPrescriptionSnapshot) {
        self.sets = snapshot.sets
        self.repMin = snapshot.repMin
        self.repMax = snapshot.repMax
        self.restSecondsBetweenSets = snapshot.restSecondsBetweenSets
        self.restSecondsAfterExercise = snapshot.restSecondsAfterExercise
        self.rir = snapshot.rir
        self.rpe = snapshot.rpe
        self.tempo = snapshot.tempo
        self.effortModeRaw = snapshot.effortModeRaw
        self.rirStart = snapshot.rirStart
        self.rirEnd = snapshot.rirEnd
        self.rpeStart = snapshot.rpeStart
        self.rpeEnd = snapshot.rpeEnd
        self.customRIRTargetsRaw = snapshot.customRIRTargetsRaw
        self.customRPETargetsRaw = snapshot.customRPETargetsRaw
        self.durationMinSeconds = snapshot.durationMinSeconds
        self.durationMaxSeconds = snapshot.durationMaxSeconds
        self.usesDuration = snapshot.usesDuration
        self.targetDistanceMeters = snapshot.targetDistanceMeters
        self.targetDistanceUnitRaw = snapshot.targetDistanceUnitRaw
        self.cardioSegmentsData = snapshot.cardioSegmentsData
        self.equipment = snapshot.equipment
        self.setupNotes = snapshot.setupNotes
    }
}

struct PlanExercise: Identifiable {
    /// **NOT slot-unique.** This is set to `Exercise.id` at plan-build
    /// time and collides when the same `Exercise` appears in two
    /// superset slots. The per-slot identifier is `routineSlotID`
    /// (below) — use it for any lookup that needs to address a
    /// specific slot. See `findSlotIndex(in:routineSlotID:)` in
    /// `ActiveWorkoutHelpers.swift` for the slot-keyed plan lookup
    /// that all in-workout state stores already use.
    var id: UUID

    // NEW — original & current
    var routineExerciseID: PersistentIdentifier
    var originalExerciseID: UUID
    var currentExerciseID: UUID

    // Display/state
    var name: String
    var notes: String?
    var templates: [PlanSetTemplate]
    var isTimeBased: Bool = false

    // Session snapshot payload (Phase 3.3)
    var routineSlotID: UUID
    var templateNotesSnapshot: String?
    var prescriptionSnapshot: PrescriptionSnapshotPayload?

    // Technique plans snapshotted at plan-build time (read-only; no live SwiftData references)
    var techniquePlansSnapshot: [TechniquePlanSnapshot] = []

    // Warmup steps snapshotted at plan-build time (read-only; no live SwiftData references)
    var warmupStepsSnapshot: [WarmupStepSnapshot] = []

    /// Alternative Exercises Phase E — the slot's prepared alternatives,
    /// frozen at plan-build time like the two snapshots above (§4.2).
    ///
    /// The freeze is what makes editing a routine mid-workout safe: the
    /// session offers what the slot had when it started, not what the routine
    /// says now. Optional-free and defaulted to `[]`, so every existing
    /// construction site — the resume rebuilds, the test fixtures — keeps
    /// compiling and keeps meaning "no alternatives".
    ///
    /// Nothing reads this yet: `ActiveWorkoutView.initializeSessionPlans`
    /// copies it into the slot's `SessionPlan` (which is what persists across
    /// Save & Exit), and the switch sheet that will offer them is Phase F.
    var alternativesSnapshot: [SlotAlternative] = []

    // Phase 6.C1: source-block snapshot fields. Denormalized onto
    // PlanExercise at plan-build time so the single populator
    // `populateSnapshotFields(on:from:)` can copy them onto WorkoutItem
    // without an enclosing-block lookup. Optional / nil-default so
    // construction sites that don't have block context (e.g. orphan
    // fallback rebuilding from a legacy WorkoutItem with nil snapshot
    // fields, or test fixtures) can omit them — the future display
    // path treats nil as "render flat".
    var sourceBlockSlotID: UUID? = nil
    var sourceBlockIsSuperset: Bool? = nil
    var sourceBlockOrder: Int? = nil
    var sourceExerciseOrderInBlock: Int? = nil
}

struct PlanBlock: Identifiable {
    var id = UUID()
    var isSuperset: Bool
    var restAfterSeconds: Int?
    var supersetRoundRestSeconds: Int?
    var exercises: [PlanExercise]
}

struct WorkoutPlan: Identifiable {
    var id = UUID()
    var routineID: UUID
    var routineName: String
    /// Phase 6.B: id of the `RoutineVariant` selected for this session, if any.
    /// Carried through to the persisted `Workout.routineVariantID`. Optional
    /// because legacy routines that pre-date variant backfill may not have one
    /// when the start path runs, and because the fallback resume path
    /// (planFromWorkoutItems) cannot recover this from items alone.
    var routineVariantID: UUID?
    var blocks: [PlanBlock]
}

// MARK: - View

struct StartWorkoutFromRoutineView: View {
    @Bindable var routine: Routine

    @State private var cachedPlan: WorkoutPlan?

    // 9-B2 bug-fix (Issue 4 Part B): when an active workout exists for
    // this routine, the Start button must NOT push a freshly-built plan
    // that reflects the routine's original slot exercises — that would
    // silently override any in-flight swap state.
    @Environment(\.modelContext) private var ctx
    @ObservedObject private var activeGuard = ActiveWorkoutGuard.shared

    /// Returns the plan to push into `ActiveWorkoutView`.
    ///
    /// **Entry #12 P1 resume-consistency contract:** when a session is already
    /// active for THIS routine, this entry point must surface the *same* plan
    /// the "Resume workout" banner surfaces, and must never rebuild,
    /// reinterpret, or "fix" it. The banner (`RoutinesView` / `RootTabView`)
    /// pushes `activeGuard.activePlan` — the live in-memory plan that
    /// `swapExercise` keeps current — so this path now prefers exactly that.
    ///
    /// Previously this always called `WorkoutResumeService.rebuildPlan(...)`,
    /// which reconstructs from the **routine template**. That gave the two
    /// entry points genuinely different plans after a switch: the rebuild
    /// re-derived the set count from `re.prescription.sets` and re-attached a
    /// `prescriptionSnapshot` built from the slot's ORIGINAL exercise — so a
    /// Plank → Bench Press switch rendered Bench Press with Plank's duration
    /// fields, while Resume showed something else entirely.
    ///
    /// `rebuildPlan` remains the fallback for the one case it is actually for:
    /// a cold restart, where the in-memory plan is gone and the persisted
    /// workout is the only source left.
    @MainActor
    private func resolvedStartPlan() -> WorkoutPlan? {
        var activeWorkout: Workout? = nil
        if let activeID = activeGuard.activeWorkoutID {
            let descriptor = FetchDescriptor<Workout>(
                predicate: #Predicate { $0.id == activeID }
            )
            if let workout = try? ctx.fetch(descriptor).first,
               workout.routineID == routine.id
            {
                activeWorkout = workout
            }
        }

        switch activeWorkoutPlanSource(
            hasActiveWorkoutForThisRoutine: activeWorkout != nil,
            hasLiveActivePlan: activeGuard.activePlan != nil
        ) {
        case .liveActiveSession:
            // Same object the Resume banner pushes.
            return activeGuard.activePlan ?? cachedPlan
        case .coldRestartRebuild:
            guard let activeWorkout else { return cachedPlan }
            return WorkoutResumeService.rebuildPlan(
                for: activeWorkout, in: ctx
            ) ?? cachedPlan
        case .freshStart:
            return cachedPlan
        }
    }

    // MARK: - Plan Builder

    /// Builds the frozen `WorkoutPlan` a session runs on.
    ///
    /// `static` (Alternative Exercises Phase E): the body reads nothing but its
    /// `routine` argument, and being callable without a view is what lets the
    /// freeze — prescription snapshot, warm-ups, techniques, and now
    /// alternatives — be tested against the real start path instead of a
    /// look-alike reproduced in the test file. Behavior is unchanged.
    static func makePlan(from routine: Routine) -> WorkoutPlan {
        let blocks: [PlanBlock] = routine.blocks
            .sorted { $0.order < $1.order }
            .compactMap { b -> PlanBlock? in
                let exs: [PlanExercise] = b.exercises
                    .sorted { $0.order < $1.order }
                    .compactMap { re in
                        guard let ex = re.exercise else { return nil }
                        let templates = re.resolvedTemplates().enumerated()
                            .map { (i, tpl) in
                                PlanSetTemplate(
                                    id: "\(ex.id.uuidString)-set\(i)",
                                    kind: tpl.kind,
                                    targetReps: tpl.targetReps,
                                    targetWeight: tpl.targetWeight.map {
                                        Int($0.rounded())
                                    },
                                    restSecondsAfter: tpl.restSecondsAfter,
                                    durationSeconds: tpl.durationSeconds
                                )
                            }
                        // Snapshot technique plans (read-only; no live SwiftData
                        // references). Techniques the slot's exercise can't
                        // support are dropped at capture time — a duration
                        // exercise must not carry a Tempo Override (or any
                        // rep-count technique) into the session or into the
                        // History snapshot frozen from it.
                        let techniquePlansSnapshot: [TechniquePlanSnapshot] =
                            compatibleTechniquePlans(
                                re.prescription?.techniquePlans ?? [],
                                isBodyweight: isBodyweightEquipment(
                                    ex.equipmentType),
                                usesDuration: ex.isTimeBased
                            )
                            .sorted { $0.order < $1.order }
                            .map { tp in
                                TechniquePlanSnapshot(
                                    order: tp.order,
                                    type: tp.type,
                                    dropPercent: tp.dropPercent,
                                    dropCount: tp.dropCount,
                                    rounds: tp.rounds,
                                    restSeconds: tp.restSeconds,
                                    partialRangeNote: tp.partialRangeNote,
                                    partialRangeRaw: tp.partialRangeRaw,
                                    note: tp.note,
                                    reps: tp.reps,
                                    appliesToRaw: tp.appliesToRaw,
                                    appliesToSetNumber: tp.appliesToSetNumber,
                                    appliesToSetIndicesRaw: tp.appliesToSetIndicesRaw.isEmpty ? nil : tp.appliesToSetIndicesRaw,
                                    dropsetEffortRaw: tp.dropsetEffortRaw,
                                    dropsetEffortReps: tp.dropsetEffortReps
                                )
                            }

                        let warmupStepsSnapshot: [WarmupStepSnapshot] =
                            (re.prescription?.warmupScheme?.steps ?? [])
                            .sorted { $0.order < $1.order }
                            .map { step in
                                WarmupStepSnapshot(
                                    order: step.order,
                                    kind: step.kind,
                                    reps: step.reps,
                                    percentOfWorking: step.percentOfWorking,
                                    note: step.note,
                                    restSecondsAfter: step.restSecondsAfter,
                                    weight: step.weight
                                )
                            }

                        return PlanExercise(
                            id: ex.id,
                            routineExerciseID: re.id,
                            originalExerciseID: ex.id,
                            currentExerciseID: ex.id,
                            name: ex.name,
                            notes: ex.notes,
                            templates: templates,
                            isTimeBased: ex.isTimeBased,
                            routineSlotID: re.slotID,
                            templateNotesSnapshot: re.templateNotes,
                            prescriptionSnapshot: re.prescription.map {
                                PrescriptionSnapshotPayload(
                                    from: $0, exercise: ex
                                )
                            },
                            techniquePlansSnapshot: techniquePlansSnapshot,
                            warmupStepsSnapshot: warmupStepsSnapshot,
                            // Alternative Exercises Phase E — the slot's
                            // prepared alternatives, frozen here and read from
                            // the session's own copy thereafter (§4.2). Decoded
                            // through the tolerant Phase C accessor, so a
                            // corrupt payload costs the alternatives and never
                            // the workout.
                            alternativesSnapshot: re.prescription?
                                .slotAlternatives ?? [],
                            // Phase 6.C1 — block snapshot for History grouping
                            sourceBlockSlotID: b.slotID,
                            sourceBlockIsSuperset: b.isSuperset,
                            sourceBlockOrder: b.order,
                            sourceExerciseOrderInBlock: re.order
                        )
                    }
                guard !exs.isEmpty else { return nil }
                return PlanBlock(
                    isSuperset: b.isSuperset,
                    restAfterSeconds: b.restAfterSeconds,
                    supersetRoundRestSeconds: b.supersetRoundRestSeconds,
                    exercises: exs
                )
            }

        return WorkoutPlan(
            routineID: routine.id,
            routineName: routine.name,
            routineVariantID: routine.preferredVariantID,
            blocks: blocks
        )
    }

    // MARK: - Body

    var body: some View {
        List {
            overviewSection
            blocksSection
        }
        .navigationTitle("Start Workout")
        // Design system integration (purely visual)
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 56)
        .listRowSpacing(8)
        .scrollContentBackground(.hidden)
        .background(DSColor.bg.ignoresSafeArea())
        .onAppear {
            cachedPlan = Self.makePlan(from: routine)
        }
        .onChange(of: routine) {
            cachedPlan = Self.makePlan(from: routine)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // Prefer the resume-rebuilt plan when this routine has an
                // active in-flight workout (preserves swap state). Falls
                // back to the cached freshly-built plan otherwise.
                NavigationLink {
                    if let plan = resolvedStartPlan() {
                        ActiveWorkoutView(plan: plan)
                    } else {
                        // Fallback (shouldn't happen once onAppear ran)
                        ActiveWorkoutView(plan: Self.makePlan(from: routine))
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.dsBody.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("beginWorkoutFromRoutine")
                .disabled(cachedPlan == nil)
            }
        }
    }

    // MARK: - Sections (UI-only changes)

    private var overviewSection: some View {
        Section {
            Text(routine.name)
                .font(.dsBody.weight(.semibold))

            if let notes = routine.notes, !notes.isEmpty {
                Text(notes)
                    .font(.dsBodySecondary)
                    .foregroundStyle(.secondary)
            }
        } header: {
            DSSectionHeader(title: "Overview", systemImage: "info.circle")
        }
    }

    private var blocksSection: some View {
        Section {
            ForEach(routine.blocks.sorted { $0.order < $1.order }) { b in
                VStack(alignment: .leading, spacing: 6) {
                    Text(b.isSuperset ? "Superset" : "Exercise")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)

                    Text(
                        b.exercises
                            .sorted { $0.order < $1.order }
                            .compactMap { $0.exercise?.name }
                            .joined(separator: " + ")
                    )
                    .font(.dsBody)
                }
            }
        } header: {
            DSSectionHeader(
                title: "Blocks",
                systemImage: "square.grid.2x2"
            )
        }
    }
}
