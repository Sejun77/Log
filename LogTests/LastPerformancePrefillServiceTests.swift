import SwiftData
import XCTest

@testable import Log

/// Tests for the Slice 1 last-performance prefill extractor.
/// `Workout`/`WorkoutItem`/`SetLog` are `@Model` reference types, so these run
/// on `SwiftDataTestHarness` (in-memory container) — same approach as
/// `WorkoutHistoryAnalyticsTests`. The service performs no inserts/saves; the
/// harness just lets us build fixtures.
@MainActor
final class LastPerformancePrefillServiceTests: SwiftDataTestHarness {

    private typealias Suggestion =
        LastPerformancePrefillService.LastPerformanceSetSuggestion

    private let referenceDate = Date(timeIntervalSinceReferenceDate: 0)
    private func day(_ d: Double) -> Date {
        referenceDate.addingTimeInterval(d * 86_400)
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeWorkout(
        date: Date,
        completed: Bool = true,
        excludedFromPrefill: Bool = false
    ) -> Workout {
        let w = Workout(date: date, items: [])
        if completed { w.completedAt = date.addingTimeInterval(3600) }
        w.excludedFromPrefill = excludedFromPrefill
        context.insert(w)
        return w
    }

    private func makeExercise(_ name: String) -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        return ex
    }

    /// A set spec covering every field the service reads.
    private struct SetSpec {
        var kind: SetKind = .working
        var reps: Int = 0
        var weight: Double? = nil
        var duration: Int? = nil
        var subIndex: Int? = nil
        var index: Int? = nil  // override indexInExercise (defaults to array order)
    }

    @discardableResult
    private func addItem(
        to w: Workout,
        exercise: Exercise,
        sets: [SetSpec]
    ) -> WorkoutItem {
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        var logs: [SetLog] = []
        for (i, s) in sets.enumerated() {
            let log = SetLog(
                indexInExercise: s.index ?? i,
                kind: s.kind,
                reps: s.reps,
                weight: s.weight,
                durationSeconds: s.duration,
                subIndex: s.subIndex
            )
            context.insert(log)
            logs.append(log)
        }
        item.setLogs = logs
        context.insert(item)
        w.items.append(item)
        return item
    }

    private func allWorkouts() -> [Workout] {
        (try? context.fetch(FetchDescriptor<Workout>())) ?? []
    }

    // MARK: - Source selection

