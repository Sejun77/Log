import Foundation

/// Phase 7.4-C.1 — pure rest-decision logic extracted from
/// `ActiveWorkoutView.restSecondsAfterCurrentLog` for the simplest
/// non-superset, non-dropset scenarios. Side effects (timer
/// start/stop, persistence, haptics, focus advance, overlay
/// visibility) remain in `ActiveWorkoutView`; this file only
/// answers "how many seconds, or skip?".
///
/// Scope of this slice:
///   • Normal non-superset between-set rest.
///   • Normal non-superset final-set rest after exercise.
///   • Template-based dropset skip: nil when the next template
///     is `.dropset`.
///   • Last-set-of-workout suppression.
///
/// NOT in scope (still handled inline in `ActiveWorkoutView`):
///   • Supersets / round logic.
///   • Current set is `.dropset` (final-drop logic).
///   • Technique-based intra-drop rest.
///   • Warmup rest.
///   • `block.restAfterSeconds` additive post-processing.

struct RestContext {
    /// 0-based index of the set that was just logged.
    let setIndex: Int

    /// Kind of the *next* set's template, or `nil` if no next set exists.
    /// Used only to detect "skip rest before a template-based dropset".
    /// When the resolved template at `setIndex + 1` is missing (because
    /// `effectiveSetCount` exceeds `templates.count`), callers should
    /// pass `.working` to match the inline fallback.
    let nextTemplateKind: SetKind?

    /// Effective set count for the current exercise, already resolved via
    /// session plan → snapshot → templates.
    let effectiveSetCount: Int

    /// Planned rest between sets resolved upstream (session plan →
    /// snapshot → nil). Callers pass `nil` for non-positive values; the
    /// planner mirrors the inline `?? ?? > 0` chain rather than
    /// re-filtering this field.
    let plannedRestBetweenSets: Int?

    /// Planned rest after exercise resolved upstream (session plan →
    /// snapshot → nil). Used only on the final set. Callers pass `nil`
    /// for non-positive values.
    let plannedRestAfterExercise: Int?

    /// `restSecondsAfter` on the current set's template. May be `0`,
    /// negative, or `nil`; non-positive values fall out of the chain.
    let templateRestSecondsAfter: Int?

    /// `true` iff this is the last set of the last exercise of the last
    /// block in the workout — rest is always suppressed in that case.
    let isLastSetOfWorkout: Bool
}

enum RestPlanner {
    /// Compute rest seconds to start after a logged set for the simple
    /// non-superset, non-dropset path. Returns `nil` to skip rest.
    ///
    /// Behavior is byte-identical to the inline branch previously living
    /// in `ActiveWorkoutView.restSecondsAfterCurrentLog`; the inline
    /// branch is replaced by a call to this function, and all other
    /// branches (supersets, current-set-is-dropset, technique-based
    /// dropsets, warmup) remain inline.
    static func restSecondsAfterLog(_ ctx: RestContext) -> Int? {
        // Workout is over — never start a rest timer after the final log.
        if ctx.isLastSetOfWorkout { return nil }

        let isFinalSet = ctx.setIndex == ctx.effectiveSetCount - 1

        // Before a template-based dropset, skip the parent set's rest so
        // the user proceeds straight to the drop.
        if !isFinalSet, ctx.nextTemplateKind == .dropset { return nil }

        // Fallback chain:
        //   final set:     plannedRestAfterExercise → plannedRestBetweenSets → template.restSecondsAfter
        //   non-final set: plannedRestBetweenSets   → template.restSecondsAfter
        let afterEx = isFinalSet ? ctx.plannedRestAfterExercise : nil
        guard
            let r = afterEx
                ?? ctx.plannedRestBetweenSets
                ?? ctx.templateRestSecondsAfter,
            r > 0
        else { return nil }
        return r
    }
}
