import XCTest

@testable import Log

/// Phase 6.C3 — `supersetLogsToInvalidate(...)` is the pure helper
/// that the swap path consults to decide which additional logged sets
/// in a superset block must be cleared to restore the round-prefix
/// invariant after the replaced slot's own logs have been cleared.
///
/// These tests pin the contract on plain `XCTestCase` because the
/// helper takes only value types (`[UUID]`, `[UUID: Int]`,
/// `[UUID: Set<Int>]`) and returns the same — no SwiftData needed.
final class SupersetReplacementCleanupTests: XCTestCase {

    // MARK: - Fixtures

    /// Two-slot superset with stable IDs so the round sequence is
    /// `A0, B0, A1, B1, A2, B2, ...`.
    private struct TwoSlot {
        let a = UUID()
        let b = UUID()
        let setCounts: [UUID: Int]
        let order: [UUID]
        init(setsA: Int = 3, setsB: Int = 3) {
            setCounts = [a: setsA, b: setsB]
            order = [a, b]
        }
    }

    /// Three-slot superset (A, B, C).
    private struct ThreeSlot {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let setCounts: [UUID: Int]
        let order: [UUID]
        init(setsA: Int = 3, setsB: Int = 3, setsC: Int = 3) {
            setCounts = [a: setsA, b: setsB, c: setsC]
            order = [a, b, c]
        }
    }

    // MARK: - Replacing the first slot (the original repro)

    /// Repro from the bug report:
    ///   1) A1 logged.   2) B1 logged.   3) Replace A with C.
    ///   4) A's logs are now empty; B's {0} is now ahead of an unlogged
    ///      earlier required member of round 1 → must be cleared.
    func testFirstSlotReplaced_AfterA1AndB1_ClearsB1() {
        let fx = TwoSlot()
        // Caller passes loggedBySlot AFTER clearing the replaced slot.
        let logged: [UUID: Set<Int>] = [fx.a: [], fx.b: [0]]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertEqual(extraneous, [fx.b: [0]])
    }

    /// A1, B1, A2 are logged; A is replaced. A's logs cleared by the
    /// swap path, so we should clear B1 (orphaned ahead of an
    /// unlogged A1).
    func testFirstSlotReplaced_AfterA1B1A2_ClearsB1() {
        let fx = TwoSlot()
        // A's {0,1} cleared by the swap; B retains {0}.
        let logged: [UUID: Set<Int>] = [fx.a: [], fx.b: [0]]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertEqual(extraneous, [fx.b: [0]])
    }

    /// Full round 1 + round 2: A1, B1, A2, B2 logged. Replace A.
    /// Both rounds of B are orphaned ahead of unlogged earlier
    /// required members → both cleared.
    func testFirstSlotReplaced_AfterFullTwoRounds_ClearsAllOfBs() {
        let fx = TwoSlot()
        let logged: [UUID: Set<Int>] = [fx.a: [], fx.b: [0, 1]]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertEqual(extraneous, [fx.b: [0, 1]])
    }

    // MARK: - Replacing the second (later) slot

    /// A1, B1 logged. Replace B with D. B's logs cleared by the swap
    /// path, A1 remains. A's {0} is still a valid prefix of the round
    /// sequence (the only logged element is the first); nothing extra
    /// to clear.
    func testSecondSlotReplaced_AfterA1AndB1_KeepsA1() {
        let fx = TwoSlot()
        let logged: [UUID: Set<Int>] = [fx.a: [0], fx.b: []]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertTrue(
            extraneous.isEmpty,
            "B is the *later* member of round 1, so A1 alone is a "
                + "valid prefix; nothing to clear"
        )
    }

    /// A1, B1, A2 logged. Replace B → B logs cleared. A's {0} stays
    /// valid; A's {1} is orphaned ahead of an unlogged B1 → must be
    /// cleared.
    func testSecondSlotReplaced_AfterA1B1A2_ClearsA2OnlyKeepsA1() {
        let fx = TwoSlot()
        let logged: [UUID: Set<Int>] = [fx.a: [0, 1], fx.b: []]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertEqual(extraneous, [fx.a: [1]])
    }

    // MARK: - Three-slot superset cascade

    /// Three-slot superset (A, B, C). Logged: A0, B0, C0, A1, B1.
    /// Replace B (middle slot) — B's {0,1} cleared by the swap path.
    /// Round 0: A0 is a valid prefix-of-1; B0 missing; C0 is now
    /// orphaned ahead of unlogged B0 → cleared. Round 1: A1 then
    /// requires round 0 complete → orphaned → cleared. Final: only
    /// A0 survives.
    func testMiddleSlotReplaced_InThreeSlotSuperset_CascadesForward() {
        let fx = ThreeSlot()
        let logged: [UUID: Set<Int>] = [
            fx.a: [0, 1],
            fx.b: [],
            fx.c: [0],
        ]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertEqual(extraneous, [fx.a: [1], fx.c: [0]])
    }

    // MARK: - Unequal set counts

