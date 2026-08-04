import Foundation

// ======================================================
// MARK: - Cardio previous-performance prefill
// ======================================================

/// One set's previously performed cardio metrics, narrowed to the fields that
/// may be prefilled into a new session.
///
/// **Outcome metrics are absent by construction**, not by a caller remembering
/// to skip them. Average heart rate, heart-rate zone and calories describe what
/// the body did during *that specific bout*; putting them into an empty field
/// would present a number nobody measured as if it had been. They are dropped
/// here, at the type, so no future call site can reintroduce them by accident.
///
/// What remains is what the user *sets up*: how far they intend to go, and how
/// the machine is configured. Those are decisions, and repeating last session's
/// decision is a good guess.
struct CardioPrefillSuggestion: Equatable {
    let setIndex: Int
    /// Canonical meters, already normalized — an out-of-range or corrupt stored
    /// value never reaches here.
    let distanceMeters: Double?
    /// The unit the bout was logged in, so the prefilled number reads back the
    /// way the user typed it.
    let distanceUnit: DistanceUnit?
    let inclinePercent: Double?
    let resistanceLevel: Double?

    /// True when nothing survived the filter — the set had only outcome
    /// metrics, or none at all. Such a set does not qualify as a prefill
    /// source.
    var isEmpty: Bool {
        distanceMeters == nil && inclinePercent == nil
            && resistanceLevel == nil
    }
}

/// Finds the most recent eligible performed cardio bout for an exercise.
///
/// The cardio counterpart of `LastPerformancePrefillService`, and deliberately
/// its sibling rather than an extension of it: the two answer different
/// questions (reps/weight/duration vs. distance/incline/resistance) and filter
/// their source sets differently, but they **share one definition of
/// eligibility** via `LastPerformancePrefillService.prefillCandidates`, so a
/// workout the user excluded from prefill is excluded from both.
///
/// Read-only and `ModelContext`-free: it takes a plain `[Workout]` and returns
/// values, so it is unit-testable and cannot mutate the routine, the snapshot,
/// the session plan, or History.
enum CardioPrefillService {

    /// Most-recent eligible performed cardio metrics for `exerciseID`, keyed by
    /// `SetLog.indexInExercise`.
    ///
    /// Selection mirrors `LastPerformancePrefillService.suggestions`: walk
    /// eligible workouts newest → oldest and return the **first** one that has
    /// at least one qualifying set. Qualifying means a working set
    /// (`kind == .working && subIndex == nil`) carrying at least one
    /// prefillable metric — a duration-only cardio bout is a complete, valid
    /// log but has nothing to offer here, so it does not stop the search.
    ///
    /// Empty when nothing qualifies, which leaves the caller on its existing
    /// fallbacks (the routine target, then nothing).
    static func suggestions(
        forExerciseID exerciseID: UUID,
        in workouts: [Workout],
        excluding currentWorkoutID: UUID? = nil
    ) -> [Int: CardioPrefillSuggestion] {
        let candidates = LastPerformancePrefillService.prefillCandidates(
            in: workouts, excluding: currentWorkoutID)

        for workout in candidates {
            let map = cardioSuggestions(forExerciseID: exerciseID, in: workout)
            if !map.isEmpty { return map }
        }
        return [:]
    }

    /// Carry-down resolver for a current set index, mirroring
    /// `LastPerformancePrefillService.suggestion(forCurrentSetIndex:from:)`
    /// exactly so the two prefills never disagree about which previous set a
    /// row corresponds to: exact match, else the highest previous index when
    /// this session has more sets, else the nearest lower index across a gap.
    static func suggestion(
        forCurrentSetIndex index: Int,
        from suggestions: [Int: CardioPrefillSuggestion]
    ) -> CardioPrefillSuggestion? {
        if let exact = suggestions[index] { return exact }
        guard let maxIndex = suggestions.keys.max() else { return nil }
        if index > maxIndex { return suggestions[maxIndex] }
        let lower = suggestions.keys.filter { $0 < index }.max()
        return lower.flatMap { suggestions[$0] }
    }

    /// The prefillable subset of one performed set's metrics.
    ///
    /// Every value is read through `SetLog.cardioMetrics`, so a row holding a
    /// negative distance, an absurd resistance, or an unparseable unit yields
    /// nil for that field rather than reaching an entry box. Returns nil when
    /// nothing survives.
    static func prefillable(from log: SetLog) -> CardioPrefillSuggestion? {
        let metrics = log.cardioMetrics
        let suggestion = CardioPrefillSuggestion(
            setIndex: log.indexInExercise,
            distanceMeters: metrics.distanceMeters,
            distanceUnit: metrics.distanceUnit,
            inclinePercent: metrics.inclinePercent,
            resistanceLevel: metrics.resistanceLevel
        )
        return suggestion.isEmpty ? nil : suggestion
    }

    // MARK: - Per-workout extraction

    private static func cardioSuggestions(
        forExerciseID exerciseID: UUID,
        in workout: Workout
    ) -> [Int: CardioPrefillSuggestion] {
        var map: [Int: CardioPrefillSuggestion] = [:]
        for item in workout.items where item.exercise?.id == exerciseID {
            for log in item.setLogs
            where log.kind == .working && log.subIndex == nil {
                guard let suggestion = prefillable(from: log) else { continue }
                map[log.indexInExercise] = suggestion
            }
        }
        return map
    }
}

