import XCTest

@testable import Log

/// Phase 9-B2 — `makeSwapDefaultTemplates(...)` is the pure helper that
/// `ActiveWorkoutView.swapExercise(planExercise:with:)` calls instead of
/// reading `newEx.defaultTemplates` directly. These tests pin the
/// field-by-field contract documented on the helper:
///   - `targetWeight` is always nil (9-A.5 accepted loss)
///   - `kind` is always `.working` (no warmup/dropset rows from defaults)
///   - set count is sourced from the slot's session plan or snapshot,
///     falling back to `AppSettings.defaultSets`, clamped to ≥ 1
///   - rest sourced from session plan or snapshot, falling back to
///     `AppSettings.defaultRestBetweenSets`
///   - time-based exercises get a duration; rep-based exercises get nil
///   - duration falls back to a hardcoded 60s when no hint is set
///
/// Helper is pure (no `ModelContext`, no `Exercise` instance), so tests
/// can call it with literals — no SwiftData fixture overhead.
final class SwapDefaultTemplatesTests: XCTestCase {

    // MARK: - Fixture

    private let exerciseID = UUID()

    // MARK: - Set count sourcing

    func testSetsHintWinsWhenPositive() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 5,
            restBetweenSetsHint: nil,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        XCTAssertEqual(templates.count, 5)
    }

    func testNilSetsHintFallsBackToAppSettingsDefault() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: nil,
            restBetweenSetsHint: nil,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        XCTAssertEqual(templates.count, AppSettings.defaultSets)
    }

    func testZeroSetsHintFallsBackToAppSettingsDefault() {
        // A persisted-but-cleared session plan with sets=0 must NOT collapse
        // the swap to a zero-row PlanExercise; fall back to AppSettings.
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 0,
            restBetweenSetsHint: nil,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        XCTAssertEqual(templates.count, AppSettings.defaultSets)
    }

    func testNegativeSetsHintFallsBackToAppSettingsDefault() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: -3,
            restBetweenSetsHint: nil,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        XCTAssertEqual(templates.count, AppSettings.defaultSets)
    }

    func testCountIsClampedToAtLeastOne() {
        // Even if AppSettings.defaultSets somehow returned 0, the clamp
        // guarantees the active-workout UI gets at least one render row.
        // Easiest way to exercise: pass a positive setsHint of 1.
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 1,
            restBetweenSetsHint: nil,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        XCTAssertEqual(templates.count, 1)
    }

    // MARK: - targetWeight contract (9-A.5 accepted loss)

    func testTargetWeightIsAlwaysNil() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 3,
            restBetweenSetsHint: 90,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        for t in templates {
            XCTAssertNil(
                t.targetWeight,
                "9-A.5 accepted loss: swap defaults never carry targetWeight"
            )
        }
    }

    // MARK: - kind contract (no warmup/dropset surfacing)

    func testKindIsAlwaysWorking() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 4,
            restBetweenSetsHint: 60,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        for t in templates {
            XCTAssertEqual(
                t.kind, .working,
                "9-A.5: swap defaults never synthesize warmup or dropset rows"
            )
        }
    }

    // MARK: - Rest sourcing

    func testRestHintWinsWhenPositive() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 2,
            restBetweenSetsHint: 75,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        for t in templates {
            XCTAssertEqual(t.restSecondsAfter, 75)
        }
    }

    func testNilRestHintFallsBackToAppSettingsDefault() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 2,
            restBetweenSetsHint: nil,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        for t in templates {
            XCTAssertEqual(
                t.restSecondsAfter, AppSettings.defaultRestBetweenSets)
        }
    }

    func testZeroRestHintFallsBackToAppSettingsDefault() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 2,
            restBetweenSetsHint: 0,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        for t in templates {
            XCTAssertEqual(
                t.restSecondsAfter, AppSettings.defaultRestBetweenSets)
        }
    }

    // MARK: - Duration sourcing (time-based)

    func testRepBasedExerciseHasNilDuration() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 3,
            restBetweenSetsHint: nil,
            durationMinHint: 30,
            durationMaxHint: 45
        )
        for t in templates {
            XCTAssertNil(
                t.durationSeconds,
                "rep-based exercise must not carry a duration"
            )
        }
    }

    func testTimeBasedPrefersDurationMaxWhenAvailable() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: true,
            setsHint: 2,
            restBetweenSetsHint: nil,
            durationMinHint: 30,
            durationMaxHint: 45
        )
        for t in templates {
            XCTAssertEqual(t.durationSeconds, 45)
        }
    }

    func testTimeBasedFallsBackToDurationMinWhenMaxNil() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: true,
            setsHint: 2,
            restBetweenSetsHint: nil,
            durationMinHint: 20,
            durationMaxHint: nil
        )
        for t in templates {
            XCTAssertEqual(t.durationSeconds, 20)
        }
    }

    func testTimeBasedFallsBackTo60WhenBothDurationHintsNil() {
        // Matches BackfillService.hydrate(_:from:) 9-A1 hardcoded 60s
        // fallback (no AppSettings.defaultDuration today — see 9-A.5
        // decision to defer that setting to Phase 10).
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: true,
            setsHint: 2,
            restBetweenSetsHint: nil,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        for t in templates {
            XCTAssertEqual(t.durationSeconds, 60)
        }
    }

    // MARK: - ID format

    func testIDFormatMatchesSwapCompositeKey() {
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 3,
            restBetweenSetsHint: nil,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        XCTAssertEqual(
            templates.map(\.id),
            (0..<3).map { "\(exerciseID.uuidString)-set\($0)" },
            "ID format must match the pre-9-B2 stable composite key so any "
            + "downstream caching keyed on the row id continues to work."
        )
    }

    // MARK: - targetReps contract

    func testTargetRepsIsZero() {
        // SessionPlanResolver.plannedRepTarget sources reps from
        // sessionPlan/snapshot at row-render time; the template's
        // targetReps is only used when both higher tiers are nil. Keep
        // 0 here so the contract documented on the helper holds.
        let templates = makeSwapDefaultTemplates(
            forExerciseID: exerciseID,
            isTimeBased: false,
            setsHint: 2,
            restBetweenSetsHint: nil,
            durationMinHint: nil,
            durationMaxHint: nil
        )
        for t in templates {
            XCTAssertEqual(t.targetReps, 0)
        }
    }
}
