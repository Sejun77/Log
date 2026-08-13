import Foundation

// MARK: - Exercise Switch Plan Adapter
//
// Pure decision service for the mid-workout "Switch Exercise" flow.
//
// When the user swaps the exercise in an active slot, the app asks whether to
// **Keep current plan** or **Reset plan for this slot**. Before this service
// existed, both choices were implemented ad-hoc inside `ActiveWorkoutView`:
//
//   * "Keep" preserved `sessionPlans[slotID]` verbatim — which silently
//     retained the OLD exercise's tracking-specific fields (`usesDuration`,
//     reps *or* duration, tempo) — except on a tracking-type change, where a
//     blanket `sessionPlans[slotID] = SessionPlan()` wiped the whole plan
//     (including the set count the user expected to keep) *before* the set-count
//     hint was read, so the slot silently fell back to `AppSettings.defaultSets`.
//   * "Reset" nil'd the snapshot and the session plan, leaving the effective
//     values to be re-derived downstream from `AppSettings` defaults with no
//     tracking-type adaptation of its own.
//
// Both paths now funnel through `outcome(...)`, which returns the slot's
// post-switch `SessionPlan` plus the two "may I keep the snapshot?" flags. The
// returned plan is COMPLETE — every field the slot should have after the switch
// is materialized on it — so it can serve as the slot's single source of truth
// (see `ExerciseSwitchPlanAdapter.adaptedSnapshot` for the matching snapshot
// projection that keeps tier-2 resolution in agreement with tier-1).
//
// Compatibility contract (see ENTRY_12_TESTFLIGHT_FEEDBACK.md P1 entry):
//
//   Always preserved (both tracking types can express them):
//     set count, rest between sets, rest after exercise, RIR/RPE effort target
//
//   Preserved only within the same tracking type:
//     tempo (non-duration → non-duration only), warm-up steps, techniques
//
//   Never blindly carried over:
//     the prescription / routine-specific note (it described the OLD exercise)
//
// Session/workout-level notes (`Workout.notes`) and exercise-level notes
// (`Exercise.notes` / `Exercise.setupDefaults`) are NOT part of a `SessionPlan`
// and are deliberately outside this service — the former is workout-scoped and
// untouched by switching, the latter resolve live from the selected exercise.
//
// Pure: no SwiftData, no SwiftUI, no `AppSettings` reads at call time. The
// reset source is injected by the caller (`ResetSource.appDefaults(...)` reads
// `AppSettings` on the caller's behalf) so tests stay hermetic.

enum ExerciseSwitchPlanAdapter {

    // MARK: - Inputs

    /// Which button the user tapped in the "Session plan for this slot" dialog.
    enum Choice: Equatable {
        case keepCurrentPlan
        case resetPlan
        /// Alternative Exercises Phase F1 — apply a prepared alternative's
        /// prescription (`ALTERNATIVE_EXERCISES_DESIGN.md` §9.1).
        ///
        /// Routes to the **same** `resetPlan` path as `.resetPlan`, because the
        /// semantics are identical — *replace the plan from a supplied source,
        /// adapted to the new mode*. What differs is only the source's
        /// richness: `appDefaults` has no warm-ups, techniques, distance,
        /// segments or note; a prepared alternative has all five, because the
        /// user authored them.
        ///
        /// The payload rides on the choice rather than on `ResetSource` so a
        /// caller cannot ask for an alternative and forget to supply one.
        case useAlternative(AlternativePrescriptionPayload)
    }

