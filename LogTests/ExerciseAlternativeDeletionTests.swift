import SwiftData
import XCTest

@testable import Log

/// Build 10 C1 — deleting an `Exercise` that routines reference as a prepared
/// alternative.
///
/// Before this slice, deleting such an exercise removed its direct routine
/// slots and left every prepared alternative pointing at a model that no longer
/// existed. Those dangling references resurfaced mid-workout as disabled
/// `Exercise unavailable` rows in the switch sheet, in routines the user had no
/// way to repair, and the delete confirmation never mentioned them.
///
/// What these pin:
///
///  1. **The confirmation tells the truth.** It names the prepared alternatives
///     and their count, and it still says exactly what it always said about
///     direct routine usage.
///  2. **The cleanup is complete and surgical.** Matching alternatives are
///     pruned from every slot; non-matching ones survive with their ids, their
///     prescriptions, and a dense `order`; the last one removed clears the
///     column to nil rather than storing an empty payload.
///  3. **Stored data cannot break it.** A corrupt alternatives column is left
///     alone rather than crashing or being silently rewritten.
@MainActor
final class ExerciseAlternativeDeletionTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func makeExercise(name: String) -> Exercise {
        let e = Exercise(name: name)
        context.insert(e)
        return e
    }

    private func makeRoutine(name: String, order: Int = 0) -> Routine {
        let r = Routine(name: name, blocks: [])
        context.insert(r)
        r.order = order
        return r
    }

    @discardableResult
    private func addSlot(
        to routine: Routine, exercise: Exercise, isSuperset: Bool = false,
        partner: Exercise? = nil
    ) -> SlotPrescription {
        let prescription = SlotPrescription()
        context.insert(prescription)
        let slot = RoutineExercise(exercise: exercise, order: 0, setTemplates: [])
        context.insert(slot)
        slot.prescription = prescription

        var slots = [slot]
        if let partner {
            let p = RoutineExercise(exercise: partner, order: 1, setTemplates: [])
            context.insert(p)
            let pp = SlotPrescription()
            context.insert(pp)
            p.prescription = pp
            slots.append(p)
        }

        let block = RoutineBlock(
            isSuperset: isSuperset,
            order: (routine.blocks.map(\.order).max() ?? -1) + 1,
            exercises: slots
        )
        context.insert(block)
        routine.blocks.append(block)
        return prescription
    }

    @discardableResult
    private func addAlternative(
        _ exercise: Exercise, to prescription: SlotPrescription,
        note: String? = nil
    ) -> SlotAlternative {
        SlotAlternativeAuthoring.append(
            exerciseID: exercise.id,
            exerciseName: exercise.name,
            prescription: AlternativePrescriptionPayload(sets: 4, repMin: 6),
            to: prescription)
    }

    private func allRoutines() -> [Routine] {
        (try? context.fetch(FetchDescriptor<Routine>())) ?? []
    }

    // MARK: - 1. Impact message

    func testMessageForUnusedExerciseIsUnchanged() {
        let target = makeExercise(name: "Never Used")
        let impact = ExerciseDeletionImpact(
            routines: allRoutines(), exerciseID: target.id)

        XCTAssertFalse(impact.isUsed)
        XCTAssertEqual(
            impact.message(exerciseName: "Never Used"),
            "Delete “Never Used”? This cannot be undone.")
    }

    /// The direct-usage sentence is the pre-C1 wording, word for word — this
    /// slice deliberately changes nothing about it.
    func testMessageForDirectUsageOnlyIsUnchanged() {
        let target = makeExercise(name: "Bench Press")
        let routine = makeRoutine(name: "Push")
        addSlot(to: routine, exercise: target)

        let impact = ExerciseDeletionImpact(
            routines: allRoutines(), exerciseID: target.id)
        let message = impact.message(exerciseName: "Bench Press")

        XCTAssertEqual(
            message,
            "Delete “Bench Press”? This will remove it from 1 routine, "
                + "delete 0 superset blocks, and unlink 1 exercise reference. "
                + "This cannot be undone.")
        XCTAssertFalse(message.contains("alternative"))
    }

    func testMessageForAlternativeOnlyUsageWarnsAboutPreparedWork() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Machine Chest Press")
        let routine = makeRoutine(name: "Push")
        addAlternative(target, to: addSlot(to: routine, exercise: primary))

        let impact = ExerciseDeletionImpact(
            routines: allRoutines(), exerciseID: target.id)
        let message = impact.message(exerciseName: "Machine Chest Press")

        XCTAssertEqual(impact.alternativeCount, 1)
        XCTAssertFalse(impact.hasDirectUsage)
        XCTAssertTrue(
            message.contains(
                "It is also used as 1 prepared alternative, "
                    + "which will be removed."),
            message)
        XCTAssertTrue(message.hasPrefix("Delete “Machine Chest Press”?"))
    }

    func testMessageForDirectAndAlternativeUsageMentionsBoth() {
        let target = makeExercise(name: "Incline Press")
        let primary = makeExercise(name: "Bench Press")
        let routine = makeRoutine(name: "Push")
        addSlot(to: routine, exercise: target)
        addAlternative(target, to: addSlot(to: routine, exercise: primary))
        addAlternative(target, to: addSlot(to: routine, exercise: primary))

        let impact = ExerciseDeletionImpact(
            routines: allRoutines(), exerciseID: target.id)
        let message = impact.message(exerciseName: "Incline Press")

        XCTAssertTrue(impact.hasDirectUsage)
        XCTAssertEqual(impact.alternativeCount, 2)
        // The pre-C1 direct sentence, intact...
        XCTAssertTrue(message.contains("unlink 1 exercise reference"), message)
        // ...plus the new one.
        XCTAssertTrue(
            message.contains(
                "It is also used as 2 prepared alternatives, "
                    + "which will be removed."),
            message)
    }

    func testImpactCountsAlternativesAcrossRoutinesAndSlots() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Dumbbell Press")
        let push = makeRoutine(name: "Push", order: 0)
        let upper = makeRoutine(name: "Upper", order: 1)
        addAlternative(target, to: addSlot(to: push, exercise: primary))
        addAlternative(target, to: addSlot(to: push, exercise: primary))
        addAlternative(target, to: addSlot(to: upper, exercise: primary))

        let impact = ExerciseDeletionImpact(
            routines: allRoutines(), exerciseID: target.id)

        XCTAssertEqual(impact.alternativeCount, 3)
        // Alternative-only routines do not inflate the direct routine count.
        XCTAssertEqual(impact.routineCount, 0)
    }

    // MARK: - 2. Pruning on delete

    func testDeletingExercisePrunesMatchingAlternatives() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Machine Chest Press")
        let routine = makeRoutine(name: "Push")
        let prescription = addSlot(to: routine, exercise: primary)
        addAlternative(target, to: prescription)

        XCTAssertEqual(prescription.slotAlternatives.count, 1)

        ExerciseDeletionService.delete(target, in: context)

        XCTAssertTrue(prescription.slotAlternatives.isEmpty)
    }

    func testDeletingExercisePreservesNonMatchingAlternatives() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Machine Chest Press")
        let keeper = makeExercise(name: "Dumbbell Press")
        let routine = makeRoutine(name: "Push")
        let prescription = addSlot(to: routine, exercise: primary)
        let keptAlternative = addAlternative(keeper, to: prescription)
        addAlternative(target, to: prescription)

        ExerciseDeletionService.delete(target, in: context)

        let survivors = prescription.slotAlternatives
        XCTAssertEqual(survivors.count, 1)
        XCTAssertEqual(survivors.first?.exerciseID, keeper.id)
        // Identity and prepared prescription both survive untouched.
        XCTAssertEqual(survivors.first?.id, keptAlternative.id)
        XCTAssertEqual(survivors.first?.prescription.sets, 4)
        XCTAssertEqual(survivors.first?.prescription.repMin, 6)
    }

    /// Removing an alternative from the middle must leave the survivors densely
    /// numbered, or the editor's reorder handler writes against stale indices.
    func testPruningRenormalizesOrderOfSurvivors() {
        let primary = makeExercise(name: "Bench Press")
        let first = makeExercise(name: "A")
        let target = makeExercise(name: "B")
        let third = makeExercise(name: "C")
        let routine = makeRoutine(name: "Push")
        let prescription = addSlot(to: routine, exercise: primary)
        addAlternative(first, to: prescription)
        addAlternative(target, to: prescription)
        addAlternative(third, to: prescription)

        ExerciseDeletionService.delete(target, in: context)

        let survivors = prescription.slotAlternatives
        XCTAssertEqual(survivors.map(\.order), [0, 1])
        XCTAssertEqual(
            survivors.map(\.exerciseID), [first.id, third.id])
    }

    func testRemovingLastAlternativeClearsTheColumnToNil() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Machine Chest Press")
        let routine = makeRoutine(name: "Push")
        let prescription = addSlot(to: routine, exercise: primary)
        addAlternative(target, to: prescription)

        XCTAssertNotNil(prescription.alternativesData)

        ExerciseDeletionService.delete(target, in: context)

        // "Had them and lost them" must persist identically to "never had any".
        XCTAssertNil(prescription.alternativesData)
    }

    func testPruningReachesEverySlotOfEveryRoutine() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Dumbbell Press")
        let push = makeRoutine(name: "Push", order: 0)
        let upper = makeRoutine(name: "Upper", order: 1)
        let a = addSlot(to: push, exercise: primary)
        let b = addSlot(to: push, exercise: primary)
        let c = addSlot(to: upper, exercise: primary)
        for p in [a, b, c] { addAlternative(target, to: p) }

        ExerciseDeletionService.delete(target, in: context)

        for p in [a, b, c] {
            XCTAssertTrue(p.slotAlternatives.isEmpty)
            XCTAssertNil(p.alternativesData)
        }
    }

    func testNoDanglingAlternativeSurvivesDeletion() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Machine Chest Press")
        let deletedID = target.id
        let routine = makeRoutine(name: "Push")
        let prescription = addSlot(to: routine, exercise: primary)
        addAlternative(target, to: prescription)

        ExerciseDeletionService.delete(target, in: context)

        let dangling = allRoutines()
            .flatMap(\.blocks)
            .flatMap(\.exercises)
            .compactMap(\.prescription)
            .flatMap(\.slotAlternatives)
            .filter { $0.exerciseID == deletedID }
        XCTAssertTrue(dangling.isEmpty)
    }

    // MARK: - 3. Corrupt payload tolerance

    func testCorruptAlternativesDataDoesNotCrashDelete() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Machine Chest Press")
        let routine = makeRoutine(name: "Push")
        let prescription = addSlot(to: routine, exercise: primary)
        let corrupt = Data("{ not a payload".utf8)
        prescription.alternativesData = corrupt

        ExerciseDeletionService.delete(target, in: context)

        // Nothing matched, so nothing was written — the corrupt column is left
        // exactly as it was rather than silently rewritten.
        XCTAssertEqual(prescription.alternativesData, corrupt)
    }

    func testPruneReportsHowManyItRemoved() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Dumbbell Press")
        let keeper = makeExercise(name: "Machine Press")
        let routine = makeRoutine(name: "Push")
        let prescription = addSlot(to: routine, exercise: primary)
        addAlternative(target, to: prescription)
        addAlternative(keeper, to: prescription)
        addAlternative(target, to: prescription)

        let removed = ExerciseDeletionService.pruneAlternatives(
            referencing: target.id, in: allRoutines())

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(prescription.slotAlternatives.count, 1)
    }

    // MARK: - 4. Direct deletion behavior is unchanged

    func testDirectSlotDeletionStillUnlinksNormalBlockSlots() {
        let target = makeExercise(name: "Bench Press")
        let keeper = makeExercise(name: "Row")
        let routine = makeRoutine(name: "Push")
        let block = RoutineBlock(isSuperset: false, order: 0, exercises: [])
        context.insert(block)
        for (i, ex) in [target, keeper].enumerated() {
            let slot = RoutineExercise(exercise: ex, order: i, setTemplates: [])
            context.insert(slot)
            block.exercises.append(slot)
        }
        routine.blocks.append(block)

        ExerciseDeletionService.delete(target, in: context)

        XCTAssertEqual(block.exercises.count, 1)
        XCTAssertEqual(block.exercises.first?.exercise?.id, keeper.id)
        // Survivor order is renormalized.
        XCTAssertEqual(block.exercises.map(\.order), [0])
    }

    func testDirectSlotDeletionStillDeletesSupersetBlockWhole() {
        let target = makeExercise(name: "Bench Press")
        let partner = makeExercise(name: "Incline Fly")
        let routine = makeRoutine(name: "Push")
        addSlot(to: routine, exercise: target, isSuperset: true, partner: partner)

        XCTAssertEqual(routine.blocks.count, 1)

        ExerciseDeletionService.delete(target, in: context)

        XCTAssertTrue(routine.blocks.isEmpty)
    }

    func testDirectSlotDeletionRenormalizesBlockOrder() {
        let target = makeExercise(name: "Bench Press")
        let keeper = makeExercise(name: "Row")
        let routine = makeRoutine(name: "Push")
        // Superset block first (deleted whole), then a surviving block.
        addSlot(
            to: routine, exercise: target, isSuperset: true,
            partner: makeExercise(name: "Fly"))
        addSlot(to: routine, exercise: keeper)

        ExerciseDeletionService.delete(target, in: context)

        XCTAssertEqual(routine.blocks.count, 1)
        XCTAssertEqual(routine.blocks.first?.order, 0)
    }

    func testDeletingExerciseRemovesTheExerciseItself() {
        let target = makeExercise(name: "Bench Press")
        try? context.save()

        ExerciseDeletionService.delete(target, in: context)

        let remaining =
            (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        XCTAssertFalse(remaining.contains { $0.name == "Bench Press" })
    }

    /// Direct and alternative cleanup in one pass: the slot goes, the sibling
    /// slot's prepared alternative goes, and the routine survives.
    func testDeletingExerciseUsedBothWaysCleansBoth() {
        let target = makeExercise(name: "Incline Press")
        let primary = makeExercise(name: "Bench Press")
        let routine = makeRoutine(name: "Push")
        addSlot(to: routine, exercise: target)
        let prescription = addSlot(to: routine, exercise: primary)
        addAlternative(target, to: prescription)

        ExerciseDeletionService.delete(target, in: context)

        XCTAssertTrue(prescription.slotAlternatives.isEmpty)
        let remainingSlots = routine.blocks
            .flatMap(\.exercises)
            .compactMap { $0.exercise?.id }
        XCTAssertEqual(remainingSlots, [primary.id])
    }
}
