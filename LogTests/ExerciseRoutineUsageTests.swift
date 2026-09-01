import SwiftData
import XCTest

@testable import Log

/// Exercise Detail "Used in Routines" polish — locks down the read-only
/// `ExerciseRoutineUsage` helper: unique-routine counting, per-routine slot
/// counts, superset-block inclusion, nil-reference safety, and the
/// `(Routine.order, Routine.name)` ordering shown on the Routines tab.
@MainActor
final class ExerciseRoutineUsageTests: SwiftDataTestHarness {

    // MARK: - Fixture helpers

    @discardableResult
    private func makeRoutine(name: String, order: Int = 0) -> Routine {
        let r = Routine(name: name, blocks: [])
        context.insert(r)
        r.order = order
        return r
    }

    private func makeExercise(name: String) -> Exercise {
        let e = Exercise(name: name)
        context.insert(e)
        return e
    }

    /// Append a block to `routine` holding one `RoutineExercise` slot per
    /// entry in `exercises` (a `nil` entry produces an unlinked slot).
    @discardableResult
    private func addBlock(
        to routine: Routine,
        isSuperset: Bool = false,
        exercises: [Exercise?]
    ) -> RoutineBlock {
        let order = (routine.blocks.map(\.order).max() ?? -1) + 1
        var slots: [RoutineExercise] = []
        for (i, ex) in exercises.enumerated() {
            // RoutineExercise.init requires a non-nil exercise; for unlinked
            // slots we attach a throwaway then null the relationship to model
            // a deleted/missing reference.
            let placeholder = ex ?? makeExercise(name: "Placeholder \(i)")
            let re = RoutineExercise(
                exercise: placeholder, order: i, setTemplates: []
            )
            context.insert(re)
            if ex == nil { re.exercise = nil }
            slots.append(re)
        }
        let block = RoutineBlock(
            isSuperset: isSuperset, order: order, exercises: slots
        )
        context.insert(block)
        routine.blocks.append(block)
        return block
    }

    // MARK: - Count behavior

    func testUnusedExerciseReturnsZeroRoutines() {
        let target = makeExercise(name: "Bench Press")
        let other = makeExercise(name: "Squat")
        let r = makeRoutine(name: "Legs")
        addBlock(to: r, exercises: [other])

        let usage = ExerciseRoutineUsage(routines: [r], exerciseID: target.id)

        XCTAssertEqual(usage.routineCount, 0)
        XCTAssertTrue(usage.entries.isEmpty)
        XCTAssertEqual(usage.summary, "Used in 0 routines")
    }

    func testExerciseInOneRoutineReturnsOneRoutine() {
        let target = makeExercise(name: "Bench Press")
        let r = makeRoutine(name: "Push")
        addBlock(to: r, exercises: [target])

        let usage = ExerciseRoutineUsage(routines: [r], exerciseID: target.id)

        XCTAssertEqual(usage.routineCount, 1)
        XCTAssertEqual(usage.entries.first?.routineName, "Push")
        XCTAssertEqual(usage.entries.first?.slotCount, 1)
        XCTAssertNil(usage.entries.first?.slotSuffix)
        XCTAssertEqual(usage.summary, "Used in 1 routine")
    }

    func testDuplicateExerciseInSameRoutineCountsAsOneRoutine() {
        let target = makeExercise(name: "Bench Press")
        let r = makeRoutine(name: "Push")
        // Same exercise referenced from two separate blocks of one routine.
        addBlock(to: r, exercises: [target])
        addBlock(to: r, exercises: [target])

        let usage = ExerciseRoutineUsage(routines: [r], exerciseID: target.id)

        XCTAssertEqual(usage.routineCount, 1)
    }

    func testDuplicateExerciseInSameRoutineReportsTwoSlots() {
        let target = makeExercise(name: "Bench Press")
        let r = makeRoutine(name: "Push")
        addBlock(to: r, exercises: [target])
        addBlock(to: r, exercises: [target])

        let usage = ExerciseRoutineUsage(routines: [r], exerciseID: target.id)

        XCTAssertEqual(usage.entries.first?.slotCount, 2)
        XCTAssertEqual(usage.entries.first?.slotSuffix, "· 2 slots")
    }

