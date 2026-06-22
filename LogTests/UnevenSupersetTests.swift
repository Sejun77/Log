import SwiftData
import XCTest

@testable import Log

// MARK: - Pure round / ordering math (no SwiftData host)

/// Uneven-superset round + ordering math. These pin the runtime fix: rounds are
/// driven by the MAXIMUM set count across the block, so a shorter exercise drops
/// out of the later rounds (no equalization, no phantom sets). Equal-set blocks
/// are the special case where every count equals the max.
final class SupersetRoundMathTests: XCTestCase {

    // MARK: lastRoundIndex

    func testLastRoundIndexEqualSets() {
        XCTAssertEqual(SupersetRoundMath.lastRoundIndex(setCounts: [3, 3]), 2)
    }

    func testLastRoundIndexUsesMaxNotFirst_LongerFirst() {
        XCTAssertEqual(SupersetRoundMath.lastRoundIndex(setCounts: [3, 2]), 2)
    }

    func testLastRoundIndexUsesMaxNotFirst_LongerSecond() {
        // The regression-prone case: longest exercise is NOT first.
        XCTAssertEqual(SupersetRoundMath.lastRoundIndex(setCounts: [2, 3]), 2)
    }

    func testLastRoundIndexThreeExerciseUneven() {
        XCTAssertEqual(SupersetRoundMath.lastRoundIndex(setCounts: [3, 2, 1]), 2)
    }

    func testLastRoundIndexSingleAndEmpty() {
        XCTAssertEqual(SupersetRoundMath.lastRoundIndex(setCounts: [1, 3]), 2)
        XCTAssertEqual(SupersetRoundMath.lastRoundIndex(setCounts: [3, 1]), 2)
        XCTAssertEqual(SupersetRoundMath.lastRoundIndex(setCounts: []), 0)
        XCTAssertEqual(SupersetRoundMath.lastRoundIndex(setCounts: [0, 0]), 0)
    }

    // MARK: Ordering simulation

    /// Independently re-derive the canonical interleaved order for a set of
    /// per-exercise counts (block order): for each round, one set of every
    /// exercise that still has a set at that round index, in block order.
    private func expectedOrder(_ counts: [Int]) -> [[Int]] {
        guard let maxCount = counts.max(), maxCount > 0 else { return [] }
        var seq: [[Int]] = []
        for r in 0..<maxCount {
            for (i, c) in counts.enumerated() where r < c {
                seq.append([i, r])
            }
        }
        return seq
    }

