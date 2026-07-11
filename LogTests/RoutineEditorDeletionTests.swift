import SwiftData
import XCTest

@testable import Log

/// Regression coverage for the TestFlight crash on the routine-editor
/// **exercise/block deletion** path:
///
///   Open a routine → delete an exercise → crash in
///   `SwiftData.PersistentModel.graph_keyPathToString(keypath:)`.
///
/// Root cause: `RoutineEditor.deleteBlockSafely` refetched the block to delete
/// with `FetchDescriptor<RoutineBlock>(predicate: #Predicate { $0.id == id })`.
/// `RoutineBlock` has **no stored `id` attribute** (only `slotID`), so `.id`
/// resolves to `PersistentModel.persistentModelID` — a computed property.
/// SwiftData's `graph_keyPathToString(keypath:)` crashes translating that key
/// path in optimized (release/TestFlight) builds — the same failure mode
/// already fixed in `RoutineExercise.safeExercise(in:)`.
///
/// Fix: the deletion moved to `RoutineBlockBuilder.deleteBlock` /
/// `.removeExercises`, which operate on the in-memory model graph by reference
/// (`persistentModelID` compared in Swift — never a key-path `#Predicate`),
/// detaching from the parent `@Relationship` first, then deleting, then
/// renormalizing `order`. These tests pin that behavior across every deletion
/// shape the crash report and task enumerate.
@MainActor
final class RoutineEditorDeletionTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    @discardableResult
    private func makeExercise(name: String = "Bench Press") -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        return ex
    }

    @discardableResult
    private func makeSlot(exercise: Exercise?, order: Int = 0) -> RoutineExercise {
        // `RoutineExercise.init` requires a non-optional exercise; build with a
        // throwaway and null it when a nil-relationship slot is wanted.
        let seed = exercise ?? makeExercise(name: "seed")
        let re = RoutineExercise(exercise: seed, order: order, setTemplates: [])
        context.insert(re)
        if exercise == nil { re.exercise = nil }
        return re
    }

    @discardableResult
    private func makeBlock(
        exercises: [RoutineExercise],
        isSuperset: Bool = false,
        supersetRoundRestSeconds: Int? = nil,
        order: Int = 0
    ) -> RoutineBlock {
        let b = RoutineBlock(
            isSuperset: isSuperset, order: order, exercises: exercises
        )
        b.supersetRoundRestSeconds = supersetRoundRestSeconds
        context.insert(b)
        return b
    }

    @discardableResult
    private func makeRoutine(blocks: [RoutineBlock]) -> Routine {
        let r = Routine(name: "Push Day", blocks: blocks)
        context.insert(r)
        try? context.save()
        return r
    }

    private func fetchBlocks() -> [RoutineBlock] {
        (try? context.fetch(FetchDescriptor<RoutineBlock>())) ?? []
    }

    private func fetchSlots() -> [RoutineExercise] {
        (try? context.fetch(FetchDescriptor<RoutineExercise>())) ?? []
    }

    // MARK: - deleteBlock: normal single-exercise block

    /// Deleting an exercise from a normal (single-exercise, non-superset) block
    /// removes the block, its slot, and leaves the surviving blocks contiguous.
    func testDeleteExerciseFromNormalBlock() {
        let keepEx = makeExercise(name: "Squat")
        let dropEx = makeExercise(name: "Bench")
        let keep = makeBlock(exercises: [makeSlot(exercise: keepEx)], order: 0)
        let drop = makeBlock(exercises: [makeSlot(exercise: dropEx)], order: 1)
        let r = makeRoutine(blocks: [keep, drop])

        RoutineBlockBuilder.deleteBlock(drop, from: r, in: context)

        XCTAssertEqual(r.blocks.count, 1)
        XCTAssertEqual(r.blocks.first?.persistentModelID, keep.persistentModelID)
        // Survivor order renormalized to 0…n-1.
        XCTAssertEqual(r.blocks.first?.order, 0)
        // Block + its slot are gone from the store.
        XCTAssertEqual(fetchBlocks().count, 1)
        XCTAssertEqual(fetchSlots().count, 1)
    }

    /// Deleting the only exercise (i.e. the only block) empties the routine —
    /// an empty routine is a valid, non-crashing state.
    func testDeleteOnlyExerciseLeavesEmptyRoutine() {
        let block = makeBlock(exercises: [makeSlot(exercise: makeExercise())])
        let r = makeRoutine(blocks: [block])

        RoutineBlockBuilder.deleteBlock(block, from: r, in: context)

        XCTAssertTrue(r.blocks.isEmpty)
        XCTAssertTrue(fetchBlocks().isEmpty)
        XCTAssertTrue(fetchSlots().isEmpty)
        // Empty routine must not be startable and must not crash.
        XCTAssertFalse(r.isStartable(in: context))
    }

    /// Mirrors the editor's animated path: the block is detached from
    /// `routine.blocks` *before* the deferred `deleteBlock` runs. `deleteBlock`
    /// must be idempotent about the already-removed reference.
    func testDeleteBlockIsIdempotentWhenAlreadyDetached() {
        let a = makeBlock(exercises: [makeSlot(exercise: makeExercise(name: "A"))], order: 0)
        let b = makeBlock(exercises: [makeSlot(exercise: makeExercise(name: "B"))], order: 1)
        let r = makeRoutine(blocks: [a, b])

        // Simulate the withAnimation removal that happens first in the editor.
        r.blocks.removeAll { $0.persistentModelID == b.persistentModelID }
        // The deferred store mutation still deletes the captured block cleanly.
        RoutineBlockBuilder.deleteBlock(b, from: r, in: context)

        XCTAssertEqual(r.blocks.count, 1)
        XCTAssertEqual(fetchBlocks().count, 1)
        XCTAssertEqual(fetchSlots().count, 1)
    }

    /// Deleting a slot whose `Exercise` relationship is nil/deleted/stale must
    /// not read the dead relationship and must not crash.
    func testDeleteBlockWithNilExerciseSlot() {
        let block = makeBlock(exercises: [makeSlot(exercise: nil)])
        let r = makeRoutine(blocks: [block])

        RoutineBlockBuilder.deleteBlock(block, from: r, in: context)

        XCTAssertTrue(r.blocks.isEmpty)
        XCTAssertTrue(fetchBlocks().isEmpty)
    }

    func testDeleteBlockAfterLinkedExerciseDeleted() {
        let ex = makeExercise()
        let block = makeBlock(exercises: [makeSlot(exercise: ex)])
        let r = makeRoutine(blocks: [block])

        // Delete the underlying Exercise out from under the slot first.
        context.delete(ex)
        try? context.save()

        // Deleting the block must still succeed without touching the dead link.
        RoutineBlockBuilder.deleteBlock(block, from: r, in: context)

        XCTAssertTrue(r.blocks.isEmpty)
        XCTAssertTrue(fetchBlocks().isEmpty)
    }

    // MARK: - removeExercises: superset per-slot delete

    /// Removing one exercise from a superset detaches + deletes that slot,
    /// keeps the survivors, and renormalizes their order to 0…n-1.
    func testRemoveOneExerciseFromSuperset() {
        let re1 = makeSlot(exercise: makeExercise(name: "A"), order: 0)
        let re2 = makeSlot(exercise: makeExercise(name: "B"), order: 1)
        let re3 = makeSlot(exercise: makeExercise(name: "C"), order: 2)
        let block = makeBlock(
            exercises: [re1, re2, re3],
            isSuperset: true,
            supersetRoundRestSeconds: 60
        )
        let r = makeRoutine(blocks: [block])

        RoutineBlockBuilder.removeExercises([re2], from: block, in: context)

        XCTAssertEqual(block.exercises.count, 2)
        let survivingIDs = Set(block.exercises.map(\.persistentModelID))
        XCTAssertTrue(survivingIDs.contains(re1.persistentModelID))
        XCTAssertTrue(survivingIDs.contains(re3.persistentModelID))
        XCTAssertFalse(survivingIDs.contains(re2.persistentModelID))
        // Orders renormalized contiguously.
        XCTAssertEqual(
            block.exercises.map(\.order).sorted(), [0, 1]
        )
        // Slot removed from the store; routine still startable.
        XCTAssertEqual(fetchSlots().count, 2)
        XCTAssertTrue(r.isStartable(in: context))
    }

    /// Removing the last remaining exercise(s) from a block is a degenerate
    /// shape the UI guards against (min-2), but the helper must still not crash
    /// and must leave a valid empty block.
    func testRemoveLastExercisesFromBlock() {
        let re1 = makeSlot(exercise: makeExercise(name: "A"), order: 0)
        let re2 = makeSlot(exercise: makeExercise(name: "B"), order: 1)
        let block = makeBlock(
            exercises: [re1, re2],
            isSuperset: true,
            supersetRoundRestSeconds: 60
        )
        let r = makeRoutine(blocks: [block])

        RoutineBlockBuilder.removeExercises([re1, re2], from: block, in: context)

        XCTAssertTrue(block.exercises.isEmpty)
        XCTAssertTrue(fetchSlots().isEmpty)
        // Empty block contributes no content → routine not startable, no crash.
        XCTAssertFalse(r.isStartable(in: context))
    }

    /// An empty `toRemove` set is a safe no-op (no deletion, no order churn).
    func testRemoveExercisesEmptyIsNoOp() {
        let re1 = makeSlot(exercise: makeExercise(name: "A"), order: 0)
        let re2 = makeSlot(exercise: makeExercise(name: "B"), order: 1)
        let block = makeBlock(
            exercises: [re1, re2], isSuperset: true, supersetRoundRestSeconds: 60
        )
        makeRoutine(blocks: [block])

        RoutineBlockBuilder.removeExercises([], from: block, in: context)

        XCTAssertEqual(block.exercises.count, 2)
        XCTAssertEqual(fetchSlots().count, 2)
    }

    // MARK: - Startability & summaries after deletion

    /// After deleting a block, startability recomputes off the surviving blocks
    /// only — it must never read the deleted slot.
    func testStartabilityAfterDeletingOneOfTwoBlocks() {
        let a = makeBlock(exercises: [makeSlot(exercise: makeExercise(name: "A"))], order: 0)
        let b = makeBlock(exercises: [makeSlot(exercise: makeExercise(name: "B"))], order: 1)
        let r = makeRoutine(blocks: [a, b])

        XCTAssertTrue(r.isStartable(in: context))

        RoutineBlockBuilder.deleteBlock(a, from: r, in: context)

        // Still startable — the survivor has a resolvable exercise.
        XCTAssertTrue(r.isStartable(in: context))
    }

    /// Block prescription summaries regenerate cleanly after a deletion: the
    /// deleted block's `slotID` key disappears and no stale slot is read.
    func testSummaryGenerationAfterDeletion() {
        let keepEx = makeExercise(name: "Squat")
        let keepSlot = makeSlot(exercise: keepEx)
        keepSlot.prescription = SlotPrescription(sets: 3, repMin: 5, repMax: 5)
        let keep = makeBlock(exercises: [keepSlot], order: 0)

        let dropSlot = makeSlot(exercise: makeExercise(name: "Bench"))
        let drop = makeBlock(exercises: [dropSlot], order: 1)
        let r = makeRoutine(blocks: [keep, drop])

        RoutineBlockBuilder.deleteBlock(drop, from: r, in: context)

        let summaries = BlockPrescriptionSummary.map(for: r.blocks)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertNotNil(summaries[keep.slotID])
        XCTAssertNil(summaries[drop.slotID])
    }

    // MARK: - The remaining (SAFE) stored-scalar predicate

    /// Proves the one surviving `#Predicate { $0.id == id }` in `RoutineEditor`
    /// (`endActiveSessionIfAny`, over `Workout`) is safe: `Workout.id` is a
    /// real stored `@Attribute(.unique) var id: UUID`, so the key path maps to a
    /// stored column instead of the computed `persistentModelID` that crashes.
    func testFetchWorkoutByStoredID() {
        let w = Workout(items: [])
        context.insert(w)
        try? context.save()
        let id = w.id

        let d = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == id })
        let found = try? context.fetch(d).first

        XCTAssertEqual(found?.id, id)
    }
}
