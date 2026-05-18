import SwiftData
import XCTest

@testable import Log

/// Phase 7 Slice 7.3 — `BackfillService.backfillRoutineVariantIDs(in:)` was
/// extracted from `BootstrapRoot` so it can be unit-tested. Behavior must
/// stay identical to the launch-time pass that ships in Phase 6.B Slice B:
/// idempotent; matches by `routineID` first; lowercased `routineName`
/// fallback; never overwrites a non-nil `routineVariantID`; preferred-variant
/// selection delegates to `Routine.preferredVariantID`.
@MainActor
final class BackfillServiceTests: SwiftDataTestHarness {

    // MARK: - Fixture helpers

    @discardableResult
    private func makeRoutine(
        name: String, variants: [RoutineVariant]
    ) -> Routine {
        let r = Routine(name: name, blocks: [])
        context.insert(r)
        r.variants = variants
        return r
    }

    @discardableResult
    private func makeWorkout(
        routineName: String? = nil,
        routineID: UUID? = nil,
        routineVariantID: UUID? = nil
    ) -> Workout {
        let w = Workout(
            routineName: routineName,
            routineID: routineID,
            routineVariantID: routineVariantID,
            items: []
        )
        context.insert(w)
        return w
    }

    // MARK: - a) No-op when no candidates

    func testNoOpWhenAllWorkoutsAlreadyLinked() throws {
        let def = RoutineVariant(name: "Default", order: 0)
        let routine = makeRoutine(name: "Push", variants: [def])
        let w = makeWorkout(
            routineID: routine.id,
            routineVariantID: def.id
        )
        try context.save()

        BackfillService.backfillRoutineVariantIDs(in: context)

        XCTAssertEqual(w.routineVariantID, def.id)
    }

    func testNoOpWhenStoreHasNoWorkouts() {
        let def = RoutineVariant(name: "Default", order: 0)
        makeRoutine(name: "Push", variants: [def])

        // Should not crash, should not save anything.
        BackfillService.backfillRoutineVariantIDs(in: context)

        let fetched = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        XCTAssertTrue(fetched.isEmpty)
    }

    // MARK: - b) routineID match fills routineVariantID

    func testRoutineIDMatchFillsRoutineVariantID() {
        let def = RoutineVariant(name: "Default", order: 0)
        let routine = makeRoutine(name: "Push", variants: [def])
        let w = makeWorkout(
            routineName: "Push",
            routineID: routine.id,
            routineVariantID: nil
        )

        BackfillService.backfillRoutineVariantIDs(in: context)

        XCTAssertEqual(w.routineVariantID, def.id)
    }

    // MARK: - c) Name fallback

    func testRoutineNameFallbackFillsWhenRoutineIDMissing() {
        let def = RoutineVariant(name: "Default", order: 0)
        let routine = makeRoutine(name: "Pull", variants: [def])
        // Workout has no routineID; only the snapshot name remains.
        let w = makeWorkout(
            routineName: "Pull",
            routineID: nil,
            routineVariantID: nil
        )

        BackfillService.backfillRoutineVariantIDs(in: context)

        XCTAssertEqual(w.routineVariantID, def.id)
        // routineID was nil before and the backfill must not invent one.
        XCTAssertNil(w.routineID)
        _ = routine
    }

    func testRoutineNameFallbackIsCaseInsensitive() {
        let def = RoutineVariant(name: "Default", order: 0)
        makeRoutine(name: "Legs", variants: [def])
        let w = makeWorkout(
            routineName: "LEGS",
            routineID: nil,
            routineVariantID: nil
        )

        BackfillService.backfillRoutineVariantIDs(in: context)

        XCTAssertEqual(w.routineVariantID, def.id)
    }

    func testRoutineIDStaleFallsThroughToNameFallback() {
        // routineID points at a routine that no longer exists, but the
        // snapshot name still matches a live routine — should resolve via
        // the name fallback, not be left nil.
        let def = RoutineVariant(name: "Default", order: 0)
        makeRoutine(name: "Push", variants: [def])
        let w = makeWorkout(
            routineName: "Push",
            routineID: UUID(),  // unknown id
            routineVariantID: nil
        )

        BackfillService.backfillRoutineVariantIDs(in: context)

        XCTAssertEqual(w.routineVariantID, def.id)
    }

