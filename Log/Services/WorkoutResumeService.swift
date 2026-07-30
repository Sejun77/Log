import Foundation
import SwiftData

// MARK: - Workout Resume Service

/// Rebuilds a `WorkoutPlan` from persisted data so the app can resume
/// an active workout after a cold restart.
enum WorkoutResumeService {

    /// Attempt to rebuild a plan for the given workout.
    ///
    /// **Primary path** – `Workout.routineID` is set and the `Routine` still
    /// exists: rebuild from the routine template (same logic as
    /// `StartWorkoutFromRoutineView.makePlan()`).
    ///
    /// **Fallback path** – routine is missing or `routineID` is nil: build a
    /// flat single-exercise-per-block plan from `Workout.items`.
    @MainActor
    static func rebuildPlan(
        for workout: Workout,
        in context: ModelContext
    ) -> WorkoutPlan? {
        // Try the primary (routine-based) path first.
        if let routineID = workout.routineID {
            let descriptor = FetchDescriptor<Routine>(
                predicate: #Predicate { $0.id == routineID }
            )
            if let routine = try? context.fetch(descriptor).first {
                return planFromRoutine(
                    routine, workout: workout,
                    workoutName: workout.routineName
                )
            }
        }

        // Fallback: build from workout items.
        return planFromWorkoutItems(workout)
    }

    // MARK: - Primary Path

