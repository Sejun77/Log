import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 5 — what a routine slot offers, by tracking mode.
///
/// `CardioRoutineRules` exists because the prescription editor is a `View` and
/// cannot be instantiated in a unit test. Every rule the editor applies is a
/// pure function there, and this file is the specification those functions
/// satisfy.
///
/// Half of the assertions below are about `.strength` and `.timedHold` — they
/// pin that this slice changed **nothing** for a bench press or a plank.
@MainActor
final class CardioRoutineRulesTests: SwiftDataTestHarness {

    private func exercise(
        name: String, timeBased: Bool = false, cardio: Bool = false
    ) -> Exercise {
        let ex = Exercise(name: name)
        context.insert(ex)
        ex.setTimeBased(timeBased)
        ex.setCardio(cardio)
        return ex
    }

    private func bench() -> Exercise { exercise(name: "Bench Press") }
    private func plank() -> Exercise { exercise(name: "Plank", timeBased: true) }
    private func treadmill() -> Exercise {
        exercise(name: "Treadmill Run", timeBased: true, cardio: true)
    }

    // MARK: - 11–13. Target distance visibility

    func testTargetDistanceShowsOnlyForCardio() {
        XCTAssertTrue(CardioRoutineRules.showsTargetDistance(.cardio))
        XCTAssertFalse(CardioRoutineRules.showsTargetDistance(.strength))
        XCTAssertFalse(CardioRoutineRules.showsTargetDistance(.timedHold))
    }

    /// Resolved from the live exercise the way the editor resolves it.
    func testTargetDistanceVisibilityFollowsTheExercise() {
        XCTAssertTrue(
            CardioRoutineRules.showsTargetDistance(treadmill().trackingMode))
        XCTAssertFalse(
            CardioRoutineRules.showsTargetDistance(plank().trackingMode),
            "a Plank slot must not offer a distance target")
        XCTAssertFalse(
            CardioRoutineRules.showsTargetDistance(bench().trackingMode))
    }

    // MARK: - 17–22. Suppressed controls

    func testCardioHidesWarmupScheme() {
        XCTAssertFalse(CardioRoutineRules.showsWarmupScheme(.cardio))
    }

    func testStrengthAndTimedHoldKeepWarmupScheme() {
        XCTAssertTrue(CardioRoutineRules.showsWarmupScheme(.strength))
        XCTAssertTrue(
            CardioRoutineRules.showsWarmupScheme(.timedHold),
            "a weighted plank still warms up")
    }

    func testCardioHidesTechniques() {
        XCTAssertFalse(CardioRoutineRules.showsTechniques(.cardio))
    }

    func testStrengthAndTimedHoldKeepTechniques() {
        XCTAssertTrue(CardioRoutineRules.showsTechniques(.strength))
        XCTAssertTrue(CardioRoutineRules.showsTechniques(.timedHold))
    }

    /// Tempo was already hidden for every duration slot; cardio changes
    /// nothing about that rule, it only restates it.
    func testTempoShowsOnlyForStrength() {
        XCTAssertTrue(CardioRoutineRules.showsTempo(.strength))
        XCTAssertFalse(CardioRoutineRules.showsTempo(.timedHold))
        XCTAssertFalse(CardioRoutineRules.showsTempo(.cardio))
    }

    // MARK: - 23–24. Effort control

    func testCardioHidesTheCombinedEffortControl() {
        XCTAssertFalse(CardioRoutineRules.showsEffortControl(.cardio))
    }

    func testStrengthAndTimedHoldKeepTheEffortControl() {
        XCTAssertTrue(CardioRoutineRules.showsEffortControl(.strength))
        XCTAssertTrue(CardioRoutineRules.showsEffortControl(.timedHold))
    }

    /// The routine editor and the three active-workout display sites must not
    /// drift: both read the same predicate.
    func testEffortRuleIsSharedWithTheActiveWorkout() {
        for mode in [TrackingMode.strength, .timedHold, .cardio] {
            XCTAssertEqual(
                CardioRoutineRules.showsEffortControl(mode),
                WorkoutEffortTargetResolver.isEffortApplicable(to: mode))
        }
    }

    // MARK: - 14–16. New-slot defaults

    func testCardioDefaultsToOneSet() {
        XCTAssertEqual(CardioRoutineRules.defaultSets(.cardio), 1)
    }

    func testNonCardioKeepsTheUserDefaultSetCount() {
        XCTAssertEqual(
            CardioRoutineRules.defaultSets(.strength), AppSettings.defaultSets)
        XCTAssertEqual(
            CardioRoutineRules.defaultSets(.timedHold), AppSettings.defaultSets)
    }

    func testCardioDefaultsToNoRest() {
        XCTAssertNil(CardioRoutineRules.defaultRestBetweenSets(.cardio))
        XCTAssertNil(CardioRoutineRules.defaultRestAfterExercise(.cardio))
    }

    func testNonCardioKeepsTheUserDefaultRest() {
        XCTAssertEqual(
            CardioRoutineRules.defaultRestBetweenSets(.strength),
            AppSettings.defaultRestBetweenSets)
        XCTAssertEqual(
            CardioRoutineRules.defaultRestBetweenSets(.timedHold),
            AppSettings.defaultRestBetweenSets)
    }

