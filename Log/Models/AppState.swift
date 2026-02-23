import Foundation
import SwiftData

// MARK: - Workout Lifecycle State

enum WorkoutLifecycleState: String, Codable {
    case idle
    case active
    case finished
}

// MARK: - Persisted App State (singleton)

@Model
final class AppState {
    /// Singleton key — always "appState". Enforced by @Attribute(.unique).
    @Attribute(.unique) var key: String

    /// Persisted backing for `workoutState`.
    var workoutStateRaw: String

    /// The active workout's UUID, if any.
    var activeWorkoutID: UUID?

    /// When the active workout started (for timer reconstruction).
    var activeWorkoutStartedAt: Date?

    /// When the current rest timer ends (wall-clock). Nil if no rest running.
    var activeRestEndsAt: Date?

    /// The slot (exercise) that triggered the current rest. Used for stable notification IDs.
    var activeRestSlotID: UUID?

    // MARK: - Computed

    var workoutState: WorkoutLifecycleState {
        get { WorkoutLifecycleState(rawValue: workoutStateRaw) ?? .idle }
        set { workoutStateRaw = newValue.rawValue }
    }

    // MARK: - Init

    init() {
        self.key = "appState"
        self.workoutStateRaw = WorkoutLifecycleState.idle.rawValue
    }
}
