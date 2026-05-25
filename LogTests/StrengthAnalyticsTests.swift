import XCTest

@testable import Log

/// Pure-calculation tests for the AP Calculus AB analytics layer. These touch
/// no SwiftData, so they subclass plain `XCTestCase` (no `SwiftDataTestHarness`).
final class StrengthAnalyticsTests: XCTestCase {

    private typealias SeriesPoint = StrengthAnalytics.SeriesPoint
    private typealias VolumePoint = StrengthAnalytics.VolumePoint

    /// Fixed reference date + day offset, so every series sits on a clean,
    /// deterministic day grid independent of the wall clock.
    private let referenceDate = Date(timeIntervalSinceReferenceDate: 0)
    private func day(_ d: Double) -> Date {
        referenceDate.addingTimeInterval(d * 86_400)
    }

    // MARK: - 1. e1RM formula

    func test_e1RM_epleyFormula() {
        let value = StrengthAnalytics.e1RM(weight: 100, reps: 5)
        XCTAssertNotNil(value)
        // 100 × (1 + 5/30) = 116.6666...
        XCTAssertEqual(value!, 116.6666666, accuracy: 1e-4)
        XCTAssertEqual(value!, 100 * (1 + 5.0 / 30.0), accuracy: 1e-9)
    }

    // MARK: - 2. Invalid e1RM inputs

    func test_e1RM_invalidInputsReturnNil() {
        XCTAssertNil(StrengthAnalytics.e1RM(weight: 0, reps: 5))
        XCTAssertNil(StrengthAnalytics.e1RM(weight: -10, reps: 5))
        XCTAssertNil(StrengthAnalytics.e1RM(weight: 100, reps: 0))
        XCTAssertNil(StrengthAnalytics.e1RM(weight: 100, reps: -3))
    }

    // MARK: - 3. Rep cap excludes reps > 12

    func test_e1RM_repCapExcludesAboveTwelve() {
        XCTAssertNotNil(StrengthAnalytics.e1RM(weight: 100, reps: 12))
        XCTAssertNil(StrengthAnalytics.e1RM(weight: 100, reps: 13))
        XCTAssertNil(StrengthAnalytics.e1RM(weight: 100, reps: 20))

        // bestE1RM must skip the out-of-domain 20-rep set and use the 5-rep one.
        let best = StrengthAnalytics.bestE1RM(
            sets: [(weight: 100, reps: 20), (weight: 90, reps: 5)]
        )
        XCTAssertEqual(best!, 90 * (1 + 5.0 / 30.0), accuracy: 1e-9)
    }

    // MARK: - 4. Average rate of change on two points

    func test_averageRateOfChange_twoPoints() {
        let pts = [
            SeriesPoint(date: day(0), value: 100),
            SeriesPoint(date: day(7), value: 114),
        ]
        XCTAssertEqual(StrengthAnalytics.averageRateOfChangePerDay(pts)!, 2, accuracy: 1e-9)
        XCTAssertEqual(StrengthAnalytics.averageRateOfChangePerWeek(pts)!, 14, accuracy: 1e-9)
    }

    // MARK: - 5. Same-date / zero Δt is safe

    func test_averageRateOfChange_sameDateReturnsNil() {
        let pts = [
            SeriesPoint(date: day(3), value: 100),
            SeriesPoint(date: day(3), value: 120),
        ]
        XCTAssertNil(StrengthAnalytics.averageRateOfChangePerDay(pts))
        XCTAssertNil(StrengthAnalytics.averageRateOfChangePerWeek(pts))
    }

    // MARK: - 6. First derivative on linear data is constant

    func test_firstDerivative_linearConstantSlope() {
        // value = 2 · t  ⇒  slope = 2 / day everywhere
        let pts = (0...4).map { SeriesPoint(date: day(Double($0)), value: 2 * Double($0)) }
        let d = StrengthAnalytics.firstDerivative(pts)

        XCTAssertEqual(d.count, 5)
        for p in d {
            XCTAssertEqual(p.slopePerDay, 2, accuracy: 1e-9)
            XCTAssertEqual(p.slopePerWeek, 14, accuracy: 1e-9)
        }
    }

    // MARK: - 7. Central difference for interior points

