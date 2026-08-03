import Foundation

// ======================================================
// MARK: - Tracking mode
// ======================================================

/// How an exercise is tracked, derived from `Exercise.isTimeBased` +
/// `Exercise.isCardio`.
///
/// This is a read-only *view* over the two stored flags, not a replacement for
/// them. Storing a mode enum instead would force a SwiftData migration and
/// rewrite ~95 `isTimeBased` call sites for no user-visible gain; deriving it
/// recovers the enum's real benefit — an exhaustive `switch` at new call
/// sites — at zero migration cost. Old code keeps reading `isTimeBased`.
enum TrackingMode: Equatable {
    /// Reps + weight. `isTimeBased == false`.
    case strength
    /// Duration only, no distance/pace — Plank, Wall Sit, dead hangs.
    case timedHold
    /// Duration + cardio metrics — treadmill, bike, rower, walking.
    case cardio
}

extension Exercise {

    /// Derived tracking mode. Reads `isTimeBased` **first**, so the impossible
    /// `isCardio == true && isTimeBased == false` state (only reachable via a
    /// hand-edited store or a future importer bug) degrades safely to
    /// `.strength` rather than trapping or reporting a cardio exercise with no
    /// duration field.
    var trackingMode: TrackingMode {
        guard isTimeBased else { return .strength }
        return isCardio ? .cardio : .timedHold
    }

    /// Write site for the time-based flag. Clearing time-based also clears
    /// cardio, because cardio without a duration is the impossible state.
    ///
    /// Callers must prefer this over assigning `isTimeBased` directly whenever
    /// the exercise already exists; assignment is still fine at construction
    /// time (seeding, CSV import, routine transfer), where `isCardio` is
    /// already false.
    func setTimeBased(_ newValue: Bool) {
        isTimeBased = newValue
        if !newValue { isCardio = false }
    }

    /// Write site for the cardio flag. Marking an exercise cardio is only
    /// meaningful when it is time-based; a request to do so on a non-time-based
    /// exercise is ignored (and any stale `true` is cleared) so the invariant
    /// holds no matter what the caller does.
    func setCardio(_ newValue: Bool) {
        guard isTimeBased else {
            isCardio = false
            return
        }
        isCardio = newValue
    }
}
