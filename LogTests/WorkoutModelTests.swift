import SwiftData
import XCTest

@testable import Log

/// Phase 7 Slice 7.1 — schema-level smoke covering the Phase 6.B Slice A
/// additive field `Workout.routineVariantID`. These tests are intentionally
/// minimal: they verify the default, the constructor wiring, and that the
/// value round-trips through an in-memory store. Acts as a canary for any
/// future migration / schema-registration regression.
@MainActor
final class WorkoutModelTests: SwiftDataTestHarness {

    func testWorkoutDefaultsRoutineVariantIDToNil() {
        let workout = Workout(items: [])
        context.insert(workout)

        XCTAssertNil(workout.routineVariantID)
        XCTAssertNil(workout.routineID)
        XCTAssertNil(workout.routineName)
    }

    func testWorkoutAcceptsRoutineVariantIDViaInit() {
        let variantID = UUID()
        let workout = Workout(
            routineName: "Leg Day",
            routineID: UUID(),
            routineVariantID: variantID,
            items: []
        )
        context.insert(workout)

        XCTAssertEqual(workout.routineVariantID, variantID)
    }

    func testWorkoutRoutineVariantIDRoundTripsThroughStore() throws {
        let variantID = UUID()
        let workout = Workout(
            routineName: "Push",
            routineID: UUID(),
            routineVariantID: variantID,
            items: []
        )
        context.insert(workout)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.routineVariantID, variantID)
    }

    func testWorkoutCanBePersistedWithNilRoutineVariantID() throws {
        // Mirrors a legacy pre-Slice-A row that hasn't been backfilled yet.
        let workout = Workout(routineName: "Legacy", items: [])
        context.insert(workout)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(fetched.first?.routineName, "Legacy")
        XCTAssertNil(fetched.first?.routineVariantID)
    }
}
