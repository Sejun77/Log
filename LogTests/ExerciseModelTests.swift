import SwiftData
import XCTest

@testable import Log

/// Phase 10-B (2026-05-23) — schema canary for the additive Exercise fields
/// `equipmentType` and `setupDefaults`. Mirrors the `WorkoutModelTests` shape:
/// pins the default, the constructor wiring, the round-trip through an
/// in-memory store, and the nil-persistence case that simulates a legacy
/// pre-10-B row. Doubles as a regression net for any future schema /
/// migration drift on these two fields.
@MainActor
final class ExerciseModelTests: SwiftDataTestHarness {

    func testExerciseDefaultsEquipmentAndSetupToNil() {
        let ex = Exercise(name: "Bench Press")
        context.insert(ex)

        XCTAssertNil(ex.equipmentType)
        XCTAssertNil(ex.setupDefaults)
    }

    func testExerciseAcceptsEquipmentAndSetupViaInit() {
        let ex = Exercise(
            name: "Bench Press",
            equipmentType: "Barbell",
            setupDefaults: "Flat bench, shoulder-width grip"
        )
        context.insert(ex)

        XCTAssertEqual(ex.equipmentType, "Barbell")
        XCTAssertEqual(ex.setupDefaults, "Flat bench, shoulder-width grip")
    }

    func testExerciseEquipmentAndSetupRoundTripThroughStore() throws {
        let ex = Exercise(
            name: "Cable Row",
            equipmentType: "Cable",
            setupDefaults: "Low pulley, V-handle"
        )
        context.insert(ex)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.equipmentType, "Cable")
        XCTAssertEqual(fetched.first?.setupDefaults, "Low pulley, V-handle")
    }

    func testExerciseCanBePersistedWithNilEquipmentAndSetup() throws {
        // Mirrors a legacy pre-10-B row that hasn't been backfilled. Pins
        // that lightweight migration on these two optional fields leaves
        // them nil rather than substituting an empty string or default.
        let ex = Exercise(name: "Legacy Squat", isCustom: true)
        context.insert(ex)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(fetched.first?.name, "Legacy Squat")
        XCTAssertNil(fetched.first?.equipmentType)
        XCTAssertNil(fetched.first?.setupDefaults)
    }
}