    // MARK: - d) Never overwrites a non-nil routineVariantID

    func testNonNilRoutineVariantIDIsNeverOverwritten() {
        let def = RoutineVariant(name: "Default", order: 0)
        let routine = makeRoutine(name: "Push", variants: [def])
        let unrelated = UUID()  // some other UUID, not Default's id
        let w = makeWorkout(
            routineName: "Push",
            routineID: routine.id,
            routineVariantID: unrelated
        )

        BackfillService.backfillRoutineVariantIDs(in: context)

        XCTAssertEqual(w.routineVariantID, unrelated)
    }

    // MARK: - e) Unresolved workout stays nil

    func testUnresolvedWorkoutRemainsNil() {
        // No routine matches either by id or by name → must stay nil so the
        // row remains eligible for a future pass if the routine reappears.
        let def = RoutineVariant(name: "Default", order: 0)
        makeRoutine(name: "Push", variants: [def])
        let w = makeWorkout(
            routineName: "Cardio",
            routineID: UUID(),
            routineVariantID: nil
        )

        BackfillService.backfillRoutineVariantIDs(in: context)

        XCTAssertNil(w.routineVariantID)
    }

    func testNoRoutinesAtAllLeavesCandidateNil() {
        let w = makeWorkout(
            routineName: "Push",
            routineID: UUID(),
            routineVariantID: nil
        )

        BackfillService.backfillRoutineVariantIDs(in: context)

        XCTAssertNil(w.routineVariantID)
    }

    // MARK: - f) Idempotency

    func testIdempotency_SecondRunDoesNotChangeState() {
        let def = RoutineVariant(name: "Default", order: 0)
        let routine = makeRoutine(name: "Push", variants: [def])
        let resolvableID = makeWorkout(
            routineName: "Push",
            routineID: routine.id,
            routineVariantID: nil
        )
        let unresolvable = makeWorkout(
            routineName: "Cardio",
            routineID: UUID(),
            routineVariantID: nil
        )
        let preExisting = UUID()
        let alreadyLinked = makeWorkout(
            routineName: "Push",
            routineID: routine.id,
            routineVariantID: preExisting
        )

        BackfillService.backfillRoutineVariantIDs(in: context)
        let afterFirst = (
            resolvableID.routineVariantID,
            unresolvable.routineVariantID,
            alreadyLinked.routineVariantID
        )

        BackfillService.backfillRoutineVariantIDs(in: context)
        let afterSecond = (
            resolvableID.routineVariantID,
            unresolvable.routineVariantID,
            alreadyLinked.routineVariantID
        )

        XCTAssertEqual(afterFirst.0, def.id)
        XCTAssertNil(afterFirst.1)
        XCTAssertEqual(afterFirst.2, preExisting)
        // State after second pass matches state after first pass.
        XCTAssertEqual(afterSecond.0, afterFirst.0)
        XCTAssertEqual(afterSecond.1, afterFirst.1)
        XCTAssertEqual(afterSecond.2, afterFirst.2)
    }

    // MARK: - g) Preferred-variant selection delegates to Routine.preferredVariantID

    func testPreferredVariantRuleHonoredDefaultBeatsLowerOrder() {
        let bulk = RoutineVariant(name: "Bulk", order: 0)
        let def = RoutineVariant(name: "Default", order: 5)
        let routine = makeRoutine(name: "Push", variants: [bulk, def])
        let w = makeWorkout(
            routineID: routine.id,
            routineVariantID: nil
        )

        BackfillService.backfillRoutineVariantIDs(in: context)

        // Default wins over lower-order Bulk, matching Routine.preferredVariantID.
        XCTAssertEqual(w.routineVariantID, def.id)
    }

    func testPreferredVariantRuleHonoredLowestOrderWhenNoDefault() {
        let bulk = RoutineVariant(name: "Bulk", order: 0)
        let cut = RoutineVariant(name: "Cut", order: 5)
        let routine = makeRoutine(name: "Push", variants: [cut, bulk])
        let w = makeWorkout(
            routineID: routine.id,
            routineVariantID: nil
        )

        BackfillService.backfillRoutineVariantIDs(in: context)

        XCTAssertEqual(w.routineVariantID, bulk.id)
    }
}
