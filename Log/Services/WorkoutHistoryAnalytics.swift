import Foundation

// MARK: - WorkoutHistoryAnalytics

/// Read-only extractor that turns persisted `Workout` history into the pure
/// `StrengthAnalytics` series the analytics view consumes.
///
/// It only *reads* model objects (`Workout` / `WorkoutItem` / `SetLog` /
/// `Exercise`): no `ModelContext`, no `@Query`, no mutation, no inserts. It
/// never creates `Workout` rows. Because it operates on a plain `[Workout]`
/// passed in by the caller, it is unit-testable on `SwiftDataTestHarness`
/// (same approach as `groupItemsBySourceBlock`).
///
/// Strength/volume rules mirror `HistoryView.ProgressChart` and reuse the
/// Slice-1 primitives (`StrengthAnalytics.e1RM` / `.bestE1RM` /
/// `.sessionVolume`) so the numbers stay consistent app-wide:
///   * working sets only (`kind == .working`), weight > 0, reps > 0,
///   * e1RM additionally caps reps ≤ 12 (Epley validity); volume does not,
///   * one strength point per session = max e1RM across the exercise's items,
///   * one volume point per session = Σ(weight × reps) across the items.
enum WorkoutHistoryAnalytics {

    // MARK: - Exercise identity

    /// Identity used to group a workout item into one logical exercise across
    /// sessions. Prefer the live `Exercise.id`; fall back to the normalized
    /// (trimmed, lowercased) name snapshot for items whose exercise was
    /// deleted (`exercise == nil`, `.nullify` rule), so history stays readable.
    enum ExerciseKey: Hashable {
        case id(UUID)
        case deletedName(String)
    }

    /// A selectable exercise in the real-history picker.
    struct ExerciseRef: Identifiable, Hashable {
        let key: ExerciseKey
        let displayName: String
        var id: ExerciseKey { key }
        var isDeleted: Bool {
            if case .deletedName = key { return true }
            return false
        }
    }

    /// Stable grouping key for one item.
    static func key(for item: WorkoutItem) -> ExerciseKey {
        if let id = item.exercise?.id { return .id(id) }
        return .deletedName(normalize(item.exerciseNameSnapshot))
    }

    /// Human label for one item: live name, else surviving snapshot, else a
    /// neutral placeholder for fully-deleted history.
    static func displayName(for item: WorkoutItem) -> String {
        item.exercise?.name
            ?? trimmedOrNil(item.exerciseNameSnapshot)
            ?? "Deleted exercise"
    }

    // MARK: - Completion filter

    /// A workout counts as real history once it has a `completedAt` timestamp.
    /// In-progress (active) and legacy pre-completion rows are skipped.
    static func completedWorkouts(_ workouts: [Workout]) -> [Workout] {
        workouts.filter { $0.completedAt != nil }
    }

    // MARK: - Available exercises

    /// Distinct exercises appearing in completed history with at least one
    /// valid working set (so selecting one always yields data). Sorted by
    /// display name; the first display name seen for a key wins.
    static func availableExercises(in workouts: [Workout]) -> [ExerciseRef] {
        var displayNameByKey: [ExerciseKey: String] = [:]
        for workout in completedWorkouts(workouts) {
            for item in workout.items where hasValidWorkingSet(item) {
                let k = key(for: item)
                if displayNameByKey[k] == nil {
                    displayNameByKey[k] = displayName(for: item)
                }
            }
        }
        return displayNameByKey
            .map { ExerciseRef(key: $0.key, displayName: $0.value) }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    // MARK: - Series extraction

    /// One strength point per completed session in which the exercise appears
    /// with a valid working e1RM: `value` = max e1RM across that session's
    /// matching items. Sessions with no qualifying set are skipped.
    static func strengthSeries(
        for ref: ExerciseRef,
        in workouts: [Workout]
    ) -> [StrengthAnalytics.SeriesPoint] {
        completedWorkouts(workouts).compactMap { workout in
            let items = workout.items.filter { key(for: $0) == ref.key }
            guard !items.isEmpty,
                  let best = items.compactMap(bestWorkingE1RM).max()
            else { return nil }
            return StrengthAnalytics.SeriesPoint(date: workout.date, value: best)
        }
    }

    /// One volume point per completed session in which the exercise appears
    /// with positive working volume: `volume` = Σ(weight × reps) across that
    /// session's matching items. Zero-volume sessions are skipped.
    static func volumeSeries(
        for ref: ExerciseRef,
        in workouts: [Workout]
    ) -> [StrengthAnalytics.VolumePoint] {
        completedWorkouts(workouts).compactMap { workout in
            let items = workout.items.filter { key(for: $0) == ref.key }
            guard !items.isEmpty else { return nil }
            let volume = items.reduce(0.0) { $0 + workingVolume($1) }
            guard volume > 0 else { return nil }
            return StrengthAnalytics.VolumePoint(date: workout.date, volume: volume)
        }
    }

    // MARK: - Per-item helpers

    private static func workingSets(_ item: WorkoutItem) -> [SetLog] {
        item.setLogs.filter { $0.kind == .working }
    }

    private static func hasValidWorkingSet(_ item: WorkoutItem) -> Bool {
        workingSets(item).contains { ($0.weight ?? 0) > 0 && $0.reps > 0 }
    }

    /// Max valid Epley e1RM among the item's working sets (reps ≤ 12 cap is
    /// enforced inside `StrengthAnalytics.e1RM`). nil if none qualify.
    private static func bestWorkingE1RM(_ item: WorkoutItem) -> Double? {
        StrengthAnalytics.bestE1RM(sets: setTuples(item))
    }

    /// Σ(weight × reps) over the item's working sets (weight > 0, reps > 0, no
    /// rep cap) via `StrengthAnalytics.sessionVolume`.
    private static func workingVolume(_ item: WorkoutItem) -> Double {
        StrengthAnalytics.sessionVolume(setTuples(item))
    }

    private static func setTuples(_ item: WorkoutItem) -> [(weight: Double, reps: Int)] {
        workingSets(item).map { (weight: $0.weight ?? 0, reps: $0.reps) }
    }

    // MARK: - Name normalization

    private static func normalize(_ raw: String?) -> String {
        (trimmedOrNil(raw) ?? "deleted exercise").lowercased()
    }

    private static func trimmedOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