    /// The app's default / reset prescription source for a slot.
    ///
    /// Mirrors `makeDefaultPrescription(isTimeBased:in:)` — the same factory the
    /// routine editor uses when a slot first needs a prescription — so "Reset
    /// plan" lands on exactly the values a freshly-authored slot for the new
    /// exercise would have. Deliberately carries no warm-ups, techniques, or
    /// prescription note: the reset source provides none, so both snapshots are
    /// cleared rather than inherited from the replaced exercise.
    ///
    /// **Not** a latest-history prefill. Sourcing the new exercise's last
    /// performance during a switch is deferred to a future explicit
    /// "Use Last Performance" option (Entry #12 product decision).
    struct ResetSource: Equatable {
        var sets: Int?
        var repMin: Int?
        var repMax: Int?
        var restSecondsBetweenSets: Int?
        var restSecondsAfterExercise: Int?
        var durationMinSeconds: Int?
        var durationMaxSeconds: Int?
        var rir: Double?
        var rpe: Double?
        var tempo: String?
        var slotNotes: String?
        /// Cardio Slice 6 — the reset source's own distance target. Only ever
        /// applied when the switched-in exercise is `.cardio`; for any other
        /// mode the field has no landing place and the target is cleared.
        var targetDistanceMeters: Double?
        var targetDistanceUnitRaw: String?
        /// Structured Cardio Slice 12D — the reset source's own segment plan,
        /// encoded. Only ever applied when the switched-in exercise is
        /// `.cardio`; every other mode has nowhere to put it, so the plan is
        /// cleared rather than carried. `appDefaults` supplies none — the app
        /// has no notion of a default structured plan, and inventing one would
        /// be programming a session on the user's behalf.
        var cardioSegmentsData: Data?

        /// True when the reset source carries its own effort target. When
        /// false, the pre-switch RIR/RPE is preserved instead — effort applies
        /// to both tracking types, so a switch should never silently drop it.
        var providesEffortTarget: Bool { rir != nil || rpe != nil }

        /// True when the source's prescription is **complete and
        /// authoritative**, so its effort target replaces the pre-switch one
        /// even when it is empty (Phase F1).
        ///
        /// `appDefaults` leaves this false: with autoreg off it has no opinion
        /// about effort, and inheriting the slot's is the kinder reading. A
        /// prepared alternative is the opposite case — the user authored the
        /// whole plan, so an alternative deliberately written with no effort
        /// target must not silently inherit "RIR 2" from the exercise it
        /// replaced.
        var replacesEffortTarget: Bool = false

        /// Whether this source decides the slot's post-switch effort target.
        /// Reading through one property keeps the plan and the snapshot
        /// projection from ever disagreeing about who won.
        var ownsEffortTarget: Bool {
            providesEffortTarget || replacesEffortTarget
        }

        init(
            sets: Int? = nil,
            repMin: Int? = nil,
            repMax: Int? = nil,
            restSecondsBetweenSets: Int? = nil,
            restSecondsAfterExercise: Int? = nil,
            durationMinSeconds: Int? = nil,
            durationMaxSeconds: Int? = nil,
            rir: Double? = nil,
            rpe: Double? = nil,
            tempo: String? = nil,
            slotNotes: String? = nil,
            targetDistanceMeters: Double? = nil,
            targetDistanceUnitRaw: String? = nil,
            cardioSegmentsData: Data? = nil
        ) {
            self.sets = sets
            self.repMin = repMin
            self.repMax = repMax
            self.restSecondsBetweenSets = restSecondsBetweenSets
            self.restSecondsAfterExercise = restSecondsAfterExercise
            self.durationMinSeconds = durationMinSeconds
            self.durationMaxSeconds = durationMaxSeconds
            self.rir = rir
            self.rpe = rpe
            self.tempo = tempo
            self.slotNotes = slotNotes
            self.targetDistanceMeters = targetDistanceMeters
            self.targetDistanceUnitRaw = targetDistanceUnitRaw
            self.cardioSegmentsData = cardioSegmentsData
        }

        /// The app-default reset source for a slot of the given tracking mode,
        /// read from `AppSettings`. Field-for-field equivalent to
        /// `makeDefaultPrescription(isTimeBased:isCardio:in:)` — including the
        /// Slice 5 cardio rules, so resetting onto a treadmill lands on the
        /// same one set / no rest / no effort a freshly-authored cardio slot
        /// gets — except that it never fabricates a duration: a duration slot
        /// with no configured target falls through to the same 60s floor
        /// `makeSwapDefaultTemplates` applies, keeping the two helpers in
        /// agreement.
        ///
        /// Carries **no** target distance. App defaults have no notion of one,
        /// and inventing a distance for an exercise the user just picked would
        /// be prescribing on their behalf. A caller with a real reset source
        /// (a routine slot) may supply one through the initializer.
        static func appDefaults(for mode: TrackingMode) -> ResetSource {
            var source = ResetSource()
            source.sets = CardioRoutineRules.defaultSets(mode)
            if mode.usesDuration {
                source.durationMinSeconds = nil
                source.durationMaxSeconds = nil
            } else {
                source.repMin = AppSettings.defaultRepMin
                source.repMax = AppSettings.defaultRepMax
            }
            source.restSecondsBetweenSets =
                CardioRoutineRules.defaultRestBetweenSets(mode)
            source.restSecondsAfterExercise =
                CardioRoutineRules.defaultRestAfterExercise(mode)
            if CardioRoutineRules.seedsEffortTarget(mode) {
                switch AppSettings.autoregMode {
                case .rir: source.rir = AppSettings.defaultRIR
                case .rpe: source.rpe = AppSettings.defaultRPE
                case .none: break
                }
            }
            // Tempo and the prescription note are intentionally left nil: the
            // reset source provides neither, so neither may be inherited from
            // the replaced exercise.
            return source
        }

