import SwiftData
import XCTest

@testable import Log

/// Phase 6.C1 follow-up — `findSlotIndex(in:routineSlotID:)` is the pure
/// helper that all slot-targeted plan-graph mutations (swap, reset-plan)
/// must use instead of keying on `PlanExercise.id` (which equals
/// `Exercise.id` and collides for duplicate-Exercise superset slots).
///
/// Bug being pinned: pre-fix `swapExercise` and `performPendingSwap`
/// looked up the target slot via `plan.blocks.firstIndex(where: {
/// $0.exercises.contains(where: { $0.id == planEx.id }) })`. When a
/// superset contained two slots of the same Exercise, swapping the
/// second slot mutated the first slot's `currentExerciseID` and wiped
/// its already-logged set. The fix routes every slot-targeted lookup
/// through `findSlotIndex(in:routineSlotID:)`.
final class PlanSlotLookupTests: XCTestCase {

    // MARK: - Fixture

    /// Build a minimal `PlanExercise` with deliberately non-slot-unique
    /// `id` (Exercise.id) but a distinct `routineSlotID`.
    private func makePlanExercise(
        exerciseID: UUID,
        routineSlotID: UUID,
        name: String
    ) -> PlanExercise {
        PlanExercise(
            id: exerciseID,
            routineExerciseID: makeFakePersistentID(),
            originalExerciseID: exerciseID,
            currentExerciseID: exerciseID,
            name: name,
            notes: nil,
            templates: [],
            isTimeBased: false,
            routineSlotID: routineSlotID,
            templateNotesSnapshot: nil,
            prescriptionSnapshot: nil,
            techniquePlansSnapshot: [],
            warmupStepsSnapshot: []
        )
    }

    /// `PersistentIdentifier` cannot be constructed via a public API
    /// outside of SwiftData. The lookup helper never inspects this
    /// field, so a placeholder built via `unsafeBitCast` is safe — but
    /// we don't need to: the lookup ignores `routineExerciseID`
    /// entirely. Use a default-constructed value via a tiny harness.
    private func makeFakePersistentID() -> PersistentIdentifier {
        // PersistentIdentifier conforms to Codable. Decode an empty
        // JSON object → fails. Easiest: route through SwiftData's
        // default initializer if available; otherwise just construct
        // a placeholder we never inspect.
        //
        // Tests in this file never read .routineExerciseID, so any
        // valid PersistentIdentifier works. We avoid the issue by
        // using the only public ctor — JSON-decoding a known shape.
        let json = "{\"implementation\":{\"primaryKey\":\"x\",\"uriRepresentation\":\"x://test\",\"isTemporary\":true,\"entityName\":\"\"}}"
        let data = json.data(using: .utf8)!
        return (try? JSONDecoder().decode(PersistentIdentifier.self, from: data))
            ?? (try! JSONDecoder().decode(PersistentIdentifier.self, from: data))
    }

    /// Build a single-block `WorkoutPlan` from an array of (exerciseID,
    /// routineSlotID) pairs. Each pair becomes one `PlanExercise`.
    private func makePlan(
        block isSuperset: Bool,
        slots: [(exerciseID: UUID, routineSlotID: UUID, name: String)]
    ) -> WorkoutPlan {
        let exs = slots.map {
            makePlanExercise(
                exerciseID: $0.exerciseID,
                routineSlotID: $0.routineSlotID,
                name: $0.name
            )
        }
        let block = PlanBlock(
            isSuperset: isSuperset,
            restAfterSeconds: nil,
            supersetRoundRestSeconds: nil,
            exercises: exs
        )
        return WorkoutPlan(
            routineID: UUID(),
            routineName: "Test",
            routineVariantID: nil,
            blocks: [block]
        )
    }

    // MARK: - Duplicate-Exercise superset (the original bug)

