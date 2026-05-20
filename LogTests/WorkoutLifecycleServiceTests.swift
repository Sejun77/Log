import SwiftData
import XCTest

@testable import Log

/// Phase 7.7 / 8-B — pins the SwiftData + AppState lifecycle mutations for
/// `Save & Exit` (resumable), `Finish` (terminal — mark complete), and
/// `Discard` (terminal — delete). These are the exact mutations that the
/// Save & Exit bug fix (commit `9fbcfc9`) had no automated coverage for; the
/// service extraction in this slice closes that gap.
///
/// View-coupled side effects (RestTimer.stop, Live Activity teardown,
/// ActiveWorkoutGuard.endSession, dismiss, draft-store clears) remain in
/// `ActiveWorkoutView.unlockAndDismiss` and are intentionally not under
/// this test surface — see Phase 7.6 / 7.7 notes in REFACTOR_PLAN.md.
@MainActor
final class WorkoutLifecycleServiceTests: SwiftDataTestHarness {

    // MARK: - Fixture helpers

    @discardableResult
    private func makeWorkout() -> Workout {
        let w = Workout(items: [])
        context.insert(w)
        return w
    }

    /// Fully populates an AppState with active-session sentinel values so
    /// every clear assertion has something non-nil to clear from.
    private func populateActiveAppState(_ s: AppState, workoutID: UUID) {
        s.workoutState = .active
        s.activeWorkoutID = workoutID
        s.activeWorkoutStartedAt = Date(timeIntervalSince1970: 1_700_000_000)
        s.activeRestEndsAt = Date(timeIntervalSince1970: 1_700_000_300)
        s.activeRestSlotID = UUID()
        s.sessionPlansJSON = "{\"k\":\"v\"}"
        s.activeBlockIndex = 2
        s.activeExerciseIndex = 1
    }

    private func assertActiveAppStateCleared(
        _ s: AppState, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(s.workoutState, .idle, file: file, line: line)
        XCTAssertNil(s.activeWorkoutID, file: file, line: line)
        XCTAssertNil(s.activeWorkoutStartedAt, file: file, line: line)
        XCTAssertNil(s.activeRestEndsAt, file: file, line: line)
        XCTAssertNil(s.activeRestSlotID, file: file, line: line)
        XCTAssertNil(s.sessionPlansJSON, file: file, line: line)
        XCTAssertNil(s.activeBlockIndex, file: file, line: line)
        XCTAssertNil(s.activeExerciseIndex, file: file, line: line)
    }

    // MARK: - 1) saveAndExit does not complete workout

    func testSaveAndExitDoesNotCompleteWorkout() {
        let w = makeWorkout()
        XCTAssertNil(w.completedAt)

        WorkoutLifecycleService.saveAndExit(in: context)

        XCTAssertNil(w.completedAt)
    }

    // MARK: - 2) saveAndExit preserves active AppState fields

    func testSaveAndExitPreservesActiveAppStateFields() throws {
        let w = makeWorkout()
        let s = BootstrapRoot.fetchOrCreateAppState(in: context)
        populateActiveAppState(s, workoutID: w.id)
        try context.save()

        WorkoutLifecycleService.saveAndExit(in: context)

        // Every field must remain set — Save & Exit is the resumable path.
        XCTAssertEqual(s.workoutState, .active)
        XCTAssertEqual(s.activeWorkoutID, w.id)
        XCTAssertEqual(
            s.activeWorkoutStartedAt,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(
            s.activeRestEndsAt,
            Date(timeIntervalSince1970: 1_700_000_300)
        )
        XCTAssertNotNil(s.activeRestSlotID)
        XCTAssertEqual(s.sessionPlansJSON, "{\"k\":\"v\"}")
        XCTAssertEqual(s.activeBlockIndex, 2)
        XCTAssertEqual(s.activeExerciseIndex, 1)
    }

    // MARK: - 3) finish sets completedAt

    func testFinishSetsCompletedAt() {
        let w = makeWorkout()
        let s = BootstrapRoot.fetchOrCreateAppState(in: context)
        XCTAssertNil(w.completedAt)

        let before = Date()
        let returned = WorkoutLifecycleService.finish(
            workout: w, appState: s, in: context
        )
        let after = Date()

        XCTAssertNotNil(w.completedAt)
        XCTAssertEqual(returned, w.completedAt)
        let ts = try! XCTUnwrap(w.completedAt)
        XCTAssertGreaterThanOrEqual(ts, before)
        XCTAssertLessThanOrEqual(ts, after)
    }

    // MARK: - 4) finish clears active AppState fields

    func testFinishClearsActiveAppStateFields() throws {
        let w = makeWorkout()
        let s = BootstrapRoot.fetchOrCreateAppState(in: context)
        populateActiveAppState(s, workoutID: w.id)
        try context.save()

        WorkoutLifecycleService.finish(
            workout: w, appState: s, in: context
        )

        assertActiveAppStateCleared(s)
    }

    // MARK: - 5) discard deletes workout

    func testDiscardDeletesWorkout() throws {
        let w = makeWorkout()
        let s = BootstrapRoot.fetchOrCreateAppState(in: context)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 1)

        WorkoutLifecycleService.discard(
            workout: w, appState: s, in: context
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 0)
    }

    // MARK: - 6) discard clears active AppState fields

    func testDiscardClearsActiveAppStateFields() throws {
        let w = makeWorkout()
        let s = BootstrapRoot.fetchOrCreateAppState(in: context)
        populateActiveAppState(s, workoutID: w.id)
        try context.save()

        WorkoutLifecycleService.discard(
            workout: w, appState: s, in: context
        )

        assertActiveAppStateCleared(s)
    }

    // MARK: - 7) clearActiveAppState is idempotent

    func testClearActiveAppStateIsIdempotent() {
        let s = BootstrapRoot.fetchOrCreateAppState(in: context)
        populateActiveAppState(s, workoutID: UUID())

        // One call clears.
        WorkoutLifecycleService.clearActiveAppState(s)
        assertActiveAppStateCleared(s)

        // Two more calls leave the same nil-everywhere state.
        WorkoutLifecycleService.clearActiveAppState(s)
        WorkoutLifecycleService.clearActiveAppState(s)
        assertActiveAppStateCleared(s)

        // Nil appState is a defensive no-op (does not crash).
        WorkoutLifecycleService.clearActiveAppState(nil)
    }

    // MARK: - 8) finish with nil workout still clears AppState

    func testFinishWithNilWorkoutStillClearsAppState() throws {
        let s = BootstrapRoot.fetchOrCreateAppState(in: context)
        populateActiveAppState(s, workoutID: UUID())
        try context.save()

        let returned = WorkoutLifecycleService.finish(
            workout: nil, appState: s, in: context
        )

        XCTAssertNil(returned)
        assertActiveAppStateCleared(s)
    }

    // MARK: - 9) discard with nil workout still clears AppState

    func testDiscardWithNilWorkoutStillClearsAppState() throws {
        let s = BootstrapRoot.fetchOrCreateAppState(in: context)
        populateActiveAppState(s, workoutID: UUID())
        try context.save()

        WorkoutLifecycleService.discard(
            workout: nil, appState: s, in: context
        )

        assertActiveAppStateCleared(s)
    }
}
