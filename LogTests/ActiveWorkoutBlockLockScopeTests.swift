import SwiftData
import XCTest

@testable import Log

/// Regression coverage for cross-routine block freezing.
///
/// **The bug.** `RoutineEditor` decided whether a block was "in use" by asking
/// `ActiveWorkoutGuard.isLocked(exercise.id)` — Exercise-*definition*
/// identity. `beginSession` fills `lockedExerciseIDs` with every Exercise the
/// active plan references, so once a workout started from Routine A, *every*
/// block in *every* routine that referenced one of those exercises rendered
/// the lock badge, lost its Delete/Duplicate swipe actions, and refused
/// edit-mode deletion. Reusing Bench Press across routines is normal training
/// practice, so this froze unrelated plans.
///
/// **The rule.** Block identity follows routine ownership, not exercise
/// identity: a block belongs to exactly one routine, and only the routine the
/// active session was started from owns blocks the session is executing.
/// `ActiveWorkoutGuard.isBlockInUse(routineID:exerciseIDs:)` checks routine
/// ownership first and only then the exercise set — so the source routine
/// keeps exactly the protection it had, and every other routine is free.
///
/// Routine-level and exercise-library-level locks are deliberately untouched
/// and are re-asserted below: deleting Bench Press from the library mid-session
/// stays blocked no matter which routine you reach it from, because the
/// Exercise *entity* really is in use.
@MainActor
final class ActiveWorkoutBlockLockScopeTests: SwiftDataTestHarness {

    private var sut: ActiveWorkoutGuard { ActiveWorkoutGuard.shared }

    override func setUp() {
        super.setUp()
        sut.endSession()
    }

    override func tearDown() {
        sut.endSession()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeExercise(_ name: String) -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        return ex
    }

    private func makeSlot(_ exercise: Exercise, order: Int = 0)
        -> RoutineExercise
    {
        let re = RoutineExercise(
            exercise: exercise, order: order, setTemplates: []
        )
        context.insert(re)
        return re
    }

    private func makeBlock(
        _ exercises: [Exercise],
        isSuperset: Bool = false,
        order: Int = 0
    ) -> RoutineBlock {
        let slots = exercises.enumerated().map { makeSlot($1, order: $0) }
        let b = RoutineBlock(
            isSuperset: isSuperset, order: order, exercises: slots
        )
        if isSuperset { b.supersetRoundRestSeconds = 90 }
        context.insert(b)
        return b
    }

    private func makeRoutine(_ name: String, blocks: [RoutineBlock]) -> Routine
    {
        let r = Routine(name: name, blocks: blocks)
        context.insert(r)
        try? context.save()
        return r
    }

    /// Starts a session through the real start path: the same
    /// `makePlan(from:)` the Start button uses, handed to the same
    /// `beginSession(plan:)`. Nothing about the lock sets is faked.
    private func startSession(from routine: Routine) {
        let plan = StartWorkoutFromRoutineView.makePlan(from: routine)
        sut.activeWorkoutID = UUID()
        sut.beginSession(plan: plan)
    }

    /// The rule `RoutineEditor.blockIsInUseByActiveWorkout` applies to a row.
    private func blockIsInUse(_ block: RoutineBlock, in routine: Routine)
        -> Bool
    {
        sut.isBlockInUse(
            routineID: routine.id,
            exerciseIDs: block.exercises.compactMap { $0.exercise?.id }
        )
    }

    // MARK: - Shared exercise across two routines

    /// Routine A: A1 → X. Routine B: B1 → X. Start from A.
    func testSharedExerciseDoesNotLockOtherRoutinesBlock() {
        let x = makeExercise("Bench Press")
        let a1 = makeBlock([x])
        let routineA = makeRoutine("Push A", blocks: [a1])
        let b1 = makeBlock([x])
        let routineB = makeRoutine("Push B", blocks: [b1])

        startSession(from: routineA)

        // The source routine keeps every protection it had.
        XCTAssertTrue(
            sut.isRoutineLocked(routineA.id),
            "The routine the session was started from must stay locked.")
        XCTAssertTrue(
            blockIsInUse(a1, in: routineA),
            "Block A1 belongs to the active session's routine and must stay "
                + "protected — narrowing the scope must not disarm the guard.")

        // The unrelated routine is untouched.
        XCTAssertFalse(
            sut.isRoutineLocked(routineB.id),
            "Routine B is a different training plan and is not in use.")
        XCTAssertFalse(
            blockIsInUse(b1, in: routineB),
            """
            Block B1 was frozen only because it references the same Exercise \
            as the active workout. Sharing an exercise across routines is \
            normal; block lock must follow routine ownership, not Exercise id.
            """
        )
    }

