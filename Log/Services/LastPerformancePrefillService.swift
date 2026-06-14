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

    /// One dropset sub-row's last-logged values (Slice 3). `parentSetIndex`
    /// mirrors `SetLog.indexInExercise` (the parent working set the drop hangs
    /// off); `subIndex` mirrors `SetLog.subIndex` (1-based drop number). Both
    /// reps and weight are optional so the caller's merge helper can apply the
    /// drop-specific priority chain.
    struct LastPerformanceDropSuggestion: Equatable {
        let parentSetIndex: Int
        let subIndex: Int
        let reps: Int?
        let weight: Double?
    }

    /// Most-recent completed working-set performance for `exerciseID`.
    ///
    /// Behavior:
    ///   1. Keep only completed workouts (`completedAt != nil`).
    ///   2. Drop `currentWorkoutID` if provided (the in-progress session).
    ///   3. Drop workouts the user marked excluded from prefill
    ///      (`excludedFromPrefill == true`) — they stay in History but never
    ///      seed a future prefill, so selection falls back to the next most
    ///      recent included workout.
    ///   4. Sort by `completedAt` descending (newest first); ties broken by
    ///      `date` descending so order is deterministic.
    ///   5. Walk newest → oldest and return the suggestions from the FIRST
    ///      workout that has at least one qualifying working set for the
    ///      exercise. Older workouts are not consulted once a match is found.
    ///   6. Returns an empty map when nothing qualifies.
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
            .filter { !$0.excludedFromPrefill }
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

    // MARK: - Dropset sub-rows (Slice 3)

    /// Most-recent completed dropset sub-row performance for `exerciseID`,
    /// keyed `[parentSetIndex: [subIndex: suggestion]]`.
    ///
    /// Same selection contract as `suggestions(...)` — completed workouts only,
    /// `currentWorkoutID` excluded, workouts flagged `excludedFromPrefill`
    /// skipped, newest-first by `completedAt` (tie-broken by `date`) — but walks
    /// newest → oldest and returns the FIRST workout that has at least one
    /// dropset sub-row (`subIndex != nil`) for the exercise.
    /// This selection is independent of the working-set lookup: the most recent
    /// workout with drops may differ from the most recent with working sets.
    /// Returns an empty map when nothing qualifies.
    static func dropSuggestions(
        forExerciseID exerciseID: UUID,
        in workouts: [Workout],
        excluding currentWorkoutID: UUID? = nil
    ) -> [Int: [Int: LastPerformanceDropSuggestion]] {
        let candidates = workouts
            .filter { $0.completedAt != nil }
            .filter { $0.id != currentWorkoutID }
            .filter { !$0.excludedFromPrefill }
            .sorted { lhs, rhs in
                let l = lhs.completedAt ?? lhs.date
                let r = rhs.completedAt ?? rhs.date
                if l != r { return l > r }
                return lhs.date > rhs.date
            }

        for workout in candidates {
            let map = dropSubRowSuggestions(forExerciseID: exerciseID, in: workout)
            if !map.isEmpty { return map }
        }
        return [:]
    }

    /// Carry-down resolver for one current drop sub-row against a previous-
    /// session drop map (typically the output of `dropSuggestions(...)`).
    ///
    /// Rule:
    ///   * exact `(parentSetIndex, subIndex)` match wins,
    ///   * else if `subIndex` is beyond the previous drop count for that SAME
    ///     parent, carry the highest previous `subIndex` for that parent down,
    ///   * else (a gap below the max) the nearest lower previous `subIndex`,
    ///   * nil when the parent index has no drops, or the map is empty.
    ///
    /// v1 never carries across different parent set indices. Pure.
    static func dropSuggestion(
        forParentSetIndex parentSetIndex: Int,
        subIndex: Int,
        from suggestions: [Int: [Int: LastPerformanceDropSuggestion]]
    ) -> LastPerformanceDropSuggestion? {
        guard let drops = suggestions[parentSetIndex], !drops.isEmpty else {
            return nil
        }
        if let exact = drops[subIndex] { return exact }
        guard let maxSub = drops.keys.max() else { return nil }
        if subIndex > maxSub { return drops[maxSub] }
        let lower = drops.keys.filter { $0 < subIndex }.max()
        return lower.flatMap { drops[$0] }
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

    /// Build the dropset sub-row map for one workout, keyed
    /// `[parentSetIndex: [subIndex: suggestion]]`. Only `subIndex != nil` logs
    /// qualify — main working sets and legacy template dropset logs without a
    /// `subIndex` are excluded. Empty when the workout has no drops for the
    /// exercise. On duplicate `(parentSetIndex, subIndex)` the last log wins.
    private static func dropSubRowSuggestions(
        forExerciseID exerciseID: UUID,
        in workout: Workout
    ) -> [Int: [Int: LastPerformanceDropSuggestion]] {
        var map: [Int: [Int: LastPerformanceDropSuggestion]] = [:]
        for item in workout.items where item.exercise?.id == exerciseID {
            for log in item.setLogs {
                guard let sub = log.subIndex else { continue }
                map[log.indexInExercise, default: [:]][sub] =
                    LastPerformanceDropSuggestion(
                        parentSetIndex: log.indexInExercise,
                        subIndex: sub,
                        reps: log.reps,
                        weight: log.weight
                    )
            }
        }
        return map
    }
}
