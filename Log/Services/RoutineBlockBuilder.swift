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

    /// Append one `RoutineExercise` slot per exercise to an existing superset
    /// `block`, in the given order. Each new slot takes a contiguous `order`
    /// after the current maximum, gets a fresh `slotID`, and a default
    /// `SlotPrescription` whose `sets` is coerced to the superset's shared
    /// value (`sharedSets`, falling back to `AppSettings.defaultSets` when it's
    /// `<= 0`) so the block-wide "Sets per exercise" invariant holds without an
    /// extra user touch. Existing slots are never mutated. Duplicate `Exercise`
    /// references intentionally produce distinct slots.
    ///
    /// Mirrors the prior single-slot `SupersetDetailNoRest.addExercise(_:)`
    /// exactly, generalized to N exercises.
    @discardableResult
    static func addExercisesToSuperset(
        _ exercises: [Exercise],
        to block: RoutineBlock,
        sharedSets: Int,
        in ctx: ModelContext
    ) -> [RoutineExercise] {
        guard !exercises.isEmpty else { return [] }

        var created: [RoutineExercise] = []
        for ex in exercises {
            let nextOrder = (block.exercises.map(\.order).max() ?? -1) + 1
            let re = RoutineExercise(exercise: ex, order: nextOrder, setTemplates: [])
            ctx.insert(re)
            let p = makeDefaultPrescription(isTimeBased: ex.isTimeBased, in: ctx)
            p.sets = sharedSets > 0 ? sharedSets : AppSettings.defaultSets
            re.prescription = p
            block.exercises.append(re)
            created.append(re)
        }
        try? ctx.save()
        return created
    }

    /// Duplicate `source` into the **same** `routine`, inserting the copy
    /// **immediately after** the source block. Every existing block ordered
    /// after the source shifts down by one (`order += 1`); the source block and
    /// all earlier blocks keep their `order`, so an already-contiguous block
    /// list stays contiguous (`0..<n+1`). This is the minimal-mutation form of
    /// the renumber already used by `RoutineEditor.moveBlocks` /
    /// `normalizeRoutineModel`.
    ///
    /// The deep copy itself is delegated to `RoutineDuplicator.copyBlock` — the
    /// new block and every child `RoutineExercise` get a **fresh** `slotID`;
    /// `isSuperset` / `restAfterSeconds` / `supersetRoundRestSeconds` are
    /// carried; `SetTemplate`s / `SlotPrescription` / `TechniquePlan`s /
    /// `WarmupScheme` + `WarmupStep`s are deep-copied; only the definition-level
    /// `Exercise` references are shared. The **source block is never mutated**,
    /// no `Workout` / history is touched, and `ctx.save()` runs **once** after
    /// the graph is built and orders are adjusted.
    ///
    /// `RoutineBlock` has no inverse-to-`Routine` relationship, so the owning
    /// `routine` is passed explicitly (the caller is responsible for `source`
    /// actually belonging to `routine`). No lock-gating here — that is enforced
    /// at the UI call site.
    @MainActor
    @discardableResult
    static func duplicateBlock(
        _ source: RoutineBlock,
        in routine: Routine,
        ctx: ModelContext
    ) -> RoutineBlock {
        let insertOrder = source.order + 1

        // Shift every block ordered after the source down by one *before* the
        // copy is appended, so the copy lands cleanly at `insertOrder` and the
        // list stays contiguous when the input was.
        for block in routine.blocks where block.order >= insertOrder {
            block.order += 1
        }

        let copy = RoutineDuplicator.copyBlock(source, in: ctx)
        copy.order = insertOrder
        routine.blocks.append(copy)

        try? ctx.save()
        return copy
    }
}
