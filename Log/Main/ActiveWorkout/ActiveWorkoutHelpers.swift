import Foundation

// MARK: - Active-Workout Pure Helpers (Phase 11.6-A)
//
// These four helpers were lifted out of `ActiveWorkoutView` as part of
// Phase 11.6-A. Each is pure — it reads only its parameters plus a small
// number of module-level statics (`Units.weightIsKg`,
// `RestTimer.stableNotificationID(workoutID:slotID:)`) — so promoting them
// to module-internal free functions widens no `ActiveWorkoutView` state.

// MARK: - Weight rounding / formatting

/// Rounds a raw weight to the nearest 0.5 (kg) or 1.0 (lb) depending on
/// the user's current `Units.weightIsKg` setting. Pure.
func roundWeight(_ raw: Double) -> Double {
    Units.weightIsKg
        ? (raw * 2).rounded() / 2  // nearest 0.5
        : raw.rounded()             // nearest 1.0
}

/// Formats a rounded weight value for display in set/drop rows. Integer
/// values render without a decimal point. Pure.
func formatWeight(_ w: Double) -> String {
    w.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(w)) : String(w)
}

// MARK: - Stable rest notification ID

/// Builds a stable rest-timer notification ID of the form
/// `"rest.<workoutID>.<slotID>"`, falling back to
/// `"rest.unknown.<slotID>"` when the workout has not yet been fetched.
///
/// Behavior is byte-identical to the original `ActiveWorkoutView.restNotificationID(slotID:)`:
/// callers pass the current `workout?.id` straight through. The optional is
/// preserved so the "unknown" fallback string still appears whenever the
/// active `Workout` has not yet been hydrated — `RestTimer` keys
/// pending UNUserNotificationCenter requests off this string, so the
/// fallback shape **must not** change.
///
/// `@MainActor`-isolated because the underlying
/// `RestTimer.stableNotificationID(workoutID:slotID:)` is a static on a
/// `@MainActor` final class. Every existing call site is already
/// `@MainActor` (inside `ActiveWorkoutView`, a SwiftUI `View`), so the
/// isolation requirement is invisible at the call sites.
@MainActor
func activeRestNotificationID(workoutID: UUID?, slotID: UUID) -> String {
    guard let wID = workoutID else {
        return "rest.unknown.\(slotID.uuidString)"
    }
    return RestTimer.stableNotificationID(workoutID: wID, slotID: slotID)
}

// MARK: - Lightweight default plan template

/// Builds a lightweight `PlanSetTemplate` for set indices that go beyond
/// the resolved templates array (e.g., a session-plan-driven set count
/// that exceeds the prescription snapshot's template count). Pure — the
/// resulting template carries the synthetic id `"<exercise>-extra<index>"`
/// matching the original inline construction.
func defaultTemplate(for exercise: PlanExercise, at index: Int) -> PlanSetTemplate {
    PlanSetTemplate(
        id: "\(exercise.currentExerciseID.uuidString)-extra\(index)",
        kind: .working,
        targetReps: 0,
        targetWeight: nil,
        restSecondsAfter: nil,
        durationSeconds: nil
    )
}