        /// The reset source for a **prepared alternative** (Phase F1).
        ///
        /// The thing `appDefaults` cannot be: a real, authored replacement
        /// plan. Every field maps straight across, including the three the app
        /// has no default for — target distance, structured cardio, and the
        /// slot note — because the user wrote them for *this* exercise.
        ///
        /// Mode gating is unchanged and still belongs to `resetPlan`: a
        /// distance or a segment plan on this source lands only when the
        /// switched-in exercise is actually cardio, and a tempo only when it is
        /// not duration-based. So an alternative authored before its exercise
        /// was edited into another tracking mode degrades exactly the way a
        /// reset does, rather than smuggling a stale field through.
        ///
        /// Warm-ups, techniques and the effort-progression pair are **not**
        /// here: `ResetSource` is `SessionPlan`-shaped and a `SessionPlan` has
        /// no field for any of them. They ride on `Outcome.appliedAlternative`
        /// instead, which is where the caller applies them.
        static func alternative(
            _ payload: AlternativePrescriptionPayload
        ) -> ResetSource {
            var source = ResetSource()
            source.sets = payload.sets
            source.repMin = payload.repMin
            source.repMax = payload.repMax
            source.restSecondsBetweenSets = payload.restSecondsBetweenSets
            source.restSecondsAfterExercise = payload.restSecondsAfterExercise
            source.durationMinSeconds = payload.durationMinSeconds
            source.durationMaxSeconds = payload.durationMaxSeconds
            source.rir = payload.rir
            source.rpe = payload.rpe
            source.tempo = payload.tempo
            source.slotNotes = payload.slotNotes
            source.targetDistanceMeters = payload.targetDistanceMeters
            source.targetDistanceUnitRaw = payload.targetDistanceUnitRaw
            // Encoded here rather than carried as a plan, because that is the
            // shape the reset branch already applies — the same encoding
            // `SlotPrescription.setStructuredCardioPlan` uses.
            source.cardioSegmentsData = payload.cardioSegments.flatMap {
                try? JSONEncoder().encode($0)
            }
            source.replacesEffortTarget = true
            return source
        }
    }

    // MARK: - Output

    /// The slot's post-switch state. `sessionPlan` is complete and
    /// authoritative; the two flags tell the caller whether the slot's
    /// existing warm-up / technique snapshots survive the switch.
    struct Outcome: Equatable {
        var sessionPlan: SessionPlan
        /// Warm-up steps survive only within the same tracking type, and never
        /// across a reset (the reset source supplies no warm-ups).
        var keepWarmupSteps: Bool
        /// Techniques survive only within the same tracking type, and never
        /// across a reset. Surviving techniques are still filtered against the
        /// new exercise's compatibility rules by
        /// `retainedTechniques(from:isBodyweight:usesDuration:)`.
        var keepTechniques: Bool
        /// True when the snapshot's effort-**progression** fields
        /// (`effortModeRaw`, `rir/rpeStart|End`) must be dropped because the
        /// reset source replaced them with its own single effort target.
        /// Keeping them would let a stale `"progression"` mode outrank the
        /// freshly reset single value in `WorkoutEffortTargetResolver`.
        var clearsEffortProgression: Bool = false
        /// Cardio Slice 6 — whether the slot's typed cardio metric drafts
        /// (distance, heart rate, calories, incline, resistance, zone) survive.
        ///
        /// True for exactly one case: **cardio → cardio, Keep current plan.**
        /// There the numbers still describe the same kind of bout, and the user
        /// asked to keep what they had. Everywhere else they are cleared —
        /// carrying "5 km, 142 bpm" onto a bench press, or onto a *different*
        /// cardio machine after an explicit Reset, attaches measurements to an
        /// exercise that did not produce them.
        ///
        /// Structured Cardio Slice 12D reuses this flag for the segment
        /// **checklist ticks**, because the question is identical — "does the
        /// slot's session-scoped cardio progress state still describe what is
        /// being done?" — and its truth table is identical too. A second flag
        /// with the same value would only be one more thing to keep in step.
        /// The ticks are additionally reconciled against the post-switch plan
        /// by the caller, so a Keep that preserved the plan keeps its ticks and
        /// a Reset onto a different plan drops the ones that no longer exist.
        var keepCardioDrafts: Bool = false
        /// The tracking mode of the switched-in exercise. Carried on the
        /// outcome so `adaptedSnapshot` can apply mode-specific rules — chiefly
        /// that a cardio slot's snapshot must not retain effort-progression
        /// fields — without the caller having to pass the mode twice.
        var newMode: TrackingMode = .strength