    func testCardioSeedsNoEffortTarget() {
        XCTAssertFalse(CardioRoutineRules.seedsEffortTarget(.cardio))
        XCTAssertTrue(CardioRoutineRules.seedsEffortTarget(.strength))
        XCTAssertTrue(CardioRoutineRules.seedsEffortTarget(.timedHold))
    }

    // MARK: - The factory applies them

    func testNewCardioSlotGetsOneSetNoRestAndNoEffort() {
        let p = makeDefaultPrescription(
            isTimeBased: true, isCardio: true, in: context)

        XCTAssertEqual(p.sets, 1)
        XCTAssertNil(p.restSecondsBetweenSets)
        XCTAssertNil(p.restSecondsAfterExercise)
        XCTAssertTrue(p.usesDuration)
        XCTAssertNil(p.repMin)
        XCTAssertNil(p.repMax)
        // A hidden control must not leave a value the block summary would show.
        XCTAssertNil(p.rir)
        XCTAssertNil(p.rpe)
        XCTAssertNil(p.targetDistanceMeters)
    }

    func testNewStrengthSlotIsUnchanged() {
        let p = makeDefaultPrescription(isTimeBased: false, in: context)

        XCTAssertEqual(p.sets, AppSettings.defaultSets)
        XCTAssertEqual(p.repMin, AppSettings.defaultRepMin)
        XCTAssertEqual(p.repMax, AppSettings.defaultRepMax)
        XCTAssertEqual(
            p.restSecondsBetweenSets, AppSettings.defaultRestBetweenSets)
        XCTAssertFalse(p.usesDuration)
        XCTAssertNil(p.targetDistanceMeters)

        switch AppSettings.autoregMode {
        case .rir: XCTAssertEqual(p.rir, AppSettings.defaultRIR)
        case .rpe: XCTAssertEqual(p.rpe, AppSettings.defaultRPE)
        case .none: XCTAssertNil(p.rir)
        }
    }

    func testNewTimedHoldSlotIsUnchanged() {
        let p = makeDefaultPrescription(isTimeBased: true, in: context)

        XCTAssertEqual(p.sets, AppSettings.defaultSets)
        XCTAssertEqual(
            p.restSecondsBetweenSets, AppSettings.defaultRestBetweenSets)
        XCTAssertTrue(p.usesDuration)
        XCTAssertNil(p.repMin)
        XCTAssertNil(p.targetDistanceMeters)

        switch AppSettings.autoregMode {
        case .rir: XCTAssertEqual(p.rir, AppSettings.defaultRIR)
        case .rpe: XCTAssertEqual(p.rpe, AppSettings.defaultRPE)
        case .none: XCTAssertNil(p.rir)
        }
    }

    /// The `isCardio` argument defaults to false, so every call site written
    /// before this slice produces exactly what it produced before.
    func testFactoryDefaultsToNonCardio() {
        let implicit = makeDefaultPrescription(isTimeBased: true, in: context)
        let explicit = makeDefaultPrescription(
            isTimeBased: true, isCardio: false, in: context)

        XCTAssertEqual(implicit.sets, explicit.sets)
        XCTAssertEqual(
            implicit.restSecondsBetweenSets, explicit.restSecondsBetweenSets)
        XCTAssertEqual(implicit.rir, explicit.rir)
    }

    /// A caller passing the inconsistent pair (cardio but not time-based) gets
    /// the safe reading — a strength slot — rather than a distance target on a
    /// reps prescription. The invariant is enforced on `Exercise`, but the
    /// factory does not assume its callers respected it.
    func testCardioWithoutTimeBasedResolvesToStrengthDefaults() {
        let p = makeDefaultPrescription(
            isTimeBased: false, isCardio: true, in: context)

        XCTAssertEqual(p.sets, AppSettings.defaultSets)
        XCTAssertFalse(p.usesDuration)
        XCTAssertEqual(p.repMin, AppSettings.defaultRepMin)
    }

    // MARK: - Suppression never deletes

    /// Hiding a control must not remove what it edits: a slot that already
    /// carries a warm-up scheme, a technique plan or an effort value keeps all
    /// three after being marked cardio, so switching back restores them.
    func testMarkingAnExerciseCardioDoesNotEraseExistingProgramming() throws {
        let ex = exercise(name: "Rowing Machine")
        let p = makeDefaultPrescription(isTimeBased: false, in: context)
        p.rir = 2
        p.tempo = "3-1-3-0"

        let scheme = WarmupScheme(name: "Warmup")
        context.insert(scheme)
        p.warmupScheme = scheme

        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = p
        try context.save()

        // The user ticks Time-based, then Cardio in Exercise Detail.
        ex.setTimeBased(true)
        ex.setCardio(true)
        try context.save()

        XCTAssertEqual(ex.trackingMode, .cardio)
        XCTAssertFalse(CardioRoutineRules.showsWarmupScheme(ex.trackingMode))
        XCTAssertNotNil(
            p.warmupScheme,
            "suppression is display-only — the scheme must survive")
        XCTAssertEqual(p.rir, 2, "the effort value must survive too")
        XCTAssertEqual(p.tempo, "3-1-3-0")
    }
}