    func testSameExerciseInMultipleRoutinesCountsMultipleRoutines() {
        let target = makeExercise(name: "Bench Press")
        let push = makeRoutine(name: "Push", order: 0)
        let upper = makeRoutine(name: "Upper", order: 1)
        addBlock(to: push, exercises: [target])
        addBlock(to: upper, exercises: [target])

        let usage = ExerciseRoutineUsage(
            routines: [push, upper], exerciseID: target.id
        )

        XCTAssertEqual(usage.routineCount, 2)
        XCTAssertEqual(usage.entries.map(\.slotCount), [1, 1])
    }

    func testUnrelatedExercisesAreIgnored() {
        let target = makeExercise(name: "Bench Press")
        let a = makeExercise(name: "Row")
        let b = makeExercise(name: "Curl")
        let r = makeRoutine(name: "Pull")
        addBlock(to: r, exercises: [a, b])

        let usage = ExerciseRoutineUsage(routines: [r], exerciseID: target.id)

        XCTAssertEqual(usage.routineCount, 0)
    }

    func testNilExerciseReferencesAreSkippedAndDoNotCrash() {
        let target = makeExercise(name: "Bench Press")
        let r = makeRoutine(name: "Push")
        // One real target slot alongside an unlinked (nil) slot in the block.
        addBlock(to: r, exercises: [target, nil])
        // A routine whose only slot is unlinked must not be counted.
        let ghost = makeRoutine(name: "Ghost")
        addBlock(to: ghost, exercises: [nil])

        let usage = ExerciseRoutineUsage(
            routines: [r, ghost], exerciseID: target.id
        )

        XCTAssertEqual(usage.routineCount, 1)
        XCTAssertEqual(usage.entries.first?.routineName, "Push")
        XCTAssertEqual(usage.entries.first?.slotCount, 1)
    }

    func testExerciseInSupersetBlockStillCounts() {
        let target = makeExercise(name: "Bench Press")
        let partner = makeExercise(name: "Incline Fly")
        let r = makeRoutine(name: "Push")
        addBlock(to: r, isSuperset: true, exercises: [target, partner])

        let usage = ExerciseRoutineUsage(routines: [r], exerciseID: target.id)

        XCTAssertEqual(usage.routineCount, 1)
        XCTAssertEqual(usage.entries.first?.slotCount, 1)
    }

    // MARK: - Ordering

    func testOrderingFollowsRoutineOrderThenName() {
        let target = makeExercise(name: "Bench Press")
        // (order, name): Zebra(1) should come after the two order-0 routines,
        // which sort Apple < Bravo by name.
        let zebra = makeRoutine(name: "Zebra", order: 1)
        let apple = makeRoutine(name: "Apple", order: 0)
        let bravo = makeRoutine(name: "Bravo", order: 0)
        for r in [zebra, apple, bravo] {
            addBlock(to: r, exercises: [target])
        }

        // Pass in deliberately unsorted to prove the helper sorts internally.
        let usage = ExerciseRoutineUsage(
            routines: [zebra, bravo, apple], exerciseID: target.id
        )

        XCTAssertEqual(
            usage.entries.map(\.routineName), ["Apple", "Bravo", "Zebra"]
        )
    }
}

// ======================================================
// MARK: - Alternative Exercises usage (Build 10 C1)
// ======================================================

/// `ExerciseRoutineUsage` used to scan direct `RoutineExercise` slots only, so
/// an exercise referenced solely as a prepared alternative reported
/// "Used in 0 routines" — the false statement the Exercise Detail screen showed
/// immediately above a Delete button that would strand that prepared work.
///
/// These pin the corrected counting: the two kinds of usage are counted
/// separately, never summed, and a corrupt alternatives column costs the count
/// rather than the scan.
@MainActor
final class ExerciseAlternativeUsageTests: SwiftDataTestHarness {

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

