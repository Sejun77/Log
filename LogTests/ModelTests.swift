import SwiftData
// LogTests/ModelTests.swift
import XCTest

@testable import Log

@MainActor
final class ModelTests: SwiftDataTestHarness {
    func testRoutineRoundTrip() throws {
        let squat = Exercise(name: "Back Squat")
        context.insert(squat)
        let block = RoutineBlock(
            isSuperset: false,
            order: 0,
            restAfterSeconds: 60,
            exercises: [
                RoutineExercise(
                    exercise: squat,
                    order: 0,
                    setTemplates: [
                        SetTemplate(
                            kind: .working,
                            targetReps: 5,
                            targetWeight: 100
                        )
                    ]
                )
            ]
        )
        let routine = Routine(name: "Leg Day", blocks: [block])
        context.insert(routine)

        let fetched = try context.fetch(FetchDescriptor<Routine>())
        XCTAssertEqual(fetched.first?.name, "Leg Day")
        XCTAssertEqual(fetched.first?.blocks.first?.restAfterSeconds, 60)
        XCTAssertEqual(
            fetched.first?.blocks.first?.exercises.first?.exercise?.name,
            "Back Squat"
        )
    }
}