        /// The prepared alternative this outcome applied, or nil for
        /// keep/reset (Phase F1).
        ///
        /// Carries exactly the parts of an authored prescription that a
        /// `SessionPlan` has nowhere to put — warm-up steps, techniques, and
        /// the effort-**progression** pair — so the caller applies one object
        /// rather than reassembling five. Nil keeps every pre-F1 outcome
        /// byte-identical, which is what lets the existing adapter suite pass
        /// unmodified.
        var appliedAlternative: AlternativePrescriptionPayload? = nil

        /// Warm-up steps that **replace** the slot's, or nil to fall back to
        /// `keepWarmupSteps`.
        ///
        /// The distinction matters: `keepWarmupSteps` is a verdict about the
        /// steps the slot already has ("may they survive?"), and a prepared
        /// alternative needs the other question answered ("use these
        /// instead"). An alternative that carries none returns `[]` — it
        /// authored no warm-up, so the slot gets none, rather than inheriting
        /// the replaced exercise's ramp.
        var replacementWarmupSteps: [WarmupStepSnapshot]? {
            appliedAlternative?.warmupSteps
        }

        /// Techniques that **replace** the slot's, or nil to fall back to
        /// `keepTechniques`. Still filtered by
        /// `retainedTechniques(from:isBodyweight:usesDuration:)` at the call
        /// site, so an alternative cannot introduce a combination the routine
        /// editor would have rejected.
        var replacementTechniques: [TechniquePlanSnapshot]? {
            appliedAlternative?.techniques
        }
    }

    // MARK: - Adaptation

    /// Resolve the post-switch `SessionPlan` for a slot.
    ///
    /// - Parameters:
    ///   - choice: which dialog button the user tapped.
    ///   - current: the slot's live pre-switch `SessionPlan`, if any.
    ///   - oldMode: tracking mode of the exercise being replaced.
    ///   - newMode: tracking mode of the exercise being switched in.
    ///   - resetSource: the default/reset prescription source, used only for
    ///     `.resetPlan`.
    ///
    /// Takes `TrackingMode`, not `isTimeBased`: a boolean cannot tell a
    /// treadmill from a plank, and the whole point of Slice 6 is that
    /// cardio-only state must not survive a switch onto an exercise that has
    /// nowhere to put it. Note that the two axes are genuinely different —
    /// cardio → timedHold *changes mode* but **keeps** the duration target,
    /// because both are logged by time. `trackingTypeChanged` below is the
    /// field-shape question (`usesDuration`), never mode equality.
    static func outcome(
        choice: Choice,
        current: SessionPlan?,
        oldMode: TrackingMode,
        newMode: TrackingMode,
        resetSource: ResetSource
    ) -> Outcome {
        let trackingTypeChanged = oldMode.usesDuration != newMode.usesDuration

        switch choice {
        case .keepCurrentPlan:
            return keepCurrentPlan(
                current: current,
                trackingTypeChanged: trackingTypeChanged,
                oldMode: oldMode,
                newMode: newMode
            )
        case .resetPlan:
            return resetPlan(
                current: current,
                newMode: newMode,
                resetSource: resetSource
            )
        case .useAlternative(let payload):
            // The reset branch, with a richer source — no second code path.
            // The `resetSource` argument is deliberately ignored: the choice
            // carries its own, so a caller cannot pair "use this alternative"
            // with somebody else's plan.
            var outcome = resetPlan(
                current: current,
                newMode: newMode,
                resetSource: .alternative(payload)
            )
            outcome.appliedAlternative = payload
            return outcome
        }
    }

