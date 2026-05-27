import SwiftData
import XCTest

@testable import Log

/// Authoring-behavior tests for the multi-select "Add Exercise" path
/// (`RoutineBlockBuilder.addSingleExerciseBlocks`). Pins: one block per
/// exercise in order, contiguous block order, unique slotIDs, duplicate picks
/// → distinct slots, default prescription per slot, and no mutation on empty
/// input / to existing blocks.
@MainActor
final class RoutineBlockBuilderTests: SwiftDataTestHarness {

    @discardableResult
    private func makeExercise(_ name: String) -> Exercise {
        let e = Exercise(name: name)
        context.insert(e)
        return e
    }

    private func makeRoutine(_ name: String = "R") -> Routine {
        let r = Routine(name: name, blocks: [])
        context.insert(r)
        return r
    }

    func testAddsOneBlockPerExerciseInTapOrder() {
        let r = makeRoutine()
        let a = makeExercise("A")
        let b = makeExercise("B")
        let c = makeExercise("C")

        RoutineBlockBuilder.addSingleExerciseBlocks([a, b, c], to: r, in: context)

        XCTAssertEqual(r.blocks.count, 3)
        let sorted = r.blocks.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.map(\.order), [0, 1, 2])
        XCTAssertTrue(sorted.allSatisfy { !$0.isSuperset })
        XCTAssertTrue(sorted.allSatisfy { $0.exercises.count == 1 })
        XCTAssertEqual(
            sorted.compactMap { $0.exercises.first?.exercise?.name },
            ["A", "B", "C"]
        )
    }

    func testEachAddedSlotHasUniqueSlotID() {
        let r = makeRoutine()
        let xs = [makeExercise("A"), makeExercise("B"), makeExercise("C")]

        RoutineBlockBuilder.addSingleExerciseBlocks(xs, to: r, in: context)

        let slotIDs = r.blocks.compactMap { $0.exercises.first?.slotID }
        XCTAssertEqual(slotIDs.count, 3)
        XCTAssertEqual(Set(slotIDs).count, 3, "RoutineExercise slotIDs must be unique")
        XCTAssertEqual(
            Set(r.blocks.map(\.slotID)).count, 3, "RoutineBlock slotIDs must be unique")
    }

    func testDuplicateExercisesProduceDistinctSlots() {
        let r = makeRoutine()
        let a = makeExercise("A")

        RoutineBlockBuilder.addSingleExerciseBlocks([a, a], to: r, in: context)

        XCTAssertEqual(r.blocks.count, 2)
        let slots = r.blocks.compactMap { $0.exercises.first }
        XCTAssertEqual(slots.count, 2)
        XCTAssertNotEqual(
            slots[0].slotID, slots[1].slotID,
            "Two slots of the same Exercise must have distinct slotIDs")
        XCTAssertEqual(slots.compactMap { $0.exercise?.id }, [a.id, a.id])
    }

    func testContiguousOrderAfterExistingBlocksAndNoMutation() {
        let r = makeRoutine()
        let a = makeExercise("A")
        let b = makeExercise("B")

        RoutineBlockBuilder.addSingleExerciseBlocks([a], to: r, in: context)  // order 0
        let firstBlock = r.blocks.first
        let firstOrder = firstBlock?.order
        let firstSlotID = firstBlock?.exercises.first?.slotID

        RoutineBlockBuilder.addSingleExerciseBlocks([b], to: r, in: context)  // order 1

        XCTAssertEqual(r.blocks.map(\.order).sorted(), [0, 1])
        // The pre-existing block is untouched.
        let blockA = r.blocks.first { $0.exercises.first?.exercise?.name == "A" }
        XCTAssertEqual(blockA?.order, firstOrder)
        XCTAssertEqual(blockA?.exercises.first?.slotID, firstSlotID)
    }

    func testEmptyInputCausesNoMutation() {
        let r = makeRoutine()
        let a = makeExercise("A")
        RoutineBlockBuilder.addSingleExerciseBlocks([a], to: r, in: context)
        let before = r.blocks.count

        let created = RoutineBlockBuilder.addSingleExerciseBlocks([], to: r, in: context)

        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(r.blocks.count, before)
    }

    func testEachSlotGetsDefaultPrescription() {
        let r = makeRoutine()
        let a = makeExercise("A")

        RoutineBlockBuilder.addSingleExerciseBlocks([a], to: r, in: context)

        let re = r.blocks.first?.exercises.first
        XCTAssertNotNil(re?.prescription)
        XCTAssertEqual(re?.prescription?.sets, AppSettings.defaultSets)
    }

    // MARK: - Existing-superset multi-add (Slice B)

    /// Build a superset block (attached to `routine`) with one slot per name,
    /// each slot's `prescription.sets` seeded to `sets`.
    private func makeSupersetBlock(
        on routine: Routine, sets: Int, _ names: String...
    ) -> RoutineBlock {
        var slots: [RoutineExercise] = []
        for (i, n) in names.enumerated() {
            let ex = makeExercise(n)
            let re = RoutineExercise(exercise: ex, order: i, setTemplates: [])
            context.insert(re)
            let p = makeDefaultPrescription(isTimeBased: false, in: context)
            p.sets = sets
            re.prescription = p
            slots.append(re)
        }
        let block = RoutineBlock(
            isSuperset: true, order: 0, restAfterSeconds: nil, exercises: slots)
        context.insert(block)
        routine.blocks.append(block)
        try? context.save()
        return block
    }

    func testSupersetAddAppendsSlotsInTapOrder() {
        let r = makeRoutine()
        let block = makeSupersetBlock(on: r, sets: 4, "A", "B")

        RoutineBlockBuilder.addExercisesToSuperset(
            [makeExercise("C"), makeExercise("D")],
            to: block, sharedSets: 4, in: context)

        XCTAssertEqual(block.exercises.count, 4)
        let sorted = block.exercises.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.map(\.order), [0, 1, 2, 3])
        XCTAssertEqual(
            sorted.compactMap { $0.exercise?.name }, ["A", "B", "C", "D"])
    }

    func testSupersetAddSlotsHaveUniqueSlotIDs() {
        let r = makeRoutine()
        let block = makeSupersetBlock(on: r, sets: 3, "A", "B")

        RoutineBlockBuilder.addExercisesToSuperset(
            [makeExercise("C"), makeExercise("D")],
            to: block, sharedSets: 3, in: context)

        let ids = block.exercises.map(\.slotID)
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(Set(ids).count, 4)
    }

    func testSupersetAddDuplicatesProduceDistinctSlots() {
        let r = makeRoutine()
        let block = makeSupersetBlock(on: r, sets: 3, "A", "B")
        let dup = makeExercise("Dup")

        RoutineBlockBuilder.addExercisesToSuperset(
            [dup, dup], to: block, sharedSets: 3, in: context)

        XCTAssertEqual(block.exercises.count, 4)
        let dupSlots = block.exercises.filter { $0.exercise?.id == dup.id }
        XCTAssertEqual(dupSlots.count, 2)
        XCTAssertNotEqual(dupSlots[0].slotID, dupSlots[1].slotID)
    }

    func testSupersetAddContiguousOrderAndExistingUnchanged() {
        let r = makeRoutine()
        let block = makeSupersetBlock(on: r, sets: 3, "A", "B")
        let existing = block.exercises.sorted { $0.order < $1.order }
        let existingSlotIDs = existing.map(\.slotID)
        let existingOrders = existing.map(\.order)
        let existingSets = existing.compactMap { $0.prescription?.sets }

        RoutineBlockBuilder.addExercisesToSuperset(
            [makeExercise("C")], to: block, sharedSets: 3, in: context)

        let afterExisting =
            block.exercises
            .filter { existingSlotIDs.contains($0.slotID) }
            .sorted { $0.order < $1.order }
        XCTAssertEqual(afterExisting.map(\.slotID), existingSlotIDs)
        XCTAssertEqual(afterExisting.map(\.order), existingOrders)
        XCTAssertEqual(
            afterExisting.compactMap { $0.prescription?.sets }, existingSets)

        let newSlot = block.exercises.first { $0.exercise?.name == "C" }
        XCTAssertEqual(newSlot?.order, 2)
    }

    func testSupersetAddInheritsSharedSets() {
        let r = makeRoutine()
        let block = makeSupersetBlock(on: r, sets: 5, "A", "B")

        RoutineBlockBuilder.addExercisesToSuperset(
            [makeExercise("C")], to: block, sharedSets: 5, in: context)

        let newSlot = block.exercises.first { $0.exercise?.name == "C" }
        XCTAssertEqual(newSlot?.prescription?.sets, 5)
    }

    func testSupersetAddSharedSetsZeroFallsBackToDefault() {
        let r = makeRoutine()
        let block = makeSupersetBlock(on: r, sets: 3, "A", "B")

        RoutineBlockBuilder.addExercisesToSuperset(
            [makeExercise("C")], to: block, sharedSets: 0, in: context)

        let newSlot = block.exercises.first { $0.exercise?.name == "C" }
        XCTAssertEqual(newSlot?.prescription?.sets, AppSettings.defaultSets)
    }

    func testSupersetAddEmptyInputCausesNoMutation() {
        let r = makeRoutine()
        let block = makeSupersetBlock(on: r, sets: 3, "A", "B")
        let before = block.exercises.count

        let created = RoutineBlockBuilder.addExercisesToSuperset(
            [], to: block, sharedSets: 3, in: context)

        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(block.exercises.count, before)
    }
}
