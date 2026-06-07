import Foundation

// MARK: - LastPerformancePrefillService (Slice 1)
//
// Read-only extractor that finds the most recent completed working-set
// performance for a single exercise, so the active-workout UI can prefill
// input drafts with the user's last working weights/reps/duration instead
// of falling back to prescription defaults (reps → repMax, weight → blank).
//
// Like `WorkoutHistoryAnalytics`, it only *reads* model objects
// (`Workout` / `WorkoutItem` / `SetLog` / `Exercise`): no `ModelContext`,
// no `@Query`, no mutation, no inserts. It operates on a plain `[Workout]`
// passed in by the caller, so it is unit-testable on `SwiftDataTestHarness`.
//
// Slice 1 is computation only — wiring into `ActiveWorkoutView` is Slice 2.
//
// v1 rules (see audit):
//   * Source: the single most recent COMPLETED workout (`completedAt != nil`)
//     that contains working-set logs for the exercise. Not restricted to the
//     same routine.
//   * Set filtering: `kind == .working && subIndex == nil` only — warm-ups and
//     dropset sub-rows are excluded (dropset prefill is deferred to Slice 3).
//   * Keyed by `SetLog.indexInExercise`, preserving set order.
//   * Returns raw logged values (reps / weight / durationSeconds). The caller
//     decides whether to apply reps, weight, or duration based on
//     bodyweight / time-based UI rules — the service applies none of them.
enum LastPerformancePrefillService {

    /// One set's last-logged values, addressed by its `indexInExercise`.
    /// All metric fields are optional so the caller can apply per-mode rules
    /// (bodyweight → reps only, time-based → duration only) in Slice 2.
    struct LastPerformanceSetSuggestion: Equatable {
        let setIndex: Int
        let reps: Int?
        let weight: Double?
        let durationSeconds: Int?
    }

    /// Most-recent completed working-set performance for `exerciseID`.
    ///
    /// Behavior:
    ///   1. Keep only completed workouts (`completedAt != nil`).
    ///   2. Drop `currentWorkoutID` if provided (the in-progress session).
    ///   3. Sort by `completedAt` descending (newest first); ties broken by
    ///      `date` descending so order is deterministic.
    ///   4. Walk newest → oldest and return the suggestions from the FIRST
    ///      workout that has at least one qualifying working set for the
    ///      exercise. Older workouts are not consulted once a match is found.
    ///   5. Returns an empty map when nothing qualifies.
    ///
    /// Qualifying sets: items whose live `Exercise.id == exerciseID`, logs
    /// with `kind == .working && subIndex == nil`. When a single index appears
    /// more than once (legacy/duplicate data), the last log encountered for
    /// that index wins.
    static func suggestions(
        forExerciseID exerciseID: UUID,
        in workouts: [Workout],
        excluding currentWorkoutID: UUID? = nil
    ) -> [Int: LastPerformanceSetSuggestion] {
        let candidates = workouts
            .filter { $0.completedAt != nil }
            .filter { $0.id != currentWorkoutID }
            .sorted { lhs, rhs in
                let l = lhs.completedAt ?? lhs.date
                let r = rhs.completedAt ?? rhs.date
                if l != r { return l > r }
                return lhs.date > rhs.date
            }

        for workout in candidates {
            let map = workingSetSuggestions(forExerciseID: exerciseID, in: workout)
            if !map.isEmpty { return map }
        }
        return [:]
    }

    /// Carry-down resolver for a current set index against a previous-session
    /// suggestion map (typically the output of `suggestions(...)`).
    ///
    /// Rule:
    ///   * exact `setIndex` match wins,
    ///   * if `index` is beyond the previous count, return the last available
    ///     previous set (highest `setIndex`) — "carry the top set down",
    ///   * empty map → nil.
    ///
    /// Pure; no SwiftData access.
    static func suggestion(
        forCurrentSetIndex index: Int,
        from suggestions: [Int: LastPerformanceSetSuggestion]
    ) -> LastPerformanceSetSuggestion? {
        if let exact = suggestions[index] { return exact }
        guard let maxIndex = suggestions.keys.max() else { return nil }
        if index > maxIndex { return suggestions[maxIndex] }
        // Index is below the max but absent (a gap in indices) — fall back to
        // the nearest lower logged index, else nil.
        let lower = suggestions.keys.filter { $0 < index }.max()
        return lower.flatMap { suggestions[$0] }
    }

    // MARK: - Per-workout extraction

    /// Build the working-set suggestion map for one workout. Empty when the
    /// workout has no qualifying working sets for the exercise.
    private static func workingSetSuggestions(
        forExerciseID exerciseID: UUID,
        in workout: Workout
    ) -> [Int: LastPerformanceSetSuggestion] {
        var map: [Int: LastPerformanceSetSuggestion] = [:]
        for item in workout.items where item.exercise?.id == exerciseID {
            for log in item.setLogs
            where log.kind == .working && log.subIndex == nil {
                map[log.indexInExercise] = LastPerformanceSetSuggestion(
                    setIndex: log.indexInExercise,
                    reps: log.reps,
                    weight: log.weight,
                    durationSeconds: log.durationSeconds
                )
            }
        }
        return map
    }
}