    /// "Keep current plan" — preserve the current structure wherever it stays
    /// valid for the new exercise, adapt where the tracking type forces it.
    private static func keepCurrentPlan(
        current: SessionPlan?,
        trackingTypeChanged: Bool,
        oldMode: TrackingMode,
        newMode: TrackingMode
    ) -> Outcome {
        let newIsTimeBased = newMode.usesDuration
        // Cardio → cardio is the only switch where a distance target, and the
        // typed metrics under it, still describe the thing being done. Every
        // other combination clears both: no other mode has a field to put them
        // in, and a target silently riding along on a bench press is exactly
        // the stale-state class of bug this slice exists to close.
        let staysCardio = oldMode == .cardio && newMode == .cardio

        var plan = SessionPlan()
        plan.usesDuration = newIsTimeBased
        if staysCardio {
            plan.targetDistanceMeters = current?.targetDistanceMeters
            plan.targetDistanceUnitRaw = current?.targetDistanceUnitRaw
            // Structured Cardio Slice 12D. Same rule, same reason: a segment
            // plan is programming for a cardio bout, so it survives exactly
            // where the distance target does. Copied as the raw payload, so a
            // plan this build would normalize is not silently rewritten by a
            // switch. Dropping it on every other combination is what stops a
            // treadmill's warm-up/work/cool-down riding along on a bench press
            // — and the routine slot still holds it, so switching back
            // restores it ("hidden but intact").
            plan.cardioSegmentsData = current?.cardioSegmentsData
        }

        // Always preserved — valid under either tracking type.
        plan.sets = current?.sets
        plan.restSecondsBetweenSets = current?.restSecondsBetweenSets
        plan.restSecondsAfterExercise = current?.restSecondsAfterExercise

        // …except effort, which stops at cardio. RIR is "reps in reserve", and
        // the app offers RIR and RPE through one control, so a cardio slot has
        // nothing to show and nothing to edit. Carrying the replaced exercise's
        // "RIR 2" onto a treadmill leaves a value the user can neither see nor
        // remove, and which would resurface the moment the slot was switched
        // back or the plan applied to the routine. Cleared at the boundary
        // instead — the same treatment reps and tempo already get.
        if newMode != .cardio {
            plan.rir = current?.rir
            plan.rpe = current?.rpe
        }

        // The prescription / routine-specific note described the exercise that
        // was just replaced, so it never blindly carries over. "Keep" has no
        // new-exercise note source, so the slot note is cleared. (Session notes
        // live on `Workout.notes` and are untouched by this service.)
        plan.slotNotes = nil

        if trackingTypeChanged {
            // Tracking-specific fields from the old mode are meaningless for
            // the new one — leave reps AND duration unset so the slot shows the
            // new type's fields cleanly with no mixed state. Tempo, warm-ups,
            // and techniques are all mode-coupled and are cleared with them.
            plan.tempo = nil
            return Outcome(
                sessionPlan: plan, keepWarmupSteps: false,
                keepTechniques: false, keepCardioDrafts: staysCardio,
                newMode: newMode
            )
        }

        // Same tracking type — carry the mode's own fields across.
        if newIsTimeBased {
            plan.durationMinSeconds = current?.durationMinSeconds
            plan.durationMaxSeconds = current?.durationMaxSeconds
            // Tempo never applies to a duration-based exercise, even
            // duration → duration: there are no reps to phase.
            plan.tempo = nil
        } else {
            plan.repMin = current?.repMin
            plan.repMax = current?.repMax
            plan.tempo = normalizedTempo(current?.tempo)
        }

        return Outcome(
            sessionPlan: plan, keepWarmupSteps: true, keepTechniques: true,
            keepCardioDrafts: staysCardio, newMode: newMode
        )
    }

