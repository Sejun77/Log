import SwiftData
import XCTest

@testable import Log

/// Routine row summary subtitle polish — locks down the read-only
/// `RoutineSummary` helper: slot counting across normal and superset blocks,
/// superset counting, duplicate-slot behavior, nil-reference safety, the
/// "Empty routine" case, and pluralization of the subtitle wording.
///
/// Documented counting decision (see `RoutineSummary`): a slot is counted by
/// `block.exercises.count` regardless of whether its `exercise` reference is
/// nil, so a deleted/unlinked slot still counts toward the exercise total and
/// can never crash the (purely structural) scan.
@MainActor
final class RoutineSummaryTests: SwiftDataTestHarness {

    // MARK: - Fixture helpers

    @discardableResult
    private func makeRoutine(name: String = "Routine") -> Routine {
        let r = Routine(name: name, blocks: [])
        context.insert(r)
        return r
    }

    private func makeExercise(name: String) -> Exercise {
        let e = Exercise(name: name)
        context.insert(e)
        return e
    }

    /// Append a block holding one `RoutineExercise` slot per entry (a `nil`
    /// entry models a deleted/unlinked reference: a throwaway exercise is
    /// attached then the relationship is nulled).
    @discardableResult
    private func addBlock(
        to routine: Routine,
        isSuperset: Bool = false,
        exercises: [Exercise?]
    ) -> RoutineBlock {
        let order = (routine.blocks.map(\.order).max() ?? -1) + 1
        var slots: [RoutineExercise] = []
        for (i, ex) in exercises.enumerated() {
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

    // MARK: - Empty

    func testEmptyRoutineShowsEmptyRoutine() {
        let r = makeRoutine()

        let summary = RoutineSummary(routine: r)

        XCTAssertEqual(summary.exerciseCount, 0)
        XCTAssertEqual(summary.supersetCount, 0)
        XCTAssertEqual(summary.subtitle, "Empty routine")
    }

    // MARK: - Normal blocks

    func testOneNormalBlockWithOneExercise() {
        let r = makeRoutine()
        addBlock(to: r, exercises: [makeExercise(name: "Bench")])

        let summary = RoutineSummary(routine: r)

        XCTAssertEqual(summary.exerciseCount, 1)
        XCTAssertEqual(summary.supersetCount, 0)
        XCTAssertEqual(summary.subtitle, "1 exercise")
    }

    func testMultipleNormalBlocksSumExerciseCount() {
        let r = makeRoutine()
        // Three single-exercise blocks + one two-exercise block = 5 slots.
        addBlock(to: r, exercises: [makeExercise(name: "Bench")])
        addBlock(to: r, exercises: [makeExercise(name: "Row")])
        addBlock(to: r, exercises: [makeExercise(name: "Squat")])
        addBlock(
            to: r,
            exercises: [makeExercise(name: "Curl"), makeExercise(name: "Press")]
        )

        let summary = RoutineSummary(routine: r)

        XCTAssertEqual(summary.exerciseCount, 5)
        XCTAssertEqual(summary.supersetCount, 0)
        XCTAssertEqual(summary.subtitle, "5 exercises")
    }

    // MARK: - Supersets

    func testOneSupersetBlockCountsExercisesAndOneSuperset() {
        let r = makeRoutine()
        addBlock(
            to: r,
            isSuperset: true,
            exercises: [makeExercise(name: "Bench"), makeExercise(name: "Fly")]
        )

        let summary = RoutineSummary(routine: r)

        XCTAssertEqual(summary.exerciseCount, 2)
        XCTAssertEqual(summary.supersetCount, 1)
        XCTAssertEqual(summary.subtitle, "2 exercises · 1 superset")
    }

    func testMultipleSupersetsPluralizeCorrectly() {
        let r = makeRoutine()
        // 2 supersets (2 slots each) + 4 normal single-slot blocks = 8 slots.
        addBlock(
            to: r, isSuperset: true,
            exercises: [makeExercise(name: "A1"), makeExercise(name: "A2")]
        )
        addBlock(
            to: r, isSuperset: true,
            exercises: [makeExercise(name: "B1"), makeExercise(name: "B2")]
        )
        addBlock(to: r, exercises: [makeExercise(name: "C")])
        addBlock(to: r, exercises: [makeExercise(name: "D")])
        addBlock(to: r, exercises: [makeExercise(name: "E")])
        addBlock(to: r, exercises: [makeExercise(name: "F")])

        let summary = RoutineSummary(routine: r)

        XCTAssertEqual(summary.exerciseCount, 8)
        XCTAssertEqual(summary.supersetCount, 2)
        XCTAssertEqual(summary.subtitle, "8 exercises · 2 supersets")
    }

    // MARK: - Duplicate slots

    func testDuplicateExerciseSlotsCountSeparately() {
        let r = makeRoutine()
        let bench = makeExercise(name: "Bench")
        // Same exercise referenced from two distinct slots/blocks.
        addBlock(to: r, exercises: [bench])
        addBlock(to: r, exercises: [bench])

        let summary = RoutineSummary(routine: r)

        XCTAssertEqual(summary.exerciseCount, 2)
        XCTAssertEqual(summary.subtitle, "2 exercises")
    }

    // MARK: - Nil / deleted references

    /// Documented behavior: a nil (deleted/unlinked) slot still counts toward
    /// the exercise total, and the scan never dereferences `re.exercise`, so it
    /// cannot crash.
    func testNilExerciseReferencesStillCountAsSlotsAndDoNotCrash() {
        let r = makeRoutine()
        // One linked slot + one unlinked (nil) slot in the same block.
        addBlock(to: r, exercises: [makeExercise(name: "Bench"), nil])

        let summary = RoutineSummary(routine: r)

        XCTAssertEqual(summary.exerciseCount, 2)
        XCTAssertEqual(summary.subtitle, "2 exercises")
    }

    func testRoutineWithOnlyNilSlotIsNotEmpty() {
        let r = makeRoutine()
        addBlock(to: r, exercises: [nil])

        let summary = RoutineSummary(routine: r)

        XCTAssertEqual(summary.exerciseCount, 1)
        XCTAssertEqual(summary.subtitle, "1 exercise")
    }

    // MARK: - Value-in wording (no SwiftData)

    func testValueInitWordingRules() {
        XCTAssertEqual(
            RoutineSummary(exerciseCount: 0, supersetCount: 0).subtitle,
            "Empty routine"
        )
        XCTAssertEqual(
            RoutineSummary(exerciseCount: 1, supersetCount: 0).subtitle,
            "1 exercise"
        )
        XCTAssertEqual(
            RoutineSummary(exerciseCount: 5, supersetCount: 0).subtitle,
            "5 exercises"
        )
        XCTAssertEqual(
            RoutineSummary(exerciseCount: 5, supersetCount: 1).subtitle,
            "5 exercises · 1 superset"
        )
        XCTAssertEqual(
            RoutineSummary(exerciseCount: 8, supersetCount: 2).subtitle,
            "8 exercises · 2 supersets"
        )
    }

    // MARK: - map(for:)

    func testMapKeysSummariesByRoutineID() {
        let push = makeRoutine(name: "Push")
        addBlock(to: push, exercises: [makeExercise(name: "Bench")])
        let pull = makeRoutine(name: "Pull")  // empty

        let map = RoutineSummary.map(for: [push, pull])

        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map[push.id]?.subtitle, "1 exercise")
        XCTAssertEqual(map[pull.id]?.subtitle, "Empty routine")
    }
}
