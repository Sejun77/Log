import XCTest

@testable import Log

/// Navigation after leaving the active workout.
///
/// `ActiveWorkoutView` routes every exit through the pure
/// `workoutExitNavigation(for:)`; `.returnToRoutinesRoot` calls the
/// `returnToRoutinesRoot` environment action, which is
/// `RoutinesNavigationState.returnToRoot()` on the Routines stack. Each entry
/// path into the active workout is one `RoutinesNavigationState` destination
/// (anything deeper is pushed by the screen that destination shows), so these
/// two pure pieces are the whole navigation contract.
///
/// Persistence per exit is pinned separately in `WorkoutLifecycleServiceTests`
/// (Save & Exit stays active and resumable, Discard deletes, Finish completes)
/// — this file only covers where the user lands.
final class WorkoutExitNavigationTests: XCTestCase {

    // MARK: - Fixtures

    /// Every intentional exit. Plain Finish and the sheet's "Finish This
    /// Workout Only" both record `.finishOnly`. The decision does not read the
    /// selection, so an empty set (as in `ActiveWorkoutFinishConfirmTests`)
    /// stands in for Save Selected Changes.
    private let allExits: [(name: String, exit: WorkoutExit)] = [
        ("Finish", .finished(.finishOnly)),
        ("Finish This Workout Only", .finished(.finishOnly)),
        ("Save Selected Changes", .finished(.saveSelected([]))),
        ("Save & Exit", .savedAndExited),
        ("Discard", .discarded),
    ]

    /// Routines → Start Workout → Active.
    private var rowStartStack: RoutinesNavigationState {
        RoutinesNavigationState(startRoutineID: UUID())
    }

    /// Routines → Editor → Start Workout → Active.
    private var editorStartStack: RoutinesNavigationState {
        RoutinesNavigationState(selectedRoutineID: UUID())
    }

    /// Routines → Active (Resume banner, cold-restart resume).
    private var resumeStack: RoutinesNavigationState {
        RoutinesNavigationState(showActiveWorkout: true)
    }

    /// What `ActiveWorkoutView.leave(_:)` does to the Routines stack.
    private func leave(
        _ exit: WorkoutExit, from stack: RoutinesNavigationState
    ) -> RoutinesNavigationState {
        var nav = stack
        switch workoutExitNavigation(for: exit) {
        case .returnToRoutinesRoot: nav.returnToRoot()
        }
        return nav
    }

    // MARK: - Every exit returns to the Routines root

    func test_plainFinish_returnsToRoutinesRoot() {
        XCTAssertEqual(
            workoutExitNavigation(for: .finished(.finishOnly)),
            .returnToRoutinesRoot)
    }

    func test_finishThisWorkoutOnly_returnsToRoutinesRoot() {
        // The Save Routine Changes sheet's "Finish This Workout Only" records
        // the same `.finishOnly` request as the plain dialog.
        XCTAssertEqual(
            workoutExitNavigation(for: .finished(.finishOnly)),
            .returnToRoutinesRoot)
    }

    func test_saveSelectedChanges_returnsToRoutinesRoot() {
        XCTAssertEqual(
            workoutExitNavigation(for: .finished(.saveSelected([]))),
            .returnToRoutinesRoot)
    }

    func test_saveAndExit_returnsToRoutinesRoot() {
        XCTAssertEqual(
            workoutExitNavigation(for: .savedAndExited), .returnToRoutinesRoot)
    }

    func test_discard_returnsToRoutinesRoot() {
        XCTAssertEqual(
            workoutExitNavigation(for: .discarded), .returnToRoutinesRoot)
    }

    // MARK: - Every exit × every entry stack ends at the root

    func test_rowStartStack_everyExitLandsOnRoutinesRoot() {
        XCTAssertFalse(rowStartStack.isAtRoot)
        for (name, exit) in allExits {
            XCTAssertTrue(
                leave(exit, from: rowStartStack).isAtRoot,
                "\(name) from row Start")
        }
    }

    func test_editorStartStack_everyExitLandsOnRoutinesRoot() {
        XCTAssertFalse(editorStartStack.isAtRoot)
        for (name, exit) in allExits {
            XCTAssertTrue(
                leave(exit, from: editorStartStack).isAtRoot,
                "\(name) from editor Start")
        }
    }

    func test_resumeStack_everyExitLandsOnRoutinesRoot() {
        XCTAssertFalse(resumeStack.isAtRoot)
        for (name, exit) in allExits {
            XCTAssertTrue(
                leave(exit, from: resumeStack).isAtRoot,
                "\(name) from Resume")
        }
    }

    // MARK: - Cancel navigates nowhere

    func test_cancelFromFinishConfirmation_recordsNoExit() {
        // Cancel records no request, so no `finishWorkout` — and therefore no
        // exit navigation — ever runs.
        var slot: FinishRequest? = nil
        XCTAssertNil(consumePendingFinish(&slot))
    }

    func test_cancelOrSwipeFromSaveRoutineChanges_recordsNoExit() {
        // The sheet's onDismiss forwards its held request; Cancel and swipe
        // leave it nil, so the forwarded request is nil and nothing consumes.
        let sheetFinishRequest: FinishRequest? = nil
        var slot = sheetFinishRequest
        XCTAssertNil(consumePendingFinish(&slot))
        XCTAssertNil(slot)
    }

    // MARK: - Navigation state

    func test_returnToRoot_clearsEveryDestinationAtOnce() {
        var nav = RoutinesNavigationState(
            selectedRoutineID: UUID(),
            startRoutineID: UUID(),
            showActiveWorkout: true,
            showUserGuide: true)
        nav.returnToRoot()
        XCTAssertEqual(nav, RoutinesNavigationState())
    }

    func test_freshState_isAtRoot() {
        XCTAssertTrue(RoutinesNavigationState().isAtRoot)
    }
}
