import Foundation

/// Phase 7.4-C — pure rest-decision logic extracted from
/// `ActiveWorkoutView.restSecondsAfterCurrentLog`. Side effects
/// (timer start/stop, persistence, haptics, focus advance, overlay
/// visibility) remain in `ActiveWorkoutView`; this file only
/// answers "how many seconds, or skip?".
///
/// Slice 7.4-C.1 (simple non-superset):
///   • Normal non-superset between-set rest.
///   • Normal non-superset final-set rest after exercise.
///   • Template-based dropset skip: nil when the next template is `.dropset`.
///   • Last-set-of-workout suppression.
///
/// Slice 7.4-C.2 (superset round rest):
///   • Mid-round suppression until every participating exercise's
///     parent set (and any required drops) is complete.
///   • Base round rest from `supersetRoundRestSeconds`.
///   • Fallback chain combining `plannedRestBetweenSets` with template
///     rest (normal round) or `priorWorkingRest` (after-dropset round)
///     via max across participating exercises.
///   • Next-round-has-dropset skip on normal rounds (only fires when
///     there IS a next round AND no round-level rest is configured).
///   • Final-round transition rest from `block.restAfterSeconds` —
///     **replaces** the round rest (only fires when the round-completing
///     log happens on the last exercise of the block).
///   • Last-set-of-workout suppression.
///
/// NOT in scope (still handled inline in `ActiveWorkoutView`):
///   • Current set is `.dropset` (final-drop logic).
///   • Technique-based intra-drop rest.
///   • Warmup rest.
///   • `block.restAfterSeconds` additive post-processing for
///     non-superset blocks (planner returns the base for the simple
///     path; the view layers the additive on top).

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

/// One exercise's contribution to a single round of a superset block,
/// evaluated at a specific `setIndex`. Mirrors the fields the inline
/// branch reads off `PlanExercise` / `PlanSetTemplate` so the planner
/// does not depend on those view-side types.
struct SupersetRoundParticipant {
    /// `true` when this exercise is active for this round
    /// (`setIndex < effectiveSetCount`). Out-of-range exercises are
    /// skipped — they do not gate the round and do not contribute to
    /// the max-rest combine.
    let participates: Bool

    /// `true` iff the parent set at this round's `setIndex` is fully
    /// complete — parent logged AND, when a dropset technique applies,
    /// all configured drops logged. Matches `isWorkingSetComplete`.
    let isComplete: Bool

    /// Pre-resolved `plannedRestBetweenSets` for this exercise (session
    /// plan → snapshot → nil). Callers pass `nil` for non-positive
    /// values.
    let plannedRestBetweenSets: Int?

    /// Kind of the template at this round's `setIndex`, defaulting to
    /// `.working` when the templates array does not cover the index
    /// (matches the inline `?? .working`).
    let currentTemplateKind: SetKind

    /// Raw `restSecondsAfter` on the template at `setIndex` — may be
    /// `0`, negative, or `nil`. Filtered by the `> 0` chain.
    let currentTemplateRestSecondsAfter: Int?

    /// Kind of the template at `setIndex + 1`, defaulting to `.working`
    /// when missing. `nil` iff there is no next round for this
    /// exercise (`setIndex + 1 >= effectiveSetCount`).
    let nextTemplateKind: SetKind?

    /// Nearest prior WORKING set's positive `restSecondsAfter` from
    /// this exercise's templates, computed upstream via the same
    /// back-scan the view uses for `priorWorkingRest`. `nil` when none
    /// exists.
    let priorWorkingRest: Int?
}

/// Context for one rest-decision after a log inside a superset block.
struct SupersetRoundContext {
    /// 0-based round index (= `setIndex` of the just-logged set).
    let setIndex: Int

    /// One entry per `block.exercises`, in order. Non-participating
    /// entries are still present (so callers can derive context without
    /// repacking) — the planner filters them.
    let participants: [SupersetRoundParticipant]

    /// 0-based index of the last round in the block. The inline view
    /// derives this from `effectiveSetCount(firstExercise) - 1` under
    /// the documented assumption that all exercises in a superset share
    /// a set count; the planner just consumes the value.
    let lastRoundIndex: Int

    /// Block-level round rest, when configured (`> 0`). When set, takes
    /// precedence over the per-exercise fallback chain.
    let supersetRoundRestSeconds: Int?

