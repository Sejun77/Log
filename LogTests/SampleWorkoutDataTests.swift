import XCTest

@testable import Log

/// Tests for the in-memory analytics showcase dataset. Like
/// `StrengthAnalyticsTests`, these are pure value-type tests — plain
/// `XCTestCase`, **no `SwiftDataTestHarness`**, no `ModelContext`, no `@Query`.
/// That the whole file compiles and runs without the harness is itself the
/// proof of requirement 7 ("does not require SwiftData").
final class SampleWorkoutDataTests: XCTestCase {

    // MARK: - 1. Dataset is non-empty

    func test_sample_isNonEmpty() {
        let bench = SampleWorkoutData.benchPress()
        XCTAssertEqual(bench.name, "Bench Press")
        XCTAssertEqual(bench.sessions.count, 10)
        XCTAssertFalse(bench.sessions.isEmpty)
        // Multiple sets per session so volume is meaningful.
        XCTAssertTrue(bench.sessions.allSatisfy { $0.sets.count == 3 })
        XCTAssertFalse(SampleWorkoutData.allExercises().isEmpty)
    }

    // MARK: - 2. Dates are sorted / sortable and span several weeks

    func test_sample_datesAreStrictlyIncreasing() {
        let sessions = SampleWorkoutData.benchPress().sessions
        let dates = sessions.map(\.date)

        XCTAssertEqual(dates, dates.sorted(), "sample dates are already ascending")
        for (earlier, later) in zip(dates, dates.dropFirst()) {
            XCTAssertLessThan(earlier, later, "no duplicate / out-of-order dates")
        }

        // Span: first → last should cover ~9 weeks (10 weekly sessions).
        let spanDays = StrengthAnalytics.days(from: dates.first!, to: dates.last!)
        XCTAssertEqual(spanDays, 63, accuracy: 1e-6)  // 9 weeks × 7 days
    }

    // MARK: - 3. Strength series is analyzable by StrengthAnalytics

    func test_sample_strengthSeriesIsAnalyzable() {
        let bench = SampleWorkoutData.benchPress()
        let strength = SampleWorkoutData.strengthSeries(bench.sessions)

        XCTAssertEqual(strength.count, 10)
        // First session: 60 × 8 ⇒ e1RM = 60·(1 + 8/30) = 76.0
        XCTAssertEqual(strength.first!.value, 76.0, accuracy: 1e-6)
        // Last session: 72.5 × 5 ⇒ e1RM = 72.5·(1 + 5/30) = 84.5833…
        XCTAssertEqual(strength.last!.value, 72.5 * (1 + 5.0 / 30.0), accuracy: 1e-6)

        let summary = StrengthAnalytics.analyze(strength: strength)
        XCTAssertEqual(summary.pointCount, 10)
        XCTAssertNotNil(summary.averageRatePerWeek)
    }

    // MARK: - 4. Volume accumulation is positive

    func test_sample_volumeAccumulationIsPositive() {
        let bench = SampleWorkoutData.benchPress()
        let volume = SampleWorkoutData.volumeSeries(bench.sessions)

        XCTAssertEqual(volume.count, 10)
        XCTAssertTrue(volume.allSatisfy { $0.volume > 0 }, "every session has real volume")

        let accumulated = StrengthAnalytics.accumulatedVolume(volume)
        // Monotonic non-decreasing running sum, ending positive.
        XCTAssertGreaterThan(accumulated.last!.accumulatedVolume, 0)
        XCTAssertEqual(
            accumulated.last!.accumulatedVolume,
            volume.reduce(0) { $0 + $1.volume },
            accuracy: 1e-6
        )
        for (earlier, later) in zip(accumulated, accumulated.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.accumulatedVolume, earlier.accumulatedVolume)
        }
    }

    // MARK: - 5. Overall strength increase

    func test_sample_showsOverallStrengthIncrease() {
        let summary = SampleWorkoutData.analysisSummary(for: SampleWorkoutData.benchPress())

        XCTAssertGreaterThan(summary.latestValue!, summary.firstValue!)
        XCTAssertGreaterThan(summary.totalChange!, 0)
        XCTAssertGreaterThan(summary.averageRatePerWeek!, 0, "net progress over the block")
    }

    // MARK: - 6. Slowing / plateau near the end

    func test_sample_showsSlowingOrPlateauNearEnd() {
        let summary = SampleWorkoutData.analysisSummary(for: SampleWorkoutData.benchPress())

        // Recent slope sits inside the plateau band (last three sessions are
        // identical 72.5×5 ⇒ recent slope ≈ 0).
        XCTAssertTrue(summary.isPlateau)
        XCTAssertEqual(summary.recentDerivativePerWeek!, 0, accuracy: 1e-6)

        // And the second derivative is negative — gains are slowing overall.
        XCTAssertLessThan(summary.secondDerivativePerWeekSquared!, 0)
        XCTAssertEqual(summary.concavity, .slowing)
    }

    // MARK: - 7. Positive accumulated volume via the roll-up summary

    func test_sample_summaryHasPositiveAccumulatedVolume() {
        let summary = SampleWorkoutData.analysisSummary(for: SampleWorkoutData.benchPress())
        XCTAssertGreaterThan(summary.totalAccumulatedVolume, 0)
    }

    // MARK: - Custom start date threads through (showcase can end near today)

    func test_sample_customStartDateShiftsTimeline() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let bench = SampleWorkoutData.benchPress(startingFrom: start)

        XCTAssertEqual(bench.sessions.first!.date, start)
        // Spacing and analysis are unaffected by the absolute anchor.
        let summary = SampleWorkoutData.analysisSummary(for: bench)
        XCTAssertGreaterThan(summary.averageRatePerWeek!, 0)
        XCTAssertTrue(summary.isPlateau)
    }
}