    /// Append a one-slot block whose slot carries a `SlotPrescription`, and
    /// return that prescription so a test can hang alternatives off it.
    @discardableResult
    private func addSlot(
        to routine: Routine, exercise: Exercise
    ) -> SlotPrescription {
        let prescription = SlotPrescription()
        context.insert(prescription)
        let slot = RoutineExercise(exercise: exercise, order: 0, setTemplates: [])
        context.insert(slot)
        slot.prescription = prescription
        let block = RoutineBlock(
            isSuperset: false,
            order: (routine.blocks.map(\.order).max() ?? -1) + 1,
            exercises: [slot]
        )
        context.insert(block)
        routine.blocks.append(block)
        return prescription
    }

    private func addAlternatives(
        _ exercises: [Exercise], to prescription: SlotPrescription
    ) {
        for (index, exercise) in exercises.enumerated() {
            SlotAlternativeAuthoring.append(
                exerciseID: exercise.id,
                exerciseName: exercise.name,
                prescription: AlternativePrescriptionPayload(sets: 3),
                to: prescription)
            _ = index
        }
    }

    // MARK: - 1. Direct-only usage is unchanged

    func testDirectSlotOnlyCountsAsDirectUsage() {
        let target = makeExercise(name: "Bench Press")
        let routine = makeRoutine(name: "Push")
        addSlot(to: routine, exercise: target)

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        XCTAssertEqual(usage.slotCount, 1)
        XCTAssertEqual(usage.alternativeCount, 0)
        XCTAssertEqual(usage.routineCount, 1)
        XCTAssertTrue(usage.hasDirectUsage)
        XCTAssertTrue(usage.isUsed)
        XCTAssertEqual(usage.summary, "Used in 1 routine")
        // The suffix stays suppressed at a single slot, exactly as before.
        XCTAssertNil(usage.entries.first?.slotSuffix)
    }

    // MARK: - 2. Alternative-only usage

    func testAlternativeOnlyCountsAsAlternativeUsage() {
        let primary = makeExercise(name: "Barbell Bench Press")
        let target = makeExercise(name: "Machine Chest Press")
        let routine = makeRoutine(name: "Push")
        let prescription = addSlot(to: routine, exercise: primary)
        addAlternatives([target], to: prescription)

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        XCTAssertEqual(usage.slotCount, 0)
        XCTAssertEqual(usage.alternativeCount, 1)
        XCTAssertFalse(usage.hasDirectUsage)
        // The routine is still listed — it *is* affected by a deletion.
        XCTAssertEqual(usage.routineCount, 1)
        XCTAssertEqual(usage.entries.first?.routineName, "Push")
    }

    /// The headline regression: this is the exact statement the pre-C1 screen
    /// made about an exercise several routines were relying on.
    func testAlternativeOnlyNeverReportsZeroRoutines() {
        let primary = makeExercise(name: "Squat")
        let target = makeExercise(name: "Hack Squat")
        let routine = makeRoutine(name: "Legs")
        addAlternatives([target], to: addSlot(to: routine, exercise: primary))

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        XCTAssertNotEqual(usage.summary, "Used in 0 routines")
        XCTAssertEqual(usage.summary, "Used as 1 alternative")
    }

    func testAlternativeOnlySummaryPluralizes() {
        let primary = makeExercise(name: "Squat")
        let target = makeExercise(name: "Hack Squat")
        let a = makeRoutine(name: "Legs A", order: 0)
        let b = makeRoutine(name: "Legs B", order: 1)
        addAlternatives([target], to: addSlot(to: a, exercise: primary))
        addAlternatives([target], to: addSlot(to: b, exercise: primary))

        let usage = ExerciseRoutineUsage(routines: [a, b], exerciseID: target.id)

        XCTAssertEqual(usage.alternativeCount, 2)
        XCTAssertEqual(usage.summary, "Used as 2 alternatives")
    }

    // MARK: - 3. Both kinds of usage

    func testDirectAndAlternativeUsageAreCountedSeparately() {
        let target = makeExercise(name: "Incline Press")
        let primary = makeExercise(name: "Bench Press")
        let routine = makeRoutine(name: "Push")
        // Direct slot in one block, an alternative on another block's slot.
        addSlot(to: routine, exercise: target)
        addAlternatives([target], to: addSlot(to: routine, exercise: primary))

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        XCTAssertEqual(usage.slotCount, 1)
        XCTAssertEqual(usage.alternativeCount, 1)
        // One routine, counted once — not two.
        XCTAssertEqual(usage.routineCount, 1)
        XCTAssertEqual(usage.summary, "Used in 1 routine · 1 alternative")
    }

