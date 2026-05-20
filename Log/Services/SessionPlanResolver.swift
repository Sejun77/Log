import Foundation

// MARK: - SessionPlanResolver (Phase 11.6-B)
//
// Pure namespace that resolves planned-target values (set count, rep target,
// duration target, rest-between-sets, rest-after-exercise) by walking a
// three-tier fallback chain:
//
//   Tier 1: the live `SessionPlan` for the current slot (user edits during
//           the active workout, via Edit Plan)
//   Tier 2: the immutable `PrescriptionSnapshotPayload` captured at plan-
//           build time
//   Tier 3: the `PlanSetTemplate` value (for `plannedRepTarget` and
//           `plannedDurationTarget`), the `resolvedTemplates` count clamped
//           to at least 1 (for `effectiveSetCount`), or `nil` (for the two
//           rest helpers)
//
// Every function is a `static` on the namespace `enum`, takes only value-
// type parameters, and returns a value. The caller (`ActiveWorkoutView`)
// is still responsible for reading `sessionPlans[slotID]` and
// `exercise.prescriptionSnapshot` from its `@State` surface and passing
// them in — the resolver itself never touches any UI state.
//
// This was extracted out of `ActiveWorkoutView` in Phase 11.6-B as a thin
// service mirroring the Phase 7.4-C `RestPlanner` pattern. Behavior is
// preserved byte-for-byte against the previous private methods on
// `ActiveWorkoutView`:
//
//   - `effectiveSetCount`         preserves the `> 0` filter on both
//                                 sessionPlan.sets and snapshot.sets, and
//                                 the `max(1, …)` clamp on the template
//                                 fallback so the UI always renders ≥1 row.
//   - `plannedRepTarget`          prefers `repMax ?? repMin` at both
//                                 sessionPlan and snapshot tiers, falling
//                                 back to `template.targetReps`. Note: the
//                                 `??` chain treats `nil` (unset) as "fall
//                                 through" but accepts a `0` value as a
//                                 valid stored rep — matching the prior
//                                 method's nil-only filter.
//   - `plannedDurationTarget`     same pair pattern on
//                                 `durationMaxSeconds ?? durationMinSeconds`,
//                                 falling back to `template.durationSeconds`.
//                                 Returns `Int?`; nil means "no duration
//                                 configured anywhere."
//   - `plannedRestBetweenSets`    applies a `> 0` filter at both
//                                 sessionPlan and snapshot tiers, returning
//                                 nil if neither has a positive value.
//   - `plannedRestAfterExercise`  same `> 0` filter pattern. Used only on
//                                 the final working set of a non-superset
//                                 exercise. Nil means callers fall through
//                                 to `plannedRestBetweenSets`.

enum SessionPlanResolver {

    /// Effective set count for an exercise. Walks `sessionPlan.sets > 0`
    /// → `snapshot.sets > 0` → `max(1, resolvedTemplates.count)`. The
    /// final `max(1, …)` clamp ensures the active-workout UI always
    /// renders at least one row, even when a routine has zero templates
    /// AND no session-plan or snapshot override.
    static func effectiveSetCount(
        sessionPlan: SessionPlan?,
        snapshot: PrescriptionSnapshotPayload?,
        resolvedTemplates: [PlanSetTemplate]
    ) -> Int {
        if let sp = sessionPlan, let s = sp.sets, s > 0 { return s }
        if let snap = snapshot, let s = snap.sets, s > 0 { return s }
        return max(1, resolvedTemplates.count)
    }

    /// Resolve the planned rep target for a working set. Walks
    /// `sessionPlan.(repMax ?? repMin)` → `snapshot.(repMax ?? repMin)`
    /// → `template.targetReps`. Each `??` pair treats nil (unset) as
    /// "fall through to the next tier" but accepts any stored Int — so
    /// a deliberately-stored `0` does NOT cascade.
    static func plannedRepTarget(
        sessionPlan: SessionPlan?,
        snapshot: PrescriptionSnapshotPayload?,
        template: PlanSetTemplate
    ) -> Int {
        if let sp = sessionPlan, let v = sp.repMax ?? sp.repMin { return v }
        if let snap = snapshot, let v = snap.repMax ?? snap.repMin { return v }
        return template.targetReps
    }

    /// Resolve the planned duration target for a time-based set. Walks
    /// `sessionPlan.(durationMaxSeconds ?? durationMinSeconds)` →
    /// `snapshot.(durationMaxSeconds ?? durationMinSeconds)` →
    /// `template.durationSeconds`. Returns `Int?` — `nil` means no
    /// duration configured at any tier.
    static func plannedDurationTarget(
        sessionPlan: SessionPlan?,
        snapshot: PrescriptionSnapshotPayload?,
        template: PlanSetTemplate
    ) -> Int? {
        if let sp = sessionPlan,
            let v = sp.durationMaxSeconds ?? sp.durationMinSeconds
        { return v }
        if let snap = snapshot,
            let v = snap.durationMaxSeconds ?? snap.durationMinSeconds
        { return v }
        return template.durationSeconds
    }

    /// Resolve the planned between-set rest. Walks
    /// `sessionPlan.restSecondsBetweenSets > 0` →
    /// `snapshot.restSecondsBetweenSets > 0` → `nil`. Callers compose
    /// the nil result with template-level rest or `RestPlanner` defaults.
    static func plannedRestBetweenSets(
        sessionPlan: SessionPlan?,
        snapshot: PrescriptionSnapshotPayload?
    ) -> Int? {
        if let sp = sessionPlan,
            let v = sp.restSecondsBetweenSets, v > 0
        { return v }
        if let snap = snapshot,
            let v = snap.restSecondsBetweenSets, v > 0
        { return v }
        return nil
    }

    /// Resolve the planned rest-after-exercise. Walks
    /// `sessionPlan.restSecondsAfterExercise > 0` →
    /// `snapshot.restSecondsAfterExercise > 0` → `nil`. Used only on
    /// the final working set of a non-superset exercise; a nil result
    /// is the caller's signal to fall through to
    /// `plannedRestBetweenSets`.
    static func plannedRestAfterExercise(
        sessionPlan: SessionPlan?,
        snapshot: PrescriptionSnapshotPayload?
    ) -> Int? {
        if let sp = sessionPlan,
            let v = sp.restSecondsAfterExercise, v > 0
        { return v }
        if let snap = snapshot,
            let v = snap.restSecondsAfterExercise, v > 0
        { return v }
        return nil
    }
}
