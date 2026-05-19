import XCTest

@testable import Log

/// Phase 7.4-C.1 — `RestPlanner` was extracted out of
/// `ActiveWorkoutView.restSecondsAfterCurrentLog` for the simplest
/// non-superset, non-dropset branches. These tests pin the fallback
/// chain and the two "skip rest" cases (next-template-is-dropset and
/// last-set-of-workout) so future refactors can't silently regress
/// rest behavior on the most common path.
///
/// Out of scope here: supersets, current-set-is-dropset (final-drop),
/// technique-based dropsets, warmup, and the `block.restAfterSeconds`
/// post-processing — those still live inline in `ActiveWorkoutView`.
final class RestPlannerTests: XCTestCase {

    // MARK: - Helpers

    private func makeCtx(
        setIndex: Int = 0,
        nextTemplateKind: SetKind? = .working,
        effectiveSetCount: Int = 3,
        plannedRestBetweenSets: Int? = nil,
        plannedRestAfterExercise: Int? = nil,
        templateRestSecondsAfter: Int? = nil,
        isLastSetOfWorkout: Bool = false
    ) -> RestContext {
        RestContext(
            setIndex: setIndex,
            nextTemplateKind: nextTemplateKind,
            effectiveSetCount: effectiveSetCount,
            plannedRestBetweenSets: plannedRestBetweenSets,
            plannedRestAfterExercise: plannedRestAfterExercise,
            templateRestSecondsAfter: templateRestSecondsAfter,
            isLastSetOfWorkout: isLastSetOfWorkout
        )
    }

    // MARK: - Non-final set fallback chain

