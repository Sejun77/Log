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

    /// Bulk "Apply to all exercises" for a superset's set count. Writes
    /// `value` (clamped: `> 0` ⇒ the value, else `nil`) to every child slot's
    /// `prescription.sets`, then saves once. This is the explicit, opt-in bulk
    /// convenience behind the "Set All Exercises → Apply" button; it never runs
    /// while the user is merely adjusting a draft stepper. Per-slot counts
    /// remain independently editable afterwards (no enforced equality). Slots
    /// without a prescription are skipped.
    static func applySetCountToAll(
        _ value: Int,
        in block: RoutineBlock,
        ctx: ModelContext
    ) {
        for re in block.exercises {
            re.prescription?.sets = value > 0 ? value : nil
        }
        try? ctx.save()
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

    /// Delete an entire `RoutineBlock` from `routine` (the routine-editor swipe
    /// / edit-mode block delete, which for a single-exercise block is how the
    /// user "removes an exercise from the routine").
    ///
    /// Ordering is load-bearing and mirrors `removeExercises`:
    ///   1. Detach the block from `routine.blocks` **first** so the
    ///      `@Relationship` array never references the soon-to-be-deleted
    ///      block (a lingering tombstone reference is what
    ///      `normalizeRoutineModel` would later trip over).
    ///   2. Delete each child `RoutineExercise` (cascades its
    ///      `SlotPrescription` / templates), then the block itself.
    ///   3. Renormalize the surviving blocks' `order` to `0…n-1` so the
    ///      list stays contiguous.
    ///
    /// **No `#Predicate`/fetch.** The block is passed by reference. The prior
    /// implementation refetched it with `#Predicate<RoutineBlock> { $0.id == id }`;
    /// `RoutineBlock` has no stored `id` attribute, so `.id` is the computed
    /// `PersistentModel.persistentModelID` and SwiftData's
    /// `graph_keyPathToString(keypath:)` crashed translating that key path in
    /// release/TestFlight builds. `firstIndex(where:)` compares
    /// `persistentModelID` in memory (safe — no key-path-to-string), and works
    /// whether or not the caller has already detached the block (idempotent:
    /// the animated editor path removes the row before the deferred model
    /// mutation runs).
    static func deleteBlock(
        _ block: RoutineBlock,
        from routine: Routine,
        in ctx: ModelContext
    ) {
        if let idx = routine.blocks.firstIndex(where: {
            $0.persistentModelID == block.persistentModelID
        }) {
            routine.blocks.remove(at: idx)
        }

        // A child slot cascade-deleted when its `Exercise` was removed
        // (`Exercise.routineUsages` is `.cascade`) lingers in `block.exercises`
        // as an *invalidated* tombstone whose backing data is gone —
        // `RoutineExercise` declares no inverse to `RoutineBlock`, so SwiftData
        // never nullifies the block's array. Deleting the block would then
        // cascade into that dead backing data and fatally trap. Detach such
        // tombstones from the relationship FIRST — `persistentModelID` is safe
        // to read even on an invalidated instance, so filtering against the
        // store's live slots (the same guard `Routine.isStartable(in:)` uses)
        // never touches dead data. Predicate-free fetch — no key path.
        let liveSlotIDs: Set<PersistentIdentifier> = Set(
            ((try? ctx.fetch(FetchDescriptor<RoutineExercise>())) ?? [])
                .map(\.persistentModelID)
        )
        block.exercises.removeAll {
            !liveSlotIDs.contains($0.persistentModelID)
        }
        for re in block.exercises { ctx.delete(re) }
        ctx.delete(block)

        let sorted = routine.blocks.sorted { $0.order < $1.order }
        for (i, blk) in sorted.enumerated() { blk.order = i }
        try? ctx.save()
    }

    /// Remove specific child slots from a superset `block` (the per-exercise
    /// swipe delete inside `SupersetDetailNoRest`). Detaches the removed slots
    /// from the parent `@Relationship` array **first**, then deletes them
    /// (cascading their `SlotPrescription` / templates), then renormalizes the
    /// survivors' `order` to `0…n-1`.
    ///
    /// No min-count enforcement here — the "a superset keeps ≥ 2 exercises"
    /// guard stays at the UI call site (`removeExercise(at:)`). Membership is
    /// matched by `persistentModelID` in memory (no `#Predicate`, no fetch), so
    /// slots not belonging to `block`, or an empty `toRemove`, are safe no-ops.
    static func removeExercises(
        _ toRemove: [RoutineExercise],
        from block: RoutineBlock,
        in ctx: ModelContext
    ) {
        let removeIDs = Set(toRemove.map(\.persistentModelID))
        guard !removeIDs.isEmpty else { return }

        let survivors = block.exercises
            .filter { !removeIDs.contains($0.persistentModelID) }
            .sorted { $0.order < $1.order }

        // Detach from the parent FIRST so the @Relationship array no longer
        // references the soon-to-be-deleted children.
        block.exercises = survivors
        for re in toRemove where removeIDs.contains(re.persistentModelID) {
            ctx.delete(re)
        }
        for (i, re) in survivors.enumerated() { re.order = i }
        try? ctx.save()
    }
}
