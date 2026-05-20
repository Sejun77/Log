import SwiftData
import XCTest

@testable import Log

/// Phase 7 stabilization — pins the `AppState` ↔ `WorkoutLifecycleState`
/// invariants that the Save & Exit / Finish / Discard branches and the launch
/// validation flow (`BootstrapRoot.validateActiveSession`,
/// `RootTabView.checkForActiveSession`) all depend on.
///
/// Also locks in the backward-compat safety of the Phase 8-A
/// `WorkoutLifecycleState.finished` removal: a persisted `"finished"` raw
/// string (which never reached production but is the natural worry on enum
/// pruning) must decode to `.idle` via the existing `?? .idle` fallback.
@MainActor
final class AppStateLifecycleTests: SwiftDataTestHarness {

    // MARK: - 1) Default values

    func testAppStateDefaultsToIdleAndNilActiveFields() {
        let s = AppState()
        context.insert(s)

        XCTAssertEqual(s.workoutState, .idle)
        XCTAssertEqual(s.workoutStateRaw, "idle")
        XCTAssertNil(s.activeWorkoutID)
        XCTAssertNil(s.activeWorkoutStartedAt)
        XCTAssertNil(s.activeRestEndsAt)
        XCTAssertNil(s.activeRestSlotID)
        XCTAssertNil(s.sessionPlansJSON)
        XCTAssertNil(s.activeBlockIndex)
        XCTAssertNil(s.activeExerciseIndex)
        XCTAssertEqual(s.key, "appState")
    }

    // MARK: - 2) Get/set round-trips through the raw string and persists

    func testWorkoutStateGetSetRoundTripsAndPersists() throws {
        let s = AppState()
        context.insert(s)

        s.workoutState = .active
        XCTAssertEqual(s.workoutStateRaw, "active")

        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AppState>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.workoutState, .active)
        XCTAssertEqual(fetched.first?.workoutStateRaw, "active")
    }

    // MARK: - 3) Unknown raw string falls back to .idle

    /// Pins the Phase 8-A safety guarantee: even a persisted `"finished"`
    /// value (the case removed in Phase 8-A) decodes to `.idle` via the
    /// `WorkoutLifecycleState(rawValue:) ?? .idle` fallback. Same applies
    /// to any future enum pruning.
    func testUnknownRawStringFallsBackToIdle() {
        let s = AppState()
        context.insert(s)

        s.workoutStateRaw = "finished"
        XCTAssertEqual(s.workoutState, .idle)

        s.workoutStateRaw = "bogus-future-case"
        XCTAssertEqual(s.workoutState, .idle)

        s.workoutStateRaw = ""
        XCTAssertEqual(s.workoutState, .idle)
    }

    // MARK: - 4) fetchOrCreateAppState is singleton-safe across repeat calls

    func testFetchOrCreateAppStateReturnsSingletonOnRepeatCalls() throws {
        let first = BootstrapRoot.fetchOrCreateAppState(in: context)
        let second = BootstrapRoot.fetchOrCreateAppState(in: context)

        XCTAssertEqual(first.key, "appState")
        XCTAssertEqual(second.key, "appState")
        // Same persistent identity — fetched, not re-inserted.
        XCTAssertTrue(first === second)

        let all = try context.fetch(FetchDescriptor<AppState>())
        XCTAssertEqual(all.count, 1, "fetchOrCreateAppState must not duplicate the singleton")
    }

    // MARK: - 5) Existing active fields survive a save + refetch

    func testFetchOrCreateAppStatePreservesExistingFieldsAfterSave() throws {
        let workoutID = UUID()
        let restSlotID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let first = BootstrapRoot.fetchOrCreateAppState(in: context)
        first.workoutState = .active
        first.activeWorkoutID = workoutID
        first.activeWorkoutStartedAt = startedAt
        first.activeRestSlotID = restSlotID
        first.activeBlockIndex = 2
        first.activeExerciseIndex = 1
        first.sessionPlansJSON = "{\"key\":\"value\"}"
        try context.save()

        // Re-fetch via the same helper — must return the same singleton with
        // all fields intact.
        let second = BootstrapRoot.fetchOrCreateAppState(in: context)
        XCTAssertEqual(second.workoutState, .active)
        XCTAssertEqual(second.activeWorkoutID, workoutID)
        XCTAssertEqual(second.activeWorkoutStartedAt, startedAt)
        XCTAssertEqual(second.activeRestSlotID, restSlotID)
        XCTAssertEqual(second.activeBlockIndex, 2)
        XCTAssertEqual(second.activeExerciseIndex, 1)
        XCTAssertEqual(second.sessionPlansJSON, "{\"key\":\"value\"}")

        let all = try context.fetch(FetchDescriptor<AppState>())
        XCTAssertEqual(all.count, 1)
    }
}
