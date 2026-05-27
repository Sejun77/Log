import SwiftData

/// Authoring-side helper for adding exercises to a routine. Extracted from the
/// view so the multi-add behavior (slot count, contiguous block order, unique
/// slotIDs, default prescriptions) is unit-testable on `SwiftDataTestHarness`
/// without instantiating `RoutineEditor`.
@MainActor
enum RoutineBlockBuilder {
    /// Append one **single-exercise, non-superset** `RoutineBlock` per exercise
    /// to `routine`, in the given order. Each new block takes a contiguous
    /// `order` after the current maximum; each new `RoutineExercise` gets a
    /// fresh `slotID` (model default) and a default `SlotPrescription`. Existing
    /// blocks/slots are never mutated. Duplicate `Exercise` references in
    /// `exercises` intentionally produce distinct slots.
    ///
    /// Mirrors `RoutineEditor.appendBlock(isSuperset: false, exercises: [ex])`
    /// exactly for the single-exercise case — supersets keep their own path.
    @discardableResult
    static func addSingleExerciseBlocks(
        _ exercises: [Exercise],
        to routine: Routine,
        in ctx: ModelContext
    ) -> [RoutineBlock] {
        guard !exercises.isEmpty else { return [] }

        var created: [RoutineBlock] = []
        for ex in exercises {
            let nextOrder = (routine.blocks.map(\.order).max() ?? -1) + 1
            let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
            ctx.insert(re)
            re.prescription = makeDefaultPrescription(
                isTimeBased: ex.isTimeBased, in: ctx)
            let block = RoutineBlock(
                isSuperset: false,
                order: nextOrder,
                restAfterSeconds: nil,
                exercises: [re]
            )
            ctx.insert(block)
            routine.blocks.append(block)
            created.append(block)
        }
        try? ctx.save()
        return created
    }
}
