import Foundation
import SwiftData

/// Freezes a plan slot's session snapshots onto its `WorkoutItem`.
///
/// Moved verbatim out of `ActiveWorkoutView.populateSnapshotFields` so the
/// cold-resume path (`WorkoutResumeService.rebuildPlan`, which reads these
/// fields back for a switched slot) can be tested against exactly what a live
/// switch writes. The only change is that the switched-in exercise is passed in
/// rather than fetched here.
enum WorkoutItemSnapshotWriter {

    /// - Parameter liveSwappedExercise: the switched-in `Exercise` when the slot
    ///   was switched and that exercise still resolves; nil otherwise.
    @MainActor
    static func populate(
        _ item: WorkoutItem,
        from planEx: PlanExercise,
        liveSwappedExercise: Exercise?,
        in ctx: ModelContext
    ) {
        item.routineSlotID = planEx.routineSlotID
        item.templateNotesSnapshot = planEx.templateNotesSnapshot
        item.exerciseNameSnapshot = planEx.name
        if let payload = planEx.prescriptionSnapshot {
            let snapshot = payload.toModel()
            // Switch Exercise consistency: the `prescriptionSnapshot` payload
            // captured at session start still describes the ORIGINAL exercise's
            // equipment/setup (the keep-plan swap path preserves it verbatim),
            // while `item.exercise` / `exerciseNameSnapshot` already point at
            // the swapped-in exercise. History reads Equipment & Setup solely
            // from this frozen snapshot, so without this it would show the
            // switched exercise's NAME alongside the original's equipment/setup.
            // Freeze the swapped-in exercise's LIVE equipment/setup here —
            // mirroring the `resolvedSwappedValue` contract the live Active
            // Workout display uses — so finished History is internally
            // consistent. Frozen at snapshot time: later library edits never
            // mutate it (snapshot-immutability invariant preserved for the
            // non-swapped case, which keeps the snapshot values).
            let isSwapped =
                planEx.currentExerciseID != planEx.originalExerciseID
            let liveExercise = isSwapped ? liveSwappedExercise : nil
            let resolved = resolvedSnapshotEquipmentSetup(
                isSwapped: isSwapped && liveExercise != nil,
                liveEquipment: liveExercise?.equipmentType,
                liveSetup: liveExercise?.setupDefaults,
                snapshotEquipment: snapshot.equipment,
                snapshotSetup: snapshot.setupNotes
            )
            snapshot.equipment = resolved.equipment
            snapshot.setupNotes = resolved.setupNotes
            ctx.insert(snapshot)
            item.plannedPrescriptionSnapshot = snapshot
        }
        // Persist warmup steps so they survive a cold restart when the routine
        // may be unavailable (fallback resume path via planFromWorkoutItems).
        if !planEx.warmupStepsSnapshot.isEmpty {
            item.warmupStepsSnapshotData = try? JSONEncoder().encode(
                planEx.warmupStepsSnapshot
            )
        }
        // Persist technique plans for the same cold-restart reason.
        if !planEx.techniquePlansSnapshot.isEmpty {
            item.techniquePlansSnapshotData = try? JSONEncoder().encode(
                planEx.techniquePlansSnapshot
            )
        }
        // Phase 6.C1 — copy source-block snapshot for future History
        // superset grouping. Nil values (e.g. swap-target PlanExercise
        // built without block context in some edge case) propagate
        // through unchanged and the future display treats them as flat.
        item.sourceBlockSlotID = planEx.sourceBlockSlotID
        item.sourceBlockIsSuperset = planEx.sourceBlockIsSuperset
        item.sourceBlockOrder = planEx.sourceBlockOrder
        item.sourceExerciseOrderInBlock = planEx.sourceExerciseOrderInBlock
    }
}