    func testNonFinalSetUsesPlannedRestBetweenSets() {
        // a. plannedRestBetweenSets wins over template rest on a non-final set.
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: 75,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 75)
    }

    func testNonFinalSetFallsBackToTemplateRestSecondsAfter() {
        // b. With no planned rest, the template's restSecondsAfter is used.
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: nil,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 30)
    }

    func testNonFinalSetIgnoresPlannedRestAfterExercise() {
        // plannedRestAfterExercise is final-set-only and must NOT leak
        // into the non-final fallback chain.
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: nil,
            plannedRestAfterExercise: 999,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 30)
    }

    // MARK: - Final set fallback chain

    func testFinalSetPrefersPlannedRestAfterExercise() {
        // c. plannedRestAfterExercise wins over both other links on the final set.
        let ctx = makeCtx(
            setIndex: 2,
            nextTemplateKind: nil,
            plannedRestBetweenSets: 60,
            plannedRestAfterExercise: 120,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 120)
    }

    func testFinalSetFallsBackToPlannedRestBetweenSets() {
        // d. With no plannedRestAfterExercise, plannedRestBetweenSets is used.
        let ctx = makeCtx(
            setIndex: 2,
            nextTemplateKind: nil,
            plannedRestBetweenSets: 60,
            plannedRestAfterExercise: nil,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 60)
    }

    func testFinalSetFallsBackToTemplateRestSecondsAfter() {
        // e. With no planned values, the template's restSecondsAfter is used.
        let ctx = makeCtx(
            setIndex: 2,
            nextTemplateKind: nil,
            plannedRestBetweenSets: nil,
            plannedRestAfterExercise: nil,
            templateRestSecondsAfter: 30
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 30)
    }

    // MARK: - Skip when next template is a dropset

    func testReturnsNilWhenNextTemplateIsDropset() {
        // f. Skipping rest before a template-based dropset means the user
        // proceeds directly to the drop without resting first.
        let ctx = makeCtx(
            setIndex: 0,
            nextTemplateKind: .dropset,
            effectiveSetCount: 3,
            plannedRestBetweenSets: 90,
            templateRestSecondsAfter: 30
        )
        XCTAssertNil(RestPlanner.restSecondsAfterLog(ctx))
    }

    func testDropsetNextCheckIsIgnoredOnFinalSet() {
        // The "next is dropset" guard only fires when there IS a next set.
        // On the final set, the planned-rest-after-exercise chain wins.
        let ctx = makeCtx(
            setIndex: 2,
            nextTemplateKind: .dropset,
            effectiveSetCount: 3,
            plannedRestAfterExercise: 90
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterLog(ctx), 90)
    }

    // MARK: - Last set of workout suppression

    func testLastSetOfWorkoutReturnsNil() {
        // g. Even with every planned-rest value set, the suppression wins.
        let ctx = makeCtx(
            setIndex: 2,
            nextTemplateKind: nil,
            effectiveSetCount: 3,
            plannedRestBetweenSets: 60,
            plannedRestAfterExercise: 120,
            templateRestSecondsAfter: 30,
            isLastSetOfWorkout: true
        )
        XCTAssertNil(RestPlanner.restSecondsAfterLog(ctx))
    }

    // MARK: - Zero / negative normalization

    func testZeroTemplateRestNormalizesToNil() {
        // h. The inline `r > 0` filter must be preserved: a literal 0
        // from the template means "no rest", not "0 seconds of rest".
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: nil,
            templateRestSecondsAfter: 0
        )
        XCTAssertNil(RestPlanner.restSecondsAfterLog(ctx))
    }

    func testNegativeTemplateRestNormalizesToNil() {
        // h (cont'd). Negative template rest should also fall out.
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: nil,
            templateRestSecondsAfter: -10
        )
        XCTAssertNil(RestPlanner.restSecondsAfterLog(ctx))
    }

    func testAllNilReturnsNil() {
        // No rest configured anywhere — planner must return nil rather
        // than starting a 0-second timer.
        let ctx = makeCtx(
            setIndex: 0,
            plannedRestBetweenSets: nil,
            plannedRestAfterExercise: nil,
            templateRestSecondsAfter: nil
        )
        XCTAssertNil(RestPlanner.restSecondsAfterLog(ctx))
    }

    // MARK: - Superset helpers (7.4-C.2)

    private func makeParticipant(
        participates: Bool = true,
        isComplete: Bool = true,
        plannedRestBetweenSets: Int? = nil,
        currentTemplateKind: SetKind = .working,
        currentTemplateRestSecondsAfter: Int? = nil,
        nextTemplateKind: SetKind? = .working,
        priorWorkingRest: Int? = nil
    ) -> SupersetRoundParticipant {
        SupersetRoundParticipant(
            participates: participates,
            isComplete: isComplete,
            plannedRestBetweenSets: plannedRestBetweenSets,
            currentTemplateKind: currentTemplateKind,
            currentTemplateRestSecondsAfter: currentTemplateRestSecondsAfter,
            nextTemplateKind: nextTemplateKind,
            priorWorkingRest: priorWorkingRest
        )
    }

    private func makeSupersetCtx(
        setIndex: Int = 0,
        participants: [SupersetRoundParticipant] = [],
        lastRoundIndex: Int = 2,
        supersetRoundRestSeconds: Int? = nil,
        blockRestAfterSeconds: Int? = nil,
        isLastBlockOfWorkout: Bool = false,
        isLastExerciseOfBlock: Bool = false
    ) -> SupersetRoundContext {
        SupersetRoundContext(
            setIndex: setIndex,
            participants: participants,
            lastRoundIndex: lastRoundIndex,
            supersetRoundRestSeconds: supersetRoundRestSeconds,
            blockRestAfterSeconds: blockRestAfterSeconds,
            isLastBlockOfWorkout: isLastBlockOfWorkout,
            isLastExerciseOfBlock: isLastExerciseOfBlock
        )
    }

    // MARK: - Mid-round suppression

    func testSupersetIncompleteRoundReturnsNil() {
        // Any participating-but-not-complete exercise must suppress rest
        // until the round is fully complete, regardless of how much
        // rest is otherwise configured.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(isComplete: true, plannedRestBetweenSets: 90),
                makeParticipant(isComplete: false, plannedRestBetweenSets: 90),
            ],
            supersetRoundRestSeconds: 120
        )
        XCTAssertNil(RestPlanner.restSecondsAfterSupersetRound(ctx))
    }

    func testSupersetRoundCompletionWaitsForDropsetChildDrops() {
        // The `isComplete` flag is the caller's responsibility — it must
        // be false when a dropset technique still has drops pending, even
        // if the parent set is logged. This test pins the contract: the
        // planner trusts isComplete and suppresses rest accordingly.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(isComplete: true),
                makeParticipant(isComplete: false), // dropset drops still pending
            ]
        )
        XCTAssertNil(RestPlanner.restSecondsAfterSupersetRound(ctx))
    }

    func testSupersetSkipsNonParticipatingExercises() {
        // Exercises whose set count does not reach this round must not
        // gate completion and must not contribute to the max-rest combine.
        // Here B does not participate; only A's 60s should win.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(participates: true, isComplete: true,
                                plannedRestBetweenSets: 60),
                makeParticipant(participates: false, isComplete: false,
                                plannedRestBetweenSets: 99),
            ]
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 60)
    }

    // MARK: - Base round rest

    func testSupersetCompleteNonFinalRoundUsesRoundRestSeconds() {
        // block.supersetRoundRestSeconds wins over the per-exercise
        // fallback chain when configured (> 0).
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(plannedRestBetweenSets: 30,
                                currentTemplateRestSecondsAfter: 45),
                makeParticipant(plannedRestBetweenSets: 60,
                                currentTemplateRestSecondsAfter: 99),
            ],
            supersetRoundRestSeconds: 120
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 120)
    }

    func testSupersetCompleteNonFinalRoundUsesMaxPlannedRestBetweenSets() {
        // No block-level rest configured: max across per-exercise
        // plannedRestBetweenSets wins (template rest is dominated by
        // planned rest within each exercise's chain).
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(plannedRestBetweenSets: 60,
                                currentTemplateRestSecondsAfter: 30),
                makeParticipant(plannedRestBetweenSets: 90,
                                currentTemplateRestSecondsAfter: 30),
            ]
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 90)
    }

    func testSupersetCompleteNonFinalRoundFallsBackToMaxTemplateRest() {
        // With no planned rest anywhere, per-exercise template rest is
        // the last link of the fallback chain. Max across exercises.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(plannedRestBetweenSets: nil,
                                currentTemplateRestSecondsAfter: 30),
                makeParticipant(plannedRestBetweenSets: nil,
                                currentTemplateRestSecondsAfter: 50),
            ]
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 50)
    }

    func testSupersetRoundWithNoRestConfiguredAnywhereReturnsNil() {
        // No planned, no template, no round rest, no dropset → nil
        // (matches the inline `(found && maxSeconds > 0) ? maxSeconds : nil`).
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(),
                makeParticipant(),
            ]
        )
        XCTAssertNil(RestPlanner.restSecondsAfterSupersetRound(ctx))
    }

    // MARK: - After-dropset round

    func testSupersetAfterDropsetRoundUsesPlannedThenPriorWorkingRest() {
        // When ANY exercise in the round has currentTemplateKind == .dropset,
        // the planner takes the "after-dropset" branch:
        // plannedRestBetweenSets ?? priorWorkingRest, max across exercises.
        // Here ex1 supplies planned 45, ex2 supplies prior-working 70 — max wins.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(plannedRestBetweenSets: 45,
                                currentTemplateKind: .dropset,
                                currentTemplateRestSecondsAfter: 5),
                makeParticipant(plannedRestBetweenSets: nil,
                                currentTemplateRestSecondsAfter: 99,
                                priorWorkingRest: 70),
            ]
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 70)
    }

    func testSupersetAfterDropsetRoundIgnoresCurrentTemplateRest() {
        // Defensive: in the after-dropset branch, the current template's
        // restSecondsAfter must NOT be in the chain (the chain is planned
        // → priorWorkingRest). A huge value on the current template should
        // not leak in.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(plannedRestBetweenSets: nil,
                                currentTemplateKind: .dropset,
                                currentTemplateRestSecondsAfter: 9999,
                                priorWorkingRest: 30),
                makeParticipant(plannedRestBetweenSets: nil,
                                currentTemplateRestSecondsAfter: 9999,
                                priorWorkingRest: nil),
            ]
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 30)
    }

    // MARK: - Next-round template dropset skip

    func testSupersetNextRoundTemplateDropsetSkipReturnsNil() {
        // Normal round (no current dropset), no round-level rest. The
        // next round contains a template-based dropset and there IS a
        // next round → skip rest now so the user proceeds to the drop.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(plannedRestBetweenSets: 60,
                                nextTemplateKind: .dropset),
                makeParticipant(plannedRestBetweenSets: 60,
                                nextTemplateKind: .working),
            ],
            lastRoundIndex: 2
        )
        XCTAssertNil(RestPlanner.restSecondsAfterSupersetRound(ctx))
    }

    func testSupersetNextRoundDropsetSkipIgnoredOnFinalRound() {
        // The next-round-dropset skip only fires when there IS a next
        // round. On the final round, the chain produces normally.
        let ctx = makeSupersetCtx(
            setIndex: 2,
            participants: [
                makeParticipant(plannedRestBetweenSets: 60,
                                nextTemplateKind: .dropset),
                makeParticipant(plannedRestBetweenSets: 60,
                                nextTemplateKind: nil),
            ],
            lastRoundIndex: 2,
            isLastExerciseOfBlock: true
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 60)
    }

    func testSupersetNextRoundDropsetSkipIgnoredWhenRoundRestConfigured() {
        // The next-round-dropset skip only fires in the per-exercise
        // fallback branch — it does NOT override an explicit round rest.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(nextTemplateKind: .dropset),
                makeParticipant(nextTemplateKind: .working),
            ],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 120
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 120)
    }

    // MARK: - Final-round transition rest

    func testSupersetFinalRoundUsesTransitionRestWhenConfigured() {
        // Final round + last exercise of block + extra > 0 → replace.
        // The round rest is intentionally large to prove "replace, not add".
        let ctx = makeSupersetCtx(
            setIndex: 2,
            participants: [
                makeParticipant(isComplete: true),
                makeParticipant(isComplete: true),
            ],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 60,
            blockRestAfterSeconds: 180,
            isLastExerciseOfBlock: true
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 180)
    }

    func testSupersetFinalRoundFallsBackToRoundRestWhenTransitionRestIsNil() {
        // No transition rest configured → round rest stays in place.
        let ctx = makeSupersetCtx(
            setIndex: 2,
            participants: [
                makeParticipant(isComplete: true),
                makeParticipant(isComplete: true),
            ],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 60,
            blockRestAfterSeconds: nil,
            isLastExerciseOfBlock: true
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 60)
    }

    func testSupersetTransitionRestNotAppliedOnNonFinalRound() {
        // Defensive: a non-final round must not apply the transition
        // replacement even when blockRestAfterSeconds is configured.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(plannedRestBetweenSets: 60),
                makeParticipant(plannedRestBetweenSets: 60),
            ],
            lastRoundIndex: 2,
            blockRestAfterSeconds: 180,
            isLastExerciseOfBlock: true
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 60)
    }

    func testSupersetTransitionRestNotAppliedWhenNotLastExerciseOfBlock() {
        // Final round, but `currentExerciseIndex` is not the last
        // exercise — the transition replacement waits for the round-
        // completing log to happen on the last exercise of the block.
        let ctx = makeSupersetCtx(
            setIndex: 2,
            participants: [
                makeParticipant(isComplete: true),
                makeParticipant(isComplete: true),
            ],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 60,
            blockRestAfterSeconds: 180,
            isLastExerciseOfBlock: false
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 60)
    }

    // MARK: - Last set of workout

    func testSupersetLastSetOfLastBlockReturnsNil() {
        // Final round + last exercise of block + last block of workout
        // → suppress rest, even when both round rest and transition
        // rest are configured.
        let ctx = makeSupersetCtx(
            setIndex: 2,
            participants: [
                makeParticipant(isComplete: true),
                makeParticipant(isComplete: true),
            ],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 60,
            blockRestAfterSeconds: 180,
            isLastBlockOfWorkout: true,
            isLastExerciseOfBlock: true
        )
        XCTAssertNil(RestPlanner.restSecondsAfterSupersetRound(ctx))
    }

    // MARK: - Phase 7.4-C.3 — Non-superset final-drop rest

    func testFinalDropInExerciseNonFinalWorkingSetUsesPlannedRestBetweenSets() {
        // Non-final working set in the exercise → planned-rest-between-sets.
        // The planned-rest-after-exercise field is final-set-only and must
        // not leak into the non-final chain.
        let r = RestPlanner.restSecondsAfterFinalDropInExercise(
            setIndex: 0,
            effectiveSetCount: 3,
            plannedRestBetweenSets: 75,
            plannedRestAfterExercise: 999,
            isLastSetOfWorkout: false
        )
        XCTAssertEqual(r, 75)
    }

    func testFinalDropInExerciseFinalWorkingSetPrefersPlannedRestAfterExercise() {
        // Last working set + after-exercise rest configured → after-exercise wins.
        let r = RestPlanner.restSecondsAfterFinalDropInExercise(
            setIndex: 2,
            effectiveSetCount: 3,
            plannedRestBetweenSets: 60,
            plannedRestAfterExercise: 120,
            isLastSetOfWorkout: false
        )
        XCTAssertEqual(r, 120)
    }

    func testFinalDropInExerciseFinalWorkingSetFallsBackToPlannedRestBetweenSets() {
        // Last working set, no after-exercise rest → between-sets fallback.
        let r = RestPlanner.restSecondsAfterFinalDropInExercise(
            setIndex: 2,
            effectiveSetCount: 3,
            plannedRestBetweenSets: 60,
            plannedRestAfterExercise: nil,
            isLastSetOfWorkout: false
        )
        XCTAssertEqual(r, 60)
    }

    func testFinalDropInExerciseLastSetOfWorkoutReturnsNil() {
        // Last set of the very last block of the workout → suppress rest
        // entirely, regardless of any planned rest values.
        let r = RestPlanner.restSecondsAfterFinalDropInExercise(
            setIndex: 2,
            effectiveSetCount: 3,
            plannedRestBetweenSets: 60,
            plannedRestAfterExercise: 120,
            isLastSetOfWorkout: true
        )
        XCTAssertNil(r)
    }

    func testFinalDropInExerciseNoPlannedRestReturnsNil() {
        // Nothing planned at any tier → nil (no rest fires).
        let r = RestPlanner.restSecondsAfterFinalDropInExercise(
            setIndex: 1,
            effectiveSetCount: 3,
            plannedRestBetweenSets: nil,
            plannedRestAfterExercise: nil,
            isLastSetOfWorkout: false
        )
        XCTAssertNil(r)
    }

    // MARK: - Phase 7.4-C.3 — Superset final-drop rest

    func testFinalDropInSupersetIncompleteRoundReturnsNil() {
        // Mid-round suppression: even with configured round rest, any
        // participating exercise that isn't complete blocks rest.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(isComplete: true, plannedRestBetweenSets: 90),
                makeParticipant(isComplete: false, plannedRestBetweenSets: 90),
            ],
            supersetRoundRestSeconds: 120
        )
        XCTAssertNil(RestPlanner.restSecondsAfterFinalDropInSuperset(ctx))
    }

    func testFinalDropInSupersetCompleteRoundUsesSupersetRoundRestSeconds() {
        // All participating exercises complete → base round rest wins.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(isComplete: true, plannedRestBetweenSets: 30),
                makeParticipant(isComplete: true, plannedRestBetweenSets: 60),
            ],
            supersetRoundRestSeconds: 120
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterFinalDropInSuperset(ctx), 120)
    }

    func testFinalDropInSupersetFallsBackToMaxPlannedRestBetweenSets() {
        // No block-level round rest → max planned rest across participants.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(isComplete: true, plannedRestBetweenSets: 45),
                makeParticipant(isComplete: true, plannedRestBetweenSets: 90),
            ]
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterFinalDropInSuperset(ctx), 90)
    }

    func testFinalDropInSupersetIgnoresCurrentTemplateRest() {
        // Stricter than restSecondsAfterSupersetRound: the dropset-final-drop
        // path does NOT fall back to currentTemplateRestSecondsAfter even
        // when planned rest is absent. With no planned rest → nil.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(isComplete: true,
                                plannedRestBetweenSets: nil,
                                currentTemplateRestSecondsAfter: 9999),
                makeParticipant(isComplete: true,
                                plannedRestBetweenSets: nil,
                                currentTemplateRestSecondsAfter: 9999),
            ]
        )
        XCTAssertNil(RestPlanner.restSecondsAfterFinalDropInSuperset(ctx))
    }

    func testFinalDropInSupersetFinalRoundUsesTransitionRest() {
        // Final round + blockRestAfterSeconds > 0 → transition replaces
        // base. Note: stricter `> 0` clamp here (unlike the `!= 0` gate
        // in restSecondsAfterSupersetRound).
        let ctx = makeSupersetCtx(
            setIndex: 2,
            participants: [
                makeParticipant(isComplete: true, plannedRestBetweenSets: 60),
                makeParticipant(isComplete: true, plannedRestBetweenSets: 60),
            ],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 90,
            blockRestAfterSeconds: 180
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterFinalDropInSuperset(ctx), 180)
    }

    func testFinalDropInSupersetFinalRoundIgnoresNonPositiveTransitionRest() {
        // Negative blockRestAfterSeconds is silently ignored (the
        // `> 0` clamp differs from the parent-log path's `!= 0`).
        let ctx = makeSupersetCtx(
            setIndex: 2,
            participants: [
                makeParticipant(isComplete: true, plannedRestBetweenSets: 60),
                makeParticipant(isComplete: true, plannedRestBetweenSets: 60),
            ],
            lastRoundIndex: 2,
            blockRestAfterSeconds: -5
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterFinalDropInSuperset(ctx), 60)
    }

    func testFinalDropInSupersetLastSetOfWorkoutReturnsNil() {
        // Final round + last block of workout → suppress.
        // Note: suppression is symmetric — does NOT require
        // `isLastExerciseOfBlock`. Set it to `false` to pin that.
        let ctx = makeSupersetCtx(
            setIndex: 2,
            participants: [
                makeParticipant(isComplete: true, plannedRestBetweenSets: 90),
                makeParticipant(isComplete: true, plannedRestBetweenSets: 90),
            ],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 60,
            blockRestAfterSeconds: 180,
            isLastBlockOfWorkout: true,
            isLastExerciseOfBlock: false
        )
        XCTAssertNil(RestPlanner.restSecondsAfterFinalDropInSuperset(ctx))
    }

    func testFinalDropInSupersetTransitionDoesNotApplyOnNonFinalRound() {
        // Defensive: blockRestAfterSeconds is configured but the current
        // round isn't the final one — base rest stays in place.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(isComplete: true, plannedRestBetweenSets: 60),
                makeParticipant(isComplete: true, plannedRestBetweenSets: 60),
            ],
            lastRoundIndex: 2,
            blockRestAfterSeconds: 180
        )
        XCTAssertEqual(RestPlanner.restSecondsAfterFinalDropInSuperset(ctx), 60)
    }

    func testFinalDropInSupersetNoConfiguredRestReturnsNil() {
        // All participating complete but no round rest, no planned rest,
        // no transition rest → nil.
        let ctx = makeSupersetCtx(
            setIndex: 0,
            participants: [
                makeParticipant(isComplete: true),
                makeParticipant(isComplete: true),
            ]
        )
        XCTAssertNil(RestPlanner.restSecondsAfterFinalDropInSuperset(ctx))
    }
}