    /// Pin the fix: a superset with two slots of the same Exercise
    /// resolves the SECOND slot's lookup to (0, 1), not (0, 0). Pre-fix
    /// the lookup-by-id always returned (0, 0) for both.
    func testFindSlotIndex_DistinguishesDuplicateExerciseSupersetSlots() {
        let sharedExerciseID = UUID()  // the "Test 1" Exercise
        let slotA = UUID()              // first superset member
        let slotB = UUID()              // second superset member

        let plan = makePlan(
            block: true,
            slots: [
                (sharedExerciseID, slotA, "Test 1 (A)"),
                (sharedExerciseID, slotB, "Test 1 (B)"),
            ]
        )

        // Both PlanExercises have the same `id` (Exercise.id) — pre-fix
        // a lookup-by-id would always return (0, 0). The slot-keyed
        // lookup must distinguish them.
        let foundA = findSlotIndex(in: plan, routineSlotID: slotA)
        let foundB = findSlotIndex(in: plan, routineSlotID: slotB)

        XCTAssertEqual(foundA?.blockIndex, 0)
        XCTAssertEqual(foundA?.exerciseIndex, 0)
        XCTAssertEqual(foundB?.blockIndex, 0)
        XCTAssertEqual(foundB?.exerciseIndex, 1)
    }

    // MARK: - Single-slot lookups (regression net for distinct exercises)

    func testFindSlotIndex_SingleSlotIsFound() {
        let exA = UUID()
        let slotA = UUID()
        let plan = makePlan(
            block: false,
            slots: [(exA, slotA, "A")]
        )

        let found = findSlotIndex(in: plan, routineSlotID: slotA)

        XCTAssertEqual(found?.blockIndex, 0)
        XCTAssertEqual(found?.exerciseIndex, 0)
    }

    func testFindSlotIndex_MultipleDistinctSlotsAreEachFoundIndependently() {
        let slot0 = UUID()
        let slot1 = UUID()
        let slot2 = UUID()
        let plan = makePlan(
            block: false,
            slots: [
                (UUID(), slot0, "A"),
                (UUID(), slot1, "B"),
                (UUID(), slot2, "C"),
            ]
        )

        XCTAssertEqual(
            findSlotIndex(in: plan, routineSlotID: slot0)?.exerciseIndex, 0
        )
        XCTAssertEqual(
            findSlotIndex(in: plan, routineSlotID: slot1)?.exerciseIndex, 1
        )
        XCTAssertEqual(
            findSlotIndex(in: plan, routineSlotID: slot2)?.exerciseIndex, 2
        )
    }

    // MARK: - Cross-block lookup

    func testFindSlotIndex_FindsSlotInLaterBlock() {
        let slot0_0 = UUID()
        let slot1_0 = UUID()
        let slot1_1 = UUID()

        let block0 = PlanBlock(
            isSuperset: false,
            restAfterSeconds: nil,
            supersetRoundRestSeconds: nil,
            exercises: [
                makePlanExercise(
                    exerciseID: UUID(), routineSlotID: slot0_0, name: "A"
                )
            ]
        )
        let block1 = PlanBlock(
            isSuperset: true,
            restAfterSeconds: nil,
            supersetRoundRestSeconds: nil,
            exercises: [
                makePlanExercise(
                    exerciseID: UUID(), routineSlotID: slot1_0, name: "B"
                ),
                makePlanExercise(
                    exerciseID: UUID(), routineSlotID: slot1_1, name: "C"
                ),
            ]
        )
        let plan = WorkoutPlan(
            routineID: UUID(),
            routineName: "Test",
            routineVariantID: nil,
            blocks: [block0, block1]
        )

        XCTAssertEqual(
            findSlotIndex(in: plan, routineSlotID: slot1_1)?.blockIndex, 1
        )
        XCTAssertEqual(
            findSlotIndex(in: plan, routineSlotID: slot1_1)?.exerciseIndex, 1
        )
    }

    // MARK: - Missing slot

    func testFindSlotIndex_UnknownSlotReturnsNil() {
        let plan = makePlan(
            block: false,
            slots: [(UUID(), UUID(), "A")]
        )

        XCTAssertNil(findSlotIndex(in: plan, routineSlotID: UUID()))
    }

    func testFindSlotIndex_EmptyPlanReturnsNil() {
        let plan = WorkoutPlan(
            routineID: UUID(),
            routineName: "Empty",
            routineVariantID: nil,
            blocks: []
        )
        XCTAssertNil(findSlotIndex(in: plan, routineSlotID: UUID()))
    }
}