// ======================================================
// MARK: - Where a cardio draft came from
// ======================================================

/// The provenance of the values sitting in one cardio set's entry fields.
///
/// Slices 5 and 6 needed only a two-state answer — "did the user touch this?" —
/// and got it for free from persistence: a seeded draft is never written to
/// `ParentDraftStore`, a typed one always is. Slice 7 adds a second *unseeded*
/// source, so that discriminator is no longer enough on its own: a target edit
/// may refresh a draft the target itself put there, but must not overwrite one
/// that came from what the user actually did last time.
///
/// Deliberately **derived, not stored.** Every input is available at read time
/// (is the set logged, is there a persisted draft, is there a prefill, is there
/// a target), so the source is a pure function of state that already survives a
/// resume. Persisting it would add a second source of truth that could drift
/// out of step with the drafts it describes.
enum CardioDraftSource: Equatable {
    /// The set is logged; the fields mirror what was recorded and are
    /// read-only until Undo.
    case logged
    /// The user typed into this set — including typing it empty. Never
    /// overwritten by anything.
    case userTyped
    /// Filled from the previous performed bout.
    case previousPerformance
    /// Filled from the routine's target distance.
    case targetSeeded
    /// Nothing to show and nothing to fill it from.
    case empty
}

/// Resolves what a cardio set's entry fields should contain, and where that
/// content came from.
///
/// One precedence chain, stated once:
///
///     logged set → user-typed draft → previous performance → routine target
///
/// Pure, so the live view and the resume path can both run it and land in the
/// same place — which is the property that makes Save & Exit safe.
enum CardioDraftResolver {

    /// Where this set's fields come from, given what exists for it.
    ///
    /// - Parameter hasPrefillDistance: whether the previous bout supplies the
    ///   **distance** specifically. Incline and resistance can prefill without
    ///   it, and when they do the distance is still the target's to fill — so
    ///   the source describes the distance field, which is the only one the
    ///   target ever writes.
    static func source(
        isLogged: Bool,
        hasUserDraft: Bool,
        hasPrefillDistance: Bool,
        hasTarget: Bool
    ) -> CardioDraftSource {
        if isLogged { return .logged }
        if hasUserDraft { return .userTyped }
        if hasPrefillDistance { return .previousPerformance }
        if hasTarget { return .targetSeeded }
        return .empty
    }

    /// The draft to seed an untouched set with.
    ///
    /// Distance comes from the previous bout when it has one and from the
    /// routine target otherwise — the product rule that a *target* is a plan
    /// and a *previous distance* is evidence, and evidence wins for the field
    /// recording what you are about to actually do. The target does not
    /// disappear: it stays on the plan card and in Edit Plan, which is where a
    /// plan belongs.
    ///
    /// Incline and resistance come only from the previous bout — the routine
    /// has no target for either (a deliberate §2.3 decision).
    ///
    /// Returns nil when neither source offers anything.
    static func seededDraft(
        prefill: CardioPrefillSuggestion?,
        target: CardioTargetDistance?,
        fallbackUnit: DistanceUnit
    ) -> CardioEntryDraft? {
        let prefillDistance = prefill.flatMap { suggestion -> (String, DistanceUnit)? in
            guard let meters = suggestion.distanceMeters else { return nil }
            let unit = suggestion.distanceUnit ?? fallbackUnit
            guard let value = unit.value(fromMeters: meters),
                let text = CardioDerived.formatDistance(value: value)
            else { return nil }
            return (text, unit)
        }

        let distance: String
        let unit: DistanceUnit
        if let prefillDistance {
            (distance, unit) = prefillDistance
        } else if let target {
            distance = target.valueText ?? ""
            unit = target.unit
        } else {
            distance = ""
            unit = fallbackUnit
        }

        let incline = prefill?.inclinePercent.flatMap(signedText) ?? ""
        let resistance =
            prefill?.resistanceLevel
            .flatMap { CardioDerived.formatDistance(value: $0) } ?? ""

        // Nothing to say — leave the row untouched rather than writing an
        // all-empty draft, which would be indistinguishable from a seeded one
        // to any future reader.
        guard !distance.isEmpty || !incline.isEmpty || !resistance.isEmpty
        else { return nil }

        // Average heart rate, calories and the HR zone are never seeded: they
        // are outcomes of a bout that already happened.
        return CardioEntryDraft(
            unit: unit,
            distance: distance,
            incline: incline,
            resistance: resistance
        )
    }

    /// True when a target-distance edit may rewrite this set's distance.
    ///
    /// Only a draft the target itself seeded. A typed value is the user's, a
    /// prefilled one is evidence of what they actually did, and a logged one is
    /// history — none of the three is the target's to overwrite.
    static func targetEditMayReplace(_ source: CardioDraftSource) -> Bool {
        source == .targetSeeded || source == .empty
    }

    /// `CardioDerived.formatDistance` rejects negatives; incline can be one.
    private static func signedText(_ value: Double) -> String? {
        guard let magnitude = CardioDerived.formatDistance(value: abs(value))
        else { return nil }
        return value < 0 ? "-\(magnitude)" : magnitude
    }
}
