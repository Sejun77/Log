import XCTest

@testable import Log

/// Regression coverage for `fix/history-calendar-selection`.
///
/// The History calendar is a visual record of `Workout.date`, not a selection
/// control: the bug was that `MultiDatePicker(selection:)` let a tap write into
/// the state driving the highlight. The non-interactive half of that fix lives
/// in `UICalendarSelectionMultiDateDelegate` and is not meaningfully unit
/// testable without a brittle UI test, so what is pinned here is the other
/// half — the derivation the calendar now reads from, which is pure.
///
/// Every assertion uses a fixed UTC Gregorian calendar so the expected day
/// buckets don't move with the machine's region.
final class WorkoutDaysCalendarTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal
    }()

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0
    ) throws -> Date {
        try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: year, month: month, day: day, hour: hour, minute: minute
                )
            )
        )
    }

    /// The expected highlight for a day, built through the *same* calendar the
    /// derivation uses. A hand-rolled `DateComponents(year:month:day:)` is not
    /// equal to one `Calendar.dateComponents` returns — the latter also carries
    /// `isLeapMonth` — and comparing against a literal would test that quirk
    /// rather than the bucketing.
    private func day(
        _ year: Int, _ month: Int, _ day: Int, in calendar: Calendar? = nil
    ) throws -> DateComponents {
        let cal = calendar ?? self.calendar
        let date = try XCTUnwrap(
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        )
        return cal.dateComponents([.year, .month, .day], from: date)
    }

    // MARK: - Derivation

    func testNoWorkoutsHighlightsNothing() {
        XCTAssertTrue(workoutDayComponents(for: [], calendar: calendar).isEmpty)
    }

    func testSingleWorkoutHighlightsItsDay() throws {
        let days = workoutDayComponents(
            for: [try date(2026, 3, 14, 6, 45)],
            calendar: calendar
        )
        XCTAssertEqual(days, [try day(2026, 3, 14)])
    }

    func testTwoWorkoutsOnSameDayCollapseToOneHighlight() throws {
        let days = workoutDayComponents(
            for: [
                try date(2026, 3, 14, 6, 45),
                try date(2026, 3, 14, 19, 5),
                try date(2026, 3, 14, 23, 59),
            ],
            calendar: calendar
        )
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days, [try day(2026, 3, 14)])
    }

    func testWorkoutsAcrossDaysHighlightEveryDay() throws {
        let days = workoutDayComponents(
            for: [
                try date(2026, 3, 14),
                try date(2026, 3, 16),
                try date(2026, 4, 1),
                try date(2025, 12, 31),
            ],
            calendar: calendar
        )
        XCTAssertEqual(
            days,
            [
                try day(2026, 3, 14), try day(2026, 3, 16),
                try day(2026, 4, 1), try day(2025, 12, 31),
            ]
        )
    }

    // MARK: - Normalization

    func testTimeOfDayIsStrippedFromTheHighlightedDay() throws {
        let days = workoutDayComponents(
            for: [try date(2026, 3, 14, 0, 0), try date(2026, 3, 14, 23, 59)],
            calendar: calendar
        )
        let only = try XCTUnwrap(days.first)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(only.year, 2026)
        XCTAssertEqual(only.month, 3)
        XCTAssertEqual(only.day, 14)
        // Only the three components `UICalendarView` matches on are carried;
        // an hour would make two same-day workouts two different highlights.
        XCTAssertNil(only.hour)
        XCTAssertNil(only.minute)
        XCTAssertNil(only.second)
    }

    func testMidnightBoundaryBucketsByTheCalendarsTimeZone() throws {
        // 2026-03-15 00:30 UTC is still 2026-03-14 in a UTC-8 calendar. The
        // derivation must follow the calendar it is handed, because that is the
        // calendar the grid draws with.
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -8 * 3600))

        let instant = try date(2026, 3, 15, 0, 30)

        XCTAssertEqual(
            workoutDayComponents(for: [instant], calendar: calendar),
            [try day(2026, 3, 15)]
        )
        XCTAssertEqual(
            workoutDayComponents(for: [instant], calendar: pacific),
            [try day(2026, 3, 14, in: pacific)]
        )
    }

    func testDerivationIsOrderIndependent() throws {
        let dates = [
            try date(2026, 4, 1),
            try date(2026, 3, 14),
            try date(2026, 3, 16),
        ]
        XCTAssertEqual(
            workoutDayComponents(for: dates, calendar: calendar),
            workoutDayComponents(for: dates.reversed(), calendar: calendar)
        )
    }
}
