import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 2 — schema + invariant canary for `Exercise.isCardio`
/// and the derived `Exercise.trackingMode`.
///
/// Cardio is modelled as a *facet* of duration rather than a sibling of it, so
/// the whole contract is two stored `Bool`s plus one rule: `isCardio == true`
/// implies `isTimeBased == true`. These tests pin that rule at both write sites
/// (`setTimeBased` / `setCardio`), pin the safe degradation when the rule is
/// violated anyway, and pin the migration promise that nothing existing turns
/// into cardio on its own.
///
/// `setTimeBased` / `setCardio` are exactly what the Exercise Detail toggles
/// bind to (`ExercisesView.optionsSection`), so these double as the
/// view-behavior tests for that screen — the project has no view models, and
/// the single `LogUITests` happy-path flow does not cover Exercise Detail
/// options.
@MainActor
final class ExerciseTrackingModeTests: SwiftDataTestHarness {

    // MARK: - Defaults

    func testIsCardioDefaultsToFalse() {
        let ex = Exercise(name: "Bench Press")
        context.insert(ex)

        XCTAssertFalse(ex.isCardio)
    }

    /// A pre-Slice-2 row has no `isCardio` column; SwiftData's lightweight
    /// migration fills the default. Round-tripping through the store asserts
    /// the default is the one that survives, not just an in-memory init value.
    func testIsCardioDefaultsToFalseThroughStore() throws {
        let ex = Exercise(name: "Plank")
        ex.isTimeBased = true
        context.insert(ex)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.isCardio, false)
        XCTAssertEqual(fetched.first?.trackingMode, .timedHold)
    }

    func testIsCardioRoundTripsThroughStore() throws {
        let ex = Exercise(name: "Treadmill Run", bodyPart: "Cardio")
        ex.setTimeBased(true)
        ex.setCardio(true)
        context.insert(ex)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(fetched.first?.isCardio, true)
        XCTAssertEqual(fetched.first?.trackingMode, .cardio)
    }

    // MARK: - Derived tracking mode

    func testTrackingModeIsStrengthForNonTimeBased() {
        let ex = Exercise(name: "Bench Press")
        context.insert(ex)

        XCTAssertEqual(ex.trackingMode, .strength)
    }

    func testTrackingModeIsTimedHoldForTimeBasedNonCardio() {
        let ex = Exercise(name: "Plank")
        ex.setTimeBased(true)
        context.insert(ex)

        XCTAssertEqual(ex.trackingMode, .timedHold)
    }

    func testTrackingModeIsCardioForTimeBasedCardio() {
        let ex = Exercise(name: "Treadmill Run")
        ex.setTimeBased(true)
        ex.setCardio(true)
        context.insert(ex)

        XCTAssertEqual(ex.trackingMode, .cardio)
    }

    /// The impossible state — only reachable by writing the stored property
    /// directly (a hand-edited store, or a future importer bug). `trackingMode`
    /// reads `isTimeBased` first, so it degrades to `.strength` instead of
    /// trapping or claiming a cardio exercise with no duration field.
    func testImpossibleStateDegradesToStrength() {
        let ex = Exercise(name: "Corrupted Row")
        ex.isTimeBased = false
        ex.isCardio = true  // deliberately bypasses setCardio
        context.insert(ex)

        XCTAssertEqual(ex.trackingMode, .strength)
    }

    // MARK: - Invariant enforcement at the write sites

    func testTurningOffTimeBasedClearsCardio() {
        let ex = Exercise(name: "Treadmill Run")
        ex.setTimeBased(true)
        ex.setCardio(true)
        context.insert(ex)
        XCTAssertEqual(ex.trackingMode, .cardio)

        ex.setTimeBased(false)

        XCTAssertFalse(ex.isCardio)
        XCTAssertFalse(ex.isTimeBased)
        XCTAssertEqual(ex.trackingMode, .strength)
    }

    /// Re-enabling time-based must not resurrect the cleared cardio flag —
    /// the user opts back in explicitly.
    func testTurningTimeBasedBackOnDoesNotRestoreCardio() {
        let ex = Exercise(name: "Treadmill Run")
        ex.setTimeBased(true)
        ex.setCardio(true)
        context.insert(ex)

        ex.setTimeBased(false)
        ex.setTimeBased(true)

        XCTAssertFalse(ex.isCardio)
        XCTAssertEqual(ex.trackingMode, .timedHold)
    }

    /// The Cardio toggle is hidden for strength exercises, but the write site
    /// refuses the write anyway so the invariant does not depend on the UI.
    func testSetCardioIsRefusedForNonTimeBasedExercise() {
        let ex = Exercise(name: "Bench Press")
        context.insert(ex)

        ex.setCardio(true)

        XCTAssertFalse(ex.isCardio)
        XCTAssertEqual(ex.trackingMode, .strength)
    }

    /// `setCardio` also repairs a pre-existing impossible state rather than
    /// leaving it in place.
    func testSetCardioClearsStaleFlagOnNonTimeBasedExercise() {
        let ex = Exercise(name: "Corrupted Row")
        ex.isCardio = true  // deliberately bypasses setCardio
        context.insert(ex)

        ex.setCardio(false)

        XCTAssertFalse(ex.isCardio)
        XCTAssertEqual(ex.trackingMode, .strength)
    }

    func testCardioCanBeTurnedOffWithoutAffectingTimeBased() {
        let ex = Exercise(name: "Treadmill Run")
        ex.setTimeBased(true)
        ex.setCardio(true)
        context.insert(ex)

        ex.setCardio(false)

        XCTAssertTrue(ex.isTimeBased)
        XCTAssertEqual(ex.trackingMode, .timedHold)
    }

    // MARK: - Migration promise: nothing converts silently

    /// A duration exercise created the pre-Slice-2 way (direct assignment, as
    /// the seeder / CSV importer / routine transfer all do) stays a timed hold.
    func testExistingDurationExerciseIsNotAutomaticallyCardio() {
        let ex = Exercise(name: "Plank")
        ex.isTimeBased = true
        context.insert(ex)

        XCTAssertFalse(ex.isCardio)
        XCTAssertEqual(ex.trackingMode, .timedHold)
    }

    /// The `bodyPart == "Cardio"` case is the one the assisted migration prompt
    /// will later offer to convert. Until the user confirms it, nothing is
    /// written — this slice must not convert it.
    func testCardioBodyPartDurationExerciseIsNotAutomaticallyCardio() {
        let ex = Exercise(name: "Treadmill Run", bodyPart: "Cardio")
        ex.isTimeBased = true
        context.insert(ex)

        XCTAssertFalse(ex.isCardio)
        XCTAssertEqual(ex.trackingMode, .timedHold)
    }

    /// The seed catalogue marks cardio only where the body part says so.
    ///
    /// > **Superseded by Cardio Slice 10.** This test originally asserted the
    /// > opposite — that *no* seed is cardio and the catalogue version is still
    /// > 2 — which was Slice 2's deliberate deferral, not a product rule.
    /// > Slice 10 shipped catalogue v3, so what is worth pinning now is the
    /// > line the deferral was protecting: cardio is opt-in **by body part**,
    /// > never inferred from an exercise's name, and a timed hold like Plank is
    /// > not swept in with it.
    func testSeedCatalogueMarksCardioOnlyForTheCardioBodyPart() {
        let seeded = ExerciseCatalog.v1.map { seed -> Exercise in
            let ex = Exercise(
                name: seed.name,
                bodyPart: seed.bodyPart,
                isCustom: false
            )
            ex.setTimeBased(seed.isTimeBased)
            ex.setCardio(seed.isCardio)
            return ex
        }

        XCTAssertFalse(
            seeded.filter { $0.isCardio }.isEmpty,
            "catalogue v3 seeds cardio exercises"
        )
        for ex in seeded where ex.isCardio {
            XCTAssertEqual(
                ex.bodyPart, "Cardio",
                "\(ex.name) is marked cardio without the Cardio body part"
            )
        }
        XCTAssertEqual(
            seeded.first { $0.name == "Plank" }?.trackingMode, .timedHold,
            "a timed hold outside Cardio must stay a timed hold"
        )
        XCTAssertGreaterThanOrEqual(
            ExerciseCatalog.currentVersion, 3,
            "catalogue v3 is what delivers the cardio seeds to fresh installs"
        )
    }
}