    /// "Reset plan for this slot" — rebuild from the default/reset source,
    /// adapted to the new exercise's tracking type.
    private static func resetPlan(
        current: SessionPlan?,
        newMode: TrackingMode,
        resetSource: ResetSource
    ) -> Outcome {
        let newIsTimeBased = newMode.usesDuration

        var plan = SessionPlan()
        plan.usesDuration = newIsTimeBased
        // Reset follows the source, never the replaced slot. A cardio reset
        // source may carry its own target; a non-cardio one has nowhere to put
        // it, so the target is cleared either way rather than inherited.
        if newMode == .cardio {
            plan.targetDistanceMeters = resetSource.targetDistanceMeters
            plan.targetDistanceUnitRaw = resetSource.targetDistanceUnitRaw
            // Structured Cardio Slice 12D — the replacement plan, if the reset
            // source has one. `appDefaults` never does, so the common Reset
            // lands on an unstructured cardio slot and the checklist
            // disappears, which is what "start over" should mean.
            plan.cardioSegmentsData = resetSource.cardioSegmentsData
        }

        plan.sets = resetSource.sets
        plan.restSecondsBetweenSets = resetSource.restSecondsBetweenSets
        plan.restSecondsAfterExercise = resetSource.restSecondsAfterExercise

        if newIsTimeBased {
            plan.durationMinSeconds = resetSource.durationMinSeconds
            plan.durationMaxSeconds = resetSource.durationMaxSeconds
            plan.tempo = nil
        } else {
            plan.repMin = resetSource.repMin
            plan.repMax = resetSource.repMax
            plan.tempo = normalizedTempo(resetSource.tempo)
        }

        // Effort applies to both *non-cardio* tracking types, so it is
        // preserved when the reset source has no opinion of its own (autoreg
        // mode `.none`). A cardio reset source never provides one and must not
        // inherit one either — see the note in `keepCurrentPlan`.
        if newMode == .cardio {
            plan.rir = nil
            plan.rpe = nil
        } else if resetSource.ownsEffortTarget {
            plan.rir = resetSource.rir
            plan.rpe = resetSource.rpe
        } else {
            plan.rir = current?.rir
            plan.rpe = current?.rpe
        }

        // Only a valid reset-source note may land here — never the replaced
        // exercise's note.
        plan.slotNotes = normalizedNote(resetSource.slotNotes)

        // The reset source supplies neither warm-ups nor techniques, so both
        // are cleared rather than inherited from the replaced exercise.
        return Outcome(
            sessionPlan: plan,
            keepWarmupSteps: false,
            keepTechniques: false,
            // Only when the reset source actually replaced the effort target;
            // when it had none the pre-switch effort (including a progression)
            // was preserved above and must stay intact. A prepared alternative
            // always owns the effort target, so the replaced exercise's
            // progression is always cleared before the alternative's own is
            // written in `adaptedSnapshot`.
            clearsEffortProgression: resetSource.ownsEffortTarget,
            // An explicit Reset discards typed cardio metrics along with
            // everything else the user is asking to start over from.
            keepCardioDrafts: false,
            newMode: newMode
        )
    }

    // MARK: - Technique retention

    /// Filter the technique snapshots a same-tracking-type switch retained
    /// against the NEW exercise's compatibility rules.
    ///
    /// `Outcome.keepTechniques` answers "may techniques survive this switch at
    /// all"; this answers "which of them are still legal on the new exercise".
    /// Both gates apply — a bodyweight switch-in drops Drop Set, and the
    /// duration gate drops rep-count-dependent techniques — reusing the single
    /// `isTechniqueAllowed` rule set that the routine editor enforces at
    /// authoring time, so no switch can produce a technique combination the
    /// editor would have rejected.
    static func retainedTechniques(
        from snapshots: [TechniquePlanSnapshot],
        isBodyweight: Bool,
        usesDuration: Bool
    ) -> [TechniquePlanSnapshot] {
        compatibleTechniques(
            snapshots, isBodyweight: isBodyweight, usesDuration: usesDuration)
    }

    // MARK: - Snapshot projection