    func test_firstDerivative_centralDifferenceInterior() {
        // Non-linear so central differs from naive forward/backward.
        let pts = [
            SeriesPoint(date: day(0), value: 0),
            SeriesPoint(date: day(1), value: 1),
            SeriesPoint(date: day(2), value: 10),
        ]
        let d = StrengthAnalytics.firstDerivative(pts)

        XCTAssertEqual(d[0].slopePerDay, 1, accuracy: 1e-9)  // forward  (1-0)/1
        XCTAssertEqual(d[1].slopePerDay, 5, accuracy: 1e-9)  // central  (10-0)/2
        XCTAssertEqual(d[2].slopePerDay, 9, accuracy: 1e-9)  // backward (10-1)/1
    }

    // MARK: - 8. Second derivative positive for concave-up data

    func test_secondDerivative_concaveUpPositive() {
        // value = t²  ⇒  concave up, S″ > 0
        let pts = (0...4).map { SeriesPoint(date: day(Double($0)), value: Double($0 * $0)) }
        XCTAssertGreaterThan(StrengthAnalytics.secondDerivativePerWeekSquared(pts)!, 0)
        XCTAssertEqual(StrengthAnalytics.concavity(pts), .accelerating)
    }

    // MARK: - 9. Second derivative negative for concave-down data

    func test_secondDerivative_concaveDownNegative() {
        // value = -t²  ⇒  concave down, S″ < 0
        let pts = (0...4).map { SeriesPoint(date: day(Double($0)), value: -Double($0 * $0)) }
        XCTAssertLessThan(StrengthAnalytics.secondDerivativePerWeekSquared(pts)!, 0)
        XCTAssertEqual(StrengthAnalytics.concavity(pts), .slowing)
    }

    // MARK: - 10. Second derivative ~0 for linear data

    func test_secondDerivative_linearRoughlyZero() {
        let pts = (0...4).map { SeriesPoint(date: day(Double($0)), value: 3 * Double($0) + 5) }
        XCTAssertEqual(StrengthAnalytics.secondDerivativePerWeekSquared(pts)!, 0, accuracy: 1e-9)
        XCTAssertEqual(StrengthAnalytics.concavity(pts), .roughlyConstant)
    }

    // MARK: - 11. Plateau true within threshold

    func test_plateau_trueWhenRecentSlopeWithinThreshold() {
        // +0.2 over 7 days ⇒ recent slope 0.2 / week ≤ 0.5 default threshold
        let pts = [
            SeriesPoint(date: day(0), value: 100),
            SeriesPoint(date: day(7), value: 100.2),
        ]
        XCTAssertEqual(StrengthAnalytics.recentDerivativePerWeek(pts)!, 0.2, accuracy: 1e-9)
        XCTAssertTrue(StrengthAnalytics.isPlateau(pts))
    }

    // MARK: - 12. Plateau false when slope exceeds threshold

    func test_plateau_falseWhenRecentSlopeExceedsThreshold() {
        // +10 over 7 days ⇒ recent slope 10 / week ≫ 0.5
        let pts = [
            SeriesPoint(date: day(0), value: 100),
            SeriesPoint(date: day(7), value: 110),
        ]
        XCTAssertFalse(StrengthAnalytics.isPlateau(pts))
    }

    // MARK: - 13. Accumulated volume running sum

    func test_accumulatedVolume_runningSum() {
        let sessions = [
            VolumePoint(date: day(0), volume: 1000),
            VolumePoint(date: day(2), volume: 500),
            VolumePoint(date: day(5), volume: 750),
        ]
        let acc = StrengthAnalytics.accumulatedVolume(sessions)
        XCTAssertEqual(acc.map(\.accumulatedVolume), [1000, 1500, 2250])
        XCTAssertEqual(acc.map(\.volume), [1000, 500, 750])
    }

    func test_sessionVolume_sumsValidSetsOnly() {
        let volume = StrengthAnalytics.sessionVolume([
            (weight: 100, reps: 5),   // 500
            (weight: 0, reps: 5),     // ignored (no load)
            (weight: 80, reps: 0),    // ignored (no reps)
            (weight: -60, reps: 8),   // ignored (negative load)
            (weight: 60, reps: 10),   // 600
        ])
        XCTAssertEqual(volume, 1100, accuracy: 1e-9)
    }

    func test_sessionVolume_noRepCap() {
        // reps > 12 are excluded from e1RM but still count toward volume.
        let volume = StrengthAnalytics.sessionVolume([(weight: 50, reps: 20)])
        XCTAssertEqual(volume, 1000, accuracy: 1e-9)
    }

    // MARK: - 14. Unsorted input is sorted before calculations