    func test_returnsMostRecentCompleted_ignoringOlder() {
        let ex = makeExercise("Bench")

        let old = makeWorkout(date: day(1))
        addItem(to: old, exercise: ex, sets: [
            SetSpec(reps: 5, weight: 60), SetSpec(reps: 5, weight: 60),
        ])

        let recent = makeWorkout(date: day(5))
        addItem(to: recent, exercise: ex, sets: [
            SetSpec(reps: 8, weight: 80), SetSpec(reps: 7, weight: 82),
        ])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map[0]?.weight, 80)
        XCTAssertEqual(map[0]?.reps, 8)
        XCTAssertEqual(map[1]?.weight, 82)
        XCTAssertEqual(map[1]?.reps, 7)
    }

    func test_ignoresInProgressWorkouts() {
        let ex = makeExercise("Bench")

        let completed = makeWorkout(date: day(1))
        addItem(to: completed, exercise: ex, sets: [SetSpec(reps: 5, weight: 60)])

        // Newer, but NOT completed — must be skipped even though it's more recent.
        let inProgress = makeWorkout(date: day(9), completed: false)
        addItem(to: inProgress, exercise: ex, sets: [SetSpec(reps: 99, weight: 999)])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[0]?.weight, 60)
        XCTAssertEqual(map[0]?.reps, 5)
    }

    func test_excludesCurrentWorkoutID() {
        let ex = makeExercise("Bench")

        let prior = makeWorkout(date: day(1))
        addItem(to: prior, exercise: ex, sets: [SetSpec(reps: 5, weight: 60)])

        // A completed workout we want excluded (e.g. the one being resumed).
        let current = makeWorkout(date: day(5))
        addItem(to: current, exercise: ex, sets: [SetSpec(reps: 99, weight: 999)])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts(), excluding: current.id
        )

        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[0]?.weight, 60)
    }

    // MARK: - Excluded-from-prefill source selection

    /// Sanity baseline: a single included most-recent workout is still used
    /// exactly as before once the exclusion flag exists (defaults to false).
    func test_excludedFromPrefill_includedMostRecentStillUsed() {
        let ex = makeExercise("Bench")

        let w = makeWorkout(date: day(5))  // excludedFromPrefill defaults false
        addItem(to: w, exercise: ex, sets: [SetSpec(reps: 8, weight: 80)])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )
        XCTAssertEqual(map[0]?.weight, 80)
    }

    /// The most recent workout is flagged excluded → it must be skipped and the
    /// older included workout used instead.
    func test_excludedFromPrefill_skipsExcludedMostRecent_usesOlderIncluded() {
        let ex = makeExercise("Bench")

        let older = makeWorkout(date: day(1))
        addItem(to: older, exercise: ex, sets: [SetSpec(reps: 5, weight: 60)])

        // Newer but marked excluded (e.g. a deload day).
        let recovery = makeWorkout(date: day(5), excludedFromPrefill: true)
        addItem(to: recovery, exercise: ex, sets: [SetSpec(reps: 12, weight: 30)])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[0]?.weight, 60)
        XCTAssertEqual(map[0]?.reps, 5)
    }

    /// When the only completed workout with the exercise is excluded, parent-set
    /// prefill returns nothing.
    func test_excludedFromPrefill_excludedOnlyWorkout_noParentSuggestion() {
        let ex = makeExercise("Bench")

        let recovery = makeWorkout(date: day(5), excludedFromPrefill: true)
        addItem(to: recovery, exercise: ex, sets: [SetSpec(reps: 12, weight: 30)])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )
        XCTAssertTrue(map.isEmpty)
    }

    /// When the only completed workout with drops is excluded, dropset prefill
    /// returns nothing.
    func test_excludedFromPrefill_excludedOnlyWorkout_noDropSuggestion() {
        let ex = makeExercise("Curl")

        let recovery = makeWorkout(date: day(5), excludedFromPrefill: true)
        addItem(to: recovery, exercise: ex, sets: [
            SetSpec(kind: .dropset, reps: 6, weight: 14, subIndex: 1, index: 0),
        ])

        let map = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )
        XCTAssertTrue(map.isEmpty)
    }

    /// Dropset prefill skips an excluded most-recent workout and falls back to
    /// the older included one.
    func test_excludedFromPrefill_dropSuggestionsSkipExcluded_usesOlder() {
        let ex = makeExercise("Curl")

        let older = makeWorkout(date: day(1))
        addItem(to: older, exercise: ex, sets: [
            SetSpec(kind: .dropset, reps: 6, weight: 14, subIndex: 1, index: 0),
        ])
        let recovery = makeWorkout(date: day(5), excludedFromPrefill: true)
        addItem(to: recovery, exercise: ex, sets: [
            SetSpec(kind: .dropset, reps: 12, weight: 6, subIndex: 1, index: 0),
        ])

        let map = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )
        XCTAssertEqual(map[0]?[1]?.weight, 14)
    }

    /// Excluding the current active workout still works alongside the new flag:
    /// the excluded-current workout is dropped, and a separately-excluded older
    /// workout is also skipped, leaving the included one.
    func test_excludedFromPrefill_currentWorkoutExclusionStillApplies() {
        let ex = makeExercise("Bench")

        let included = makeWorkout(date: day(1))
        addItem(to: included, exercise: ex, sets: [SetSpec(reps: 5, weight: 60)])

        // Most recent is the in-progress current workout (completed but resumed).
        let current = makeWorkout(date: day(9))
        addItem(to: current, exercise: ex, sets: [SetSpec(reps: 99, weight: 999)])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts(), excluding: current.id
        )

        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[0]?.weight, 60)
    }

    /// Incomplete workouts remain ignored even when not excluded (regression
    /// guard for the unchanged in-progress filter).
    func test_excludedFromPrefill_incompleteStillIgnored() {
        let ex = makeExercise("Bench")

        let completed = makeWorkout(date: day(1))
        addItem(to: completed, exercise: ex, sets: [SetSpec(reps: 5, weight: 60)])

        // Newer but not completed, not excluded — must still be skipped.
        let inProgress = makeWorkout(date: day(9), completed: false)
        addItem(to: inProgress, exercise: ex, sets: [SetSpec(reps: 99, weight: 999)])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[0]?.weight, 60)
    }

    // MARK: - Set filtering

    func test_filtersOutWarmups() {
        let ex = makeExercise("Squat")
        let w = makeWorkout(date: day(1))
        addItem(to: w, exercise: ex, sets: [
            SetSpec(kind: .warmup, reps: 10, weight: 20, index: 0),
            SetSpec(kind: .working, reps: 5, weight: 100, index: 1),
            SetSpec(kind: .working, reps: 5, weight: 100, index: 2),
        ])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(Set(map.keys), [1, 2])
        XCTAssertNil(map[0])
        XCTAssertEqual(map[1]?.weight, 100)
    }

    func test_filtersOutDropsetSubRows() {
        let ex = makeExercise("Curl")
        let w = makeWorkout(date: day(1))
        addItem(to: w, exercise: ex, sets: [
            SetSpec(kind: .working, reps: 10, weight: 30, subIndex: nil, index: 0),
            // Drop sub-rows hang off the same parent index but carry subIndex.
            SetSpec(kind: .dropset, reps: 8, weight: 20, subIndex: 1, index: 0),
            SetSpec(kind: .dropset, reps: 6, weight: 15, subIndex: 2, index: 0),
        ])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[0]?.weight, 30)
        XCTAssertEqual(map[0]?.reps, 10)
    }

    // MARK: - Ordering & contents

    func test_preservesSetOrderByIndex() {
        let ex = makeExercise("Press")
        let w = makeWorkout(date: day(1))
        // Insert logs out of natural order to prove keying is by indexInExercise.
        addItem(to: w, exercise: ex, sets: [
            SetSpec(reps: 6, weight: 50, index: 2),
            SetSpec(reps: 8, weight: 40, index: 0),
            SetSpec(reps: 7, weight: 45, index: 1),
        ])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(map[0]?.weight, 40)
        XCTAssertEqual(map[1]?.weight, 45)
        XCTAssertEqual(map[2]?.weight, 50)
    }

    func test_handlesRepsAndWeight() {
        let ex = makeExercise("Deadlift")
        let w = makeWorkout(date: day(1))
        addItem(to: w, exercise: ex, sets: [SetSpec(reps: 3, weight: 140.5)])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(
            map[0],
            Suggestion(setIndex: 0, reps: 3, weight: 140.5, durationSeconds: nil)
        )
    }

    func test_handlesDurationSeconds() {
        let ex = makeExercise("Plank")
        let w = makeWorkout(date: day(1))
        addItem(to: w, exercise: ex, sets: [
            SetSpec(reps: 0, weight: nil, duration: 60),
            SetSpec(reps: 0, weight: nil, duration: 75),
        ])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(map[0]?.durationSeconds, 60)
        XCTAssertEqual(map[1]?.durationSeconds, 75)
        XCTAssertNil(map[0]?.weight)
    }

    func test_returnsEmptyWhenNoPriorData() {
        let ex = makeExercise("Bench")
        // Only an in-progress workout exists.
        let w = makeWorkout(date: day(1), completed: false)
        addItem(to: w, exercise: ex, sets: [SetSpec(reps: 5, weight: 60)])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )
        XCTAssertTrue(map.isEmpty)
    }

    func test_returnsEmptyForUnknownExercise() {
        let ex = makeExercise("Bench")
        let other = makeExercise("Row")
        let w = makeWorkout(date: day(1))
        addItem(to: w, exercise: ex, sets: [SetSpec(reps: 5, weight: 60)])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: other.id, in: allWorkouts()
        )
        XCTAssertTrue(map.isEmpty)
    }

    func test_skipsWorkoutsWithoutWorkingSets_fallsBackToOlder() {
        let ex = makeExercise("Bench")

        let older = makeWorkout(date: day(1))
        addItem(to: older, exercise: ex, sets: [SetSpec(reps: 5, weight: 60)])

        // Newer completed workout has ONLY warm-ups for this exercise — no
        // qualifying working sets — so the service must fall back to `older`.
        let newer = makeWorkout(date: day(5))
        addItem(to: newer, exercise: ex, sets: [
            SetSpec(kind: .warmup, reps: 10, weight: 20),
        ])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[0]?.weight, 60)
    }

    // MARK: - Carry-down helper

    func test_carryDown_exactMatchWins() {
        let map: [Int: Suggestion] = [
            0: Suggestion(setIndex: 0, reps: 8, weight: 80, durationSeconds: nil),
            1: Suggestion(setIndex: 1, reps: 6, weight: 82, durationSeconds: nil),
        ]
        XCTAssertEqual(
            LastPerformancePrefillService.suggestion(forCurrentSetIndex: 1, from: map)?.weight,
            82
        )
    }

    func test_carryDown_beyondPreviousCountReturnsLast() {
        let map: [Int: Suggestion] = [
            0: Suggestion(setIndex: 0, reps: 8, weight: 80, durationSeconds: nil),
            1: Suggestion(setIndex: 1, reps: 6, weight: 82, durationSeconds: nil),
        ]
        // Routine now has 4 sets; index 3 is beyond the previous 2 → carry last.
        let s = LastPerformancePrefillService.suggestion(forCurrentSetIndex: 3, from: map)
        XCTAssertEqual(s?.setIndex, 1)
        XCTAssertEqual(s?.weight, 82)
    }

    func test_carryDown_emptyReturnsNil() {
        XCTAssertNil(
            LastPerformancePrefillService.suggestion(forCurrentSetIndex: 0, from: [:])
        )
    }

    func test_carryDown_gapFallsBackToNearestLower() {
        let map: [Int: Suggestion] = [
            0: Suggestion(setIndex: 0, reps: 8, weight: 80, durationSeconds: nil),
            2: Suggestion(setIndex: 2, reps: 6, weight: 90, durationSeconds: nil),
        ]
        // Index 1 is a gap (below max=2 but absent) → nearest lower = index 0.
        let s = LastPerformancePrefillService.suggestion(forCurrentSetIndex: 1, from: map)
        XCTAssertEqual(s?.setIndex, 0)
    }

    // MARK: - Dropset sub-rows (Slice 3)

    private typealias DropSuggestion =
        LastPerformancePrefillService.LastPerformanceDropSuggestion

    func test_dropSuggestions_returnsOnlySubIndexedLogs() {
        let ex = makeExercise("Curl")
        let w = makeWorkout(date: day(1))
        addItem(to: w, exercise: ex, sets: [
            // Parent working set (subIndex nil) — must be excluded.
            SetSpec(kind: .working, reps: 10, weight: 30, subIndex: nil, index: 0),
            // Two drop sub-rows.
            SetSpec(kind: .dropset, reps: 8, weight: 20, subIndex: 1, index: 0),
            SetSpec(kind: .dropset, reps: 6, weight: 15, subIndex: 2, index: 0),
            // Warm-up — excluded.
            SetSpec(kind: .warmup, reps: 12, weight: 10, subIndex: nil, index: 0),
            // Legacy template dropset WITHOUT a subIndex — excluded.
            SetSpec(kind: .dropset, reps: 5, weight: 12, subIndex: nil, index: 1),
        ])

        let map = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(Set(map.keys), [0])
        XCTAssertEqual(Set((map[0] ?? [:]).keys), [1, 2])
        XCTAssertEqual(map[0]?[1]?.reps, 8)
        XCTAssertEqual(map[0]?[1]?.weight, 20)
        XCTAssertEqual(map[0]?[2]?.reps, 6)
        XCTAssertEqual(map[0]?[2]?.weight, 15)
    }

    func test_dropSuggestions_preservesParentAndSubIndex() {
        let ex = makeExercise("Curl")
        let w = makeWorkout(date: day(1))
        addItem(to: w, exercise: ex, sets: [
            SetSpec(kind: .dropset, reps: 8, weight: 20, subIndex: 1, index: 0),
            SetSpec(kind: .dropset, reps: 7, weight: 18, subIndex: 1, index: 1),
            SetSpec(kind: .dropset, reps: 5, weight: 12, subIndex: 2, index: 1),
        ])

        let map = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )

        XCTAssertEqual(
            map[0]?[1],
            DropSuggestion(parentSetIndex: 0, subIndex: 1, reps: 8, weight: 20)
        )
        XCTAssertEqual(
            map[1]?[2],
            DropSuggestion(parentSetIndex: 1, subIndex: 2, reps: 5, weight: 12)
        )
    }

    func test_dropSuggestions_usesMostRecentCompletedWithDrops() {
        let ex = makeExercise("Curl")

        let old = makeWorkout(date: day(1))
        addItem(to: old, exercise: ex, sets: [
            SetSpec(kind: .dropset, reps: 5, weight: 10, subIndex: 1, index: 0),
        ])
        let recent = makeWorkout(date: day(5))
        addItem(to: recent, exercise: ex, sets: [
            SetSpec(kind: .dropset, reps: 8, weight: 20, subIndex: 1, index: 0),
        ])

        let map = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )
        XCTAssertEqual(map[0]?[1]?.weight, 20)
    }

    func test_dropSuggestions_skipsRecentWithoutDrops_fallsBackToOlder() {
        let ex = makeExercise("Curl")

        let older = makeWorkout(date: day(1))
        addItem(to: older, exercise: ex, sets: [
            SetSpec(kind: .dropset, reps: 6, weight: 14, subIndex: 1, index: 0),
        ])
        // Newer completed workout has the exercise but ONLY working sets.
        let newer = makeWorkout(date: day(5))
        addItem(to: newer, exercise: ex, sets: [
            SetSpec(kind: .working, reps: 10, weight: 30, subIndex: nil, index: 0),
        ])

        let map = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )
        XCTAssertEqual(map[0]?[1]?.weight, 14)
    }

    func test_dropSuggestions_excludesCurrentWorkoutID() {
        let ex = makeExercise("Curl")
        let prior = makeWorkout(date: day(1))
        addItem(to: prior, exercise: ex, sets: [
            SetSpec(kind: .dropset, reps: 6, weight: 14, subIndex: 1, index: 0),
        ])
        let current = makeWorkout(date: day(5))
        addItem(to: current, exercise: ex, sets: [
            SetSpec(kind: .dropset, reps: 99, weight: 999, subIndex: 1, index: 0),
        ])

        let map = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: ex.id, in: allWorkouts(), excluding: current.id
        )
        XCTAssertEqual(map[0]?[1]?.weight, 14)
    }

    func test_dropSuggestions_ignoresInProgress() {
        let ex = makeExercise("Curl")
        let inProgress = makeWorkout(date: day(9), completed: false)
        addItem(to: inProgress, exercise: ex, sets: [
            SetSpec(kind: .dropset, reps: 8, weight: 20, subIndex: 1, index: 0),
        ])

        let map = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )
        XCTAssertTrue(map.isEmpty)
    }

    func test_dropSuggestions_emptyWhenNoDrops() {
        let ex = makeExercise("Curl")
        let w = makeWorkout(date: day(1))
        addItem(to: w, exercise: ex, sets: [
            SetSpec(kind: .working, reps: 10, weight: 30, subIndex: nil, index: 0),
        ])

        let map = LastPerformancePrefillService.dropSuggestions(
            forExerciseID: ex.id, in: allWorkouts()
        )
        XCTAssertTrue(map.isEmpty)
    }

    // MARK: - dropSuggestion carry-down helper

    private func dropMap() -> [Int: [Int: DropSuggestion]] {
        [
            0: [
                1: DropSuggestion(parentSetIndex: 0, subIndex: 1, reps: 8, weight: 20),
                2: DropSuggestion(parentSetIndex: 0, subIndex: 2, reps: 6, weight: 15),
            ],
        ]
    }

    func test_dropSuggestion_exactMatch() {
        let s = LastPerformancePrefillService.dropSuggestion(
            forParentSetIndex: 0, subIndex: 2, from: dropMap()
        )
        XCTAssertEqual(s?.weight, 15)
    }

    func test_dropSuggestion_carryDownBeyondCount() {
        // Current dropset has 3 drops; sub 3 carries the last prior (sub 2).
        let s = LastPerformancePrefillService.dropSuggestion(
            forParentSetIndex: 0, subIndex: 3, from: dropMap()
        )
        XCTAssertEqual(s?.subIndex, 2)
        XCTAssertEqual(s?.weight, 15)
    }

    func test_dropSuggestion_nilWhenParentHasNoDrops() {
        // Parent index 1 has no drops → nil (no cross-parent carry in v1).
        let s = LastPerformancePrefillService.dropSuggestion(
            forParentSetIndex: 1, subIndex: 1, from: dropMap()
        )
        XCTAssertNil(s)
    }

    func test_dropSuggestion_nilWhenEmpty() {
        let s = LastPerformancePrefillService.dropSuggestion(
            forParentSetIndex: 0, subIndex: 1, from: [:]
        )
        XCTAssertNil(s)
    }
}