    /// A has 3 sets, B has 4. Logged: A0,A1,A2 and B0,B1,B2,B3.
    /// All valid (B's round 3 is unique to B; no earlier required
    /// member exists at that round). Nothing extraneous.
    func testUnequalSetCounts_TrailingExtraSetsOnLaterSlotKept() {
        let fx = TwoSlot(setsA: 3, setsB: 4)
        let logged: [UUID: Set<Int>] = [
            fx.a: [0, 1, 2],
            fx.b: [0, 1, 2, 3],
        ]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertTrue(extraneous.isEmpty)
    }

    /// A: 3 sets, B: 4. Replace A. A cleared by swap; B retains all
    /// four logs. Rounds 0–2 are orphaned (B ahead of unlogged A);
    /// round 3 has only B (A doesn't participate) — but round 0
    /// already truncated everything that follows in B, so all 4 are
    /// cleared.
    func testUnequalSetCounts_FirstSlotReplaced_ClearsAllRemaining() {
        let fx = TwoSlot(setsA: 3, setsB: 4)
        let logged: [UUID: Set<Int>] = [
            fx.a: [],
            fx.b: [0, 1, 2, 3],
        ]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertEqual(extraneous, [fx.b: [0, 1, 2, 3]])
    }

    // MARK: - Duplicate-Exercise superset (Phase 6.C1 follow-up)

    /// Two superset slots that happen to reference the same
    /// `Exercise.id` still have distinct `routineSlotID` values.
    /// The helper keys on slot IDs only — it does not look at any
    /// exercise identity — so the duplicate case behaves identically
    /// to the two-distinct-exercise case above. Pinning this
    /// explicitly so the 6.C1 follow-up invariant is regression-
    /// guarded at the helper level too.
    func testDuplicateExerciseSlots_StayDistinctByRoutineSlotID() {
        let slot1 = UUID()
        let slot2 = UUID()
        // Even if the underlying Exercise.id were equal, the helper
        // never sees it. Logged after replacing slot1's exercise:
        let logged: [UUID: Set<Int>] = [slot1: [], slot2: [0]]
        let setCounts: [UUID: Int] = [slot1: 3, slot2: 3]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: [slot1, slot2],
            setCounts: setCounts,
            loggedBySlot: logged
        )

        XCTAssertEqual(
            extraneous, [slot2: [0]],
            "slot2's log must be cleared because slot1 is now empty; "
                + "slot identity is by UUID, never by Exercise.id"
        )
    }

    // MARK: - Non-superset / single-slot inputs

    /// A standalone slot (one-element `slotOrder`) cannot violate the
    /// cross-slot prefix invariant — there's nothing to truncate
    /// against. The helper safely returns empty. The integration
    /// site gates on `block.isSuperset` so this call shape doesn't
    /// arise in practice, but pin the contract for safety.
    func testSingleSlotInput_ReturnsEmpty() {
        let slot = UUID()
        let logged: [UUID: Set<Int>] = [slot: [0, 1, 2]]
        let setCounts: [UUID: Int] = [slot: 3]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: [slot],
            setCounts: setCounts,
            loggedBySlot: logged
        )

        XCTAssertTrue(extraneous.isEmpty)
    }

    /// Even when the first slot of the superset has logs missing,
    /// the second member's logs are only flagged when they're
    /// actually present. An all-empty input returns empty.
    func testAllEmpty_ReturnsEmpty() {
        let fx = TwoSlot()
        let logged: [UUID: Set<Int>] = [fx.a: [], fx.b: []]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertTrue(extraneous.isEmpty)
    }

    /// Empty slotOrder → empty output.
    func testEmptySlotOrder_ReturnsEmpty() {
        let extraneous = supersetLogsToInvalidate(
            slotOrder: [],
            setCounts: [:],
            loggedBySlot: [:]
        )
        XCTAssertTrue(extraneous.isEmpty)
    }

    // MARK: - Already-consistent state (idempotence)

    /// If the loggedBySlot is already a valid prefix, the helper
    /// returns nothing — useful as an idempotence guard so a redundant
    /// call from the swap path doesn't over-clear.
    func testAlreadyValidPrefix_ReturnsEmpty() {
        let fx = TwoSlot()
        // A0, B0, A1, B1 — full two rounds. Valid prefix → nothing
        // extraneous even though the replaced-slot precondition does
        // not hold (the caller is responsible for that).
        let logged: [UUID: Set<Int>] = [fx.a: [0, 1], fx.b: [0, 1]]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertTrue(extraneous.isEmpty)
    }

    /// A0, B0, A1 — valid in-progress prefix (round 1 complete,
    /// halfway through round 2). Nothing to clear.
    func testInProgressValidPrefix_ReturnsEmpty() {
        let fx = TwoSlot()
        let logged: [UUID: Set<Int>] = [fx.a: [0, 1], fx.b: [0]]

        let extraneous = supersetLogsToInvalidate(
            slotOrder: fx.order,
            setCounts: fx.setCounts,
            loggedBySlot: logged
        )

        XCTAssertTrue(extraneous.isEmpty)
    }
}
