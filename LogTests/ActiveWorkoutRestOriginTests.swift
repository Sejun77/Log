import XCTest

@testable import Log

/// Manual-test polish — the rest timer must not outlive the set that started
/// it, and must not die when an unrelated set is corrected.
///
/// Before this slice the three undo paths disagreed:
///
///  - the reps/weight row stopped the rest **unconditionally**, so going back
///    to fix an older set killed the countdown running for a newer one;
///  - the duration / cardio row and the warm-up row never stopped it **at
///    all**, so unlogging the set that started the rest left the countdown, its
///    scheduled notification and its Live Activity running for a set that no
///    longer existed. That is the reported bug.
///
/// All three now route through `restClearDecision`, which is what this file
/// pins. The rule is stated once so a fourth undo path cannot invent a fourth
/// answer.
final class ActiveWorkoutRestOriginTests: XCTestCase {

    private let slotA = UUID()
    private let slotB = UUID()

    private func set(_ slot: UUID, _ index: Int) -> RestOriginSet {
        RestOriginSet(slotID: slot, setIndex: index)
    }

    // MARK: - Nothing running

    func test_noRestRunning_keeps() {
        XCTAssertEqual(
            restClearDecision(
                isRestRunning: false,
                origin: set(slotA, 0),
                unlogged: set(slotA, 0),
                remainingLoggedSetsInSlot: []),
            .keep,
            "There is nothing to clear when no countdown is running")
    }

    // MARK: - Known origin

    func test_unloggingTheSetThatStartedTheRest_clears() {
        XCTAssertEqual(
            restClearDecision(
                isRestRunning: true,
                origin: set(slotA, 2),
                unlogged: set(slotA, 2),
                remainingLoggedSetsInSlot: [0, 1]),
            .clear)
    }

    func test_unloggingAnOlderSetInTheSameSlot_keeps() {
        XCTAssertEqual(
            restClearDecision(
                isRestRunning: true,
                origin: set(slotA, 2),
                unlogged: set(slotA, 0),
                remainingLoggedSetsInSlot: [1, 2]),
            .keep,
            "Correcting an earlier set must not cancel the rest the user is "
                + "currently taking after a later one")
    }

    func test_unloggingASetInAnotherSlot_keeps() {
        XCTAssertEqual(
            restClearDecision(
                isRestRunning: true,
                origin: set(slotA, 0),
                unlogged: set(slotB, 0),
                remainingLoggedSetsInSlot: []),
            .keep,
            "A superset partner's undo must not cancel this slot's rest")
    }

    /// Warm-up rows log under the negative `-(order + 1)` index, so a warm-up
    /// rest and a working-set rest can never be confused for one another.
    func test_warmupAndWorkingSetIndicesDoNotCollide() {
        XCTAssertEqual(
            restClearDecision(
                isRestRunning: true,
                origin: set(slotA, -1),
                unlogged: set(slotA, -1),
                remainingLoggedSetsInSlot: [0]),
            .clear,
            "Un-ticking the warm-up step that started the rest clears it")

        XCTAssertEqual(
            restClearDecision(
                isRestRunning: true,
                origin: set(slotA, -1),
                unlogged: set(slotA, 0),
                remainingLoggedSetsInSlot: [-1]),
            .keep,
            "Undoing working set 1 must not clear a warm-up's rest")

        XCTAssertEqual(
            restClearDecision(
                isRestRunning: true,
                origin: set(slotA, 0),
                unlogged: set(slotA, -1),
                remainingLoggedSetsInSlot: [0]),
            .keep,
            "Un-ticking warm-up 1 must not clear working set 1's rest")
    }

    /// A drop sub-log's rest is recorded against its **parent** working set, so
    /// undoing that parent clears it.
    func test_dropRestIsOwnedByItsParentSet() {
        XCTAssertEqual(
            restClearDecision(
                isRestRunning: true,
                origin: set(slotA, 1),
                unlogged: set(slotA, 1),
                remainingLoggedSetsInSlot: [0]),
            .clear)
    }

    // MARK: - Unknown origin (cold restart)

    /// After a cold restart the rest is rehydrated from `AppState`, which
    /// stores only the slot. The conservative fallback then applies.
    func test_unknownOrigin_clearsOnlyWhenTheSlotHasNothingLoggedLeft() {
        XCTAssertEqual(
            restClearDecision(
                isRestRunning: true,
                origin: nil,
                unlogged: set(slotA, 0),
                remainingLoggedSetsInSlot: []),
            .clear,
            "Nothing is left in the slot that could justify the rest")

        XCTAssertEqual(
            restClearDecision(
                isRestRunning: true,
                origin: nil,
                unlogged: set(slotA, 0),
                remainingLoggedSetsInSlot: [1]),
            .keep,
            "Another logged set could plausibly own the rehydrated rest, so "
                + "the conservative branch leaves it running")
    }

    func test_unknownOrigin_withNoRestRunning_stillKeeps() {
        XCTAssertEqual(
            restClearDecision(
                isRestRunning: false,
                origin: nil,
                unlogged: set(slotA, 0),
                remainingLoggedSetsInSlot: []),
            .keep)
    }

    // MARK: - Identity

    func test_restOriginEquality() {
        XCTAssertEqual(set(slotA, 3), set(slotA, 3))
        XCTAssertNotEqual(set(slotA, 3), set(slotA, 4))
        XCTAssertNotEqual(set(slotA, 3), set(slotB, 3))
    }
}
