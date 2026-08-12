import XCTest

@testable import Log

/// Slice C — `formatSessionElapsed(start:now:)` is the pure helper extracted
/// from `ActiveWorkoutView.sessionElapsedString` so the toolbar clock can tick
/// inside an isolated `SessionClockView`/`TimelineView` rather than
/// invalidating the whole active-workout body. These tests pin the exact
/// formatting contract the old computed property produced:
///   - nil start → "00:00"
///   - negative interval clamped to 0
///   - MM:SS below one hour, H:MM:SS at/after one hour
final class SessionElapsedFormatTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func now(plus seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    func testNilStartShowsZero() {
        XCTAssertEqual(formatSessionElapsed(start: nil, now: now(plus: 123)), "00:00")
    }

    func testZeroElapsed() {
        XCTAssertEqual(formatSessionElapsed(start: start, now: start), "00:00")
    }

    func testNegativeIntervalClampsToZero() {
        XCTAssertEqual(formatSessionElapsed(start: start, now: now(plus: -42)), "00:00")
    }

    func testSecondsOnly() {
        XCTAssertEqual(formatSessionElapsed(start: start, now: now(plus: 9)), "00:09")
    }

    func testMinutesAndSeconds() {
        // 1m 05s
        XCTAssertEqual(formatSessionElapsed(start: start, now: now(plus: 65)), "01:05")
    }

    func testJustUnderOneHourStaysMMSS() {
        // 59m 59s
        XCTAssertEqual(formatSessionElapsed(start: start, now: now(plus: 3599)), "59:59")
    }

    func testExactlyOneHourSwitchesToHMMSS() {
        XCTAssertEqual(formatSessionElapsed(start: start, now: now(plus: 3600)), "1:00:00")
    }

    func testHoursMinutesSeconds() {
        // 2h 03m 07s
        let total: TimeInterval = 2 * 3600 + 3 * 60 + 7
        XCTAssertEqual(formatSessionElapsed(start: start, now: now(plus: total)), "2:03:07")
    }

    func testFractionalSecondsTruncate() {
        // 10.9s elapsed → still "00:10" (Int truncation, matches old behavior)
        XCTAssertEqual(formatSessionElapsed(start: start, now: now(plus: 10.9)), "00:10")
    }

    // MARK: - Background / foreground catch-up

    /// The clock is a pure function of (start, now) — `SessionClockView` feeds
    /// it `TimelineView`'s date — so a gap with no ticks in between produces
    /// the full elapsed time, not the pre-gap value. This is what makes the
    /// toolbar clock correct on foreground without any resync call.
    func testElapsedSpansAGapWithNoIntermediateTicks() {
        // 12s in, app backgrounds; 2 minutes later it returns.
        let beforeBackground = formatSessionElapsed(
            start: start,
            now: now(plus: 12)
        )
        XCTAssertEqual(beforeBackground, "00:12")

        let onForeground = formatSessionElapsed(
            start: start,
            now: now(plus: 12 + 120)
        )
        XCTAssertEqual(
            onForeground,
            "02:12",
            "Elapsed time did not include the backgrounded interval"
        )
    }

    /// A gap long enough to cross the MM:SS → H:MM:SS boundary still resolves
    /// from wall clock alone.
    func testLongBackgroundGapCrossesHourBoundary() {
        XCTAssertEqual(
            formatSessionElapsed(start: start, now: now(plus: 30)),
            "00:30"
        )
        XCTAssertEqual(
            formatSessionElapsed(start: start, now: now(plus: 30 + 3600)),
            "1:00:30"
        )
    }

    /// Same input always yields the same output regardless of how many times
    /// it is evaluated — no accumulated counter state.
    func testFormattingIsStateless() {
        let first = formatSessionElapsed(start: start, now: now(plus: 754))
        _ = formatSessionElapsed(start: start, now: now(plus: 1))
        let second = formatSessionElapsed(start: start, now: now(plus: 754))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "12:34")
    }
}
