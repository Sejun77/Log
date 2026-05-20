import Foundation
import SwiftData

/// Phase 7.7 / 8-B — pure SwiftData + AppState lifecycle mutations for the
/// active workout's three terminal paths: **Save & Exit** (resumable),
/// **Finish** (terminal — mark complete), and **Discard** (terminal — delete).
///
/// Extracted from `ActiveWorkoutView` so these mutations are unit-testable
/// without instantiating a SwiftUI view, a `RestTimer`, an `ActiveWorkoutGuard`
/// singleton, or any UserDefaults / UNUserNotificationCenter / ActivityKit
/// surface.
///
/// The service deliberately does **NOT**:
///   • call `dismiss()` or touch SwiftUI view state
///   • stop or persist `RestTimer` state
///   • end ActivityKit Live Activities
///   • clear in-memory `ActiveWorkoutGuard` locks / caches
///   • clear `DropWeightDraftStore` / `ParentDraftStore` UserDefaults
///
/// Those side effects stay in `ActiveWorkoutView.unlockAndDismiss()` where
/// they belong — they're view-instance-owned (`@StateObject` / `@Environment`)
/// or in-memory singleton state that is meaningless outside the view session.
@MainActor
enum WorkoutLifecycleService {

    // MARK: - Save & Exit (resumable)

    /// Persists any in-flight writes (e.g. workout-notes edits typed in the
    /// End dialog area). Leaves `AppState.workoutState == .active` and every
    /// `active*` field set so the workout remains resumable via both the
    /// in-memory `ActiveWorkoutGuard` banner and the cold-restart
    /// `RootTabView.checkForActiveSession` → `WorkoutResumeService` flow.
    static func saveAndExit(in ctx: ModelContext) {
        try? ctx.save()
    }

    // MARK: - Finish (terminal — mark complete)

    /// Marks `workout` as completed (`completedAt = Date()`) and clears every
    /// `AppState.active*` field plus `workoutState = .idle`. Saves the context.
    /// Returns the timestamp written, or nil when `workout` is nil.
    ///
    /// When `workout` is nil, the AppState is still cleared so a dangling
    /// resume gate cannot survive a partially-broken finish path.
    @discardableResult
    static func finish(
        workout: Workout?,
        appState: AppState?,
        in ctx: ModelContext
    ) -> Date? {
        guard let workout else {
            clearActiveAppState(appState)
            try? ctx.save()
            return nil
        }
        let now = Date()
        workout.completedAt = now
        clearActiveAppState(appState)
        try? ctx.save()
        return now
    }

    // MARK: - Discard (terminal — delete)

    /// Deletes `workout` (if non-nil) and clears every `AppState.active*`
    /// field plus `workoutState = .idle`. Saves the context.
    ///
    /// Safe with a nil workout — still clears AppState so a stale resume
    /// gate cannot survive.
    static func discard(
        workout: Workout?,
        appState: AppState?,
        in ctx: ModelContext
    ) {
        if let workout {
            ctx.delete(workout)
        }
        clearActiveAppState(appState)
        try? ctx.save()
    }

    // MARK: - Shared AppState clear

    /// Clears every `active*` field on the `AppState` singleton and sets
    /// `workoutState = .idle`. No-op when `appState` is nil. Does **not**
    /// call `ctx.save()` — callers batch with their own mutations.
    /// Idempotent: repeated calls produce the same nil-everywhere state.
    static func clearActiveAppState(_ appState: AppState?) {
        guard let appState else { return }
        appState.workoutState = .idle
        appState.activeWorkoutID = nil
        appState.activeWorkoutStartedAt = nil
        appState.activeRestEndsAt = nil
        appState.activeRestSlotID = nil
        appState.sessionPlansJSON = nil
        appState.activeBlockIndex = nil
        appState.activeExerciseIndex = nil
    }
}