    /// Block-level transition rest applied to the final round. `nil`
    /// or `0` means "no replacement"; negative values clamp to `0`
    /// (matches the inline `max(0, extra)`).
    let blockRestAfterSeconds: Int?

    /// `true` iff this is the last block of the workout. Combined with
    /// `isLastExerciseOfBlock` and the final-round check to suppress
    /// rest after the very last log of the workout.
    let isLastBlockOfWorkout: Bool

    /// `true` iff the just-logged exercise is the last in the block
    /// (positional check off `currentExerciseIndex`). Required so that
    /// the final-round transition replacement fires exactly once — on
    /// the round-completing log that happens on the last exercise.
    let isLastExerciseOfBlock: Bool
}

enum RestPlanner {
    /// Compute rest seconds to start after a logged set for the simple
    /// non-superset, non-dropset path. Returns `nil` to skip rest.
    ///
    /// Behavior is byte-identical to the inline branch previously living
    /// in `ActiveWorkoutView.restSecondsAfterCurrentLog`.
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

    /// Compute rest seconds to start after a logged set inside a
    /// superset block. Returns `nil` to skip rest. Byte-identical
    /// behavior to the inline `block.isSuperset` branch (plus the
    /// superset-specific transition-replacement and last-set-of-workout
    /// suppression) previously living in
    /// `ActiveWorkoutView.restSecondsAfterCurrentLog`.
    static func restSecondsAfterSupersetRound(
        _ ctx: SupersetRoundContext
    ) -> Int? {
        // Mid-round suppression: rest waits until every participating
        // exercise has completed its parent set (+ any required drops).
        let participating = ctx.participants.filter { $0.participates }
        if participating.contains(where: { !$0.isComplete }) {
            return nil
        }

        let isLastRound = ctx.setIndex == ctx.lastRoundIndex

        // Base round rest.
        var restSec: Int? = nil
        if let rr = ctx.supersetRoundRestSeconds, rr > 0 {
            restSec = rr
        } else {
            let roundHasDrop = participating.contains {
                $0.currentTemplateKind == .dropset
            }

            if roundHasDrop {
                // After a dropset in this round: planned rest →
                // nearest prior working-set rest. Take max across
                // participating exercises.
                var maxSeconds = 0
                var found = false
                for p in participating {
                    if let r = p.plannedRestBetweenSets ?? p.priorWorkingRest,
                       r > 0
                    {
                        maxSeconds = max(maxSeconds, r)
                        found = true
                    }
                }
                restSec = (found && maxSeconds > 0) ? maxSeconds : nil
            } else {
                // Normal round: planned rest → current template rest.
                // Take max across participating exercises.
                var maxSeconds = 0
                var found = false
                for p in participating {
                    if let r = p.plannedRestBetweenSets
                        ?? p.currentTemplateRestSecondsAfter,
                       r > 0
                    {
                        maxSeconds = max(maxSeconds, r)
                        found = true
                    }
                }
                // Next-round-has-dropset skip: only fires on normal
                // rounds (no round-level rest configured) AND only
                // when there is a next round to skip into.
                let hasNextRound = ctx.setIndex < ctx.lastRoundIndex
                let nextHasDrop = participating.contains {
                    $0.nextTemplateKind == .dropset
                }
                restSec =
                    (hasNextRound && nextHasDrop)
                    ? nil
                    : ((found && maxSeconds > 0) ? maxSeconds : nil)
            }
        }

        // Final-round transition replacement. `extra != 0` mirrors the
        // inline gate (so a literal `0` falls through, leaving the
        // computed round rest in place); `max(0, extra)` mirrors the
        // inline clamp (negative `extra` becomes `0` rest, not nil).
        if isLastRound,
           ctx.isLastExerciseOfBlock,
           let extra = ctx.blockRestAfterSeconds,
           extra != 0
        {
            restSec = max(0, extra)
        }

        // Last-set-of-workout suppression — positional, mirrors the
        // inline trailing guard: only fires on the last block, last
        // exercise (by current focus), final round.
        if isLastRound,
           ctx.isLastBlockOfWorkout,
           ctx.isLastExerciseOfBlock
        {
            return nil
        }

        return restSec
    }
}
