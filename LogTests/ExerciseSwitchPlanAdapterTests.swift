import XCTest

@testable import Log

/// Entry #12 P1 regression suite for mid-workout Switch Exercise.
///
/// A tester switching a duration-based exercise for a non-duration one and
/// choosing "Keep Current Plan" saw the slot's set count change (2 → 3) and,
/// after resuming, saw the switched-in reps/weight exercise still rendering
/// duration fields. `ExerciseSwitchPlanAdapter` is the single decision point
/// both dialog buttons now go through, so the compatibility contract is pinned
/// here at the value level.
///
/// The reset source is injected explicitly in most tests so they don't depend
/// on the device's `AppSettings`; `appDefaults` gets its own coverage at the
/// bottom.
final class ExerciseSwitchPlanAdapterTests: XCTestCase {

    private typealias Adapter = ExerciseSwitchPlanAdapter

    // MARK: - Fixtures

    /// A fully-populated duration-based slot plan (e.g. a programmed Plank):
    /// 2 sets, rest, effort, duration range, plus a stale tempo and a
    /// routine-specific note that must NOT follow the user to a new exercise.
    private func durationPlan() -> SessionPlan {
        var p = SessionPlan()
        p.usesDuration = true
        p.sets = 2
        p.durationMinSeconds = 30
        p.durationMaxSeconds = 45
        p.restSecondsBetweenSets = 90
        p.restSecondsAfterExercise = 120
        p.rir = 2
        p.rpe = 8
        p.tempo = "3-1-3-0"
        p.slotNotes = "Elbows under shoulders"
        return p
    }

    /// A fully-populated reps/weight slot plan (e.g. a programmed Bench Press).
    private func repsPlan() -> SessionPlan {
        var p = SessionPlan()
        p.usesDuration = false
        p.sets = 2
        p.repMin = 6
        p.repMax = 8
        p.restSecondsBetweenSets = 90
        p.restSecondsAfterExercise = 120
        p.rir = 2
        p.rpe = 8
        p.tempo = "3-1-3-0"
        p.slotNotes = "Pause on chest"
        return p
    }

    /// A reset source that mimics `makeDefaultPrescription` for reps/weight.
    private func repsResetSource() -> Adapter.ResetSource {
        Adapter.ResetSource(
            sets: 3, repMin: 8, repMax: 12,
            restSecondsBetweenSets: 120, rir: 2
        )
    }

    /// A reset source that mimics `makeDefaultPrescription` for duration.
    private func durationResetSource() -> Adapter.ResetSource {
        Adapter.ResetSource(
            sets: 3, restSecondsBetweenSets: 120, rir: 2
        )
    }

    // MARK: - 1) duration → non-duration, Keep Current Plan

    func test_keep_durationToReps_preservesStructureAndClearsIncompatible() {
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan,
            current: durationPlan(),
            oldIsTimeBased: true,
            newIsTimeBased: false,
            resetSource: repsResetSource()
        )
        let plan = outcome.sessionPlan

        // Preserved: set count (the reported bug — this used to become 3),
        // rest, and the effort target.
        XCTAssertEqual(plan.sets, 2)
        XCTAssertEqual(plan.restSecondsBetweenSets, 90)
        XCTAssertEqual(plan.restSecondsAfterExercise, 120)
        XCTAssertEqual(plan.rir, 2)
        XCTAssertEqual(plan.rpe, 8)

        // Switched to reps/weight fields.
        XCTAssertFalse(plan.usesDuration)

        // Cleared: duration-specific fields, tempo, warm-ups, techniques, and
        // the old prescription note.
        XCTAssertNil(plan.durationMinSeconds)
        XCTAssertNil(plan.durationMaxSeconds)
        XCTAssertNil(plan.tempo)
        XCTAssertNil(plan.slotNotes)
        XCTAssertFalse(outcome.keepWarmupSteps)
        XCTAssertFalse(outcome.keepTechniques)