    /// Project an adapted `SessionPlan` back onto the slot's tier-2
    /// `PrescriptionSnapshotPayload`.
    ///
    /// After a switch the session plan is authoritative, but `SessionPlanResolver`
    /// still consults the snapshot as tier 2 and `populateSnapshotFields` freezes
    /// it into `WorkoutItem.plannedPrescriptionSnapshot` for History. Leaving the
    /// replaced exercise's snapshot in place is what let a switched-in barbell
    /// lift render duration fields after a resume; nil-ing it instead loses the
    /// effort-progression fields and the set count. Rewriting it from the adapted
    /// plan keeps both tiers in agreement, so every read path — live rows, the
    /// plan card, a resume, and finished History — reports the same numbers.
    ///
    /// Effort-progression fields (`effortModeRaw`, `rir/rpeStart|End`) are
    /// carried over from `base` because an effort target is valid under either
    /// tracking type. Equipment / setup are taken from the switched-in
    /// exercise's live values (nil when it has none) rather than the replaced
    /// exercise's, matching `resolvedSnapshotEquipmentSetup`.
    static func adaptedSnapshot(
        from outcome: Outcome,
        base: PrescriptionSnapshotPayload?,
        equipment: String?,
        setupNotes: String?
    ) -> PrescriptionSnapshotPayload {
        let plan = outcome.sessionPlan
        var payload = base ?? .empty
        // A cardio slot shows no effort control, so its snapshot must carry no
        // effort state either — otherwise `WorkoutEffortTargetResolver` still
        // derives `.progression` from the replaced exercise's start/end pair
        // and the Plan card summarizes a target the row does not display.
        if outcome.newMode == .cardio || outcome.clearsEffortProgression {
            payload.effortModeRaw = nil
            payload.rirStart = nil
            payload.rirEnd = nil
            payload.rpeStart = nil
            payload.rpeEnd = nil
        }
        // Phase F1 — a prepared alternative's own effort mode. Written after
        // the clear above (which removed the *replaced* exercise's), and only
        // for a mode that can display one: a progression authored on an
        // alternative would otherwise be dropped entirely, because `SessionPlan`
        // carries a single rir/rpe and has nowhere to put start/end.
        if let alternative = outcome.appliedAlternative,
            outcome.newMode != .cardio
        {
            payload.effortModeRaw = alternative.effortModeRaw
            payload.rirStart = alternative.rirStart
            payload.rirEnd = alternative.rirEnd
            payload.rpeStart = alternative.rpeStart
            payload.rpeEnd = alternative.rpeEnd
        }
        payload.sets = plan.sets
        payload.repMin = plan.repMin
        payload.repMax = plan.repMax
        payload.restSecondsBetweenSets = plan.restSecondsBetweenSets
        payload.restSecondsAfterExercise = plan.restSecondsAfterExercise
        payload.rir = plan.rir
        payload.rpe = plan.rpe
        payload.tempo = plan.usesDuration ? nil : normalizedTempo(plan.tempo)
        payload.durationMinSeconds = plan.durationMinSeconds
        payload.durationMaxSeconds = plan.durationMaxSeconds
        payload.usesDuration = plan.usesDuration
        // Written unconditionally from the adapted plan — including when the
        // plan has none. `base` is the *replaced* exercise's snapshot, so
        // leaving these alone is precisely how a cardio target used to survive
        // onto a bench press and then reappear (via tier-2 resolution) on the
        // next resume.
        payload.targetDistanceMeters = plan.targetDistanceMeters
        payload.targetDistanceUnitRaw = plan.targetDistanceUnitRaw
        // Slice 12D — written unconditionally for exactly the reason above.
        // `base` is the *replaced* exercise's snapshot: leaving its segments
        // alone would let tier-2 resolution put a treadmill plan back on screen
        // after a resume, on a slot the switch had already cleared.
        payload.cardioSegmentsData = plan.cardioSegmentsData
        payload.equipment = equipment
        payload.setupNotes = setupNotes
        return payload
    }

    // MARK: - Normalization

    /// Empty / whitespace-only tempo strings normalize to nil so a blank tempo
    /// never renders an empty `"Tempo "` segment or counts as a dirty edit.
    static func normalizedTempo(_ tempo: String?) -> String? {
        guard let tempo,
            !tempo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return tempo
    }

    private static func normalizedNote(_ note: String?) -> String? {
        normalizedOptionalNote(note ?? "")
    }
}