    func test_unsortedInput_isSortedBeforeCalculations() {
        let pts = [
            SeriesPoint(date: day(7), value: 114),
            SeriesPoint(date: day(0), value: 100),
            SeriesPoint(date: day(3), value: 106),
        ]
        let derivativeDates = StrengthAnalytics.firstDerivative(pts).map(\.date)
        XCTAssertEqual(derivativeDates, [day(0), day(3), day(7)])

        // Average rate uses true first/last by date: (114-100)/7 days = 14/week.
        XCTAssertEqual(StrengthAnalytics.averageRateOfChangePerWeek(pts)!, 14, accuracy: 1e-9)
    }

    // MARK: - 15. Duplicate dates do not crash

    func test_duplicateDates_doNotCrash() {
        let pts = [
            SeriesPoint(date: day(0), value: 100),
            SeriesPoint(date: day(0), value: 110),  // same date — coalesces to max
            SeriesPoint(date: day(3), value: 120),
        ]
        let norm = StrengthAnalytics.normalized(pts)
        XCTAssertEqual(norm.count, 2)
        XCTAssertEqual(norm.first!.value, 110)  // best of the two day-0 readings

        // None of these should trap on a zero denominator.
        XCTAssertNotNil(StrengthAnalytics.averageRateOfChangePerWeek(pts))
        XCTAssertEqual(StrengthAnalytics.firstDerivative(pts).count, 2)
        _ = StrengthAnalytics.analyze(strength: pts, volume: [])
    }

    // MARK: - Extra edge cases: empty / single point

    func test_emptyAndSinglePoint_areSafe() {
        XCTAssertNil(StrengthAnalytics.averageRateOfChangePerWeek([]))
        XCTAssertTrue(StrengthAnalytics.firstDerivative([]).isEmpty)
        XCTAssertNil(StrengthAnalytics.secondDerivativePerWeekSquared([]))
        XCTAssertFalse(StrengthAnalytics.isPlateau([]))

        let one = [SeriesPoint(date: day(0), value: 100)]
        XCTAssertNil(StrengthAnalytics.averageRateOfChangePerWeek(one))
        XCTAssertTrue(StrengthAnalytics.firstDerivative(one).isEmpty)
        XCTAssertNil(StrengthAnalytics.secondDerivativePerWeekSquared(one))
        XCTAssertFalse(StrengthAnalytics.isPlateau(one))

        let summary = StrengthAnalytics.analyze(strength: one, volume: [])
        XCTAssertEqual(summary.pointCount, 1)
        XCTAssertEqual(summary.firstValue!, 100, accuracy: 1e-9)
        XCTAssertEqual(summary.latestValue!, 100, accuracy: 1e-9)
        XCTAssertEqual(summary.totalChange!, 0, accuracy: 1e-9)
        XCTAssertNil(summary.averageRatePerWeek)
        XCTAssertEqual(summary.concavity, .roughlyConstant)
        XCTAssertFalse(summary.isPlateau)
        XCTAssertEqual(summary.totalAccumulatedVolume, 0)
    }

    // MARK: - Extra edge case: all-equal values

    func test_allEqualValues_flatSlopeAndPlateau() {
        let pts = (0...4).map { SeriesPoint(date: day(Double($0)), value: 100) }
        XCTAssertEqual(StrengthAnalytics.averageRateOfChangePerWeek(pts)!, 0, accuracy: 1e-9)
        XCTAssertEqual(StrengthAnalytics.recentDerivativePerWeek(pts)!, 0, accuracy: 1e-9)
        XCTAssertTrue(StrengthAnalytics.isPlateau(pts))
        XCTAssertEqual(StrengthAnalytics.concavity(pts), .roughlyConstant)
    }

    // MARK: - Roll-up summary

    func test_analyze_summaryFields() {
        let strength = [
            SeriesPoint(date: day(0), value: 100),
            SeriesPoint(date: day(7), value: 114),
        ]
        let volume = [
            VolumePoint(date: day(0), volume: 1000),
            VolumePoint(date: day(7), volume: 1200),
        ]
        let s = StrengthAnalytics.analyze(strength: strength, volume: volume)

        XCTAssertEqual(s.pointCount, 2)
        XCTAssertEqual(s.firstValue!, 100, accuracy: 1e-9)
        XCTAssertEqual(s.latestValue!, 114, accuracy: 1e-9)
        XCTAssertEqual(s.totalChange!, 14, accuracy: 1e-9)
        XCTAssertEqual(s.averageRatePerWeek!, 14, accuracy: 1e-9)
        XCTAssertEqual(s.recentDerivativePerWeek!, 14, accuracy: 1e-9)
        XCTAssertEqual(s.totalAccumulatedVolume, 2200, accuracy: 1e-9)
    }
}
