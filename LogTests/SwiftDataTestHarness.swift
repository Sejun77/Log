import SwiftData
// LogTests/SwiftDataTestHarness.swift
import XCTest

@testable import Log

@MainActor
class SwiftDataTestHarness: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext { container.mainContext }

    override func setUp() {
        super.setUp()
        let schema = Schema([
            Exercise.self, SetTemplate.self, RoutineExercise.self,
            RoutineBlock.self, RoutineVariant.self, Routine.self,
            WarmupStep.self, WarmupScheme.self,
            TechniquePlan.self, SlotPrescription.self,
            PlannedPrescriptionSnapshot.self,
            SetLog.self, WorkoutItem.self, Workout.self,
            AppState.self,
        ])
        container = try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }
}
