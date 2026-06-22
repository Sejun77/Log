import Foundation

/// Pure superset round / ordering math, extracted from `ActiveWorkoutView` so
/// the uneven-set-count behavior is unit-testable without a SwiftUI host.
///
/// Rounds are driven by the **maximum** effective set count across the block's
/// exercises: an exercise with fewer sets simply drops out of the later rounds
/// (uneven supersets) — no equalization, no phantom sets, no placeholder rows.
/// Equal-set blocks are the special case where every count equals the max, so
/// their behavior is unchanged.
enum SupersetRoundMath {

    /// 0-based index of the final round, given each exercise's effective set
    /// count in block order. `max - 1`, clamped to `0`.
    static func lastRoundIndex(setCounts: [Int]) -> Int {
        max(0, (setCounts.max() ?? 0) - 1)
    }

    /// Whether the set at `(exerciseIndex, setIndex)` is the next loggable set
    /// in the block. Mirrors `ActiveWorkoutView.canLogSet` exactly:
    ///   • not already logged,
    ///   • every earlier set of THIS exercise is complete,
    ///   • for supersets only:
    ///     (a) the previous round is complete across every *participating*
    ///         exercise — those whose set count reaches `setIndex - 1`, so a
    ///         shorter exercise that has dropped out does not gate the round;
    ///     (b) prior exercises in block order are complete at THIS `setIndex`
    ///         (in-round ordering A → B → C), again skipping any exercise whose
    ///         set count does not reach `setIndex`.
    ///
    /// `isComplete(exerciseIndex, setIndex)` reports parent-set completion for
    /// that slot — including all required dropset drops — exactly as
    /// `ActiveWorkoutView.isWorkingSetComplete` does.
    static func isSetLoggable(
        isSuperset: Bool,
        exerciseIndex: Int,
        setIndex: Int,
        setCounts: [Int],
        alreadyLogged: Bool,
        isComplete: (_ exerciseIndex: Int, _ setIndex: Int) -> Bool
    ) -> Bool {
        if alreadyLogged { return false }

        // Within this exercise: earlier sets must be fully complete.
        for j in 0..<setIndex where !isComplete(exerciseIndex, j) {
            return false
        }

        guard isSuperset else { return true }

        // (a) Previous round complete for every participating exercise.
        if setIndex > 0 {
            let prevRound = setIndex - 1
            for (i, count) in setCounts.enumerated() where prevRound < count {
                if !isComplete(i, prevRound) { return false }
            }
        }

        // (b) In-round ordering: prior exercises at this set index first.
        for i in 0..<exerciseIndex where setIndex < setCounts[i] {
            if !isComplete(i, setIndex) { return false }
        }

        return true
    }

    /// Block-order index of the last exercise that still participates in round
    /// `roundIndex` (its set count reaches it) — i.e. the exercise whose log
    /// COMPLETES that round. Returns `nil` when no exercise participates
    /// (`roundIndex` is beyond every count).
    ///
    /// This is what the rest logic must use to fire the final-round transition
    /// rest and the last-set-of-workout suppression exactly once: for uneven
    /// supersets the round-completing exercise is **not** necessarily the last
    /// in block order (e.g. A=3, B=2 — round 2 is completed by A, index 0). For
    /// equal-set blocks every exercise participates in every round, so this is
    /// always the last index — behavior unchanged.
    static func lastParticipantIndex(
        setCounts: [Int], roundIndex: Int
    ) -> Int? {
        setCounts.lastIndex { roundIndex < $0 }
    }

    /// The next set that should receive focus in a superset block, in the
    /// canonical round-interleaved schedule: for each round (0 ..< max set
    /// count), one set of every exercise that still *has* a set at that round
    /// index, in block order. Returns the first such set that is not yet
    /// complete — which, because the schedule is also the dependency order, is
    /// exactly the next loggable set.
    ///
    /// This is what auto-advance must consult: it skips exercises that have
    /// dropped out (a shorter exercise with no set in the current/later round)
    /// instead of blindly moving to the next exercise in block order. Returns
    /// `nil` only when every set in the block is complete (block finished).
    ///
    /// `isComplete(exerciseIndex, setIndex)` reports parent-set completion for
    /// that slot — including all required dropset drops.
    static func nextLoggableSlot(
        setCounts: [Int],
        isComplete: (_ exerciseIndex: Int, _ setIndex: Int) -> Bool
    ) -> (exercise: Int, setIndex: Int)? {
        guard let maxCount = setCounts.max(), maxCount > 0 else { return nil }
        for r in 0..<maxCount {
            for (i, count) in setCounts.enumerated() where r < count {
                if !isComplete(i, r) { return (i, r) }
            }
        }
        return nil
    }
}
