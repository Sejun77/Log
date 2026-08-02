import XCTest

@testable import Log

/// Duration & rest input rules (Friends & Family Beta, 2026-08-02).
///
/// Before this slice every seconds-valued editor was a `Stepper` bounded at
/// 600s (prescription duration/rest, in-workout Edit Plan) or 300s (Settings
/// rest defaults, warm-up step rest, superset round rest). These tests pin the
/// new bounds and — more importantly — the normalization contract every editor
/// now shares, so a value entered in one screen can never be out of range in
/// another.
final class DurationInputTests: XCTestCase {

    // MARK: - 1. Bounds

    func testExerciseDurationBoundIsSixHours() {
        XCTAssertEqual(DurationLimits.maxExerciseSeconds, 21_600)
    }

    func testRestBoundIsSixtyMinutes() {
        XCTAssertEqual(DurationLimits.maxRestSeconds, 3_600)
    }

    // MARK: - 2. Long values are accepted up to the max

    func testLongDurationValuesAreAcceptedUpToTheMax() {
        // 30m, 45m, 1h, 2h, and the bound itself all survive unchanged.
        for seconds in [1_800, 2_700, 3_600, 7_200, 21_600] {
            XCTAssertEqual(
                DurationLimits.normalizedExerciseDuration(seconds), seconds,
                "\(seconds)s should be storable as an exercise duration")
        }
    }

    func testRestValuesAreAcceptedUpToTheMax() {
        for seconds in [90, 180, 600, 1_800, 3_600] {
            XCTAssertEqual(
                DurationLimits.normalizedRest(seconds), seconds,
                "\(seconds)s should be storable as rest")
        }
    }

    /// The concrete beta complaint: a 30+ minute cardio target has to fit.
    func testDurationExerciseCanRepresentLongCardio() {
        var plan = SessionPlan()
        plan.usesDuration = true
        plan.durationMinSeconds = DurationLimits.normalizedExerciseDuration(1_800)
        plan.durationMaxSeconds = DurationLimits.normalizedExerciseDuration(2_700)

        XCTAssertEqual(plan.durationMinSeconds, 1_800)
        XCTAssertEqual(plan.durationMaxSeconds, 2_700)
        XCTAssertEqual(DurationFormat.compact(2_700), "45m")
    }

    // MARK: - 3. Values above the max clamp

    func testValuesAboveMaxClampToTheMax() {
        XCTAssertEqual(
            DurationLimits.normalizedExerciseDuration(99_999), 21_600)
        XCTAssertEqual(DurationLimits.normalizedRest(99_999), 3_600)
        XCTAssertEqual(DurationLimits.clamped(99_999, max: 3_600), 3_600)
    }

    /// Clamping is the same rule for both storage shapes, so the optional and
    /// non-optional editors can never disagree about the ceiling.
    func testClampingIsConsistentAcrossOptionalAndNonOptionalForms() {
        let over = DurationLimits.maxRestSeconds + 500
        XCTAssertEqual(
            DurationLimits.normalizedRest(over),
            DurationLimits.clamped(over, max: DurationLimits.maxRestSeconds))
    }

    // MARK: - 4. Negative values are normalized safely

    func testNegativeValuesNeverStore() {
        XCTAssertNil(DurationLimits.normalizedExerciseDuration(-1))
        XCTAssertNil(DurationLimits.normalizedRest(-600))
        XCTAssertEqual(DurationLimits.clamped(-600, max: 3_600), 0)
    }

    /// Zero collapses to nil, preserving the "0 means unset / none" convention
    /// the steppers used, so a cleared field reads as unset rather than as a
    /// real zero-second target.
    func testZeroCollapsesToUnset() {
        XCTAssertNil(DurationLimits.normalizedExerciseDuration(0))
        XCTAssertNil(DurationLimits.normalizedRest(0))
    }

    func testNilStaysNil() {
        XCTAssertNil(DurationLimits.normalizedExerciseDuration(nil))
        XCTAssertNil(DurationLimits.normalizedRest(nil))
    }

    // MARK: - 5. Free-text parsing (active workout duration field)

    func testEmptyInputResolvesToUnsetRatherThanZero() {
        for text in ["", "   ", "\n"] {
            XCTAssertNil(
                DurationLimits.parseSeconds(
                    text, max: DurationLimits.maxExerciseSeconds),
                "\(text.debugDescription) should resolve to nil")
        }
    }

