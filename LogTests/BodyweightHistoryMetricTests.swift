import XCTest

@testable import Log

/// Bodyweight-safe History metric gating (originally Slice 3, updated for the
/// bodyweight-load slice). Covers `availableProgressMetrics(isTimeBased:
/// includesBodyweight:hasUserBodyweight:)` and the selection-fallback rule
/// (reset to the first available metric when the current one becomes invalid).
final class BodyweightHistoryMetricTests: XCTestCase {

    // MARK: - Bodyweight without a user bodyweight (rep-based only)

    func testBodyweightWithoutUserBodyweightIsRepsOnly() {
        XCTAssertEqual(
            availableProgressMetrics(
                isTimeBased: false, isBodyweightEquipment: true,
                includesBodyweight: true, hasUserBodyweight: false),
            [.totalReps, .bestReps]
        )
    }

    func testBodyweightWithoutUserBodyweightExcludesWeightMetrics() {
        let metrics = availableProgressMetrics(
            isTimeBased: false, isBodyweightEquipment: true,
            includesBodyweight: true, hasUserBodyweight: false)
        XCTAssertFalse(metrics.contains(.e1rm))
        XCTAssertFalse(metrics.contains(.volume))
        XCTAssertFalse(metrics.contains(.bestWeight))
    }

    // MARK: - Non-bodyweight (unchanged)

    func testNonBodyweightMetricsUnchanged() {
        XCTAssertEqual(
            availableProgressMetrics(
                isTimeBased: false, isBodyweightEquipment: false,
                includesBodyweight: false, hasUserBodyweight: false),
            [.e1rm, .volume, .bestWeight, .totalReps]
        )
    }

    // MARK: - Time-based (unchanged, takes precedence)

    func testTimeBasedMetricsUnchanged() {
        XCTAssertEqual(
            availableProgressMetrics(
                isTimeBased: true, isBodyweightEquipment: false,
                includesBodyweight: false, hasUserBodyweight: false),
            [.totalDuration]
        )
    }

    func testTimeBasedTakesPrecedenceOverBodyweight() {
        XCTAssertEqual(
            availableProgressMetrics(
                isTimeBased: true, isBodyweightEquipment: true,
                includesBodyweight: true, hasUserBodyweight: true),
            [.totalDuration]
        )
    }

    // MARK: - Selection fallback

    /// Mirrors the `onChange(of: selectedExerciseID)` rule in HistoryView: if the
    /// current metric is not available for the new exercise, fall back to the
    /// first available metric.
    private func resolvedMetric(
        current: ProgressMetric,
        isTimeBased: Bool,
        isBodyweightEquipment: Bool,
        includesBodyweight: Bool,
        hasUserBodyweight: Bool
    ) -> ProgressMetric {
        let available = availableProgressMetrics(
            isTimeBased: isTimeBased,
            isBodyweightEquipment: isBodyweightEquipment,
            includesBodyweight: includesBodyweight,
            hasUserBodyweight: hasUserBodyweight
        )
        return available.contains(current) ? current : (available.first ?? .totalReps)
    }

    func testE1rmFallsBackForBodyweightWithoutUserBodyweight() {
        XCTAssertEqual(
            resolvedMetric(
                current: .e1rm, isTimeBased: false, isBodyweightEquipment: true,
                includesBodyweight: true, hasUserBodyweight: false),
            .totalReps
        )
    }

    // Regression: e1RM is invalid for pure bodyweight equipment with the flag
    // off, so selecting such an exercise must fall back to a rep-based metric.
    func testE1rmFallsBackForBodyweightEquipmentFlagOff() {
        XCTAssertEqual(
            resolvedMetric(
                current: .e1rm, isTimeBased: false, isBodyweightEquipment: true,
                includesBodyweight: false, hasUserBodyweight: true),
            .totalReps
        )
    }

    func testValidMetricIsPreservedForBodyweight() {
        XCTAssertEqual(
            resolvedMetric(
                current: .totalReps, isTimeBased: false, isBodyweightEquipment: true,
                includesBodyweight: true, hasUserBodyweight: false),
            .totalReps
        )
    }

    func testValidMetricIsPreservedForNonBodyweight() {
        XCTAssertEqual(
            resolvedMetric(
                current: .e1rm, isTimeBased: false, isBodyweightEquipment: false,
                includesBodyweight: false, hasUserBodyweight: false),
            .e1rm
        )
    }

    func testDurationFallsBackForNonTimeBased() {
        // Preserves existing behavior: leaving a time-based exercise resets the
        // stale duration metric to the first weight-based metric (e1RM).
        XCTAssertEqual(
            resolvedMetric(
                current: .totalDuration, isTimeBased: false, isBodyweightEquipment: false,
                includesBodyweight: false, hasUserBodyweight: false),
            .e1rm
        )
    }
}
