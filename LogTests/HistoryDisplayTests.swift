import XCTest

@testable import Log

/// Covers the pure display rules that decide how much of the workout history
/// the root History page shows, and when it offers the full-history screen.
///
/// These exist because the root page deliberately stopped listing every
/// workout: listing them all made the page grow without bound, pushing Calendar
/// and Progression further below the fold with every session logged. The slice
/// size and the "is anything actually hidden" test are the whole contract
/// between `HistoryView` and `AllWorkoutsView`, so they are asserted here
/// rather than left to a screenshot.
@MainActor
final class HistoryDisplayTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    /// `n` workouts, newest first — the same ordering `HistoryView`'s
    /// `@Query(sort: \Workout.date, order: .reverse)` hands to these helpers.
    private func makeWorkouts(_ n: Int) -> [Workout] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<n).map { i in
            Workout(
                date: base.addingTimeInterval(-Double(i) * 86_400),
                items: []
            )
        }
    }

    // MARK: - Slice size

    func testRecentLimitIsFour() {
        XCTAssertEqual(
            HistoryDisplay.recentWorkoutLimit, 4,
            """
            The root History page's slice size changed. That is a deliberate \
            layout decision (it bounds the page height so Calendar and \
            Progression stay reachable) — update the rationale in \
            HistoryDisplay if this was intended.
            """
        )
    }

    func testRecentReturnsEverythingWhenUnderTheLimit() {
        let workouts = makeWorkouts(2)
        XCTAssertEqual(HistoryDisplay.recent(workouts).count, 2)
    }

    func testRecentReturnsEverythingExactlyAtTheLimit() {
        let workouts = makeWorkouts(4)
        XCTAssertEqual(HistoryDisplay.recent(workouts).count, 4)
    }

    func testRecentTruncatesAboveTheLimit() {
        let workouts = makeWorkouts(40)
        XCTAssertEqual(
            HistoryDisplay.recent(workouts).count,
            HistoryDisplay.recentWorkoutLimit
        )
    }

    func testRecentIsEmptyForNoWorkouts() {
        XCTAssertTrue(HistoryDisplay.recent([]).isEmpty)
    }

    /// The slice must be the *newest* workouts, in the order given — the helper
    /// never re-sorts, so a caller's reverse-chronological query is preserved.
    func testRecentPreservesCallerOrderAndTakesFromTheFront() {
        let workouts = makeWorkouts(10)
        let recent = HistoryDisplay.recent(workouts)
        XCTAssertEqual(
            recent.map(\.id),
            workouts.prefix(HistoryDisplay.recentWorkoutLimit).map(\.id)
        )
        // Strictly descending by date, i.e. newest first, unchanged.
        XCTAssertEqual(recent, recent.sorted { $0.date > $1.date })
    }

    // MARK: - "View All Workouts" visibility

    /// A user whose history fits entirely in the slice must not be offered a
    /// link to a screen showing exactly what they are already looking at.
    func testHasMoreIsFalseAtOrBelowTheLimit() {
        XCTAssertFalse(HistoryDisplay.hasMore([]))
        XCTAssertFalse(HistoryDisplay.hasMore(makeWorkouts(1)))
        XCTAssertFalse(HistoryDisplay.hasMore(makeWorkouts(4)))
    }

    func testHasMoreIsTrueAboveTheLimit() {
        XCTAssertTrue(HistoryDisplay.hasMore(makeWorkouts(5)))
        XCTAssertTrue(HistoryDisplay.hasMore(makeWorkouts(200)))
    }

    /// `hasMore` and `recent` must agree: the row appears exactly when the
    /// slice actually hid something.
    func testHasMoreAgreesWithWhatRecentHides() {
        for n in 0...12 {
            let workouts = makeWorkouts(n)
            let hidden = workouts.count - HistoryDisplay.recent(workouts).count
            XCTAssertEqual(
                HistoryDisplay.hasMore(workouts), hidden > 0,
                "disagreement at \(n) workouts (hidden: \(hidden))"
            )
        }
    }

    // MARK: - Duration formatting (extracted from HistoryView unchanged)

    func testDurationIsNilWhenNotCompleted() {
        let w = makeWorkouts(1)[0]
        XCTAssertNil(WorkoutRowFormat.duration(for: w))
    }

    func testDurationFormatsMinutesUnderAnHour() {
        let w = makeWorkouts(1)[0]
        w.completedAt = w.date.addingTimeInterval(45 * 60)
        XCTAssertEqual(WorkoutRowFormat.duration(for: w), "45m")
    }

    func testDurationFormatsHoursAndMinutes() {
        let w = makeWorkouts(1)[0]
        w.completedAt = w.date.addingTimeInterval(2 * 3600 + 5 * 60)
        XCTAssertEqual(WorkoutRowFormat.duration(for: w), "2h 05m")
    }

    /// A sub-minute workout still reads as "1m" rather than "0m", and a
    /// `completedAt` before `date` clamps instead of going negative.
    func testDurationFloorsAtOneMinuteAndClampsNegatives() {
        let w = makeWorkouts(1)[0]
        w.completedAt = w.date.addingTimeInterval(20)
        XCTAssertEqual(WorkoutRowFormat.duration(for: w), "1m")

        w.completedAt = w.date.addingTimeInterval(-600)
        XCTAssertEqual(WorkoutRowFormat.duration(for: w), "1m")
    }
}