    func testNonNumericInputResolvesToUnset() {
        for text in ["abc", "1m30s", "12.5", "--"] {
            XCTAssertNil(
                DurationLimits.parseSeconds(
                    text, max: DurationLimits.maxExerciseSeconds),
                "\(text.debugDescription) should resolve to nil")
        }
    }

    func testParsedInputIsTrimmedClampedAndNonNegative() {
        XCTAssertEqual(
            DurationLimits.parseSeconds(
                " 2700 ", max: DurationLimits.maxExerciseSeconds),
            2_700)
        XCTAssertEqual(
            DurationLimits.parseSeconds(
                "999999", max: DurationLimits.maxExerciseSeconds),
            21_600)
        XCTAssertNil(
            DurationLimits.parseSeconds(
                "-30", max: DurationLimits.maxExerciseSeconds))
        XCTAssertNil(
            DurationLimits.parseSeconds(
                "0", max: DurationLimits.maxExerciseSeconds))
    }

    // MARK: - 6. Short holds still work

    /// Plank / Hollow Hold / Wall Sit territory — raising the ceiling must not
    /// have introduced a floor.
    func testShortDurationExercisesAreUnaffected() {
        for seconds in [10, 20, 30, 45, 60, 90] {
            XCTAssertEqual(
                DurationLimits.normalizedExerciseDuration(seconds), seconds)
        }
        XCTAssertEqual(DurationFormat.compact(30), "30s")
        XCTAssertEqual(DurationFormat.compact(45), "45s")
        XCTAssertEqual(DurationFormat.compact(90), "1m 30s")
    }

    // MARK: - 7. Compact formatting

    func testCompactFormatting() {
        XCTAssertEqual(DurationFormat.compact(0), "0s")
        XCTAssertEqual(DurationFormat.compact(5), "5s")
        XCTAssertEqual(DurationFormat.compact(60), "1m")
        XCTAssertEqual(DurationFormat.compact(90), "1m 30s")
        XCTAssertEqual(DurationFormat.compact(600), "10m")
        XCTAssertEqual(DurationFormat.compact(1_800), "30m")
        XCTAssertEqual(DurationFormat.compact(3_600), "1h")
        XCTAssertEqual(DurationFormat.compact(3_930), "1h 5m 30s")
        XCTAssertEqual(DurationFormat.compact(21_600), "6h")
    }

    func testCompactFormattingFloorsNegativeInput() {
        XCTAssertEqual(DurationFormat.compact(-42), "0s")
    }

    // MARK: - 8. Wheel component round-trip

    func testComponentsRoundTripThroughTotalSeconds() {
        for seconds in [0, 1, 59, 60, 61, 599, 1_800, 3_600, 3_930, 21_600] {
            let c = DurationFormat.components(seconds)
            XCTAssertEqual(
                DurationFormat.totalSeconds(
                    hours: c.hours, minutes: c.minutes, seconds: c.seconds),
                seconds,
                "\(seconds)s should round-trip through h/m/s")
        }
    }

    func testComponentsAndTotalFloorNegativeInput() {
        let c = DurationFormat.components(-100)
        XCTAssertEqual(c.hours, 0)
        XCTAssertEqual(c.minutes, 0)
        XCTAssertEqual(c.seconds, 0)
        XCTAssertEqual(
            DurationFormat.totalSeconds(hours: -1, minutes: -1, seconds: -1), 0)
    }

    // MARK: - 9. Presets

    /// Presets exist to remove the tap count, so every one of them must be
    /// reachable within its field's bound.
    func testPresetsStayWithinTheirBounds() {
        for value in DurationPresets.exerciseDuration {
            XCTAssertGreaterThan(value, 0)
            XCTAssertLessThanOrEqual(value, DurationLimits.maxExerciseSeconds)
        }
        for value in DurationPresets.rest {
            XCTAssertGreaterThan(value, 0)
            XCTAssertLessThanOrEqual(value, DurationLimits.maxRestSeconds)
        }
    }

    /// The tester's specific case: 30 minutes must be one tap, not 120.
    func testDurationPresetsCoverLongCardio() {
        XCTAssertTrue(DurationPresets.exerciseDuration.contains(1_800))
        XCTAssertTrue(DurationPresets.exerciseDuration.contains(2_700))
    }
}
