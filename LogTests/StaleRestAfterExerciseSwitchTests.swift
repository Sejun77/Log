import XCTest

@testable import Log

/// A rest timer must never outlive the set it was counting down from.
///
/// The reported bug: log a set, then switch that slot's exercise. The switch
/// deletes the slot's `WorkoutItem` and every `SetLog` under it, but nothing
/// told the rest timer — so the clock kept running and its scheduled local
/// notification fired for a set that no longer existed, on an exercise the slot
/// no longer held.
///
/// `shouldCancelRestAfterExerciseSwitch` is the whole decision, and it is
/// deliberately phrased as **"does the resting slot still have a logged set"**
/// rather than "was this slot switched". That one framing buys three things:
///
///  * the reported case (the switched slot was the resting slot),
///  * the superset cascade (a *partner's* logs cleared by the round-order
///    invariant) — covered without naming it,
///  * and normal rest, untouched: a rest on a slot that still has its logs
///    keeps running, so logging without switching cannot be affected.
final class StaleRestAfterExerciseSwitchTests: XCTestCase {

    private let restingSlot = UUID()
    private let otherSlot = UUID()

    // MARK: - 1. The reported bug

    /// Log set 0, switch that slot's exercise → its logs are gone → cancel.
    func testARestWhoseSlotLostItsLogsIsCancelled() {
        XCTAssertTrue(
            shouldCancelRestAfterExerciseSwitch(
                isRestRunning: true,
                restSlotID: restingSlot,
                // Post-switch: `swapExercise` set this slot's logs to [].
                loggedSetsBySlotID: [restingSlot: []]))
    }

    /// The slot is absent from the map entirely — the same state, spelled
    /// differently, and it must read the same way.
    func testAnAbsentSlotCountsAsHavingNoLogs() {
        XCTAssertTrue(
            shouldCancelRestAfterExerciseSwitch(
                isRestRunning: true,
                restSlotID: restingSlot,
                loggedSetsBySlotID: [:]))
    }

    /// The superset cascade: the user switched `otherSlot`, and the round-order
    /// invariant cleared the resting slot's logs as collateral. Same answer, no
    /// extra rule.
    func testARestOrphanedByTheSupersetCascadeIsCancelled() {
        XCTAssertTrue(
            shouldCancelRestAfterExerciseSwitch(
                isRestRunning: true,
                restSlotID: restingSlot,
                loggedSetsBySlotID: [restingSlot: [], otherSlot: []]))
    }

    // MARK: - 2. Normal rest is untouched

    /// A superset partner switched while this slot rests mid-round: its set is
    /// still logged, so its rest is still legitimate.
    func testARestOnAnUntouchedSlotKeepsRunning() {
        XCTAssertFalse(
            shouldCancelRestAfterExerciseSwitch(
                isRestRunning: true,
                restSlotID: restingSlot,
                loggedSetsBySlotID: [restingSlot: [0], otherSlot: []]))
    }

    func testARestOnASlotWithSeveralLoggedSetsKeepsRunning() {
        XCTAssertFalse(
            shouldCancelRestAfterExerciseSwitch(
                isRestRunning: true,
                restSlotID: restingSlot,
                loggedSetsBySlotID: [restingSlot: [0, 1, 2]]))
    }

    func testNothingIsCancelledWhenNoRestIsRunning() {
        XCTAssertFalse(
            shouldCancelRestAfterExerciseSwitch(
                isRestRunning: false,
                restSlotID: restingSlot,
                loggedSetsBySlotID: [restingSlot: []]),
            "no rest to cancel — the helper must not report work to do")
    }

    // MARK: - 3. Unattributable rest

    /// `AppState.activeRestSlotID` is nil, so the rest cannot be tied to a
    /// slot. Leaving it alone is the deliberate choice: cancelling a rest that
    /// might be legitimate is the worse of the two mistakes, and every rest
    /// this app starts goes through `startRestWithPersistence`, which sets it.
    func testAnUnattributableRestIsLeftAlone() {
        XCTAssertFalse(
            shouldCancelRestAfterExerciseSwitch(
                isRestRunning: true,
                restSlotID: nil,
                loggedSetsBySlotID: [:]))
    }

    // MARK: - 4. Purity

    func testTheDecisionDependsOnlyOnItsInputs() {
        let inputs: [UUID: Set<Int>] = [restingSlot: []]
        let first = shouldCancelRestAfterExerciseSwitch(
            isRestRunning: true, restSlotID: restingSlot,
            loggedSetsBySlotID: inputs)
        let second = shouldCancelRestAfterExerciseSwitch(
            isRestRunning: true, restSlotID: restingSlot,
            loggedSetsBySlotID: inputs)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first)
    }
}
