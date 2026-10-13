import XCTest

@testable import Log

/// Finish-safety tests for the active-workout bottom "Next / Finish" button.
///
/// `ActiveWorkoutView.next()` is a `private` method on a SwiftUI `View` and not
/// directly testable, but it delegates the whole navigation decision to the
/// pure `workoutNextAction(...)` helper. The safety-critical contract is:
/// reaching the last step of the workout resolves to `.confirmFinish` (which
/// only *presents* the finish confirmation dialog) and NEVER finishes the
/// workout outright — so spam-tapping Next near the end cannot skip the
/// confirmation. `finishWorkout(...)` is invoked solely from the confirmation
/// dialog's or the Save Routine Changes sheet's buttons, so a `.confirmFinish`
/// that requires a user tap is exactly the "finish requires confirmation /
/// cancel keeps the workout / confirm finishes" behavior.
final class ActiveWorkoutFinishConfirmTests: XCTestCase {

    // MARK: - Advancing within a block

    func test_notLastExercise_advancesExercise() {
        // Block 0 has 3 exercises; currently at exercise 0.
        let action = workoutNextAction(
            currentBlockIndex: 0,
            currentExerciseIndex: 0,
            exerciseCountsPerBlock: [3, 2])
        XCTAssertEqual(action, .advanceExercise(1))
    }

    func test_middleExercise_advancesToNextExercise() {
        let action = workoutNextAction(
            currentBlockIndex: 0,
            currentExerciseIndex: 1,
            exerciseCountsPerBlock: [3, 2])
        XCTAssertEqual(action, .advanceExercise(2))
    }

    // MARK: - Advancing across blocks

    func test_lastExerciseOfNonLastBlock_advancesBlock() {
        // At the last exercise (index 2) of block 0, but block 1 still remains.
        let action = workoutNextAction(
            currentBlockIndex: 0,
            currentExerciseIndex: 2,
            exerciseCountsPerBlock: [3, 2])
        XCTAssertEqual(action, .advanceBlock)
    }

    // MARK: - Finish requires confirmation (never finishes directly)

    func test_lastExerciseOfLastBlock_confirmsFinishNeverFinishesDirectly() {
        // At the last exercise of the last block → must request confirmation.
        let action = workoutNextAction(
            currentBlockIndex: 1,
            currentExerciseIndex: 1,
            exerciseCountsPerBlock: [3, 2])
        XCTAssertEqual(action, .confirmFinish)
    }

    func test_singleBlockSingleExercise_finishRequiresConfirmation() {
        // A one-exercise workout: the very first Next must confirm, not finish.
        let action = workoutNextAction(
            currentBlockIndex: 0,
            currentExerciseIndex: 0,
            exerciseCountsPerBlock: [1])
        XCTAssertEqual(action, .confirmFinish)
    }

    // Simulates spam-tapping Next while already parked on the last step: every
    // repeated evaluation still resolves to `.confirmFinish` and never to a
    // "finish now" action, so the dialog is the only path to finishing.
    func test_repeatedNextOnLastStep_alwaysConfirms_neverAdvancesPastEnd() {
        let counts = [2, 1]
        for _ in 0..<5 {
            let action = workoutNextAction(
                currentBlockIndex: 1,
                currentExerciseIndex: 0,
                exerciseCountsPerBlock: counts)
            XCTAssertEqual(action, .confirmFinish)
        }
    }

    // MARK: - Robustness

    func test_outOfRangeBlockIndex_treatedAsEmptyBlock_confirmsFinishWhenLast() {
        // Defensive: an out-of-range block index yields exCount 0. When it is
        // also the last block, the decision is a (safe) confirm-finish, never a
        // crash or a silent finish.
        let action = workoutNextAction(
            currentBlockIndex: 0,
            currentExerciseIndex: 0,
            exerciseCountsPerBlock: [0])
        XCTAssertEqual(action, .confirmFinish)
    }

    // MARK: - Finish requests (plain confirmation + Save Routine Changes)

    // The plain dialog's Finish and the sheet's Finish This Workout Only both
    // record `.finishOnly`; Save Selected Changes records `.saveSelected`.
    // Cancel (and swiping the sheet away) records nothing.

    func test_finishOnly_writesNoRoutineChanges() {
        XCTAssertEqual(FinishRequest.finishOnly.selectedChanges, [])
    }

    // MARK: - Single-fire consumption (one confirm tap → one finish)

    func test_consumePendingFinish_returnsChoiceOnceThenNil() {
        var slot: FinishRequest? = .finishOnly

        XCTAssertEqual(
            consumePendingFinish(&slot), .finishOnly,
            "First consume must deliver the recorded choice"
        )
        XCTAssertNil(slot, "Consuming must clear the slot")
        XCTAssertNil(
            consumePendingFinish(&slot),
            "A duplicate consume (double tap / duplicate change notification) "
                + "must not run the finish pipeline again"
        )
    }

    func test_cancelRecordsNothing_soNothingFinishesOrSaves() {
        // Cancel — the dialog's, the sheet's, or a swipe-down — leaves the
        // slot nil; the consume that follows any dismissal then yields nil,
        // so the workout stays active and the routine is not written.
        var slot: FinishRequest? = nil
        XCTAssertNil(consumePendingFinish(&slot))
    }

    func test_reconfirmAfterSurvivingView_isReArmable() {
        // If the view ever survives a finish attempt, a NEW confirmation can
        // record and consume again — the single-fire guard is per-request,
        // not a permanent latch that would strand the user.
        var slot: FinishRequest? = .saveSelected([])
        XCTAssertEqual(consumePendingFinish(&slot), .saveSelected([]))

        slot = .finishOnly  // user confirms again
        XCTAssertEqual(consumePendingFinish(&slot), .finishOnly)
        XCTAssertNil(slot)
    }
}