        // No latest-history prefill: reps are left unset for the user/prefill
        // tiers rather than invented from the new exercise's history.
        XCTAssertNil(plan.repMin)
        XCTAssertNil(plan.repMax)
    }

    // MARK: - 2) non-duration → duration, Keep Current Plan

    func test_keep_repsToDuration_preservesStructureAndClearsIncompatible() {
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan,
            current: repsPlan(),
            oldIsTimeBased: false,
            newIsTimeBased: true,
            resetSource: durationResetSource()
        )
        let plan = outcome.sessionPlan

        XCTAssertEqual(plan.sets, 2)
        XCTAssertEqual(plan.restSecondsBetweenSets, 90)
        XCTAssertEqual(plan.restSecondsAfterExercise, 120)
        XCTAssertEqual(plan.rir, 2)
        XCTAssertEqual(plan.rpe, 8)

        // Switched to duration fields.
        XCTAssertTrue(plan.usesDuration)

        // Cleared: reps/weight-specific fields, tempo, warm-ups, techniques,
        // old prescription note.
        XCTAssertNil(plan.repMin)
        XCTAssertNil(plan.repMax)
        XCTAssertNil(plan.tempo)
        XCTAssertNil(plan.slotNotes)
        XCTAssertFalse(outcome.keepWarmupSteps)
        XCTAssertFalse(outcome.keepTechniques)
    }

    /// Neither direction may leave BOTH field families populated — the
    /// "mixed prescription state" the bug report called out.
    func test_keep_trackingTypeChange_neverLeavesMixedState() {
        for (old, new) in [(true, false), (false, true)] {
            let outcome = Adapter.outcome(
                choice: .keepCurrentPlan,
                current: old ? durationPlan() : repsPlan(),
                oldIsTimeBased: old,
                newIsTimeBased: new,
                resetSource: repsResetSource()
            )
            let p = outcome.sessionPlan
            let hasReps = p.repMin != nil || p.repMax != nil
            let hasDuration =
                p.durationMinSeconds != nil || p.durationMaxSeconds != nil
            XCTAssertFalse(
                hasReps && hasDuration,
                "mixed reps + duration state after \(old) → \(new)")
            XCTAssertEqual(p.usesDuration, new)
        }
    }

    // MARK: - 3) same tracking type, Keep Current Plan

    func test_keep_repsToReps_preservesCompatibleFieldsIncludingTempo() {
        // Pull-up → Chin-up.
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan,
            current: repsPlan(),
            oldIsTimeBased: false,
            newIsTimeBased: false,
            resetSource: repsResetSource()
        )
        let plan = outcome.sessionPlan

        XCTAssertEqual(plan.sets, 2)
        XCTAssertEqual(plan.repMin, 6)
        XCTAssertEqual(plan.repMax, 8)
        XCTAssertEqual(plan.restSecondsBetweenSets, 90)
        XCTAssertEqual(plan.rir, 2)
        XCTAssertFalse(plan.usesDuration)

        // Tempo survives non-duration → non-duration only.
        XCTAssertEqual(plan.tempo, "3-1-3-0")

        // Warm-ups and techniques survive within one tracking type.
        XCTAssertTrue(outcome.keepWarmupSteps)
        XCTAssertTrue(outcome.keepTechniques)

        // The old prescription note still does not carry over — it described
        // the exercise that was just replaced.
        XCTAssertNil(plan.slotNotes)
    }

    func test_keep_durationToDuration_preservesDurationButNeverTempo() {
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan,
            current: durationPlan(),
            oldIsTimeBased: true,
            newIsTimeBased: true,
            resetSource: durationResetSource()
        )
        let plan = outcome.sessionPlan

        XCTAssertEqual(plan.sets, 2)
        XCTAssertEqual(plan.durationMinSeconds, 30)
        XCTAssertEqual(plan.durationMaxSeconds, 45)
        XCTAssertTrue(plan.usesDuration)
        XCTAssertTrue(outcome.keepWarmupSteps)
        XCTAssertTrue(outcome.keepTechniques)

        // Tempo never applies to a duration exercise, even duration → duration.
        XCTAssertNil(plan.tempo)
    }

    // MARK: - 4) duration → non-duration, Reset Plan

    func test_reset_durationToReps_usesResetSourceNotOldPlan() {
        let outcome = Adapter.outcome(
            choice: .resetPlan,
            current: durationPlan(),
            oldIsTimeBased: true,
            newIsTimeBased: false,
            resetSource: repsResetSource()
        )
        let plan = outcome.sessionPlan

        // Rebuilt from the reset source.
        XCTAssertEqual(plan.sets, 3)
        XCTAssertEqual(plan.repMin, 8)
        XCTAssertEqual(plan.repMax, 12)
        XCTAssertEqual(plan.restSecondsBetweenSets, 120)
        XCTAssertFalse(plan.usesDuration)

        // Old duration fields, tempo, warm-ups, techniques, and note are gone.
        XCTAssertNil(plan.durationMinSeconds)
        XCTAssertNil(plan.durationMaxSeconds)
        XCTAssertNil(plan.tempo)
        XCTAssertNil(plan.slotNotes)
        XCTAssertFalse(outcome.keepWarmupSteps)
        XCTAssertFalse(outcome.keepTechniques)

        // Not the old plan's values (no silent carry-over).
        XCTAssertNotEqual(plan.sets, 2)
        XCTAssertNotEqual(plan.restSecondsBetweenSets, 90)
    }

    // MARK: - 5) non-duration → duration, Reset Plan

    func test_reset_repsToDuration_usesResetSourceNotOldPlan() {
        let outcome = Adapter.outcome(
            choice: .resetPlan,
            current: repsPlan(),
            oldIsTimeBased: false,
            newIsTimeBased: true,
            resetSource: durationResetSource()
        )
        let plan = outcome.sessionPlan

        XCTAssertEqual(plan.sets, 3)
        XCTAssertEqual(plan.restSecondsBetweenSets, 120)
        XCTAssertTrue(plan.usesDuration)

        // Old reps/weight fields, tempo, warm-ups, techniques, note all gone.
        XCTAssertNil(plan.repMin)
        XCTAssertNil(plan.repMax)
        XCTAssertNil(plan.tempo)
        XCTAssertNil(plan.slotNotes)
        XCTAssertFalse(outcome.keepWarmupSteps)
        XCTAssertFalse(outcome.keepTechniques)
    }

    /// Reset must never resurrect the replaced exercise's prescription note,
    /// but a reset source that DOES supply one is honored.
    func test_reset_prescriptionNote_onlyFromResetSource() {
        var source = repsResetSource()
        source.slotNotes = "Default cue for the new lift"

        let withNote = Adapter.outcome(
            choice: .resetPlan, current: durationPlan(),
            oldIsTimeBased: true, newIsTimeBased: false, resetSource: source
        )
        XCTAssertEqual(
            withNote.sessionPlan.slotNotes, "Default cue for the new lift")

        let withoutNote = Adapter.outcome(
            choice: .resetPlan, current: durationPlan(),
            oldIsTimeBased: true, newIsTimeBased: false,
            resetSource: repsResetSource()
        )
        XCTAssertNil(withoutNote.sessionPlan.slotNotes)
        XCTAssertNotEqual(
            withoutNote.sessionPlan.slotNotes, "Elbows under shoulders")
    }

    /// A whitespace-only reset-source note normalizes to nil rather than
    /// rendering an empty note row.
    func test_reset_blankResetSourceNote_normalizesToNil() {
        var source = repsResetSource()
        source.slotNotes = "   \n "
        let outcome = Adapter.outcome(
            choice: .resetPlan, current: repsPlan(),
            oldIsTimeBased: false, newIsTimeBased: false, resetSource: source
        )
        XCTAssertNil(outcome.sessionPlan.slotNotes)
    }

    // MARK: - Effort target across both choices

    func test_reset_preservesEffortWhenResetSourceHasNone() {
        // Autoreg `.none` → the reset source carries no effort target, so the
        // pre-switch RIR/RPE survives (effort is valid for both types).
        var source = repsResetSource()
        source.rir = nil
        source.rpe = nil
        XCTAssertFalse(source.providesEffortTarget)

        let outcome = Adapter.outcome(
            choice: .resetPlan, current: durationPlan(),
            oldIsTimeBased: true, newIsTimeBased: false, resetSource: source
        )
        XCTAssertEqual(outcome.sessionPlan.rir, 2)
        XCTAssertEqual(outcome.sessionPlan.rpe, 8)
        XCTAssertFalse(outcome.clearsEffortProgression)
    }

    func test_reset_resetSourceEffortWinsAndDropsProgression() {
        var source = repsResetSource()
        source.rir = 3
        let outcome = Adapter.outcome(
            choice: .resetPlan, current: durationPlan(),
            oldIsTimeBased: true, newIsTimeBased: false, resetSource: source
        )
        XCTAssertEqual(outcome.sessionPlan.rir, 3)
        XCTAssertNil(outcome.sessionPlan.rpe)
        // A stale `progression` mode must not outrank the fresh single value.
        XCTAssertTrue(outcome.clearsEffortProgression)
    }

    func test_keep_neverClearsEffortProgression() {
        for (old, new) in [(true, false), (false, true), (false, false)] {
            let outcome = Adapter.outcome(
                choice: .keepCurrentPlan,
                current: old ? durationPlan() : repsPlan(),
                oldIsTimeBased: old, newIsTimeBased: new,
                resetSource: repsResetSource()
            )
            XCTAssertFalse(
                outcome.clearsEffortProgression,
                "keep must retain the effort progression (\(old) → \(new))")
        }
    }

    // MARK: - 9) Warm-up behavior

    func test_warmups_keptOnlyWithinSameTrackingType() {
        func keepsWarmups(_ old: Bool, _ new: Bool, _ choice: Adapter.Choice)
            -> Bool
        {
            Adapter.outcome(
                choice: choice,
                current: old ? durationPlan() : repsPlan(),
                oldIsTimeBased: old, newIsTimeBased: new,
                resetSource: repsResetSource()
            ).keepWarmupSteps
        }

        // Same tracking type + keep → preserved.
        XCTAssertTrue(keepsWarmups(false, false, .keepCurrentPlan))
        XCTAssertTrue(keepsWarmups(true, true, .keepCurrentPlan))
        // Tracking type change → cleared.
        XCTAssertFalse(keepsWarmups(true, false, .keepCurrentPlan))
        XCTAssertFalse(keepsWarmups(false, true, .keepCurrentPlan))
        // Reset always clears — the reset source supplies no warm-ups, so they
        // stay empty rather than being copied from the replaced exercise.
        XCTAssertFalse(keepsWarmups(false, false, .resetPlan))
        XCTAssertFalse(keepsWarmups(true, false, .resetPlan))
    }

    // MARK: - 10) Technique behavior

    private func technique(
        _ type: TechniqueType, order: Int = 0
    ) -> TechniquePlanSnapshot {
        TechniquePlanSnapshot(
            order: order, type: type, dropPercent: nil, dropCount: nil,
            rounds: nil, restSeconds: nil, partialRangeNote: nil,
            partialRangeRaw: nil, note: nil, reps: nil, appliesToRaw: nil,
            appliesToSetNumber: nil, appliesToSetIndicesRaw: nil,
            dropsetEffortRaw: nil, dropsetEffortReps: nil
        )
    }

    func test_techniques_keptOnlyWithinSameTrackingType() {
        func keepsTechniques(_ old: Bool, _ new: Bool, _ c: Adapter.Choice)
            -> Bool
        {
            Adapter.outcome(
                choice: c,
                current: old ? durationPlan() : repsPlan(),
                oldIsTimeBased: old, newIsTimeBased: new,
                resetSource: repsResetSource()
            ).keepTechniques
        }

        XCTAssertTrue(keepsTechniques(false, false, .keepCurrentPlan))
        XCTAssertTrue(keepsTechniques(true, true, .keepCurrentPlan))
        XCTAssertFalse(keepsTechniques(true, false, .keepCurrentPlan))
        XCTAssertFalse(keepsTechniques(false, true, .keepCurrentPlan))
        XCTAssertFalse(keepsTechniques(false, false, .resetPlan))
    }

    /// Techniques that survive a same-type switch are still filtered by the
    /// EXISTING conflict rules against the switched-in exercise.
    func test_retainedTechniques_appliesExistingConflictRules() {
        let all = [
            technique(.dropset, order: 0),
            technique(.toFailure, order: 1),
            technique(.partialReps, order: 2),
        ]

        // Weighted, rep-based switch-in: everything stays legal.
        let weighted = Adapter.retainedTechniques(
            from: all, isBodyweight: false, usesDuration: false)
        XCTAssertEqual(weighted.count, 3)

        // Bodyweight switch-in drops Drop Set (a weight-reduction technique).
        let bodyweight = Adapter.retainedTechniques(
            from: all, isBodyweight: true, usesDuration: false)
        XCTAssertFalse(bodyweight.contains { $0.type == .dropset })
        XCTAssertTrue(bodyweight.contains { $0.type == .toFailure })

        // Duration switch-in drops every rep-count-dependent technique.
        let duration = Adapter.retainedTechniques(
            from: all, isBodyweight: false, usesDuration: true)
        XCTAssertEqual(duration.map(\.type), [.toFailure])
        for type in techniquesIncompatibleWithDuration {
            XCTAssertFalse(
                duration.contains { $0.type == type },
                "\(type) is incompatible with duration")
        }
    }

    // MARK: - 8) Tempo cleanup at the value level

    func test_effectiveTempo_suppressesStaleTempoOnDurationPlans() {
        var p = SessionPlan()
        p.tempo = "3-1-3-0"

        p.usesDuration = false
        XCTAssertEqual(p.effectiveTempo, "3-1-3-0")
        XCTAssertTrue(p.secondarySummary(effortSummary: nil).contains("Tempo"))

        // Same stored value, duration mode → never surfaced.
        p.usesDuration = true
        XCTAssertNil(p.effectiveTempo)
        XCTAssertFalse(p.secondarySummary(effortSummary: nil).contains("Tempo"))
    }

    func test_sessionPlanFromSnapshot_dropsTempoWhenDurationBased() {
        let durationSnap = PrescriptionSnapshotPayload(
            sets: 2, tempo: "3-1-3-0", usesDuration: true)
        XCTAssertNil(SessionPlan(from: durationSnap, notes: nil).tempo)

        let repsSnap = PrescriptionSnapshotPayload(
            sets: 2, tempo: "3-1-3-0", usesDuration: false)
        XCTAssertEqual(
            SessionPlan(from: repsSnap, notes: nil).tempo, "3-1-3-0")
    }

    func test_adaptedSnapshot_mirrorsPlanAndDropsDurationTempo() {
        // A reps → duration keep-plan switch: the rewritten tier-2 snapshot
        // must agree with tier 1 so no resolver can reach the old mode's data.
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan,
            current: repsPlan(),
            oldIsTimeBased: false,
            newIsTimeBased: true,
            resetSource: durationResetSource()
        )
        let base = PrescriptionSnapshotPayload(
            sets: 2, repMin: 6, repMax: 8, tempo: "3-1-3-0",
            effortModeRaw: "single", usesDuration: false,
            equipment: "Barbell", setupNotes: "Bench at 30°")

        let snap = Adapter.adaptedSnapshot(
            from: outcome, base: base,
            equipment: "Bodyweight", setupNotes: "Forearms down")

        XCTAssertTrue(snap.usesDuration)
        XCTAssertEqual(snap.sets, 2)
        XCTAssertNil(snap.repMin)
        XCTAssertNil(snap.repMax)
        XCTAssertNil(snap.tempo)
        // Effort target and its mode survive (valid for both tracking types).
        XCTAssertEqual(snap.rir, 2)
        XCTAssertEqual(snap.effortModeRaw, "single")
        // Equipment/setup follow the switched-in exercise, never the old one.
        XCTAssertEqual(snap.equipment, "Bodyweight")
        XCTAssertEqual(snap.setupNotes, "Forearms down")
    }

    func test_adaptedSnapshot_clearsProgressionFieldsOnReset() {
        let outcome = Adapter.outcome(
            choice: .resetPlan, current: repsPlan(),
            oldIsTimeBased: false, newIsTimeBased: false,
            resetSource: repsResetSource()
        )
        let base = PrescriptionSnapshotPayload(
            effortModeRaw: "progression", rirStart: 3, rirEnd: 0,
            usesDuration: false)

        let snap = Adapter.adaptedSnapshot(
            from: outcome, base: base, equipment: nil, setupNotes: nil)

        XCTAssertNil(snap.effortModeRaw)
        XCTAssertNil(snap.rirStart)
        XCTAssertNil(snap.rirEnd)
        XCTAssertEqual(snap.rir, 2)
    }

    // MARK: - 11) Prescription note behavior

    func test_prescriptionNote_neverBlindlyCarriesOver() {
        let cases: [(Adapter.Choice, Bool, Bool)] = [
            (.keepCurrentPlan, true, false),
            (.keepCurrentPlan, false, true),
            (.keepCurrentPlan, false, false),
            (.resetPlan, true, false),
            (.resetPlan, false, false),
        ]
        for (choice, old, new) in cases {
            let current = old ? durationPlan() : repsPlan()
            let outcome = Adapter.outcome(
                choice: choice, current: current,
                oldIsTimeBased: old, newIsTimeBased: new,
                resetSource: repsResetSource()
            )
            XCTAssertNotEqual(
                outcome.sessionPlan.slotNotes, current.slotNotes,
                "old prescription note carried over for \(choice) \(old) → \(new)"
            )
            XCTAssertNil(outcome.sessionPlan.slotNotes)
        }
    }

    // MARK: - Nil / empty current plan

    func test_keep_withNoCurrentPlan_producesEmptyPlanOfNewType() {
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan, current: nil,
            oldIsTimeBased: false, newIsTimeBased: true,
            resetSource: durationResetSource()
        )
        XCTAssertTrue(outcome.sessionPlan.usesDuration)
        XCTAssertNil(outcome.sessionPlan.sets)
        XCTAssertNil(outcome.sessionPlan.tempo)
        XCTAssertNil(outcome.sessionPlan.slotNotes)
    }

    // MARK: - appDefaults reflects AppSettings (no history prefill)

    func test_appDefaults_matchesAppSettingsAndCarriesNoWarmupsOrNote() {
        let reps = Adapter.ResetSource.appDefaults(isTimeBased: false)
        XCTAssertEqual(reps.sets, AppSettings.defaultSets)
        XCTAssertEqual(reps.repMin, AppSettings.defaultRepMin)
        XCTAssertEqual(reps.repMax, AppSettings.defaultRepMax)
        XCTAssertEqual(
            reps.restSecondsBetweenSets, AppSettings.defaultRestBetweenSets)
        XCTAssertNil(reps.tempo)
        XCTAssertNil(reps.slotNotes)

        let duration = Adapter.ResetSource.appDefaults(isTimeBased: true)
        XCTAssertEqual(duration.sets, AppSettings.defaultSets)
        // A duration reset source never carries reps.
        XCTAssertNil(duration.repMin)
        XCTAssertNil(duration.repMax)
        XCTAssertNil(duration.tempo)
        XCTAssertNil(duration.slotNotes)
    }
}
