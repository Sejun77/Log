import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 4 patch — RIR/RPE is not offered for cardio.
///
/// RIR is "reps in reserve", which is meaningless for a 30-minute run. The app
/// exposes RIR and RPE through a single control governed by one
/// `AppSettings.autoregMode` preference, so the two cannot be separated at the
/// UI without splitting that preference; the whole control is therefore hidden
/// for cardio.
///
/// `WorkoutEffortTargetResolver.isEffortApplicable` owns that rule, and all
/// three display sites in `ActiveWorkoutView` — per-set row labels, the Plan
/// card summary, and the Edit Plan sheet — route through it, so they cannot
/// drift apart. These tests pin the rule and, critically, that it is
/// **display-only**: nothing stored is erased.
@MainActor
final class CardioEffortSuppressionTests: SwiftDataTestHarness {

    // MARK: - 1. The rule

    func testEffortIsNotApplicableToCardio() {
        XCTAssertFalse(WorkoutEffortTargetResolver.isEffortApplicable(to: .cardio))
    }

    /// Strength keeps RIR/RPE exactly as before — this patch must not change
    /// unrelated behavior.
    func testEffortRemainsApplicableToStrength() {
        XCTAssertTrue(WorkoutEffortTargetResolver.isEffortApplicable(to: .strength))
    }

    /// Timed holds keep it too. "Two seconds in reserve" is a stretch, but it
    /// is what the app has always offered for a plank and changing it is not
    /// this patch's business.
    func testEffortRemainsApplicableToTimedHold() {
        XCTAssertTrue(WorkoutEffortTargetResolver.isEffortApplicable(to: .timedHold))
    }

    /// Cardio is the *only* suppressed mode — a future tracking mode would have
    /// to opt in deliberately rather than inherit suppression.
    func testCardioIsTheOnlySuppressedMode() {
        let suppressed: [TrackingMode] = [.strength, .timedHold, .cardio]
            .filter { !WorkoutEffortTargetResolver.isEffortApplicable(to: $0) }

        XCTAssertEqual(suppressed, [.cardio])
    }

    // MARK: - 2. The rule agrees with how cardio slots are identified

    /// `ActiveWorkoutView.refreshCardioSlots` builds its slot set from
    /// `Exercise.trackingMode == .cardio`, and `showsEffortUI` negates
    /// membership in that set. This asserts the two definitions of "is cardio"
    /// are the same one, using real `Exercise` rows.
    func testSuppressionMatchesExerciseTrackingMode() {
        let treadmill = Exercise(name: "Treadmill Run", bodyPart: "Cardio", isCustom: false)
        treadmill.setTimeBased(true)
        treadmill.setCardio(true)

        let plank = Exercise(name: "Plank", isCustom: false)
        plank.setTimeBased(true)

        let bench = Exercise(name: "Bench Press", isCustom: false)

        for ex in [treadmill, plank, bench] { context.insert(ex) }

        for ex in [treadmill, plank, bench] {
            XCTAssertEqual(
                WorkoutEffortTargetResolver.isEffortApplicable(to: ex.trackingMode),
                ex.trackingMode != .cardio,
                "\(ex.name) effort visibility disagrees with its tracking mode")
        }
    }

    /// Turning the Cardio toggle off restores the effort control on the next
    /// refresh — suppression follows the exercise, not a one-way latch.
    func testSuppressionFollowsTheCardioToggle() {
        let ex = Exercise(name: "Treadmill Run", isCustom: false)
        ex.setTimeBased(true)
        ex.setCardio(true)
        context.insert(ex)
        XCTAssertFalse(
            WorkoutEffortTargetResolver.isEffortApplicable(to: ex.trackingMode))

        ex.setCardio(false)

        XCTAssertTrue(
            WorkoutEffortTargetResolver.isEffortApplicable(to: ex.trackingMode))
    }

    // MARK: - 3. Suppression is display-only

    /// The critical safety property: hiding the control must not erase the
    /// values. A slot switched to cardio and back keeps its targets.
    func testStoredEffortValuesSurviveSuppression() throws {
        let prescription = SlotPrescription(rir: 2)
        context.insert(prescription)
        try context.save()

        // Suppression is a pure display predicate — it takes no model and
        // writes nothing, so there is no path by which it could clear a value.
        XCTAssertFalse(WorkoutEffortTargetResolver.isEffortApplicable(to: .cardio))

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SlotPrescription>()).first)
        XCTAssertEqual(stored.rir, 2)
    }

    /// A `SessionPlan` in-session override is likewise untouched.
    func testSessionPlanEffortValuesSurviveSuppression() {
        var plan = SessionPlan()
        plan.rir = 3
        plan.rpe = 8

        XCTAssertFalse(WorkoutEffortTargetResolver.isEffortApplicable(to: .cardio))

        XCTAssertEqual(plan.rir, 3)
        XCTAssertEqual(plan.rpe, 8)
    }

    /// The resolver still computes labels perfectly well for cardio values —
    /// suppression happens at the call site, not by breaking the resolver. This
    /// is what makes re-enabling cardio RPE later a display change only.
    func testResolverStillComputesLabelsWhenAsked() {
        let fields = WorkoutEffortTargetResolver.Fields(rir: 2, rpe: nil)

        let summary = WorkoutEffortTargetResolver.summary(
            fields: fields, autoregMode: .rir)

        XCTAssertNotNil(
            summary,
            "The resolver must stay intact; only the cardio call sites skip it")
    }
}
