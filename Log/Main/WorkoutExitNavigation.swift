import SwiftUI

// MARK: - Workout exit navigation

/// How the active workout was left.
enum WorkoutExit: Equatable {
    /// Completed through the finish confirmation or the Save Routine Changes
    /// sheet — any `FinishRequest`.
    case finished(FinishRequest)
    /// Resumable exit: the workout stays active.
    case savedAndExited
    /// The workout was deleted (Discard, or the unreachable-plan fallback).
    case discarded
}

/// Where navigation goes once the active workout has been left.
enum WorkoutExitNavigation: Equatable {
    /// Clear the whole Routines stack — the Start Workout screen and the
    /// routine editor included — landing on the Routines root.
    case returnToRoutinesRoot
}

/// The navigation for a given exit. Pure.
///
/// Every intentional exit lands on the Routines root, however the workout was
/// entered: the Start Workout screen or routine editor behind it is stale
/// once the user has left, and the root is where Resume lives after Save &
/// Exit. Exhaustive on purpose — a new exit kind must choose a destination.
func workoutExitNavigation(for exit: WorkoutExit) -> WorkoutExitNavigation {
    switch exit {
    case .finished, .savedAndExited, .discarded: return .returnToRoutinesRoot
    }
}

// MARK: - Routines navigation state

/// The Routines tab's `NavigationStack` destinations. Every screen above the
/// root is pushed — directly or transitively — by one of these, so clearing
/// them all pops the whole stack in one state change.
struct RoutinesNavigationState: Equatable {
    /// Routine editor (row tap). The editor's own Start pushes Start Workout,
    /// which pushes the active workout, on top of it.
    var selectedRoutineID: UUID? = nil
    /// Start Workout (row Start button), which pushes the active workout.
    var startRoutineID: UUID? = nil
    /// Active workout pushed directly (Resume banner, cold-restart resume).
    var showActiveWorkout = false
    var showUserGuide = false

    var isAtRoot: Bool { self == RoutinesNavigationState() }

    mutating func returnToRoot() {
        self = RoutinesNavigationState()
    }
}

extension EnvironmentValues {
    /// Provided by `RoutinesView` to everything on its stack; resets it to the
    /// Routines root. Nil outside that stack (e.g. previews), where the active
    /// workout falls back to a plain `dismiss()`.
    @Entry var returnToRoutinesRoot: (() -> Void)? = nil
}