    /// Drive a full superset using the production `isSetLoggable` gate. At each
    /// step it asserts that EXACTLY ONE set is loggable (a strict total order),
    /// logs it, and records the choice. The recorded order must equal the
    /// independently-derived `expectedOrder`.
    private func simulate(
        counts: [Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [[Int]] {
        var completed = Set<[Int]>()
        let isComplete: (Int, Int) -> Bool = { i, s in completed.contains([i, s]) }
        let total = counts.reduce(0, +)
        var order: [[Int]] = []

        for _ in 0..<total {
            var loggable: [[Int]] = []
            for i in counts.indices {
                for s in 0..<counts[i] {
                    if SupersetRoundMath.isSetLoggable(
                        isSuperset: true,
                        exerciseIndex: i,
                        setIndex: s,
                        setCounts: counts,
                        alreadyLogged: completed.contains([i, s]),
                        isComplete: isComplete
                    ) {
                        loggable.append([i, s])
                    }
                }
            }
            XCTAssertEqual(
                loggable.count, 1,
                "Exactly one set must be loggable at each step; got \(loggable)",
                file: file, line: line)
            guard let next = loggable.first else { break }
            order.append(next)
            completed.insert(next)
        }
        return order
    }

    func testOrder_3plus2() {
        // A1 → B1 → A2 → B2 → A3
        XCTAssertEqual(simulate(counts: [3, 2]), expectedOrder([3, 2]))
        XCTAssertEqual(
            simulate(counts: [3, 2]),
            [[0, 0], [1, 0], [0, 1], [1, 1], [0, 2]])
    }

    func testOrder_2plus3() {
        // A1 → B1 → A2 → B2 → B3
        XCTAssertEqual(simulate(counts: [2, 3]), expectedOrder([2, 3]))
        XCTAssertEqual(
            simulate(counts: [2, 3]),
            [[0, 0], [1, 0], [0, 1], [1, 1], [1, 2]])
    }

    func testOrder_1plus3() {
        // A1 → B1 → B2 → B3
        XCTAssertEqual(simulate(counts: [1, 3]), expectedOrder([1, 3]))
        XCTAssertEqual(simulate(counts: [1, 3]), [[0, 0], [1, 0], [1, 1], [1, 2]])
    }

    func testOrder_3plus1() {
        // A1 → B1 → A2 → A3
        XCTAssertEqual(simulate(counts: [3, 1]), expectedOrder([3, 1]))
        XCTAssertEqual(simulate(counts: [3, 1]), [[0, 0], [1, 0], [0, 1], [0, 2]])
    }

    func testOrder_3plus2plus1() {
        // A1 → B1 → C1 → A2 → B2 → A3
        XCTAssertEqual(simulate(counts: [3, 2, 1]), expectedOrder([3, 2, 1]))
        XCTAssertEqual(
            simulate(counts: [3, 2, 1]),
            [[0, 0], [1, 0], [2, 0], [0, 1], [1, 1], [0, 2]])
    }

    func testOrder_EqualSetsRegression() {
        // 3+3 still interleaves round-by-round exactly as before.
        XCTAssertEqual(
            simulate(counts: [3, 3]),
            [[0, 0], [1, 0], [0, 1], [1, 1], [0, 2], [1, 2]])
    }

    // MARK: Non-superset path

    func testNonSupersetIgnoresRoundGating() {
        // Single-exercise block: only the within-exercise prior-set rule applies.
        let counts = [3]
        let completed = Set([[0, 0]])
        // Set 1 (index 1) loggable once set 0 done; set 2 not yet.
        XCTAssertTrue(
            SupersetRoundMath.isSetLoggable(
                isSuperset: false, exerciseIndex: 0, setIndex: 1,
                setCounts: counts, alreadyLogged: false,
                isComplete: { i, s in completed.contains([i, s]) }))
        XCTAssertFalse(
            SupersetRoundMath.isSetLoggable(
                isSuperset: false, exerciseIndex: 0, setIndex: 2,
                setCounts: counts, alreadyLogged: false,
                isComplete: { i, s in completed.contains([i, s]) }))
    }

    func testAlreadyLoggedIsNotLoggable() {
        XCTAssertFalse(
            SupersetRoundMath.isSetLoggable(
                isSuperset: true, exerciseIndex: 0, setIndex: 0,
                setCounts: [3, 2], alreadyLogged: true,
                isComplete: { _, _ in true }))
    }

    // MARK: Auto-advance focus (nextLoggableSlot)

    /// Mirror `advanceForSupersetAfterLog`: log in canonical order and, after
    /// each log, record which exercise auto-advance would focus next
    /// (`nextLoggableSlot`'s exercise; -1 = block finished → stay).
    private func focusTargets(counts: [Int]) -> [Int] {
        var completed = Set<[Int]>()
        let isComplete: (Int, Int) -> Bool = { i, s in completed.contains([i, s]) }
        var targets: [Int] = []
        for slot in expectedOrder(counts) {
            completed.insert(slot)
            let next = SupersetRoundMath.nextLoggableSlot(
                setCounts: counts, isComplete: isComplete)
            targets.append(next?.exercise ?? -1)
        }
        return targets
    }

    func testAutoAdvanceSkipsDroppedOutExercise_2plus3() {
        // A=2, B=3. After A1→B, B1→A, A2→B, B2→**B** (B3, NOT A), B3→stay.
        let targets = focusTargets(counts: [2, 3])
        XCTAssertEqual(targets, [1, 0, 1, 1, -1])
        XCTAssertEqual(
            targets[3], 1,
            "After B2, auto-advance must focus B3 (exercise 1), not the "
                + "dropped-out A (exercise 0)")
    }

    func testAutoAdvanceFinalTargetIsLongerExercise_3plus2() {
        // A=3, B=2. After B2, focus A for the final unpaired A3, then stay.
        let targets = focusTargets(counts: [3, 2])
        XCTAssertEqual(targets, [1, 0, 1, 0, -1])
        XCTAssertEqual(targets[3], 0, "After B2, focus must go to A3 (exercise 0)")
    }

    func testAutoAdvanceEqualSetsUnchanged_3plus3() {
        // Plain round-robin, last log leaves focus to "stay" (-1).
        XCTAssertEqual(focusTargets(counts: [3, 3]), [1, 0, 1, 0, 1, -1])
    }

    func testNextLoggableSlotNilWhenBlockComplete() {
        XCTAssertNil(
            SupersetRoundMath.nextLoggableSlot(
                setCounts: [2, 3], isComplete: { _, _ in true }))
    }

    func testNextLoggableSlotAfterB2Is_B3() {
        // Explicit pin of the manual-bug scenario: A1,B1,A2,B2 logged.
        let done: Set<[Int]> = [[0, 0], [1, 0], [0, 1], [1, 1]]
        let next = SupersetRoundMath.nextLoggableSlot(
            setCounts: [2, 3], isComplete: { i, s in done.contains([i, s]) })
        XCTAssertEqual(next?.exercise, 1)
        XCTAssertEqual(next?.setIndex, 2)
    }

    // MARK: Last participant in round (rest-firing position)

    func testLastParticipantIndex_LongerFirst() {
        // A=3, B=2: round 2 is completed by A (index 0), not B.
        XCTAssertEqual(
            SupersetRoundMath.lastParticipantIndex(setCounts: [3, 2], roundIndex: 2), 0)
        // Earlier rounds: both participate → last is B (index 1).
        XCTAssertEqual(
            SupersetRoundMath.lastParticipantIndex(setCounts: [3, 2], roundIndex: 0), 1)
        XCTAssertEqual(
            SupersetRoundMath.lastParticipantIndex(setCounts: [3, 2], roundIndex: 1), 1)
    }

    func testLastParticipantIndex_LongerSecondAndEqual() {
        XCTAssertEqual(
            SupersetRoundMath.lastParticipantIndex(setCounts: [2, 3], roundIndex: 2), 1)
        // Equal sets: always the last exercise.
        XCTAssertEqual(
            SupersetRoundMath.lastParticipantIndex(setCounts: [3, 3], roundIndex: 2), 1)
        // Beyond every count → nil.
        XCTAssertNil(
            SupersetRoundMath.lastParticipantIndex(setCounts: [2, 3], roundIndex: 3))
    }
}

// MARK: - Uneven superset rest behavior (RestPlanner, parent-log path)

/// Pins the rest-priority fixes for uneven supersets. The active-workout call
/// site now passes `isLastExerciseOfBlock` = "current exercise is the last
/// PARTICIPANT in this round" (`SupersetRoundMath.lastParticipantIndex`), so the
/// planner fires final-round transition / last-set suppression on the correct
/// log even when the round-completing exercise is not last in block order.
final class UnevenSupersetRestTests: XCTestCase {

    /// One participant; defaults to a complete, participating working set.
    private func participant(
        participates: Bool = true,
        isComplete: Bool = true,
        plannedRestBetweenSets: Int? = nil
    ) -> SupersetRoundParticipant {
        SupersetRoundParticipant(
            participates: participates,
            isComplete: isComplete,
            plannedRestBetweenSets: plannedRestBetweenSets,
            currentTemplateKind: .working,
            currentTemplateRestSecondsAfter: nil,
            nextTemplateKind: nil,
            priorWorkingRest: nil)
    }

    // A=3, B=2, logging the final unpaired A3 (round 2). Only A participates.
    // lastParticipantIndex([3,2], 2) == 0, so the call site passes
    // isLastExerciseOfBlock = true (A is index 0 AND the last participant).

    func testFinalUnpairedSet_LastSetOfWorkout_SuppressesRest() {
        let ctx = SupersetRoundContext(
            setIndex: 2,
            participants: [participant(plannedRestBetweenSets: 90),
                           participant(participates: false)],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 120,
            blockRestAfterSeconds: nil,
            isLastBlockOfWorkout: true,
            isLastExerciseOfBlock: true)
        XCTAssertNil(
            RestPlanner.restSecondsAfterSupersetRound(ctx),
            "Final set of the whole workout must not start rest")
    }

    func testFinalUnpairedSet_WithNextBlock_UsesRestAfterBlockNotRoundRest() {
        let ctx = SupersetRoundContext(
            setIndex: 2,
            participants: [participant(plannedRestBetweenSets: 90),
                           participant(participates: false)],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 120,   // round rest…
            blockRestAfterSeconds: 200,      // …replaced by transition rest
            isLastBlockOfWorkout: false,
            isLastExerciseOfBlock: true)
        XCTAssertEqual(
            RestPlanner.restSecondsAfterSupersetRound(ctx), 200,
            "Completing the block before a next block uses rest-after-block")
    }

    func testNonFinalCompletedRoundStillUsesRoundRest() {
        // Round 0 of A=3,B=2: both participate and complete; not the last round.
        let ctx = SupersetRoundContext(
            setIndex: 0,
            participants: [participant(), participant()],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 120,
            blockRestAfterSeconds: 200,
            isLastBlockOfWorkout: false,
            isLastExerciseOfBlock: true)
        XCTAssertEqual(RestPlanner.restSecondsAfterSupersetRound(ctx), 120)
    }

    func testEqualSetsFinalRoundUnchanged() {
        // A=3,B=3 last round completes on B (last participant). Last block →
        // suppressed, exactly as before.
        let ctx = SupersetRoundContext(
            setIndex: 2,
            participants: [participant(), participant()],
            lastRoundIndex: 2,
            supersetRoundRestSeconds: 120,
            blockRestAfterSeconds: nil,
            isLastBlockOfWorkout: true,
            isLastExerciseOfBlock: true)
        XCTAssertNil(RestPlanner.restSecondsAfterSupersetRound(ctx))
    }
}

// MARK: - Authoring / persistence + prefill + history (SwiftData host)

/// Uneven-superset authoring (per-slot set counts), prefill, and History
/// grouping. Verifies the model + pure services tolerate unequal set counts
/// with no forced equalization and no phantom rows.
@MainActor
final class UnevenSupersetModelTests: SwiftDataTestHarness {

    private func makeExercise(_ name: String) -> Exercise {
        let e = Exercise(name: name)
        context.insert(e)
        return e
    }

    /// Build a superset block whose slots carry the given per-slot set counts.
    private func makeUnevenSuperset(_ counts: [Int]) -> RoutineBlock {
        var slots: [RoutineExercise] = []
        for (i, c) in counts.enumerated() {
            let ex = makeExercise("E\(i)")
            let re = RoutineExercise(exercise: ex, order: i, setTemplates: [])
            context.insert(re)
            let p = makeDefaultPrescription(isTimeBased: false, in: context)
            p.sets = c
            re.prescription = p
            slots.append(re)
        }
        let block = RoutineBlock(
            isSuperset: true, order: 0, restAfterSeconds: nil, exercises: slots)
        block.supersetRoundRestSeconds = 90
        context.insert(block)
        try? context.save()
        return block
    }

    // MARK: Per-slot set counts

    func testUnevenPerSlotSetCountsResolveIndependently() {
        let block = makeUnevenSuperset([3, 2])
        let sorted = block.exercises.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted[0].resolvedTemplates().count, 3)
        XCTAssertEqual(sorted[1].resolvedTemplates().count, 2)
    }

    func testUnevenSetCountsPersistAfterSaveAndRefetch() throws {
        let block = makeUnevenSuperset([2, 3])
        let blockSlotID = block.slotID
        try context.save()

        let descriptor = FetchDescriptor<RoutineBlock>(
            predicate: #Predicate { $0.slotID == blockSlotID })
        let refetched = try XCTUnwrap(try context.fetch(descriptor).first)
        let sorted = refetched.exercises.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.compactMap { $0.prescription?.sets }, [2, 3])
    }

    func testEqualSetCountsStillEqual() {
        let block = makeUnevenSuperset([3, 3])
        let counts = block.exercises
            .sorted { $0.order < $1.order }
            .map { $0.resolvedTemplates().count }
        XCTAssertEqual(counts, [3, 3])
    }

    /// "Set all to N" convenience — when applied, every child ends up equal,
    /// but this is explicit, not forced. (Mirrors `applySetsToAllExercises`.)
    func testSetAllToConvenienceAppliesUniformlyButIsOptional() {
        let block = makeUnevenSuperset([3, 2])
        // Simulate the bulk "Set all to 4" control.
        for re in block.exercises { re.prescription?.sets = 4 }
        try? context.save()
        let counts = block.exercises.map { $0.prescription?.sets }
        XCTAssertEqual(counts, [4, 4])

        // A subsequent per-slot edit makes them uneven again — no re-equalization.
        let sorted = block.exercises.sorted { $0.order < $1.order }
        sorted[1].prescription?.sets = 2
        try? context.save()
        XCTAssertEqual(
            block.exercises.sorted { $0.order < $1.order }
                .compactMap { $0.prescription?.sets },
            [4, 2])
    }

    func testAddExercisesToSupersetSeedsDefaultButStaysEditable() throws {
        let r = Routine(name: "R", blocks: [])
        context.insert(r)
        let block = makeUnevenSuperset([3, 2])
        r.blocks.append(block)

        // New slot seeded with the shared/default value...
        RoutineBlockBuilder.addExercisesToSuperset(
            [makeExercise("New")], to: block, sharedSets: 3, in: context)
        let newSlot = try XCTUnwrap(
            block.exercises.first { $0.exercise?.name == "New" })
        XCTAssertEqual(newSlot.prescription?.sets, 3)

        // ...but editable to a different count (uneven allowed).
        newSlot.prescription?.sets = 1
        try? context.save()
        XCTAssertEqual(newSlot.prescription?.sets, 1)
        // Existing slots untouched.
        let existing = block.exercises
            .filter { $0.exercise?.name != "New" }
            .sorted { $0.order < $1.order }
        XCTAssertEqual(existing.compactMap { $0.prescription?.sets }, [3, 2])
    }

    // MARK: Bulk "Apply to all exercises"

    func testBulkApplySetsAllChildrenOnlyOnApply() {
        let block = makeUnevenSuperset([3, 2])
        // The draft stepper changing does NOT touch children — only the
        // explicit apply call does. Simulate the apply.
        RoutineBlockBuilder.applySetCountToAll(4, in: block, ctx: context)
        XCTAssertEqual(
            block.exercises.sorted { $0.order < $1.order }
                .compactMap { $0.prescription?.sets },
            [4, 4])
    }

    func testPerSlotCountsStillEditableAfterBulkApply() {
        let block = makeUnevenSuperset([3, 2])
        RoutineBlockBuilder.applySetCountToAll(4, in: block, ctx: context)
        // Re-introduce unevenness on one slot — no re-equalization happens.
        let sorted = block.exercises.sorted { $0.order < $1.order }
        sorted[1].prescription?.sets = 2
        try? context.save()
        XCTAssertEqual(
            block.exercises.sorted { $0.order < $1.order }
                .compactMap { $0.prescription?.sets },
            [4, 2])
    }

    func testBulkApplyZeroClearsToNil() {
        let block = makeUnevenSuperset([3, 2])
        RoutineBlockBuilder.applySetCountToAll(0, in: block, ctx: context)
        XCTAssertTrue(block.exercises.allSatisfy { $0.prescription?.sets == nil })
    }

    // MARK: Prefill (per-exercise, superset-agnostic)

    private func makeCompletedWorkout(
        exercise: Exercise,
        reps: [Int],
        excludedFromPrefill: Bool = false
    ) -> Workout {
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        context.insert(item)
        for (i, rep) in reps.enumerated() {
            let log = SetLog(
                indexInExercise: i, kind: .working, reps: rep, weight: 100)
            item.setLogs.append(log)
        }
        let w = Workout(date: .now, items: [item])
        w.completedAt = .now
        w.excludedFromPrefill = excludedFromPrefill
        context.insert(w)
        try? context.save()
        return w
    }

    func testLongerExerciseExtraSetCarriesDown() {
        // The longer exercise has 3 sets this session but only 2 in history.
        let longer = makeExercise("Longer")
        _ = makeCompletedWorkout(exercise: longer, reps: [10, 9])

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: longer.id, in: try! context.fetch(FetchDescriptor<Workout>()))
        // Set index 2 (the extra set) carries down the top logged set.
        let s2 = LastPerformancePrefillService.suggestion(
            forCurrentSetIndex: 2, from: map)
        XCTAssertEqual(s2?.reps, 9)
        // Exact matches for the real history indices.
        XCTAssertEqual(
            LastPerformancePrefillService.suggestion(forCurrentSetIndex: 0, from: map)?.reps, 10)
        XCTAssertEqual(
            LastPerformancePrefillService.suggestion(forCurrentSetIndex: 1, from: map)?.reps, 9)
    }

