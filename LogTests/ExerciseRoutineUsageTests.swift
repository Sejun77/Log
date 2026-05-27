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
