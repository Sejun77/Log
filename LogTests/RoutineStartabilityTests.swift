import SwiftData
import XCTest

@testable import Log

/// Regression coverage for the TestFlight crash on the routine-open / start
/// path. The crash originated in `RoutineExercise.safeExercise(in:)`, which
/// ran a `FetchDescriptor<RoutineExercise>` with `#Predicate { $0.id == myID }`.
/// `RoutineExercise` has no stored `id` attribute — `id` is
/// `PersistentModel.persistentModelID`, a computed property — so SwiftData's
/// `graph_keyPathToString(keypath:)` crashed while translating that key path
/// in optimized (release/TestFlight) builds.
///
/// These tests pin the fixed behavior: `safeExercise(in:)` and
/// `Routine.isStartable(in:)` (the extracted body logic behind the editor's
/// Start button) must resolve — or safely decline to resolve — every degraded
/// slot/routine shape without crashing.
@MainActor
final class RoutineStartabilityTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    @discardableResult
    private func makeExercise(name: String = "Bench Press") -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        return ex
    }

    @discardableResult
    private func makeSlot(exercise: Exercise?, order: Int = 0) -> RoutineExercise {
        // `RoutineExercise.init` requires a non-optional exercise; build with a
        // throwaway and null it when a nil-relationship slot is wanted.
        let seed = exercise ?? makeExercise(name: "seed")
        let re = RoutineExercise(exercise: seed, order: order, setTemplates: [])
        context.insert(re)
        if exercise == nil { re.exercise = nil }
        return re
    }

    @discardableResult
    private func makeBlock(
        exercises: [RoutineExercise],
        isSuperset: Bool = false,
        supersetRoundRestSeconds: Int? = nil,
        order: Int = 0
    ) -> RoutineBlock {
        let b = RoutineBlock(
            isSuperset: isSuperset, order: order, exercises: exercises
        )
        b.supersetRoundRestSeconds = supersetRoundRestSeconds
        context.insert(b)
        return b
    }

    @discardableResult
    private func makeRoutine(blocks: [RoutineBlock]) -> Routine {
        let r = Routine(name: "Push Day", blocks: blocks)
        context.insert(r)
        try? context.save()
        return r
    }

    // MARK: - safeExercise(in:) degraded states

    func testSafeExerciseResolvesNormalSlot() {
        let ex = makeExercise()
        let re = makeSlot(exercise: ex)
        try? context.save()

        XCTAssertEqual(re.safeExercise(in: context)?.id, ex.id)
    }

    func testSafeExerciseReturnsNilForNilRelationship() {
        let re = makeSlot(exercise: nil)
        try? context.save()

        XCTAssertNil(re.safeExercise(in: context))
    }

    func testSafeExerciseReturnsNilAfterExerciseDeleted() {
        let ex = makeExercise()
        let re = makeSlot(exercise: ex)
        try? context.save()

        context.delete(ex)
        try? context.save()

        // Must not crash; the deleted target resolves to nil.
        XCTAssertNil(re.safeExercise(in: context))
    }

    func testSafeExerciseReturnsNilForUninsertedSlot() {
        // A RoutineExercise never inserted into a context has a nil
        // modelContext and must be treated as unresolved rather than faulting.
        let ex = makeExercise()
        let detached = RoutineExercise(exercise: ex, order: 0, setTemplates: [])

        XCTAssertNil(detached.safeExercise(in: context))
    }

    // MARK: - Routine.isStartable(in:) — the Start-button gate

    /// Crash flow #2: "trying to open a routine". An empty routine must be a
    /// safe, non-startable no-op.
    func testEmptyRoutineIsNotStartableAndDoesNotCrash() {
        let r = makeRoutine(blocks: [])
        XCTAssertFalse(r.isStartable(in: context))
    }

    /// A routine whose single block has no exercises is safe and not startable.
    func testRoutineWithEmptyBlockIsNotStartable() {
        let block = makeBlock(exercises: [])
        let r = makeRoutine(blocks: [block])
        XCTAssertFalse(r.isStartable(in: context))
    }

    /// A block whose only slot has a nil exercise contributes no content.
    func testRoutineWithNilExerciseSlotIsNotStartable() {
        let re = makeSlot(exercise: nil)
        let block = makeBlock(exercises: [re])
        let r = makeRoutine(blocks: [block])
        XCTAssertFalse(r.isStartable(in: context))
    }

    /// A slot whose exercise was deleted must not crash startability and must
    /// not count as content.
    func testRoutineWithDeletedExerciseSlotIsNotStartable() {
        let ex = makeExercise()
        let re = makeSlot(exercise: ex)
        let block = makeBlock(exercises: [re])
        let r = makeRoutine(blocks: [block])

        context.delete(ex)
        try? context.save()

        XCTAssertFalse(r.isStartable(in: context))
    }

    /// Crash flow #1 endpoint: adding the first exercise to a blank routine
    /// makes it startable.
    func testRoutineBecomesStartableAfterAddingFirstExercise() {
        // Start blank.
        let r = makeRoutine(blocks: [])
        XCTAssertFalse(r.isStartable(in: context))

        // Add the first block + exercise, mirroring the editor add flow.
        let ex = makeExercise()
        let re = makeSlot(exercise: ex)
        let block = makeBlock(exercises: [re])
        r.blocks.append(block)
        try? context.save()

        XCTAssertTrue(r.isStartable(in: context))
    }

    /// A valid single-exercise, non-superset routine is startable.
    func testSingleExerciseRoutineIsStartable() {
        let ex = makeExercise()
        let re = makeSlot(exercise: ex)
        let block = makeBlock(exercises: [re])
        let r = makeRoutine(blocks: [block])

        XCTAssertTrue(r.isStartable(in: context))
    }

    /// A superset block without a positive round-rest gates the routine off,
    /// even when it holds resolvable exercises.
    func testSupersetWithoutRoundRestIsNotStartable() {
        let re1 = makeSlot(exercise: makeExercise(name: "A"), order: 0)
        let re2 = makeSlot(exercise: makeExercise(name: "B"), order: 1)
        let block = makeBlock(
            exercises: [re1, re2],
            isSuperset: true,
            supersetRoundRestSeconds: nil
        )
        let r = makeRoutine(blocks: [block])

        XCTAssertFalse(r.isStartable(in: context))
    }

    func testSupersetWithPositiveRoundRestIsStartable() {
        let re1 = makeSlot(exercise: makeExercise(name: "A"), order: 0)
        let re2 = makeSlot(exercise: makeExercise(name: "B"), order: 1)
        let block = makeBlock(
            exercises: [re1, re2],
            isSuperset: true,
            supersetRoundRestSeconds: 60
        )
        let r = makeRoutine(blocks: [block])

        XCTAssertTrue(r.isStartable(in: context))
    }
}
