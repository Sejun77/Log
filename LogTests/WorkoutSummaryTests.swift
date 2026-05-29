import SwiftData
import XCTest

@testable import Log

/// Pure tests for the `WorkoutSummary` namespace (History row subtitle helper).
/// `Workout` / `WorkoutItem` / `SetLog` are SwiftData `@Model`s, so fixtures
/// are inserted into the harness's in-memory store before being summarized; the
/// helper itself never touches the context. Pins the counting rules (structural
/// exercise count, non-warmup set count), the singular/plural subtitle wording,
/// nil-exercise safety, and `map(for:)`.
@MainActor
final class WorkoutSummaryTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    /// One `SetLog` of the given kind. Field values are irrelevant to the
    /// summary (it only inspects `kind`); kept minimal.
    private func makeLog(_ kind: SetKind, index: Int = 0) -> SetLog {
        let log = SetLog(indexInExercise: index, kind: kind, reps: 5, weight: 100)
        context.insert(log)
        return log
    }

    /// A `WorkoutItem` with the given set logs. Pass `attachExercise: false`
    /// to simulate a deleted/unlinked exercise reference (`item.exercise = nil`)
    /// while keeping the item itself a real, countable row.
    @discardableResult
    private func makeItem(
        name: String,
        logs: [SetLog],
        attachExercise: Bool = true
    ) -> WorkoutItem {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        let item = WorkoutItem(exercise: ex, setLogs: logs)
        if !attachExercise { item.exercise = nil }
        context.insert(item)
        return item
    }

    @discardableResult
    private func makeWorkout(
        items: [WorkoutItem],
        completedAt: Date? = .now
    ) -> Workout {
        let w = Workout(items: items)
        w.completedAt = completedAt
        context.insert(w)
        return w
    }

    // MARK: - Subtitle wording (value-in init)

    func testEmptyWorkoutSubtitle() {
        XCTAssertEqual(
            WorkoutSummary(exerciseCount: 0, setCount: 0).subtitle,
            "Empty workout"
        )
        // setCount is ignored when there are no exercises.
        XCTAssertEqual(
            WorkoutSummary(exerciseCount: 0, setCount: 5).subtitle,
            "Empty workout"
        )
    }

    func testSingularPluralWording() {
        XCTAssertEqual(
            WorkoutSummary(exerciseCount: 1, setCount: 0).subtitle,
            "1 exercise"
        )
        XCTAssertEqual(
            WorkoutSummary(exerciseCount: 2, setCount: 0).subtitle,
            "2 exercises"
        )
        XCTAssertEqual(
            WorkoutSummary(exerciseCount: 1, setCount: 1).subtitle,
            "1 exercise · 1 set"
        )
        XCTAssertEqual(
            WorkoutSummary(exerciseCount: 6, setCount: 24).subtitle,
            "6 exercises · 24 sets"
        )
    }

    func testItemsWithZeroSetsOmitSetClause() {
        XCTAssertEqual(
            WorkoutSummary(exerciseCount: 3, setCount: 0).subtitle,
            "3 exercises"
        )
    }

    // MARK: - Model-driven counting

    func testEmptyWorkoutFromModel() {
        let w = makeWorkout(items: [])
        let s = WorkoutSummary(workout: w)
        XCTAssertEqual(s.exerciseCount, 0)
        XCTAssertEqual(s.setCount, 0)
        XCTAssertEqual(s.subtitle, "Empty workout")
    }

    func testOneItemNoSetLogs() {
        let item = makeItem(name: "Bench Press", logs: [])
        let w = makeWorkout(items: [item])
        let s = WorkoutSummary(workout: w)
        XCTAssertEqual(s.exerciseCount, 1)
        XCTAssertEqual(s.setCount, 0)
        XCTAssertEqual(s.subtitle, "1 exercise")
    }

    func testOneItemOneWorkingSet() {
        let item = makeItem(name: "Bench Press", logs: [makeLog(.working)])
        let w = makeWorkout(items: [item])
        let s = WorkoutSummary(workout: w)
        XCTAssertEqual(s.exerciseCount, 1)
        XCTAssertEqual(s.setCount, 1)
        XCTAssertEqual(s.subtitle, "1 exercise · 1 set")
    }

    func testMultipleItemsMultipleSets() {
        // 2 exercises, 3 working sets each = 6 sets.
        let a = makeItem(
            name: "Squat",
            logs: [makeLog(.working, index: 0), makeLog(.working, index: 1), makeLog(.working, index: 2)]
        )
        let b = makeItem(
            name: "Deadlift",
            logs: [makeLog(.working, index: 0), makeLog(.working, index: 1), makeLog(.working, index: 2)]
        )
        let w = makeWorkout(items: [a, b])
        let s = WorkoutSummary(workout: w)
        XCTAssertEqual(s.exerciseCount, 2)
        XCTAssertEqual(s.setCount, 6)
        XCTAssertEqual(s.subtitle, "2 exercises · 6 sets")
    }

    func testWarmupsExcludedWorkingAndDropsetCounted() {
        // 2 warmups + 2 working + 1 dropset → only the 3 non-warmup rows count.
        let item = makeItem(
            name: "Overhead Press",
            logs: [
                makeLog(.warmup, index: -1),
                makeLog(.warmup, index: -2),
                makeLog(.working, index: 0),
                makeLog(.working, index: 1),
                makeLog(.dropset, index: 1),
            ]
        )
        let w = makeWorkout(items: [item])
        let s = WorkoutSummary(workout: w)
        XCTAssertEqual(s.setCount, 3)
        XCTAssertEqual(s.subtitle, "1 exercise · 3 sets")
    }

    func testAllWarmupWorkoutOmitsSetClause() {
        // Items present but every logged row is a warmup → 0 counted sets.
        let item = makeItem(
            name: "Mobility",
            logs: [makeLog(.warmup, index: -1), makeLog(.warmup, index: -2)]
        )
        let w = makeWorkout(items: [item])
        let s = WorkoutSummary(workout: w)
        XCTAssertEqual(s.exerciseCount, 1)
        XCTAssertEqual(s.setCount, 0)
        XCTAssertEqual(s.subtitle, "1 exercise")
    }

    func testNilExerciseReferenceStillCountsAndDoesNotCrash() {
        let detached = makeItem(
            name: "Deleted Lift",
            logs: [makeLog(.working)],
            attachExercise: false
        )
        let normal = makeItem(name: "Bench Press", logs: [makeLog(.working)])
        let w = makeWorkout(items: [detached, normal])
        let s = WorkoutSummary(workout: w)
        // Both items count structurally even though one has a nil exercise.
        XCTAssertEqual(s.exerciseCount, 2)
        XCTAssertEqual(s.setCount, 2)
        XCTAssertEqual(s.subtitle, "2 exercises · 2 sets")
    }

    func testInProgressWorkoutSummarizesStructurally() {
        let item = makeItem(
            name: "Row",
            logs: [makeLog(.working, index: 0), makeLog(.working, index: 1)]
        )
        let w = makeWorkout(items: [item], completedAt: nil)
        let s = WorkoutSummary(workout: w)
        XCTAssertNil(w.completedAt)
        XCTAssertEqual(s.exerciseCount, 1)
        XCTAssertEqual(s.setCount, 2)
        XCTAssertEqual(s.subtitle, "1 exercise · 2 sets")
    }

    // MARK: - map(for:)

    func testMapKeyedByWorkoutID() {
        let w1 = makeWorkout(items: [makeItem(name: "A", logs: [makeLog(.working)])])
        let w2 = makeWorkout(items: [])

        let map = WorkoutSummary.map(for: [w1, w2])
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map[w1.id]?.subtitle, "1 exercise · 1 set")
        XCTAssertEqual(map[w2.id]?.subtitle, "Empty workout")
    }

    func testMapEmptyInputReturnsEmpty() {
        XCTAssertTrue(WorkoutSummary.map(for: []).isEmpty)
    }
}