    func testShorterExerciseGetsNoFakePrefillForMissingSet() {
        // The shorter exercise simply has no row at the missing index — the
        // map only ever contains real logged indices. The carry-down resolver
        // is the caller's choice; what matters is the map has no phantom entry.
        let shorter = makeExercise("Shorter")
        _ = makeCompletedWorkout(exercise: shorter, reps: [8, 8])
        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: shorter.id, in: try! context.fetch(FetchDescriptor<Workout>()))
        XCTAssertEqual(Set(map.keys), [0, 1])
        XCTAssertNil(map[2], "No phantom suggestion for a set that was never logged")
    }

    func testExcludedFromPrefillStillSkipped() {
        let ex = makeExercise("Ex")
        _ = makeCompletedWorkout(exercise: ex, reps: [5, 5], excludedFromPrefill: true)
        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: ex.id, in: try! context.fetch(FetchDescriptor<Workout>()))
        XCTAssertTrue(map.isEmpty)
    }

    // MARK: History grouping (uneven members)

    func testUnevenSupersetGroupsTogetherWithDifferentSetCounts() {
        let blockID = UUID()
        let a = makeExercise("A")
        let b = makeExercise("B")

        let itemA = WorkoutItem(exercise: a, setLogs: [])
        for i in 0..<3 {
            itemA.setLogs.append(SetLog(indexInExercise: i, kind: .working, reps: 10, weight: 100))
        }
        itemA.sourceBlockSlotID = blockID
        itemA.sourceBlockIsSuperset = true
        itemA.sourceBlockOrder = 0
        itemA.sourceExerciseOrderInBlock = 0
        context.insert(itemA)

        let itemB = WorkoutItem(exercise: b, setLogs: [])
        for i in 0..<2 {
            itemB.setLogs.append(SetLog(indexInExercise: i, kind: .working, reps: 8, weight: 80))
        }
        itemB.sourceBlockSlotID = blockID
        itemB.sourceBlockIsSuperset = true
        itemB.sourceBlockOrder = 0
        itemB.sourceExerciseOrderInBlock = 1
        context.insert(itemB)

        let groups = groupItemsBySourceBlock([itemA, itemB])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isSuperset)
        XCTAssertEqual(groups[0].items.count, 2)
        // Members ordered by sourceExerciseOrderInBlock; their set counts differ
        // and only real logged sets are present.
        XCTAssertEqual(groups[0].items.map { $0.setLogs.count }, [3, 2])
    }
}
