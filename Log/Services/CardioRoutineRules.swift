import Foundation

// ======================================================
// MARK: - Cardio routine rules
// ======================================================

/// What a routine slot offers, by tracking mode.
///
/// The routine editor's prescription section is a `View` and cannot be
/// instantiated in a unit test, so every product rule it applies lives here as
/// a pure function instead — one place to read the whole policy, and one place
/// the tests can pin it.
///
/// The shape of the policy is: **cardio removes controls that describe reps or
/// external load, and adds a distance target.** Nothing else moves. Strength
/// slots and timed-hold slots (Plank, Wall Sit) get exactly what they got
/// before this existed, which is what the `.strength` / `.timedHold` cases
/// below are for — they are not placeholders, they are the assertion that this
/// type changed nothing for them.
///
/// All of this is **display and new-slot-default policy only**. Nothing here
/// rewrites a stored value: an existing routine that already carries a warm-up
/// scheme, a technique plan or an effort target keeps it, hidden but intact,
/// so a slot later switched back to a strength exercise still has its
/// programming. Suppression that silently deleted data would be a much worse
/// bargain than a hidden field.
enum CardioRoutineRules {

    // MARK: - Editor visibility

    /// Target distance is the one control cardio *adds*.
    ///
    /// Not offered for timed holds: "how far did you plank" has no answer, and
    /// a distance field on a Plank slot would be an invitation to mis-log.
    static func showsTargetDistance(_ mode: TrackingMode) -> Bool {
        mode == .cardio
    }

    /// Warm-up schemes are hidden for cardio.
    ///
    /// The Slice 4 polish already reduced the cardio warm-up editor to "Reps"
    /// and "Note Only" by removing the two weight-based kinds — which left a
    /// screen offering to program *reps* for a treadmill. A cardio warm-up is a
    /// real thing, but it is a slower first few minutes of the same bout, not a
    /// set structure the app currently models. Hiding the whole section is
    /// honest about that; a cardio warm-up/cooldown system is a later slice.
    static func showsWarmupScheme(_ mode: TrackingMode) -> Bool {
        mode != .cardio
    }

    /// Techniques are hidden for cardio: every technique the app models
    /// (dropsets, rest-pause, partials, tempo override, myo-reps) is defined in
    /// terms of reps or load.
    static func showsTechniques(_ mode: TrackingMode) -> Bool {
        mode != .cardio
    }

    /// Tempo describes eccentric/concentric rep phases, so it shows only for
    /// strength. This is a restatement of the rule the editor has always
    /// applied via `isTimeBased` — timed holds did not show tempo before this
    /// type existed and do not show it now.
    static func showsTempo(_ mode: TrackingMode) -> Bool {
        mode == .strength
    }

    /// The combined RIR/RPE control. Delegates to the resolver that already
    /// owns this rule for the active workout, so the routine editor and the
    /// three in-workout display sites cannot drift apart.
    static func showsEffortControl(_ mode: TrackingMode) -> Bool {
        WorkoutEffortTargetResolver.isEffortApplicable(to: mode)
    }

    // MARK: - New-slot defaults

    /// Sets for a newly created slot.
    ///
    /// **One** for cardio: a 30-minute run is one bout, and the app's notion of
    /// a "set" is the wrong unit for intervals — those are Phase 3 and get
    /// structured interval support of their own. Everything else keeps
    /// `AppSettings.defaultSets`, the user's own preference.
    static func defaultSets(_ mode: TrackingMode) -> Int {
        mode == .cardio ? 1 : AppSettings.defaultSets
    }

    /// Between-set rest for a newly created slot. **None** for cardio: with one
    /// set there is nothing to rest between, and a rest timer firing after a
    /// run is noise.
    static func defaultRestBetweenSets(_ mode: TrackingMode) -> Int? {
        mode == .cardio ? nil : AppSettings.defaultRestBetweenSets
    }

    /// Rest-after-exercise for a newly created slot. Cardio gets none, for the
    /// same reason; other modes keep the existing "positive value or nothing"
    /// reading of the preference.
    static func defaultRestAfterExercise(_ mode: TrackingMode) -> Int? {
        guard mode != .cardio else { return nil }
        let configured = AppSettings.defaultRestAfterExercise
        return configured > 0 ? configured : nil
    }

    /// Whether a new slot seeds an effort (RIR/RPE) value from the user's
    /// autoreg preference.
    ///
    /// False for cardio. The control is hidden there, and a seeded value that
    /// cannot be seen or edited would still be read by the block-row summary —
    /// a new cardio slot would sprout an "RIR 2" the user never chose and
    /// cannot remove. Not seeding is the difference between "hidden" and
    /// "hidden but leaking".
    static func seedsEffortTarget(_ mode: TrackingMode) -> Bool {
        showsEffortControl(mode)
    }
}
