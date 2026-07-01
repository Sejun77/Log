import Foundation

/// Read-only one-line summary of a `Workout`'s contents, shown as a subtitle
/// under each row in History → Recent Workouts (Slice B). Mirrors
/// `RoutineSummary` in shape and discipline.
///
/// Pure value type — no SwiftData fetches, no `ModelContext`, no mutation — so
/// it is safe to compute outside the SwiftUI `body` (build a `map(for:)` once
/// per render and look up by `workout.id`) and unit-testable in isolation.
///
/// Counting rules:
///  - **Exercises = `workout.items.count`.** Counts `WorkoutItem` rows
///    *structurally*, not unique exercises: a workout that logged the same
///    exercise in two items reports two. A `WorkoutItem` whose `exercise`
///    reference is **nil** (deleted / unlinked) still counts — the item is a
///    real, display-capable history row (it renders via `exerciseNameSnapshot`).
///    Counting structurally — never dereferencing `item.exercise` — keeps this
///    helper pure and free of model-faulting, so a nil reference can never
///    crash it.
///  - **Sets = non-warmup `SetLog` rows** across all items
///    (`setLogs.filter { $0.kind != .warmup }`). `.working` and `.dropset`
///    rows count; `.warmup` rows are excluded so the headline number reflects
///    work performed, not prep. There is no "total sets" figure anywhere in
///    `WorkoutDetailView` (warmups render as separately-labelled "Warmup N"
///    rows), so excluding them creates no visible inconsistency.
///  - Volume / PRs are intentionally **out of scope for v1** (they need unit
///    handling and cross-workout comparison, respectively).
struct WorkoutSummary: Equatable {
    /// Total `WorkoutItem` rows in `Workout.items`.
    let exerciseCount: Int
    /// Total non-warmup `SetLog` rows (`.working` + `.dropset`) across items.
    let setCount: Int

    /// Value-in initializer — exercised by unit tests for the wording rules
    /// without needing a SwiftData model.
    init(exerciseCount: Int, setCount: Int) {
        self.exerciseCount = exerciseCount
        self.setCount = setCount
    }

    /// Build from a live `Workout`. Reads `workout.items` and `item.setLogs`
    /// only; never touches `item.exercise`.
    init(workout: Workout) {
        var sets = 0
        for item in workout.items {
            sets += item.setLogs.reduce(0) { count, log in
                count + (log.kind == .warmup ? 0 : 1)
            }
        }
        self.init(exerciseCount: workout.items.count, setCount: sets)
    }

    /// Subtitle shown under the workout date / routine label.
    ///  - no items → `"Empty workout"`
    ///  - items, no counted sets → `"5 exercises"` / `"1 exercise"`
    ///  - items + sets → `"6 exercises · 24 sets"` / `"1 exercise · 1 set"`
    var subtitle: String {
        guard exerciseCount > 0 else { return String(localized: "Empty workout") }
        let exercises = exerciseCount == 1
            ? String(localized: "\(exerciseCount) exercise")
            : String(localized: "\(exerciseCount) exercises")
        guard setCount > 0 else { return exercises }
        let sets = setCount == 1
            ? String(localized: "\(setCount) set")
            : String(localized: "\(setCount) sets")
        return "\(exercises) · \(sets)"
    }

    /// Precompute one summary per workout, keyed by `workout.id`, so the
    /// History list can build the map once per render and avoid re-scanning
    /// `workout.items` / `item.setLogs` inside each row's `body`.
    static func map(for workouts: [Workout]) -> [UUID: WorkoutSummary] {
        var result: [UUID: WorkoutSummary] = [:]
        result.reserveCapacity(workouts.count)
        for workout in workouts {
            result[workout.id] = WorkoutSummary(workout: workout)
        }
        return result
    }
}
