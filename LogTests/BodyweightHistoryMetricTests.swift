import XCTest

@testable import Log

/// Slice 3 — bodyweight-safe History metric gating. Covers the pure
/// `availableProgressMetrics(isTimeBased:isBodyweight:)` helper that drives the
/// History metric picker, plus the selection-fallback rule (reset to the first
/// available metric — Total Reps for bodyweight — when the current one becomes
/// invalid).
final class BodyweightHistoryMetricTests: XCTestCase {

    // MARK: - Bodyweight (non-time-based)

    func testBodyweightMetricsAreRepsOnly() {
        XCTAssertEqual(
            availableProgressMetrics(isTimeBased: false, isBodyweight: true),
            [.totalReps]
        )
    }

    func testBodyweightExcludesWeightMetrics() {
        let metrics = availableProgressMetrics(isTimeBased: false, isBodyweight: true)
        XCTAssertFalse(metrics.contains(.e1rm))
        XCTAssertFalse(metrics.contains(.volume))
        XCTAssertFalse(metrics.contains(.bestWeight))
    }

    // MARK: - Non-bodyweight (unchanged)

    func testNonBodyweightMetricsUnchanged() {
        XCTAssertEqual(
            availableProgressMetrics(isTimeBased: false, isBodyweight: false),
            [.e1rm, .volume, .bestWeight, .totalReps]
        )
    }

    // MARK: - Time-based (unchanged, takes precedence)

    func testTimeBasedMetricsUnchanged() {
        XCTAssertEqual(
            availableProgressMetrics(isTimeBased: true, isBodyweight: false),
            [.totalDuration]
        )
    }

    func testTimeBasedTakesPrecedenceOverBodyweight() {
        XCTAssertEqual(
            availableProgressMetrics(isTimeBased: true, isBodyweight: true),
            [.totalDuration]
        )
    }

    // MARK: - Selection fallback

    /// Mirrors the `onChange(of: selectedExerciseID)` rule in HistoryView: if the
    /// current metric is not available for the new exercise, fall back to the
    /// first available metric (Total Reps for bodyweight).
    private func resolvedMetric(
        current: ProgressMetric, isTimeBased: Bool, isBodyweight: Bool
    ) -> ProgressMetric {
        let available = availableProgressMetrics(
            isTimeBased: isTimeBased, isBodyweight: isBodyweight
        )
        return available.contains(current) ? current : (available.first ?? .totalReps)
    }

    func testE1rmFallsBackToTotalRepsForBodyweight() {
        XCTAssertEqual(
            resolvedMetric(current: .e1rm, isTimeBased: false, isBodyweight: true),
            .totalReps
        )
    }

    func testValidMetricIsPreservedForBodyweight() {
        XCTAssertEqual(
            resolvedMetric(current: .totalReps, isTimeBased: false, isBodyweight: true),
            .totalReps
        )
    }

    func testValidMetricIsPreservedForNonBodyweight() {
        XCTAssertEqual(
            resolvedMetric(current: .e1rm, isTimeBased: false, isBodyweight: false),
            .e1rm
        )
    }

    func testDurationFallsBackForNonTimeBased() {
        // Preserves existing behavior: leaving a time-based exercise resets the
        // stale duration metric to the first weight-based metric (e1RM).
        XCTAssertEqual(
            resolvedMetric(current: .totalDuration, isTimeBased: false, isBodyweight: false),
            .e1rm
        )
    }
}