    /// Routine B: B1 → X (shared), B2 → Y (not in the active plan at all).
    /// Neither may inherit Routine A's lock.
    func testNeitherBlockOfUnrelatedRoutineInheritsTheLock() {
        let x = makeExercise("Bench Press")
        let y = makeExercise("Cable Row")
        let routineA = makeRoutine("Push A", blocks: [makeBlock([x])])
        let b1 = makeBlock([x], order: 0)
        let b2 = makeBlock([y], order: 1)
        let routineB = makeRoutine("Push B", blocks: [b1, b2])

        startSession(from: routineA)

        XCTAssertFalse(blockIsInUse(b1, in: routineB))
        XCTAssertFalse(blockIsInUse(b2, in: routineB))
    }

    /// Supersets resolve their lock through the same helper, so an unrelated
    /// superset containing the shared exercise must also stay editable.
    func testUnrelatedSupersetWithSharedExerciseIsNotLocked() {
        let x = makeExercise("Bench Press")
        let y = makeExercise("Cable Row")
        let aSuperset = makeBlock([x, y], isSuperset: true)
        let routineA = makeRoutine("Push A", blocks: [aSuperset])
        let bSuperset = makeBlock([x, y], isSuperset: true)
        let routineB = makeRoutine("Push B", blocks: [bSuperset])

        startSession(from: routineA)

        XCTAssertTrue(
            blockIsInUse(aSuperset, in: routineA),
            "The active routine's superset must stay protected.")
        XCTAssertFalse(
            blockIsInUse(bSuperset, in: routineB),
            "An unrelated superset sharing both exercises is still a "
                + "different slot in a different plan.")
    }

    // MARK: - Protections that must not regress

    /// Exercise-library editing is governed by the separate, still-global
    /// exercise lock: the Exercise *entity* is genuinely in use, so deleting
    /// it stays blocked regardless of which routine surfaces it.
    func testExerciseLibraryLockStaysGlobal() {
        let x = makeExercise("Bench Press")
        let y = makeExercise("Cable Row")
        let routineA = makeRoutine("Push A", blocks: [makeBlock([x])])
        _ = makeRoutine("Push B", blocks: [makeBlock([x]), makeBlock([y])])

        startSession(from: routineA)

        XCTAssertTrue(
            sut.isLocked(x.id),
            "Deleting an exercise the active session is performing must stay "
                + "blocked in the exercise library — that lock is Exercise "
                + "identity and is intentionally routine-independent.")
        XCTAssertFalse(
            sut.isLocked(y.id),
            "An exercise the active plan never references is not in use.")
    }

    /// A block in the active routine whose exercise is not in the plan (a
    /// degraded slot with a nil exercise) is not in use — the narrowed rule
    /// still requires an actual exercise match inside the owning routine.
    func testActiveRoutineBlockWithoutPlanExerciseIsNotInUse() {
        let x = makeExercise("Bench Press")
        let y = makeExercise("Cable Row")
        let a1 = makeBlock([x], order: 0)
        let routineA = makeRoutine("Push A", blocks: [a1])

        startSession(from: routineA)

        // Added to the model after the plan froze; not part of the session.
        let a2 = makeBlock([y], order: 1)
        routineA.blocks.append(a2)
        try? context.save()

        XCTAssertTrue(blockIsInUse(a1, in: routineA))
        XCTAssertFalse(blockIsInUse(a2, in: routineA))
    }

    /// Ending the session releases both scopes.
    func testEndSessionReleasesBlockLock() {
        let x = makeExercise("Bench Press")
        let a1 = makeBlock([x])
        let routineA = makeRoutine("Push A", blocks: [a1])

        startSession(from: routineA)
        XCTAssertTrue(blockIsInUse(a1, in: routineA))

        sut.endSession()

        XCTAssertFalse(sut.isRoutineLocked(routineA.id))
        XCTAssertFalse(blockIsInUse(a1, in: routineA))
    }
}
