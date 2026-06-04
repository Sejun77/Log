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

// MARK: - Equipment classification

/// The canonical equipment-type string for bodyweight exercises.
let bodyweightEquipment = "Bodyweight"

/// True when an `Exercise.equipmentType` / snapshot `equipment` string
/// represents a bodyweight exercise. Trimmed + case-insensitive so
/// imported/legacy casings (e.g. " bodyweight ") still match. Pure.
func isBodyweightEquipment(_ equipment: String?) -> Bool {
    guard let equipment else { return false }
    return equipment.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare(bodyweightEquipment) == .orderedSame
}

/// Inferred default for `Exercise.includesBodyweightInLoad` from equipment:
/// bodyweight equipment counts bodyweight toward load; everything else does
/// not. Used to seed sensible defaults (catalog / new exercises) — the stored
/// flag remains user-overridable (e.g. a weighted pull-up on a Dip Belt sets it
/// true manually). Pure.
func defaultIncludesBodyweightInLoad(equipmentType: String?) -> Bool {
    isBodyweightEquipment(equipmentType)
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

// MARK: - Swap defaults (Phase 9-B2)

/// Builds the `[PlanSetTemplate]` for the new exercise after a mid-workout
/// `swapExercise(planExercise:with:)`. Pre-9-B2 the swap path read
/// `newEx.defaultTemplates` directly and mapped each row 1:1 — including
/// `targetWeight`, warmup/dropset kinds, and any per-row rest values.
/// 9-A.5 audit accepted the loss of those fields here (no
/// `SlotPrescription` landing for `targetWeight`; warmup/dropset rows on
/// `Exercise.defaultTemplates` are vestigial relative to the new
/// `WarmupScheme` / `TechniquePlan` authoring path). Per 9-B2 audit
/// guidance, this helper produces N uniform `.working` rows whose count
/// and rest are sourced from the slot's existing session plan or
/// snapshot — preserving the slot's structure across the swap — and
/// falls back to `AppSettings` defaults when neither is set.
///
/// Caller does the priority chain inline (`sessionPlan?.X ?? snapshot?.X`)
/// so this helper stays trivial to unit-test with literals — no
/// `SlotPrescription` / `ModelContext` fixture required.
///
/// Field-by-field contract:
///   - `id`: `"<exerciseID>-set<i>"` (matches the pre-9-B2 stable composite key)
///   - `kind`: `.working` always
///   - `targetReps`: `0` — `SessionPlanResolver.plannedRepTarget` reads
///     from sessionPlan/snapshot at row-render time; the template's
///     `targetReps` is only used when both higher tiers are nil
///   - `targetWeight`: `nil` — the 9-A.5 audit's documented loss; the
///     weight column starts blank after a swap and the logged-history
///     auto-suggest path takes over on subsequent sets
///   - `restSecondsAfter`: from `restBetweenSetsHint` (caller composes
///     this from sessionPlan/snapshot) else `AppSettings.defaultRestBetweenSets`
///   - `durationSeconds`: nil for rep-based exercises; for time-based
///     exercises, sourced from `durationMaxHint ?? durationMinHint`,
///     falling back to a hardcoded 60s that matches the
///     `BackfillService.hydrate(_:from:)` 9-A1 fallback
///
/// `setsHint` is the slot's expected working-set count from
/// sessionPlan/snapshot; falls back to `AppSettings.defaultSets`. The
/// final count is clamped to ≥1 so the active-workout UI always
/// renders at least one row.
func makeSwapDefaultTemplates(
    forExerciseID exerciseID: UUID,
    isTimeBased: Bool,
    setsHint: Int?,
    restBetweenSetsHint: Int?,
    durationMinHint: Int?,
    durationMaxHint: Int?
) -> [PlanSetTemplate] {
    let resolvedSets = setsHint.flatMap { $0 > 0 ? $0 : nil }
        ?? AppSettings.defaultSets
    let count = max(1, resolvedSets)

    let rest = restBetweenSetsHint.flatMap { $0 > 0 ? $0 : nil }
        ?? AppSettings.defaultRestBetweenSets

    let duration: Int? = isTimeBased
        ? (durationMaxHint ?? durationMinHint ?? 60)
        : nil

    return (0..<count).map { i in
        PlanSetTemplate(
            id: "\(exerciseID.uuidString)-set\(i)",
            kind: .working,
            targetReps: 0,
            targetWeight: nil,
            restSecondsAfter: rest,
            durationSeconds: duration
        )
    }
}

// MARK: - Slot lookup (Phase 6.C1 follow-up: duplicate-Exercise superset)

/// Locate the `(blockIndex, exerciseIndex)` of the plan slot whose
/// `routineSlotID` matches the given UUID. Returns nil if not found.
///
/// **Why this exists**: `PlanExercise.id` is set to `Exercise.id` at
/// plan-build time (see `StartWorkoutFromRoutineView.makePlan`), so it
/// is NOT unique across slots when the same `Exercise` appears in
/// multiple superset members. Lookups that key on `planExercise.id`
/// silently target the first matching slot, which corrupts swap and
/// reset-plan flows for duplicate-Exercise supersets (the original
/// 6.C1 manual-test bug: swapping the second of two same-Exercise
/// superset slots was actually mutating the first, wiping its
/// already-logged set).
///
/// The single source of slot identity is
/// `RoutineExercise.slotID` (mirrored as `PlanExercise.routineSlotID`
/// and `WorkoutItem.routineSlotID`). All in-workout state stores
/// (`sessionPlans`, `loggedByExercise`, `itemsByExerciseID`,
/// `dropsLoggedByExercise`, the drop-draft stores) already key on it;
/// plan-graph lookups must too.
///
/// Pure. No SwiftData access. Safe in any context that has a
/// `WorkoutPlan` in hand.
func findSlotIndex(
    in plan: WorkoutPlan,
    routineSlotID: UUID
) -> (blockIndex: Int, exerciseIndex: Int)? {
    for (bi, block) in plan.blocks.enumerated() {
        if let ei = block.exercises.firstIndex(
            where: { $0.routineSlotID == routineSlotID }
        ) {
            return (bi, ei)
        }
    }
    return nil
}
