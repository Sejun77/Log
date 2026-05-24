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

                        // Templates: when a swap is reconciled, mirror what
                        // `ActiveWorkoutView.swapExercise` does in 9-B2 —
                        // derive from the slot's prescription via
                        // `makeSwapDefaultTemplates` so the post-resume
                        // plan matches the in-memory plan that the
                        // RoutinesView resume banner already shows.
                        // Non-swap slots keep the original `resolvedTemplates`
                        // path (unchanged behavior).
                        let templates: [PlanSetTemplate]
                        if let swappedEx = swappedExerciseForTemplates {
                            templates = makeSwapDefaultTemplates(
                                forExerciseID: swappedEx.id,
                                isTimeBased: swappedEx.isTimeBased,
                                setsHint: re.prescription?.sets,
                                restBetweenSetsHint:
                                    re.prescription?.restSecondsBetweenSets,
                                durationMinHint:
                                    re.prescription?.durationMinSeconds,
                                durationMaxHint:
                                    re.prescription?.durationMaxSeconds
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
                                    restSecondsAfter: step.restSecondsAfter
                                )
                            }

                        let techniquePlansSnapshot: [TechniquePlanSnapshot] =
                            (re.prescription?.techniquePlans ?? [])
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
                                    note: tp.note,
                                    reps: tp.reps,
                                    appliesToRaw: tp.appliesToRaw,
                                    appliesToSetNumber: tp.appliesToSetNumber,
                                    appliesToSetIndicesRaw: tp.appliesToSetIndicesRaw.isEmpty ? nil : tp.appliesToSetIndicesRaw,
                                    dropsetEffortRaw: tp.dropsetEffortRaw,
                                    dropsetEffortReps: tp.dropsetEffortReps
                                )
                            }

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
                            templateNotesSnapshot: re.templateNotes,
                            // Phase 10-E: equipment + setup are sourced from
                            // the linked `Exercise`. Use the slot's original
                            // `ex` (re.exercise) — mirrors `makePlan` and
                            // preserves "snapshot captures the slot's
                            // original Exercise" semantics across swaps.
                            prescriptionSnapshot: re.prescription.map {
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
