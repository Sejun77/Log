import XCTest

@testable import Log

/// The haptic policy as pure decisions: which interaction produces which
/// `HapticEvent`, and when an outcome suppresses or changes it. Nothing here
/// touches UIKit or the Taptic Engine — the physical feel is judged on a
/// device, not in a test.
final class HapticPolicyTests: XCTestCase {

    // MARK: - Cue → event table

    func test_selectionRows_mapToSelection() {
        XCTAssertEqual(HapticCue.selectionChanged.event, .selection)
    }

    func test_ordinaryWorkoutActions_mapToLightImpact() {
        for cue: HapticCue in [
            .workoutStepChanged, .setLogged, .setUnlogged, .setTimerStarted,
            .exerciseSwitched, .itemCreated,
        ] {
            XCTAssertEqual(cue.event, .lightImpact, "\(cue)")
        }
    }

    func test_workflowTransitions_mapToMediumImpact() {
        XCTAssertEqual(HapticCue.workoutStarted.event, .mediumImpact)
        XCTAssertEqual(HapticCue.workoutSavedAndExited.event, .mediumImpact)
    }

    func test_finish_mapsToSuccess() {
        XCTAssertEqual(HapticCue.workoutFinished.event, .success)
    }

    func test_destructiveConfirmed_mapsToWarning() {
        XCTAssertEqual(HapticCue.destructiveConfirmed.event, .warning)
    }

    func test_rejection_mapsToError() {
        XCTAssertEqual(HapticCue.actionRejected.event, .error)
    }

    /// Save & Exit and Discard are both exits but must feel different.
    func test_saveAndExit_isDistinctFromDiscard() {
        XCTAssertNotEqual(
            HapticCue.workoutSavedAndExited.event,
            HapticCue.destructiveConfirmed.event)
    }

    /// Back / Next is the most frequent workout action; it must not share
    /// Finish's feedback.
    func test_stepNavigation_isWeakerThanFinish() {
        XCTAssertEqual(HapticCue.workoutStepChanged.event, .lightImpact)
        XCTAssertNotEqual(
            HapticCue.workoutStepChanged.event,
            HapticCue.workoutFinished.event)
    }

    /// Success is reserved for completed major operations — never for an
    /// ordinary per-set action.
    func test_successIsReservedForMajorOutcomes() {
        let successCues = HapticCue.allCases.filter { $0.event == .success }
        XCTAssertEqual(
            Set(successCues.map { "\($0)" }),
            ["workoutFinished", "restCompleted", "importSucceeded"])
    }

    // MARK: - Next / Finish

    func test_nextAdvancingExercise_isStepChange() {
        XCTAssertEqual(
            HapticPolicy.cue(for: .advanceExercise(1)), .workoutStepChanged)
    }

    func test_nextAdvancingBlock_isStepChange() {
        XCTAssertEqual(HapticPolicy.cue(for: .advanceBlock), .workoutStepChanged)
    }

    /// Reaching Finish only opens the confirmation — no success before the
    /// finish has happened.
    func test_nextReachingFinish_playsNothing() {
        XCTAssertNil(HapticPolicy.cue(for: .confirmFinish))
    }

    // MARK: - Finish outcome

    func test_finishOnly_recorded_isSuccess() {
        XCTAssertEqual(
            HapticPolicy.finishCue(
                workoutRecorded: true,
                routineChangesRequested: false,
                routineChangesSaved: false),
            .workoutFinished)
    }

    func test_saveSelectedChanges_saved_isSuccess() {
        XCTAssertEqual(
            HapticPolicy.finishCue(
                workoutRecorded: true,
                routineChangesRequested: true,
                routineChangesSaved: true),
            .workoutFinished)
    }

    func test_saveSelectedChanges_failed_isNotSuccess() {
        let cue = HapticPolicy.finishCue(
            workoutRecorded: true,
            routineChangesRequested: true,
            routineChangesSaved: false)
        XCTAssertEqual(cue, .workoutFinishedRoutineSaveFailed)
        XCTAssertNotEqual(cue?.event, .success)
    }

    func test_finishWithoutRecordedWorkout_playsNothing() {
        XCTAssertNil(
            HapticPolicy.finishCue(
                workoutRecorded: false,
                routineChangesRequested: true,
                routineChangesSaved: true))
    }

    // MARK: - Set logging

    func test_logSet_recorded_isSetLogged() {
        XCTAssertEqual(
            HapticPolicy.setLogCue(logged: true, didRecord: true), .setLogged)
    }

    func test_undoSet_removed_isSetUnlogged() {
        XCTAssertEqual(
            HapticPolicy.setLogCue(logged: false, didRecord: true), .setUnlogged)
    }

    func test_logOrUndo_thatWroteNothing_playsNothing() {
        XCTAssertNil(HapticPolicy.setLogCue(logged: true, didRecord: false))
        XCTAssertNil(HapticPolicy.setLogCue(logged: false, didRecord: false))
    }

    // MARK: - Import

    func test_importAddingRows_isSuccess() {
        XCTAssertEqual(HapticPolicy.importCue(insertedCount: 3), .importSucceeded)
    }

    func test_importAddingNothing_playsNothing() {
        XCTAssertNil(HapticPolicy.importCue(insertedCount: 0))
    }
}
