import XCTest

@testable import Log

/// Pre-Alternative-Exercises safety slice — `exerciseSwitchDeletionImpact` is
/// the gate that decides whether switching a slot's exercise needs a
/// destructive confirmation.
///
/// Switching removes the slot's `WorkoutItem` (and every `SetLog` under it) and,
/// inside a superset, cascades a clear of partner logs that the round-prefix
/// invariant no longer allows. That was silent. These tests pin the prediction:
/// zero means "apply immediately, exactly as before", non-zero means "warn
/// first", and the number must match what the cascade actually removes.
final class ExerciseSwitchDeletionImpactTests: XCTestCase {

    private let slotA = UUID()
    private let slotB = UUID()
    private let slotC = UUID()

    // MARK: - Non-superset

    func testNoLoggedSetsNeedsNoConfirmation() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: false,
            slotOrder: [slotA],
            setCounts: [slotA: 3],
            loggedBySlot: [slotA: []]
        )

        XCTAssertEqual(impact.totalLoggedSets, 0)
        XCTAssertFalse(impact.requiresConfirmation)
    }

    func testSlotAbsentFromLoggedMapNeedsNoConfirmation() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: false,
            slotOrder: [slotA],
            setCounts: [slotA: 3],
            loggedBySlot: [:]
        )

        XCTAssertFalse(impact.requiresConfirmation)
    }

    func testOneLoggedSetRequiresConfirmation() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: false,
            slotOrder: [slotA],
            setCounts: [slotA: 3],
            loggedBySlot: [slotA: [0]]
        )

        XCTAssertTrue(impact.requiresConfirmation)
        XCTAssertEqual(impact.slotLoggedSets, 1)
        XCTAssertEqual(impact.partnerLoggedSets, 0)
        XCTAssertEqual(impact.totalLoggedSets, 1)
        XCTAssertFalse(impact.includesPartnerSets)
    }

    func testMultipleLoggedSetsCountCorrectly() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: false,
            slotOrder: [slotA],
            setCounts: [slotA: 4],
            loggedBySlot: [slotA: [0, 1, 2]]
        )

        XCTAssertEqual(impact.totalLoggedSets, 3)
        XCTAssertFalse(impact.includesPartnerSets)
    }

    /// A non-superset block never cascades — the swap path invokes the cascade
    /// only for `isSuperset` — so another slot's logs must not be counted even
    /// when they are present in the map.
    func testNonSupersetIgnoresOtherSlots() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: false,
            slotOrder: [slotA, slotB],
            setCounts: [slotA: 3, slotB: 3],
            loggedBySlot: [slotA: [0], slotB: [0, 1]]
        )

        XCTAssertEqual(impact.slotLoggedSets, 1)
        XCTAssertEqual(impact.partnerLoggedSets, 0)
        XCTAssertEqual(impact.totalLoggedSets, 1)
    }

    /// A cardio slot logs one aggregate set. Nothing about the gate is
    /// mode-aware — it counts logged sets — so a single cardio bout warns
    /// exactly like a single strength set.
    func testSingleCardioAggregateSetRequiresConfirmation() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: false,
            slotOrder: [slotA],
            setCounts: [slotA: 1],
            loggedBySlot: [slotA: [0]]
        )

        XCTAssertTrue(impact.requiresConfirmation)
        XCTAssertEqual(impact.totalLoggedSets, 1)
    }

    // MARK: - Superset cascade

    /// The documented cascade case: A + B logged for round 1; switching A
    /// strands B1 ahead of the now-unlogged A1, so B1 goes too. The user must
    /// be told about **both**.
    func testSupersetCascadeCountsPartnerLogs() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: true,
            slotOrder: [slotA, slotB],
            setCounts: [slotA: 3, slotB: 3],
            loggedBySlot: [slotA: [0], slotB: [0]]
        )

        XCTAssertEqual(impact.slotLoggedSets, 1)
        XCTAssertEqual(impact.partnerLoggedSets, 1)
        XCTAssertEqual(impact.totalLoggedSets, 2)
        XCTAssertTrue(impact.includesPartnerSets)
    }

    /// Switching the *later* member leaves the earlier member's logs valid —
    /// A1 is still a legal prefix on its own — so only B's logs are removed.
    func testSwitchingLaterSupersetMemberDoesNotStrandEarlierLogs() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotB,
            isSuperset: true,
            slotOrder: [slotA, slotB],
            setCounts: [slotA: 3, slotB: 3],
            loggedBySlot: [slotA: [0], slotB: [0]]
        )

        XCTAssertEqual(impact.slotLoggedSets, 1)
        XCTAssertEqual(impact.partnerLoggedSets, 0)
        XCTAssertFalse(impact.includesPartnerSets)
    }

    /// The switched slot may itself have nothing logged and the switch can
    /// still be destructive, because emptying it invalidates a partner's later
    /// logs. This is the case a naive "does this slot have logs?" check misses.
    func testCascadeAloneCanRequireConfirmation() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: true,
            slotOrder: [slotA, slotB],
            setCounts: [slotA: 3, slotB: 3],
            loggedBySlot: [slotA: [], slotB: [0]]
        )

        XCTAssertEqual(impact.slotLoggedSets, 0)
        XCTAssertEqual(impact.partnerLoggedSets, 1)
        XCTAssertTrue(impact.requiresConfirmation)
        XCTAssertTrue(impact.includesPartnerSets)
    }

    func testCascadeAcrossMultipleRoundsAndPartners() {
        // Three-member superset, two full rounds logged. Switching the first
        // member invalidates every later log in both rounds.
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: true,
            slotOrder: [slotA, slotB, slotC],
            setCounts: [slotA: 2, slotB: 2, slotC: 2],
            loggedBySlot: [slotA: [0, 1], slotB: [0, 1], slotC: [0, 1]]
        )

        XCTAssertEqual(impact.slotLoggedSets, 2)
        XCTAssertEqual(impact.partnerLoggedSets, 4)
        XCTAssertEqual(impact.totalLoggedSets, 6)
    }

    /// Unequal set counts: a partner that does not reach a round does not
    /// participate in it, matching `supersetLogsToInvalidate`'s own rule.
    func testUnequalSetCountsDoNotOvercount() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: true,
            slotOrder: [slotA, slotB],
            setCounts: [slotA: 3, slotB: 1],
            loggedBySlot: [slotA: [0, 1], slotB: [0]]
        )

        XCTAssertEqual(impact.slotLoggedSets, 2)
        XCTAssertEqual(impact.partnerLoggedSets, 1)
    }

    func testSupersetWithNoLogsAnywhereNeedsNoConfirmation() {
        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: true,
            slotOrder: [slotA, slotB],
            setCounts: [slotA: 3, slotB: 3],
            loggedBySlot: [slotA: [], slotB: []]
        )

        XCTAssertFalse(impact.requiresConfirmation)
    }

    /// The prediction must equal what the cascade actually clears. Recomputing
    /// the partner count the way `cascadeClearSupersetRoundOrderViolations`
    /// does — post-clear state through `supersetLogsToInvalidate` — must agree.
    func testPredictionMatchesTheCascadeItWarnsAbout() {
        let setCounts = [slotA: 3, slotB: 3, slotC: 3]
        let logged: [UUID: Set<Int>] = [slotA: [0], slotB: [0], slotC: [0]]

        let impact = exerciseSwitchDeletionImpact(
            slotID: slotA,
            isSuperset: true,
            slotOrder: [slotA, slotB, slotC],
            setCounts: setCounts,
            loggedBySlot: logged
        )

        // What the swap path will do: clear the slot, then cascade.
        var afterSwapClear = logged
        afterSwapClear[slotA] = []
        let actual = supersetLogsToInvalidate(
            slotOrder: [slotA, slotB, slotC],
            setCounts: setCounts,
            loggedBySlot: afterSwapClear
        )
        let actualPartnerCount = actual
            .filter { $0.key != slotA }
            .reduce(0) { $0 + $1.value.count }

        XCTAssertEqual(impact.partnerLoggedSets, actualPartnerCount)
    }

    // MARK: - Copy

    func testNoMessageWhenNothingWouldBeRemoved() {
        let impact = ExerciseSwitchDeletionImpact()
        XCTAssertNil(ExerciseSwitchConfirmationCopy.message(for: impact))
    }

    func testSingularExerciseMessage() {
        let impact = ExerciseSwitchDeletionImpact(slotLoggedSets: 1)
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.message(for: impact),
            "Switching exercises will remove 1 logged set for this exercise."
        )
    }

    func testPluralExerciseMessage() {
        let impact = ExerciseSwitchDeletionImpact(slotLoggedSets: 3)
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.message(for: impact),
            "Switching exercises will remove 3 logged sets for this exercise."
        )
    }

    func testBlockMessageWhenPartnerSetsAreIncluded() {
        let impact = ExerciseSwitchDeletionImpact(
            slotLoggedSets: 2, partnerLoggedSets: 1
        )
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.message(for: impact),
            "Switching exercises will remove 3 logged sets from this block."
        )
    }

    func testSingularBlockMessage() {
        // Cascade-only: the switched slot had nothing, one partner set goes.
        let impact = ExerciseSwitchDeletionImpact(
            slotLoggedSets: 0, partnerLoggedSets: 1
        )
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.message(for: impact),
            "Switching exercises will remove 1 logged set from this block."
        )
    }

    func testTitleAndButtonCopy() {
        XCTAssertEqual(ExerciseSwitchConfirmationCopy.title, "Switch exercise?")
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.confirmButton,
            "Switch and Remove Sets"
        )
    }
}