    func testEntrySuffixNamesBothSlotsAndAlternatives() {
        let target = makeExercise(name: "Incline Press")
        let primary = makeExercise(name: "Bench Press")
        let routine = makeRoutine(name: "Push")
        addSlot(to: routine, exercise: target)
        addSlot(to: routine, exercise: target)
        addAlternatives(
            [target, target], to: addSlot(to: routine, exercise: primary))

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        XCTAssertEqual(usage.entries.first?.slotCount, 2)
        XCTAssertEqual(usage.entries.first?.alternativeCount, 2)
        XCTAssertEqual(
            usage.entries.first?.slotSuffix, "· 2 slots · 2 alternatives")
    }

    /// A single alternative is always named, unlike a single slot: it is not
    /// visible anywhere else on the screen.
    func testSingleAlternativeStillProducesASuffix() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Dumbbell Press")
        let routine = makeRoutine(name: "Push")
        addAlternatives([target], to: addSlot(to: routine, exercise: primary))

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        XCTAssertEqual(usage.entries.first?.slotSuffix, "· 1 alternative")
    }

    // MARK: - 4. Empty state

    func testEmptyStateGateIsFalseWhenOnlyAlternativesExist() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Dumbbell Press")
        let routine = makeRoutine(name: "Push")
        addAlternatives([target], to: addSlot(to: routine, exercise: primary))

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        XCTAssertTrue(usage.isUsed, "empty state must not appear")
    }

    func testEmptyStateGateStaysTrueForATrulyUnusedExercise() {
        let target = makeExercise(name: "Never Used")
        let other = makeExercise(name: "Bench Press")
        let routine = makeRoutine(name: "Push")
        addSlot(to: routine, exercise: other)

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        XCTAssertFalse(usage.isUsed)
        XCTAssertEqual(usage.summary, "Used in 0 routines")
    }

    // MARK: - 5. Disabled alternatives still count

    /// A disabled alternative is hidden from the switch sheet but is still
    /// prepared work, and deleting the exercise still destroys it.
    func testDisabledAlternativesAreStillCounted() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Dumbbell Press")
        let routine = makeRoutine(name: "Push")
        let prescription = addSlot(to: routine, exercise: primary)
        let added = SlotAlternativeAuthoring.append(
            exerciseID: target.id,
            exerciseName: target.name,
            prescription: AlternativePrescriptionPayload(sets: 3),
            to: prescription)
        SlotAlternativeAuthoring.update(id: added.id, in: prescription) {
            $0.isEnabled = false
        }

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        XCTAssertEqual(usage.alternativeCount, 1)
    }

    // MARK: - 6. Corrupt payload tolerance

    func testCorruptAlternativesDataDoesNotCrashUsageCounting() {
        let primary = makeExercise(name: "Bench Press")
        let target = makeExercise(name: "Dumbbell Press")
        let routine = makeRoutine(name: "Push")
        let prescription = addSlot(to: routine, exercise: primary)
        prescription.alternativesData = Data("not json at all".utf8)

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        // Corruption costs the count, never the scan.
        XCTAssertEqual(usage.alternativeCount, 0)
        XCTAssertFalse(usage.isUsed)
        XCTAssertEqual(usage.summary, "Used in 0 routines")
    }

    func testSlotWithoutAPrescriptionIsSkipped() {
        let target = makeExercise(name: "Dumbbell Press")
        let primary = makeExercise(name: "Bench Press")
        let routine = makeRoutine(name: "Push")
        let slot = RoutineExercise(exercise: primary, order: 0, setTemplates: [])
        context.insert(slot)
        // No prescription attached at all.
        let block = RoutineBlock(isSuperset: false, order: 0, exercises: [slot])
        context.insert(block)
        routine.blocks.append(block)

        let usage = ExerciseRoutineUsage(
            routines: [routine], exerciseID: target.id)

        XCTAssertEqual(usage.alternativeCount, 0)
    }
}
