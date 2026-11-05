#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftData

/// Data for UI tests that need more history than can be created through the UI.
///
/// Exists only in Debug Simulator builds, so no device or Release build contains
/// it, whatever arguments it is launched with. It also requires `--ui-testing`,
/// so it only ever adds to the store that flag has just emptied.
@MainActor
enum UITestFixtures {
    static let workoutHistoryArgument = "--ui-test-workout-history"
    static let workoutCount = 40
    static let exercisesPerWorkout = 2
    static let setsPerExercise = 2

    static func isWorkoutHistoryRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("--ui-testing") && arguments.contains(workoutHistoryArgument)
    }

    /// One routine, and completed workouts on the days before today, newest first.
    static func seedWorkoutHistory(in ctx: ModelContext) {
        let exercises = (1...exercisesPerWorkout).map { number in
            let exercise = Exercise(name: "Fixture Exercise \(number)", bodyPart: "Chest")
            ctx.insert(exercise)
            return exercise
        }

        let slot = RoutineExercise(exercise: exercises[0], order: 0, setTemplates: [])
        slot.prescription = SlotPrescription(
            sets: 3, repMin: 8, repMax: 10,
            restSecondsBetweenSets: 90, restSecondsAfterExercise: 120, rir: 2)
        let routine = Routine(
            name: "Fixture Routine", blocks: [RoutineBlock(order: 0, exercises: [slot])])
        ctx.insert(routine)

        for day in 1...workoutCount {
            let date = Calendar.current.date(byAdding: .day, value: -day, to: .now) ?? .now
            let items = exercises.map { exercise in
                WorkoutItem(
                    exercise: exercise,
                    setLogs: (0..<setsPerExercise).map { set in
                        SetLog(indexInExercise: set, kind: .working, reps: 8, weight: 60)
                    })
            }
            let workout = Workout(
                date: date, routineName: routine.name, routineID: routine.id, items: items)
            workout.completedAt = date
            ctx.insert(workout)
        }
        try? ctx.save()
    }
}
#endif
