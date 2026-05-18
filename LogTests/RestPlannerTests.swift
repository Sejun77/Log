import XCTest

@testable import Log

/// Phase 7.4-C.1 — `RestPlanner` was extracted out of
/// `ActiveWorkoutView.restSecondsAfterCurrentLog` for the simplest
/// non-superset, non-dropset branches. These tests pin the fallback
/// chain and the two "skip rest" cases (next-template-is-dropset and
/// last-set-of-workout) so future refactors can't silently regress
/// rest behavior on the most common path.
///
/// Out of scope here: supersets, current-set-is-dropset (final-drop),
/// technique-based dropsets, warmup, and the `block.restAfterSeconds`
/// post-processing — those still live inline in `ActiveWorkoutView`.
final class RestPlannerTests: XCTestCase {

    // MARK: - Helpers

    private func makeCtx(
        setIndex: Int = 0,
        nextTemplateKind: SetKind? = .working,
        effectiveSetCount: Int = 3,
        plannedRestBetweenSets: Int? = nil,
        plannedRestAfterExercise: Int? = nil,
        templateRestSecondsAfter: Int? = nil,
        isLastSetOfWorkout: Bool = false
    ) -> RestContext {
        RestContext(
            setIndex: setIndex,
            nextTemplateKind: nextTemplateKind,
            effectiveSetCount: effectiveSetCount,
            plannedRestBetweenSets: plannedRestBetweenSets,
            plannedRestAfterExercise: plannedRestAfterExercise,
            templateRestSecondsAfter: templateRestSecondsAfter,
            isLastSetOfWorkout: isLastSetOfWorkout
        )
    }

    // MARK: - Non-final set fallback chain

    func testNonFinalSetUsesPlannedRestBetweenSets() {
        // a. plannedRestBetweenSets wins over template rest on a non-final set.
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: 75,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 75)
    }

    func testNonFinalSetFallsBackToTemplateRestSecondsAfter() {
        // b. With no planned rest, the template's restSecondsAfter is used.
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: nil,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 30)
    }

    func testNonFinalSetIgnoresPlannedRestAfterExercise() {
        // plannedRestAfterExercise is final-set-only and must NOT leak
        // into the non-final fallback chain.
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: nil,
            plannedRestAfterExercise: 999,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 30)
    }

    // MARK: - Final set fallback chain

    func testFinalSetPrefersPlannedRestAfterExercise() {
        // c. plannedRestAfterExercise wins over both other links on the final set.
        let ctx = makeCtx(
            setIndex: 2,
            nextTemplateKind: nil,
            plannedRestBetweenSets: 60,
            plannedRestAfterExercise: 120,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 120)
    }

    func testFinalSetFallsBackToPlannedRestBetweenSets() {
        // d. With no plannedRestAfterExercise, plannedRestBetweenSets is used.
        let ctx = makeCtx(
            setIndex: 2,
            nextTemplateKind: nil,
            plannedRestBetweenSets: 60,
            plannedRestAfterExercise: nil,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 60)
    }

    func testFinalSetFallsBackToTemplateRestSecondsAfter() {
        // e. With no planned values, the template's restSecondsAfter is used.
        let ctx = makeCtx(
            setIndex: 2,
            nextTemplateKind: nil,
            plannedRestBetweenSets: nil,
            plannedRestAfterExercise: nil,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 30)
    }

    // MARK: - Skip when next template is a dropset

    func testReturnsNilWhenNextTemplateIsDropset() {
        // f. Skipping rest before a template-based dropset means the user
        // proceeds directly to the drop without resting first.
        let ctx = makeCtx(
            setIndex: 0,
            nextTemplateKind: .dropset,
            effectiveSetCount: 3,
            plannedRestBetweenSets: 90,
            templateRestSecondsAfter: 30
        )
        XCTAssertNil(RestPlanner.restSecondsAfterLog(ctx))
    }

    func testDropsetNextCheckIsIgnoredOnFinalSet() {
        // The "next is dropset" guard only fires when there IS a next set.
        // On the final set, the planned-rest-after-exercise chain wins.
        let ctx = makeCtx(
            setIndex: 2,
            nextTemplateKind: .dropset,
            effectiveSetCount: 3,
            plannedRestAfterExercise: 90
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 90)
    }

    // MARK: - Last set of workout suppression

    func testLastSetOfWorkoutReturnsNil() {
        // g. Even with every planned-rest value set, the suppression wins.
        let ctx = makeCtx(
            setIndex: 2,
            nextTemplateKind: nil,
            effectiveSetCount: 3,
            plannedRestBetweenSets: 60,
            plannedRestAfterExercise: 120,
            templateRestSecondsAfter: 30,
            isLastSetOfWorkout: true
        )
        XCTAssertNil(RestPlanner.restSecondsAfterLog(ctx))
    }

    // MARK: - Zero / negative normalization

    func testZeroTemplateRestNormalizesToNil() {
        // h. The inline `r > 0` filter must be preserved: a literal 0
        // from the template means "no rest", not "0 seconds of rest".
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: nil,
            templateRestSecondsAfter: 0
        )
        XCTAssertNil(RestPlanner.restSecondsAfterLog(ctx))
    }

    func testNegativeTemplateRestNormalizesToNil() {
        // h (cont'd). Negative template rest should also fall out.
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: nil,
            templateRestSecondsAfter: -10
        )
        XCTAssertNil(RestPlanner.restSecondsAfterLog(ctx))
    }

    func testAllNilReturnsNil() {
        // No rest configured anywhere — planner must return nil rather
        // than starting a 0-second timer.
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: nil,
            plannedRestAfterExercise: nil,
            templateRestSecondsAfter: nil
        )
        XCTAssertNil(RestPlanner.restSecondsAfterLog(ctx))
    }
}
