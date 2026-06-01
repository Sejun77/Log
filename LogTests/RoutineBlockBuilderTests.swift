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

    // MARK: - Duplicate block (Slice 2)

    /// Append a single-slot block to `routine`. The slot links `exercise`
    /// (pass `nil` for a deleted/unlinked slot) and, by default, gets a
    /// prescription. Returns the created block.
    @discardableResult
    private func addBlock(
        to routine: Routine,
        exercise: Exercise?,
        order: Int,
        isSuperset: Bool = false,
        restAfterSeconds: Int? = nil,
        supersetRoundRestSeconds: Int? = nil,
        withPrescription: Bool = true
    ) -> RoutineBlock {
        let re: RoutineExercise
        if let exercise {
            re = RoutineExercise(exercise: exercise, order: 0, setTemplates: [])
        } else {
            re = RoutineExercise(
                exercise: Exercise(name: ""), order: 0, setTemplates: [])
            re.exercise = nil
        }
        context.insert(re)
        if withPrescription {
            let p = SlotPrescription(
                sets: 3, repMin: 8, repMax: 12, restSecondsBetweenSets: 90)
            context.insert(p)
            re.prescription = p
        }
        let block = RoutineBlock(
            isSuperset: isSuperset, order: order,
            restAfterSeconds: restAfterSeconds, exercises: [re])
        block.supersetRoundRestSeconds = supersetRoundRestSeconds
        context.insert(block)
        routine.blocks.append(block)
        try? context.save()
        return block
    }

    private func sortedBlocks(_ r: Routine) -> [RoutineBlock] {
        r.blocks.sorted { $0.order < $1.order }
    }

    // 1. Duplicate a normal single-exercise block, inserted after source.
    func testDuplicateNormalBlockInsertedAfterSource() {
        let r = makeRoutine()
        let a = makeExercise("A")
        let src = addBlock(to: r, exercise: a, order: 0)

        let copy = RoutineBlockBuilder.duplicateBlock(src, in: r, ctx: context)

        XCTAssertEqual(r.blocks.count, 2)
        XCTAssertEqual(copy.order, 1)
        XCTAssertFalse(copy.isSuperset)
        XCTAssertEqual(copy.exercises.count, 1)
        XCTAssertEqual(copy.exercises.first?.exercise?.id, a.id)
        // Copy lands immediately after the source.
        let sorted = sortedBlocks(r)
        XCTAssertTrue(sorted[0] === src)
        XCTAssertTrue(sorted[1] === copy)
    }

    // 2 + 14. Duplicate a superset block; superset fields preserved.
    func testDuplicateSupersetBlockPreservesFields() {
        let r = makeRoutine()
        let a = makeExercise("A")
        let src = addBlock(
            to: r, exercise: a, order: 0, isSuperset: true,
            restAfterSeconds: 45, supersetRoundRestSeconds: 120)

        let copy = RoutineBlockBuilder.duplicateBlock(src, in: r, ctx: context)

        XCTAssertTrue(copy.isSuperset)
        XCTAssertEqual(copy.restAfterSeconds, 45)
        XCTAssertEqual(copy.supersetRoundRestSeconds, 120)
    }

    // 3 + 4 + 5. Insert-after, later orders shift +1, contiguous result.
    func testDuplicateShiftsLaterBlocksAndStaysContiguous() {
        let r = makeRoutine()
        let a = makeExercise("A")
        let b = makeExercise("B")
        let c = makeExercise("C")
        let blockA = addBlock(to: r, exercise: a, order: 0)
        let blockB = addBlock(to: r, exercise: b, order: 1)
        let blockC = addBlock(to: r, exercise: c, order: 2)

        let copy = RoutineBlockBuilder.duplicateBlock(blockA, in: r, ctx: context)

        XCTAssertEqual(r.blocks.count, 4)
        // Contiguous 0..<4.
        XCTAssertEqual(sortedBlocks(r).map(\.order), [0, 1, 2, 3])
        // A(0), copy(1), B(2), C(3): relative order preserved, later shifted +1.
        let sorted = sortedBlocks(r)
        XCTAssertTrue(sorted[0] === blockA)
        XCTAssertTrue(sorted[1] === copy)
        XCTAssertTrue(sorted[2] === blockB)
        XCTAssertTrue(sorted[3] === blockC)
        XCTAssertEqual(blockA.order, 0)
        XCTAssertEqual(blockB.order, 2)
        XCTAssertEqual(blockC.order, 3)
    }

    // 6 + 7 + 8 + 9. Source unchanged; fresh slotIDs; shared Exercise.
    func testDuplicateFreshIdentitiesSharedExerciseSourceUnchanged() {
        let r = makeRoutine()
        let a = makeExercise("A")
        let src = addBlock(to: r, exercise: a, order: 0)
        let srcBlockSlotID = src.slotID
        let srcSlot = src.exercises[0]
        let srcSlotID = srcSlot.slotID
        let srcOrder = src.order

        let copy = RoutineBlockBuilder.duplicateBlock(src, in: r, ctx: context)

        // Fresh block + slot slotIDs.
        XCTAssertNotEqual(copy.slotID, srcBlockSlotID)
        XCTAssertNotEqual(copy.exercises[0].slotID, srcSlotID)
        // Shared definition-level Exercise (not cloned).
        XCTAssertEqual(copy.exercises[0].exercise?.id, a.id)
        XCTAssertTrue(copy.exercises[0].exercise === srcSlot.exercise)
        // Source block unchanged (identity, order, slotIDs preserved).
        XCTAssertEqual(src.slotID, srcBlockSlotID)
        XCTAssertEqual(src.order, srcOrder)
        XCTAssertEqual(src.exercises[0].slotID, srcSlotID)
        XCTAssertEqual(src.exercises.count, 1)
    }

    // 10. Prescription deep-copied + mutation-isolated.
    func testDuplicatePrescriptionDeepCopyIsolated() {
        let r = makeRoutine()
        let a = makeExercise("A")
        let src = addBlock(to: r, exercise: a, order: 0)
        src.exercises[0].prescription?.sets = 4

        let copy = RoutineBlockBuilder.duplicateBlock(src, in: r, ctx: context)
        let srcP = src.exercises[0].prescription
        let copyP = copy.exercises[0].prescription

        XCTAssertNotNil(copyP)
        XCTAssertFalse(copyP === srcP)
        XCTAssertEqual(copyP?.sets, 4)
        copyP?.sets = 9
        XCTAssertEqual(srcP?.sets, 4)
    }

    // 11. SetTemplates deep-copied + mutation-isolated.
    func testDuplicateSetTemplatesDeepCopyIsolated() {
        let r = makeRoutine()
        let a = makeExercise("A")
        let src = addBlock(
            to: r, exercise: a, order: 0, withPrescription: false)
        let tpl = SetTemplate(
            kind: .working, targetReps: 8, targetWeight: 60, restSecondsAfter: 90)
        tpl.order = 0
        context.insert(tpl)
        src.exercises[0].setTemplates = [tpl]
        try? context.save()

        let copy = RoutineBlockBuilder.duplicateBlock(src, in: r, ctx: context)
        let copyTpls = copy.exercises[0].setTemplates

        XCTAssertEqual(copyTpls.count, 1)
        XCTAssertFalse(copyTpls.first === tpl)
        XCTAssertEqual(copyTpls.first?.targetReps, 8)
        copyTpls.first?.targetReps = 5
        XCTAssertEqual(tpl.targetReps, 8)
    }

    // 12. TechniquePlans deep-copied.
    func testDuplicateTechniquePlansDeepCopied() {
        let r = makeRoutine()
        let a = makeExercise("A")
        let src = addBlock(to: r, exercise: a, order: 0)
        let plan = TechniquePlan(
            order: 0, type: .dropset, dropPercent: 20, dropCount: 2)
        context.insert(plan)
        src.exercises[0].prescription?.techniquePlans = [plan]
        try? context.save()

        let copy = RoutineBlockBuilder.duplicateBlock(src, in: r, ctx: context)
        let copyPlans = copy.exercises[0].prescription?.techniquePlans

        XCTAssertEqual(copyPlans?.count, 1)
        XCTAssertFalse(copyPlans?.first === plan)
        XCTAssertEqual(copyPlans?.first?.typeRaw, "dropset")
        XCTAssertEqual(copyPlans?.first?.dropPercent, 20)
        XCTAssertEqual(copyPlans?.first?.dropCount, 2)
    }

    // 13. WarmupScheme + steps deep-copied + mutation-isolated.
    func testDuplicateWarmupSchemeDeepCopyIsolated() {
        let r = makeRoutine()
        let a = makeExercise("A")
        let src = addBlock(to: r, exercise: a, order: 0)
        let scheme = WarmupScheme(name: "Warmup")
        context.insert(scheme)
        let step = WarmupStep(order: 0, kind: .percentage, percentOfWorking: 0.5)
        context.insert(step)
        scheme.steps = [step]
        src.exercises[0].prescription?.warmupScheme = scheme
        try? context.save()

        let copy = RoutineBlockBuilder.duplicateBlock(src, in: r, ctx: context)
        let copyScheme = copy.exercises[0].prescription?.warmupScheme

        XCTAssertEqual(copyScheme?.name, "Warmup")
        XCTAssertEqual(copyScheme?.steps.count, 1)
        XCTAssertFalse(copyScheme === scheme)
        XCTAssertFalse(copyScheme?.steps.first === step)
        copyScheme?.steps.first?.percentOfWorking = 0.9
        XCTAssertEqual(step.percentOfWorking, 0.5)
    }

    // 15. Nil-exercise / nil-prescription slot does not crash.
    func testDuplicateNilExerciseNilPrescriptionNoCrash() {
        let r = makeRoutine()
        let src = addBlock(
            to: r, exercise: nil, order: 0, withPrescription: false)

        let copy = RoutineBlockBuilder.duplicateBlock(src, in: r, ctx: context)

        XCTAssertEqual(r.blocks.count, 2)
        XCTAssertEqual(copy.order, 1)
        XCTAssertEqual(copy.exercises.count, 1)
        XCTAssertNil(copy.exercises[0].exercise)
        XCTAssertNil(copy.exercises[0].prescription)
    }
}
