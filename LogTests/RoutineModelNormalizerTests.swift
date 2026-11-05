import SwiftData
import XCTest

@testable import Log

/// Pins what opening a routine does to its stored data. Opening a routine that
/// is already normalized must write nothing, because a save there wakes every
/// loaded `@Query` screen; a routine that does need repair must still get it.
@MainActor
final class RoutineModelNormalizerTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func makeExercise(_ name: String = "Bench Press") -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        return ex
    }

    private func makeSlot(order: Int, orphan: Bool = false) -> RoutineExercise {
        let re = RoutineExercise(exercise: makeExercise(), order: order, setTemplates: [])
        context.insert(re)
        if orphan { re.exercise = nil }
        return re
    }

    private func makeBlock(
        order: Int, isSuperset: Bool = false, slots: [RoutineExercise]
    ) -> RoutineBlock {
        let b = RoutineBlock(isSuperset: isSuperset, order: order, exercises: slots)
        context.insert(b)
        return b
    }

    private func makeRoutine(_ blocks: [RoutineBlock]) -> Routine {
        let r = Routine(name: "Push Day", blocks: blocks)
        context.insert(r)
        try! context.save()
        return r
    }

    /// Runs the normalizer and returns how many saves actually carried changes.
    private func normalizeCountingSaves(_ routine: Routine) -> Int {
        var saves = 0
        let token = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: context, queue: nil
        ) { _ in saves += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        RoutineModelNormalizer.normalize(routine, in: context)
        return saves
    }

    private func orders(_ blocks: [RoutineBlock]) -> [Int] { blocks.map(\.order).sorted() }
    private func orders(_ slots: [RoutineExercise]) -> [Int] { slots.map(\.order).sorted() }

    private func prescription(sets: Int, reps: Int, rest: Int) -> SlotPrescription {
        let p = SlotPrescription()
        p.sets = sets
        p.repMax = reps
        p.restSecondsBetweenSets = rest
        context.insert(p)
        return p
    }

    // MARK: - Already normalized: no writes

    func test_alreadyNormalized_savesNothingAndLeavesContextClean() {
        let routine = makeRoutine([
            makeBlock(order: 0, slots: [makeSlot(order: 0), makeSlot(order: 1)]),
            makeBlock(order: 1, slots: [makeSlot(order: 0)]),
            makeBlock(order: 2, isSuperset: true, slots: [makeSlot(order: 0), makeSlot(order: 1)]),
        ])

        XCTAssertEqual(normalizeCountingSaves(routine), 0)
        XCTAssertFalse(context.hasChanges)
    }

    /// Generating templates to compare against must not leave anything pending.
    func test_prescriptionComparison_withoutAMatch_writesNothing() {
        let slot = makeSlot(order: 0)
        slot.prescription = prescription(sets: 3, reps: 8, rest: 90)
        let custom = SetTemplate(targetReps: 12)
        context.insert(custom)
        slot.setTemplates = [custom]
        let routine = makeRoutine([makeBlock(order: 0, slots: [slot])])

        XCTAssertEqual(normalizeCountingSaves(routine), 0)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(slot.setTemplates.count, 1)
    }

    // MARK: - Needs repair: still corrected

    func test_blockOrderGaps_areRenumberedInOrderAndSaved() {
        let first = makeBlock(order: 10, slots: [makeSlot(order: 0)])
        let second = makeBlock(order: 20, slots: [makeSlot(order: 0)])
        let third = makeBlock(order: 35, slots: [makeSlot(order: 0)])
        let routine = makeRoutine([third, first, second])

        XCTAssertEqual(normalizeCountingSaves(routine), 1)
        XCTAssertEqual([first.order, second.order, third.order], [0, 1, 2])
        XCTAssertFalse(context.hasChanges)
    }

    func test_slotOrderGaps_areRenumberedInOrderAndSaved() {
        let a = makeSlot(order: 4)
        let b = makeSlot(order: 9)
        let routine = makeRoutine([makeBlock(order: 0, slots: [b, a])])

        XCTAssertEqual(normalizeCountingSaves(routine), 1)
        XCTAssertEqual([a.order, b.order], [0, 1])
    }

    func test_duplicateOrders_becomeDistinct() {
        let routine = makeRoutine([
            makeBlock(order: 0, slots: [makeSlot(order: 1), makeSlot(order: 1)]),
            makeBlock(order: 0, slots: [makeSlot(order: 0)]),
        ])

        RoutineModelNormalizer.normalize(routine, in: context)

        XCTAssertEqual(orders(routine.blocks), [0, 1])
        let two = routine.blocks.first { $0.exercises.count == 2 }
        XCTAssertEqual(orders(two?.exercises ?? []), [0, 1])
    }

    /// Only the slot that was out of place changes; the rest stay as they were.
    func test_partialDisorder_isRepaired() {
        let a = makeSlot(order: 0)
        let b = makeSlot(order: 5)
        let routine = makeRoutine([makeBlock(order: 0, slots: [a, b])])

        XCTAssertEqual(normalizeCountingSaves(routine), 1)
        XCTAssertEqual([a.order, b.order], [0, 1])
    }

    func test_orphanedSlot_isDeleted_andSurvivorRenumbered() {
        let keep = makeSlot(order: 1)
        let orphan = makeSlot(order: 0, orphan: true)
        let routine = makeRoutine([makeBlock(order: 0, slots: [orphan, keep])])

        XCTAssertGreaterThanOrEqual(normalizeCountingSaves(routine), 1)

        XCTAssertEqual(try! context.fetch(FetchDescriptor<RoutineExercise>()).count, 1)
        XCTAssertEqual(keep.order, 0)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(normalizeCountingSaves(routine), 0, "second open has nothing to do")
        XCTAssertEqual(keep.order, 0)
    }

    /// Existing behavior: a superset with an orphaned slot is removed as a whole.
    /// The remaining blocks close the gap, and later opens write nothing.
    func test_orphanInSuperset_removesBlock_andRemainingBlocksRenumbered() {
        let before = makeBlock(order: 0, slots: [makeSlot(order: 0)])
        let superset = makeBlock(
            order: 1, isSuperset: true,
            slots: [makeSlot(order: 0, orphan: true), makeSlot(order: 1)])
        let after = makeBlock(order: 2, slots: [makeSlot(order: 0)])
        let routine = makeRoutine([before, superset, after])

        RoutineModelNormalizer.normalize(routine, in: context)

        XCTAssertEqual(try! context.fetch(FetchDescriptor<RoutineBlock>()).count, 2)
        XCTAssertEqual(try! context.fetch(FetchDescriptor<RoutineExercise>()).count, 2)
        XCTAssertEqual([before.order, after.order], [0, 1])
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(normalizeCountingSaves(routine), 0, "second open has nothing to do")
    }

    /// Existing behavior: superset slots keep their stored order.
    func test_supersetSlotOrders_areNotRenumbered() {
        let a = makeSlot(order: 3)
        let b = makeSlot(order: 7)
        let routine = makeRoutine([makeBlock(order: 0, isSuperset: true, slots: [a, b])])

        XCTAssertEqual(normalizeCountingSaves(routine), 0)
        XCTAssertEqual([a.order, b.order], [3, 7])
    }

    // MARK: - Set templates

    private func exactCopyTemplates(for p: SlotPrescription) -> [SetTemplate] {
        let generated = p.generateTemplates()
        generated.forEach { context.insert($0) }
        return generated
    }

    func test_templatesThatExactlyCopyPrescription_areCleared() {
        let slot = makeSlot(order: 0)
        let p = prescription(sets: 3, reps: 8, rest: 90)
        slot.prescription = p
        slot.setTemplates = exactCopyTemplates(for: p)
        let routine = makeRoutine([makeBlock(order: 0, slots: [slot])])

        XCTAssertEqual(normalizeCountingSaves(routine), 1)
        XCTAssertTrue(slot.setTemplates.isEmpty)
        XCTAssertEqual(normalizeCountingSaves(routine), 0, "second open has nothing to do")
    }

    func test_templatesThatDifferFromPrescription_areKept() {
        let slot = makeSlot(order: 0)
        let p = prescription(sets: 2, reps: 8, rest: 90)
        slot.prescription = p
        let templates = exactCopyTemplates(for: p)
        templates[1].targetReps = 5
        slot.setTemplates = templates
        let routine = makeRoutine([makeBlock(order: 0, slots: [slot])])

        XCTAssertEqual(normalizeCountingSaves(routine), 0)
        XCTAssertEqual(slot.setTemplates.count, 2)
    }

    func test_templates_withoutPrescriptionContent_areKept() {
        let slot = makeSlot(order: 0)
        let t = SetTemplate(targetReps: 8)
        context.insert(t)
        slot.setTemplates = [t]
        let routine = makeRoutine([makeBlock(order: 0, slots: [slot])])

        XCTAssertEqual(normalizeCountingSaves(routine), 0)
        XCTAssertEqual(slot.setTemplates.count, 1)
    }

    // MARK: - Repeat opens and pending edits

    func test_secondOpenAfterRepair_savesNothing() {
        let routine = makeRoutine([makeBlock(order: 7, slots: [makeSlot(order: 3)])])

        XCTAssertEqual(normalizeCountingSaves(routine), 1)
        XCTAssertEqual(normalizeCountingSaves(routine), 0)
    }

    /// Existing behavior kept: opening a routine flushes edits already pending.
    func test_pendingUnrelatedEdit_isStillFlushed() {
        let routine = makeRoutine([makeBlock(order: 0, slots: [makeSlot(order: 0)])])
        routine.notes = "edited"
        XCTAssertTrue(context.hasChanges)

        XCTAssertGreaterThanOrEqual(normalizeCountingSaves(routine), 1)
        XCTAssertFalse(context.hasChanges)
    }
}
