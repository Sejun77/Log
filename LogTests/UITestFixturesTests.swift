#if DEBUG && targetEnvironment(simulator)
import SwiftData
import XCTest

@testable import Log

@MainActor
final class UITestFixturesTests: SwiftDataTestHarness {

    func test_requiresTheStoreResetFlagToo() {
        let fixture = UITestFixtures.workoutHistoryArgument
        XCTAssertFalse(UITestFixtures.isWorkoutHistoryRequested(arguments: ["Log"]))
        XCTAssertFalse(UITestFixtures.isWorkoutHistoryRequested(arguments: ["Log", fixture]))
        XCTAssertFalse(UITestFixtures.isWorkoutHistoryRequested(arguments: ["Log", "--ui-testing"]))
        XCTAssertTrue(
            UITestFixtures.isWorkoutHistoryRequested(arguments: ["Log", "--ui-testing", fixture]))
    }

    /// `AllWorkoutsFreshnessTests` asserts on this exact subtitle.
    func test_everyWorkoutHasTheExpectedSummary() throws {
        UITestFixtures.seedWorkoutHistory(in: context)

        let workouts = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(workouts.count, UITestFixtures.workoutCount)
        for workout in workouts {
            XCTAssertEqual(WorkoutSummary(workout: workout).subtitle, "2 exercises · 4 sets")
        }
    }
}
#endif