    /// Mirrors `StartWorkoutFromRoutineView.makePlan(from:)`.
    /// Also reconciles exercise swaps: if the in-progress workout has a
    /// `WorkoutItem` for a given slot (matched by `routineSlotID`) whose
    /// `exercise` differs from the routine template's exercise, the plan
    /// reflects the swapped exercise (currentExerciseID / name updated).
    private static func planFromRoutine(
        _ routine: Routine,
        workout: Workout,
        workoutName: String?
    ) -> WorkoutPlan {
        // Build a slotID → WorkoutItem lookup for swap reconciliation.
        let itemsBySlotID: [UUID: WorkoutItem] = Dictionary(
            workout.items.compactMap { item -> (UUID, WorkoutItem)? in
                guard let slotID = item.routineSlotID else { return nil }
                return (slotID, item)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let blocks: [PlanBlock] = routine.blocks
            .sorted { $0.order < $1.order }
            .compactMap { b -> PlanBlock? in
                let exs: [PlanExercise] = b.exercises
                    .sorted { $0.order < $1.order }
                    .compactMap { re in
                        guard let ex = re.exercise else { return nil }

                        // Swap reconciliation: if the workout has a WorkoutItem
                        // for this slot whose exercise differs from the routine
                        // slot's exercise, use the swapped exercise's ID,
                        // name, mode, and notes. Pre-9-B2 bug-fix only
                        // reconciled name + currentExerciseID, leaving
                        // `isTimeBased` and `templates` reflecting the
                        // original — so a rep ↔ duration swap would show
                        // the new exercise's name but the old mode after
                        // a cold-restart resume.
                        var currentID = ex.id
                        var currentName = ex.name
                        var currentIsTimeBased = ex.isTimeBased
                        var currentNotes = ex.notes
                        var swappedExerciseForTemplates: Exercise? = nil
                        if let item = itemsBySlotID[re.slotID],
                           let swappedEx = item.exercise,
                           swappedEx.id != ex.id
                        {
                            currentID = swappedEx.id
                            currentName = swappedEx.name
                            currentIsTimeBased = swappedEx.isTimeBased
                            currentNotes = swappedEx.notes
                            swappedExerciseForTemplates = swappedEx
                        } else if let item = itemsBySlotID[re.slotID],
                                  item.exercise == nil,
                                  let snap = item.exerciseNameSnapshot,
                                  !snap.isEmpty
                        {
                            // Exercise was deleted — keep original plan name
                            currentName = snap
                        }

                        // Entry #12 P1: a swapped slot's authoritative plan is
                        // the one the switch already froze onto its
                        // `WorkoutItem.plannedPrescriptionSnapshot` (written by
                        // `populateSnapshotFields` from the
                        // `ExerciseSwitchPlanAdapter` outcome). Read THAT here
                        // rather than re-deriving from `re.prescription`, which
                        // still describes the routine's original exercise —
                        // re-deriving is what made a cold resume show the
                        // template's set count and the replaced exercise's
                        // tracking type (duration fields on a reps/weight
                        // exercise).
                        //
                        // A workout swapped BEFORE this fix shipped has no
                        // adapted snapshot to restore. Rather than fall back to
                        // the raw template payload (which would put the
                        // replaced exercise's tracking type and tempo back on
                        // screen), run the same keep-plan adaptation the live
                        // switch would have run, so legacy in-flight sessions
                        // heal into a valid single-mode prescription too.
                        let swappedSessionSnapshot: PrescriptionSnapshotPayload? =
                            swappedExerciseForTemplates.map { swappedEx in
                                if let frozen = itemsBySlotID[re.slotID]?
                                    .plannedPrescriptionSnapshot
                                    .map(PrescriptionSnapshotPayload.init(from:))
                                {
                                    return frozen
                                }
                                let templatePayload = re.prescription.map {
                                    PrescriptionSnapshotPayload(
                                        from: $0, exercise: ex)
                                }
                                let outcome = ExerciseSwitchPlanAdapter.outcome(
                                    choice: .keepCurrentPlan,
                                    current: templatePayload.map {
                                        SessionPlan(
                                            from: $0, notes: re.templateNotes)
                                    },
                                    oldIsTimeBased: ex.isTimeBased,
                                    newIsTimeBased: swappedEx.isTimeBased,
                                    resetSource: .appDefaults(
                                        isTimeBased: swappedEx.isTimeBased)
                                )
                                return ExerciseSwitchPlanAdapter.adaptedSnapshot(
                                    from: outcome,
                                    base: templatePayload,
                                    equipment: swappedEx.equipmentType,
                                    setupNotes: swappedEx.setupDefaults
                                )
                            }

                        // Templates: when a swap is reconciled, mirror what
                        // `ActiveWorkoutView.swapExercise` does in 9-B2 —
                        // derive via `makeSwapDefaultTemplates` so the
                        // post-resume plan matches the in-memory plan that the
                        // RoutinesView resume banner already shows. Hints come
                        // from the session snapshot above, falling back to the
                        // template only for a pre-Entry-#12 workout whose swap
                        // predates the frozen session snapshot.
                        let templates: [PlanSetTemplate]
                        if let swappedEx = swappedExerciseForTemplates {
                            let hints = swappedSessionSnapshot
                            templates = makeSwapDefaultTemplates(
                                forExerciseID: swappedEx.id,
                                isTimeBased: swappedEx.isTimeBased,
                                setsHint: hints?.sets ?? re.prescription?.sets,
                                restBetweenSetsHint:
                                    hints?.restSecondsBetweenSets
                                    ?? re.prescription?.restSecondsBetweenSets,
                                durationMinHint:
                                    hints?.durationMinSeconds
                                    ?? re.prescription?.durationMinSeconds,
                                durationMaxHint:
                                    hints?.durationMaxSeconds
                                    ?? re.prescription?.durationMaxSeconds
                            )
                        } else {
                            templates = re.resolvedTemplates().enumerated()
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
                        }

                        // Entry #12 P1: a swapped slot's warm-up / technique
                        // state was already resolved at switch time and frozen
                        // onto the `WorkoutItem` — the routine template's own
                        // steps belong to the exercise that was replaced, so
                        // re-reading them here would resurrect warm-ups and
                        // techniques the switch deliberately cleared. Decode
                        // the persisted session snapshots instead (the same
                        // JSON the fallback `planFromWorkoutItems` path reads).
                        let swappedItem = swappedExerciseForTemplates == nil
                            ? nil
                            : itemsBySlotID[re.slotID]

                        let warmupStepsSnapshot: [WarmupStepSnapshot] =
                            swappedExerciseForTemplates != nil
                            ? (swappedItem?.warmupStepsSnapshotData
                                .flatMap {
                                    try? JSONDecoder().decode(
                                        [WarmupStepSnapshot].self, from: $0)
                                } ?? [])
                            : (re.prescription?.warmupScheme?.steps ?? [])
                            .sorted { $0.order < $1.order }
                            .map { step in
                                WarmupStepSnapshot(
                                    order: step.order,
                                    kind: step.kind,
                                    reps: step.reps,
                                    percentOfWorking: step.percentOfWorking,
                                    note: step.note,
                                    restSecondsAfter: step.restSecondsAfter
                                )
                            }

                        // Mirrors `makePlan`: techniques the slot's exercise
                        // can't support (e.g. a Tempo Override on a duration
                        // exercise) are dropped at capture time.
                        let templateTechniquePlansSnapshot: [TechniquePlanSnapshot] =
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

                        let techniquePlansSnapshot: [TechniquePlanSnapshot] =
                            swappedExerciseForTemplates != nil
                            ? (swappedItem?.techniquePlansSnapshotData
                                .flatMap {
                                    try? JSONDecoder().decode(
                                        [TechniquePlanSnapshot].self, from: $0)
                                } ?? [])
                            : templateTechniquePlansSnapshot

                        return PlanExercise(
                            id: ex.id,
                            routineExerciseID: re.id,
                            originalExerciseID: ex.id,
                            currentExerciseID: currentID,
                            name: currentName,
                            notes: currentNotes,
                            templates: templates,
                            isTimeBased: currentIsTimeBased,
                            routineSlotID: re.slotID,
                            // A swapped slot's prescription note is whatever the
                            // switch resolved (normally cleared — the routine's
                            // note described the replaced exercise). Only a
                            // non-swapped slot reads `re.templateNotes`.
                            templateNotesSnapshot:
                                swappedExerciseForTemplates != nil
                                ? swappedItem?.templateNotesSnapshot
                                : re.templateNotes,
                            // Phase 10-E: equipment + setup are sourced from
                            // the linked `Exercise`. Use the slot's original
                            // `ex` (re.exercise) — mirrors `makePlan` and
                            // preserves "snapshot captures the slot's
                            // original Exercise" semantics for NON-swapped
                            // slots. A swapped slot instead restores the
                            // session snapshot the switch froze, so its
                            // tracking type, set count, tempo, and
                            // equipment/setup all describe the switched-in
                            // exercise.
                            prescriptionSnapshot: swappedSessionSnapshot
                                ?? re.prescription.map {
                                    PrescriptionSnapshotPayload(
                                        from: $0, exercise: ex
                                    )
                                },
                            techniquePlansSnapshot: techniquePlansSnapshot,
                            warmupStepsSnapshot: warmupStepsSnapshot,
                            // Phase 6.C1 — mirror makePlan(from:)'s block snapshot
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
            routineName: workoutName ?? routine.name,
            routineVariantID: workout.routineVariantID,
            blocks: blocks
        )
    }

    // MARK: - Fallback Path

    /// Builds a flat plan from existing `WorkoutItem`s when the routine
    /// has been deleted. Each item becomes its own single-exercise block.
    private static func planFromWorkoutItems(
        _ workout: Workout
    ) -> WorkoutPlan? {
        let items = workout.items
        guard !items.isEmpty else { return nil }

        let blocks: [PlanBlock] = items.compactMap { item in
            guard let ex = item.exercise else { return nil }

            // Reconstruct templates from set logs already recorded
            let templates: [PlanSetTemplate] = item.setLogs
                .sorted { $0.indexInExercise < $1.indexInExercise }
                .enumerated()
                .map { (i, log) in
                    PlanSetTemplate(
                        id: "\(ex.id.uuidString)-set\(i)",
                        kind: log.kind,
                        targetReps: log.reps,
                        targetWeight: log.weight.map { Int($0.rounded()) },
                        restSecondsAfter: log.restSeconds,
                        durationSeconds: log.durationSeconds
                    )
                }

            // If no logs yet, build from the prescription snapshot
            let finalTemplates: [PlanSetTemplate]
            if templates.isEmpty, let snap = item.plannedPrescriptionSnapshot {
                let payload = PrescriptionSnapshotPayload(from: snap)
                let count = max(1, payload.sets ?? 3)
                finalTemplates = (0..<count).map { i in
                    PlanSetTemplate(
                        id: "\(ex.id.uuidString)-set\(i)",
                        kind: .working,
                        targetReps: payload.repMax ?? payload.repMin ?? 8,
                        targetWeight: nil,
                        restSecondsAfter: payload.restSecondsBetweenSets,
                        durationSeconds: payload.usesDuration
                            ? (payload.durationMaxSeconds ?? payload.durationMinSeconds)
                            : nil
                    )
                }
            } else if templates.isEmpty {
                // No logs and no PlannedPrescriptionSnapshot — synthesize
                // default working rows via the same Phase 9-B2 helper used
                // by mid-workout swaps. Phase 9-C1 removed the prior read
                // of `ex.defaultTemplates` here; that field is being
                // phased out as a runtime source. Accepted losses vs.
                // pre-9-C1 in this orphan branch: `targetWeight`, the
                // warmup/dropset row kinds, and per-row rest values that
                // `Exercise.defaultTemplates` could carry no longer
                // surface — the orphan plan starts with N uniform
                // `.working` rows at AppSettings defaults.
                finalTemplates = makeSwapDefaultTemplates(
                    forExerciseID: ex.id,
                    isTimeBased: ex.isTimeBased,
                    setsHint: nil,
                    restBetweenSetsHint: nil,
                    durationMinHint: nil,
                    durationMaxHint: nil
                )
            } else {
                finalTemplates = templates
            }

            let prescriptionPayload = item.plannedPrescriptionSnapshot
                .map(PrescriptionSnapshotPayload.init(from:))

            // Decode persisted snapshots (written by populateSnapshotFields at session start).
            let warmupStepsSnapshot: [WarmupStepSnapshot] =
                item.warmupStepsSnapshotData
                    .flatMap { try? JSONDecoder().decode([WarmupStepSnapshot].self, from: $0) }
                ?? []

            let techniquePlansSnapshot: [TechniquePlanSnapshot] =
                item.techniquePlansSnapshotData
                    .flatMap { try? JSONDecoder().decode([TechniquePlanSnapshot].self, from: $0) }
                ?? []

            return PlanBlock(
                isSuperset: false,
                restAfterSeconds: nil,
                supersetRoundRestSeconds: nil,
                exercises: [
                    PlanExercise(
                        id: ex.id,
                        routineExerciseID: item.persistentModelID,
                        originalExerciseID: ex.id,
                        currentExerciseID: ex.id,
                        name: ex.name,
                        notes: ex.notes,
                        templates: finalTemplates,
                        isTimeBased: ex.isTimeBased,
                        routineSlotID: item.routineSlotID ?? UUID(),
                        templateNotesSnapshot: item.templateNotesSnapshot,
                        prescriptionSnapshot: prescriptionPayload,
                        techniquePlansSnapshot: techniquePlansSnapshot,
                        warmupStepsSnapshot: warmupStepsSnapshot,
                        // Phase 6.C1 — preserve block snapshot fields when
                        // resuming from an orphaned WorkoutItem. Legacy
                        // pre-6.C1 items have nil for all four; the future
                        // History display path treats nil as "render flat".
                        sourceBlockSlotID: item.sourceBlockSlotID,
                        sourceBlockIsSuperset: item.sourceBlockIsSuperset,
                        sourceBlockOrder: item.sourceBlockOrder,
                        sourceExerciseOrderInBlock: item.sourceExerciseOrderInBlock
                    )
                ]
            )
        }

        guard !blocks.isEmpty else { return nil }

        return WorkoutPlan(
            routineID: workout.routineID ?? UUID(),
            routineName: workout.routineName ?? "Resumed Workout",
            routineVariantID: workout.routineVariantID,
            blocks: blocks
        )
    }
}
