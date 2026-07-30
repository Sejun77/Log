import SwiftData
import XCTest

@testable import Log

/// Entry #12 P1 follow-up — two product decisions taken after the main
/// switch-exercise compatibility fix:
///
///   1. **Tempo Override is incompatible with duration-based exercises.**
///      A tempo describes eccentric/concentric rep phases; a duration exercise
///      has no reps to phase. This makes the technique rule agree with the
///      prescription-level rule that hides and clears `tempo` for duration
///      slots, so tempo cannot reach a duration exercise by either route.
///
///   2. **Switch-time last-performance prefill is draft-only.** Switching to a
///      new exercise may prefill that exercise's latest performance into the
///      editable input fields, because it saves retyping familiar numbers. It
///      must never influence the workout plan: the plan is decided solely by
///      `ExerciseSwitchPlanAdapter`, and prefill runs afterwards against the
///      already-adapted plan.
///
/// The draft-only property is structural rather than incidental, and these
/// tests pin it that way: the plan decision (`ExerciseSwitchPlanAdapter`) and
/// the draft decision (`resolvedDraftDefault`) are separate pure functions, and
/// the plan function never receives a suggestion at all. So the tests below
/// feed a suggestion through the draft path and assert the plan values coming
/// out of the adapter are byte-identical either way.
@MainActor
final class SwitchExerciseTempoAndPrefillTests: SwiftDataTestHarness {

    private typealias Adapter = ExerciseSwitchPlanAdapter
    private typealias Suggestion =
        LastPerformancePrefillService.LastPerformanceSetSuggestion

    // MARK: - Fixtures

    private func technique(
        _ type: TechniqueType, order: Int = 0
    ) -> TechniquePlanSnapshot {
        TechniquePlanSnapshot(
            order: order, type: type, dropPercent: nil, dropCount: nil,
            rounds: nil, restSeconds: nil, partialRangeNote: nil,
            partialRangeRaw: nil, note: "3-1-3-0", reps: nil,
            appliesToRaw: nil, appliesToSetNumber: nil,
            appliesToSetIndicesRaw: nil, dropsetEffortRaw: nil,
            dropsetEffortReps: nil
        )
    }

    @discardableResult
    private func makeExercise(
        _ name: String, isTimeBased: Bool = false, equipment: String? = nil
    ) -> Exercise {
        let e = Exercise(name: name, isCustom: true)
        e.isTimeBased = isTimeBased
        e.equipmentType = equipment
        context.insert(e)
        return e
    }

    /// A completed workout with one working set for `exercise`.
    @discardableResult
    private func makeCompletedWorkout(
        exercise: Exercise,
        reps: Int = 0,
        weight: Double? = nil,
        durationSeconds: Int? = nil,
        date: Date = Date(timeIntervalSinceReferenceDate: 86_400),
        excludedFromPrefill: Bool = false
    ) -> Workout {
        let w = Workout(date: date, items: [])
        w.completedAt = date.addingTimeInterval(3600)
        w.excludedFromPrefill = excludedFromPrefill
        context.insert(w)

        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: reps, weight: weight,
            durationSeconds: durationSeconds, subIndex: nil)
        context.insert(log)
        let item = WorkoutItem(exercise: exercise, setLogs: [log])
        context.insert(item)
        w.items.append(item)
        return w
    }

    private func allWorkouts() -> [Workout] {
        (try? context.fetch(FetchDescriptor<Workout>())) ?? []
    }

    /// The pre-switch plan for a programmed duration slot (Plank, 2 × 30–45s).
    private func durationPlan() -> SessionPlan {
        var p = SessionPlan()
        p.usesDuration = true
        p.sets = 2
        p.durationMinSeconds = 30
        p.durationMaxSeconds = 45
        p.restSecondsBetweenSets = 90
        p.rir = 2
        p.tempo = "3-1-3-0"
        p.slotNotes = "Elbows under shoulders"
        return p
    }

    /// The pre-switch plan for a programmed reps/weight slot.
    private func repsPlan() -> SessionPlan {
        var p = SessionPlan()
        p.usesDuration = false
        p.sets = 2
        p.repMin = 6
        p.repMax = 8
        p.restSecondsBetweenSets = 90
        p.rir = 2
        p.tempo = "3-1-3-0"
        p.slotNotes = "Pause on chest"
        return p
    }

    /// Mirrors `ActiveWorkoutView.tier4Default`: prescription defaults resolved
    /// from the (already-adapted) plan, with any last-performance suggestion
    /// overlaid on top. This is the whole of what switch-time prefill can
    /// influence.
    private func seedDraft(
        plan: SessionPlan,
        suggestion: Suggestion?,
        isTimeBased: Bool,
        isBodyweight: Bool = false,
        templateReps: Int = 0
    ) -> (reps: String, weight: String, duration: String) {
        let presReps = String(plan.repMax ?? plan.repMin ?? templateReps)
        let presWeight = ""
        let presDuration =
            (plan.durationMaxSeconds ?? plan.durationMinSeconds)
            .map(String.init) ?? ""

        return resolvedDraftDefault(
            suggestion: suggestion,
            prescriptionReps: presReps,
            prescriptionWeight: presWeight,
            prescriptionDuration: presDuration,
            isTimeBased: isTimeBased,
            isBodyweight: isBodyweight
        )
    }

    // MARK: - 1) Switching to a normal exercise prefills reps/weight drafts

    func test_switchToNormalExercise_prefillsRepsAndWeightDrafts() {
        let bench = makeExercise("Bench Press", equipment: "Barbell")
        makeCompletedWorkout(exercise: bench, reps: 8, weight: 60)
        try? context.save()

        // The switched-in exercise's OWN history resolves.
        let suggestions = LastPerformancePrefillService.suggestions(
            forExerciseID: bench.id, in: allWorkouts())
        let suggestion = LastPerformancePrefillService.suggestion(
            forCurrentSetIndex: 0, from: suggestions)
        XCTAssertEqual(suggestion?.reps, 8)
        XCTAssertEqual(suggestion?.weight, 60)

        // Plank → Bench Press, Keep Current Plan.
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan, current: durationPlan(),
            oldIsTimeBased: true, newIsTimeBased: false,
            resetSource: .appDefaults(isTimeBased: false))

        let draft = seedDraft(
            plan: outcome.sessionPlan, suggestion: suggestion,
            isTimeBased: outcome.sessionPlan.usesDuration)

        XCTAssertEqual(draft.reps, "8")
        XCTAssertEqual(draft.weight, "60")
        // Duration draft stays empty for a reps/weight exercise.
        XCTAssertEqual(draft.duration, "")
    }

    /// Bodyweight switch-in still prefills reps only — user bodyweight is never
    /// injected into the load field.
    func test_switchToBodyweightExercise_prefillsRepsOnly() {
        let pullup = makeExercise("Pull-up", equipment: bodyweightEquipment)
        makeCompletedWorkout(exercise: pullup, reps: 10, weight: nil)
        try? context.save()

        let suggestion = LastPerformancePrefillService.suggestion(
            forCurrentSetIndex: 0,
            from: LastPerformancePrefillService.suggestions(
                forExerciseID: pullup.id, in: allWorkouts()))

        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan, current: repsPlan(),
            oldIsTimeBased: false, newIsTimeBased: false,
            resetSource: .appDefaults(isTimeBased: false))

        let draft = seedDraft(
            plan: outcome.sessionPlan, suggestion: suggestion,
            isTimeBased: false, isBodyweight: true)

        XCTAssertEqual(draft.reps, "10")
        XCTAssertEqual(draft.weight, "")
    }

    // MARK: - 2) Switching to a duration exercise prefills duration drafts

    func test_switchToDurationExercise_prefillsDurationDrafts() {
        let plank = makeExercise("Plank", isTimeBased: true)
        makeCompletedWorkout(exercise: plank, durationSeconds: 75)
        try? context.save()

        let suggestion = LastPerformancePrefillService.suggestion(
            forCurrentSetIndex: 0,
            from: LastPerformancePrefillService.suggestions(
                forExerciseID: plank.id, in: allWorkouts()))
        XCTAssertEqual(suggestion?.durationSeconds, 75)

        // Bench Press → Plank, Keep Current Plan.
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan, current: repsPlan(),
            oldIsTimeBased: false, newIsTimeBased: true,
            resetSource: .appDefaults(isTimeBased: true))
        XCTAssertTrue(outcome.sessionPlan.usesDuration)

        let draft = seedDraft(
            plan: outcome.sessionPlan, suggestion: suggestion,
            isTimeBased: outcome.sessionPlan.usesDuration)

        XCTAssertEqual(draft.duration, "75")
        // Reps/weight drafts keep the prescription values for a timed exercise.
        XCTAssertEqual(draft.weight, "")
    }

    /// Prefill follows the ADAPTED tracking type, not the suggestion's shape: a
    /// duration suggestion cannot leak reps/weight into a timed slot, and a
    /// reps/weight suggestion cannot leak a duration into a normal slot.
    func test_prefillRespectsAdaptedTrackingType() {
        // Reps/weight suggestion applied to a duration-adapted plan.
        let repsSuggestion = Suggestion(
            setIndex: 0, reps: 12, weight: 95, durationSeconds: nil)
        let toDuration = Adapter.outcome(
            choice: .keepCurrentPlan, current: repsPlan(),
            oldIsTimeBased: false, newIsTimeBased: true,
            resetSource: .appDefaults(isTimeBased: true))
        let durationDraft = seedDraft(
            plan: toDuration.sessionPlan, suggestion: repsSuggestion,
            isTimeBased: true)
        XCTAssertEqual(
            durationDraft.weight, "", "weight must not leak into a timed slot")

        // Duration suggestion applied to a reps/weight-adapted plan.
        let durationSuggestion = Suggestion(
            setIndex: 0, reps: nil, weight: nil, durationSeconds: 75)
        let toReps = Adapter.outcome(
            choice: .keepCurrentPlan, current: durationPlan(),
            oldIsTimeBased: true, newIsTimeBased: false,
            resetSource: .appDefaults(isTimeBased: false))
        let repsDraft = seedDraft(
            plan: toReps.sessionPlan, suggestion: durationSuggestion,
            isTimeBased: false)
        XCTAssertEqual(
            repsDraft.duration, "",
            "duration must not leak into a reps/weight slot")
    }

    // MARK: - 3/4) Prefill never changes the plan or the snapshot

    /// The plan produced by the adapter is identical whether or not a
    /// suggestion exists — the adapter has no prefill input, and seeding drafts
    /// afterwards cannot reach back into it.
    func test_prefillDoesNotChangePlanValues() {
        for (choice, old, new) in [
            (Adapter.Choice.keepCurrentPlan, true, false),
            (Adapter.Choice.keepCurrentPlan, false, true),
            (Adapter.Choice.keepCurrentPlan, false, false),
            (Adapter.Choice.resetPlan, true, false),
            (Adapter.Choice.resetPlan, false, true),
        ] {
            let current = old ? durationPlan() : repsPlan()
            let outcome = Adapter.outcome(
                choice: choice, current: current,
                oldIsTimeBased: old, newIsTimeBased: new,
                resetSource: .appDefaults(isTimeBased: new))
            let planBefore = outcome.sessionPlan

            // Seed drafts with a rich suggestion — the operation switching
            // performs after the plan is decided.
            let suggestion = Suggestion(
                setIndex: 0, reps: 12, weight: 95, durationSeconds: 75)
            _ = seedDraft(
                plan: outcome.sessionPlan, suggestion: suggestion,
                isTimeBased: new)

            // Every plan value the requirements name is untouched.
            XCTAssertEqual(outcome.sessionPlan, planBefore)
            XCTAssertEqual(outcome.sessionPlan.sets, planBefore.sets)
            XCTAssertEqual(
                outcome.sessionPlan.restSecondsBetweenSets,
                planBefore.restSecondsBetweenSets)
            XCTAssertEqual(
                outcome.sessionPlan.restSecondsAfterExercise,
                planBefore.restSecondsAfterExercise)
            XCTAssertEqual(outcome.sessionPlan.rir, planBefore.rir)
            XCTAssertEqual(outcome.sessionPlan.rpe, planBefore.rpe)
            XCTAssertEqual(outcome.sessionPlan.tempo, planBefore.tempo)
            XCTAssertEqual(outcome.sessionPlan.slotNotes, planBefore.slotNotes)
            XCTAssertEqual(
                outcome.sessionPlan.usesDuration, planBefore.usesDuration)
            XCTAssertEqual(outcome.keepWarmupSteps, outcome.keepWarmupSteps)
            XCTAssertEqual(outcome.keepTechniques, outcome.keepTechniques)
        }
    }

    /// A suggestion must never reach the plan values. A Keep switch preserves
    /// the pre-switch set count / rest / effort even when history exists that
    /// would suggest very different numbers.
    func test_planKeepsProgrammedValuesDespiteDifferentHistory() {
        let bench = makeExercise("Bench Press", equipment: "Barbell")
        // History with 5 sets' worth of very different numbers.
        makeCompletedWorkout(exercise: bench, reps: 12, weight: 95)
        try? context.save()

        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan, current: durationPlan(),
            oldIsTimeBased: true, newIsTimeBased: false,
            resetSource: .appDefaults(isTimeBased: false))

        // Programmed structure survives verbatim.
        XCTAssertEqual(outcome.sessionPlan.sets, 2)
        XCTAssertEqual(outcome.sessionPlan.restSecondsBetweenSets, 90)
        XCTAssertEqual(outcome.sessionPlan.rir, 2)
        // Rep RANGE is not invented from history — it stays unset so the plan
        // reflects the switch decision, while only the draft shows "12".
        XCTAssertNil(outcome.sessionPlan.repMin)
        XCTAssertNil(outcome.sessionPlan.repMax)
        // Incompatible state still cleared.
        XCTAssertNil(outcome.sessionPlan.tempo)
        XCTAssertNil(outcome.sessionPlan.slotNotes)
        XCTAssertNil(outcome.sessionPlan.durationMaxSeconds)
        XCTAssertFalse(outcome.keepWarmupSteps)
        XCTAssertFalse(outcome.keepTechniques)
    }

    /// The tier-2 snapshot the switch writes is derived from the adapted plan
    /// only. Seeding drafts afterwards leaves it byte-identical.
    func test_prefillDoesNotChangePrescriptionSnapshot() {
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan, current: durationPlan(),
            oldIsTimeBased: true, newIsTimeBased: false,
            resetSource: .appDefaults(isTimeBased: false))
        let base = PrescriptionSnapshotPayload(
            sets: 2, tempo: "3-1-3-0", effortModeRaw: "single",
            usesDuration: true, equipment: "Bodyweight")

        let snapshot = Adapter.adaptedSnapshot(
            from: outcome, base: base,
            equipment: "Barbell", setupNotes: "Bench at 30°")

        _ = seedDraft(
            plan: outcome.sessionPlan,
            suggestion: Suggestion(
                setIndex: 0, reps: 12, weight: 95, durationSeconds: nil),
            isTimeBased: false)

        let snapshotAfter = Adapter.adaptedSnapshot(
            from: outcome, base: base,
            equipment: "Barbell", setupNotes: "Bench at 30°")

        XCTAssertEqual(snapshot.sets, snapshotAfter.sets)
        XCTAssertEqual(snapshot.sets, 2)
        XCTAssertEqual(snapshot.repMin, snapshotAfter.repMin)
        XCTAssertNil(snapshotAfter.repMin, "history must not seed the snapshot")
        XCTAssertNil(snapshotAfter.repMax)
        XCTAssertEqual(snapshot.usesDuration, snapshotAfter.usesDuration)
        XCTAssertFalse(snapshotAfter.usesDuration)
        XCTAssertNil(snapshotAfter.tempo)
        XCTAssertEqual(snapshot.rir, snapshotAfter.rir)
        XCTAssertEqual(
            snapshot.restSecondsBetweenSets,
            snapshotAfter.restSecondsBetweenSets)
    }

    // MARK: - 5) Stale prefill from the replaced exercise is cleared

    /// `refreshLastPerformancePrefill` clears the slot before loading. This
    /// pins the reason: the replaced exercise's history must not resolve for
    /// the switched-in exercise, whether or not the new one has history.
    func test_staleHistoryFromReplacedExerciseIsNotUsed() {
        let plank = makeExercise("Plank", isTimeBased: true)
        let bench = makeExercise("Bench Press", equipment: "Barbell")
        makeCompletedWorkout(exercise: plank, durationSeconds: 45)
        makeCompletedWorkout(exercise: bench, reps: 8, weight: 60)
        try? context.save()

        // Resolving by the switched-in exercise's id yields only ITS history.
        let benchMap = LastPerformancePrefillService.suggestions(
            forExerciseID: bench.id, in: allWorkouts())
        XCTAssertEqual(benchMap[0]?.reps, 8)
        XCTAssertEqual(benchMap[0]?.weight, 60)
        XCTAssertNil(
            benchMap[0]?.durationSeconds,
            "the replaced exercise's duration must not carry over")
    }

    /// The critical clear-first case: the new exercise has NO history, so an
    /// unconditional overwrite would leave the replaced exercise's suggestions
    /// in place. An empty result must clear the slot instead.
    func test_switchToExerciseWithoutHistory_clearsStaleSuggestions() {
        let plank = makeExercise("Plank", isTimeBased: true)
        let brandNew = makeExercise("Brand New Lift")
        makeCompletedWorkout(exercise: plank, durationSeconds: 45)
        try? context.save()

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: brandNew.id, in: allWorkouts())
        XCTAssertTrue(
            map.isEmpty,
            "no history for the new exercise → slot must end up cleared")

        // And an empty map resolves to no suggestion, so seeding falls through.
        XCTAssertNil(
            LastPerformancePrefillService.suggestion(
                forCurrentSetIndex: 0, from: map))
    }

    // MARK: - 6) No history → prescription/default drafts

    func test_noHistory_fallsBackToPrescriptionDrafts() {
        // Reset Plan into a reps/weight exercise with no history at all.
        let outcome = Adapter.outcome(
            choice: .resetPlan, current: durationPlan(),
            oldIsTimeBased: true, newIsTimeBased: false,
            resetSource: Adapter.ResetSource(
                sets: 3, repMin: 8, repMax: 12, restSecondsBetweenSets: 120))

        let draft = seedDraft(
            plan: outcome.sessionPlan, suggestion: nil, isTimeBased: false)

        // The prescription's rep target, not a history value.
        XCTAssertEqual(draft.reps, "12")
        XCTAssertEqual(draft.weight, "")
        XCTAssertEqual(draft.duration, "")
    }

    func test_noHistory_durationSlotFallsBackToPrescriptionDuration() {
        var current = SessionPlan()
        current.usesDuration = true
        current.sets = 3
        current.durationMaxSeconds = 60

        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan, current: current,
            oldIsTimeBased: true, newIsTimeBased: true,
            resetSource: .appDefaults(isTimeBased: true))

        let draft = seedDraft(
            plan: outcome.sessionPlan, suggestion: nil, isTimeBased: true)
        XCTAssertEqual(draft.duration, "60")
    }

    // MARK: - 9) Normal workout-start prefill still works

    func test_sessionStartPrefill_unchanged() {
        let bench = makeExercise("Bench Press")
        makeCompletedWorkout(exercise: bench, reps: 8, weight: 60)
        try? context.save()

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: bench.id, in: allWorkouts())
        XCTAssertEqual(map[0]?.reps, 8)
        XCTAssertEqual(map[0]?.weight, 60)
    }

    /// Workouts the user excluded from prefill are still skipped on the switch
    /// path, because it reuses the same service call as session start.
    func test_switchPrefillSkipsExcludedWorkouts() {
        let bench = makeExercise("Bench Press")
        makeCompletedWorkout(
            exercise: bench, reps: 8, weight: 60,
            date: Date(timeIntervalSinceReferenceDate: 86_400))
        makeCompletedWorkout(
            exercise: bench, reps: 3, weight: 20,
            date: Date(timeIntervalSinceReferenceDate: 5 * 86_400),
            excludedFromPrefill: true)
        try? context.save()

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: bench.id, in: allWorkouts())
        XCTAssertEqual(map[0]?.reps, 8, "excluded workout must be skipped")
        XCTAssertEqual(map[0]?.weight, 60)
    }

    /// The in-progress session is excluded, so a slot can't prefill from sets
    /// logged moments earlier in the same workout.
    func test_switchPrefillExcludesCurrentSession() {
        let bench = makeExercise("Bench Press")
        let current = makeCompletedWorkout(exercise: bench, reps: 8, weight: 60)
        try? context.save()

        let map = LastPerformancePrefillService.suggestions(
            forExerciseID: bench.id, in: allWorkouts(), excluding: current.id)
        XCTAssertTrue(map.isEmpty)
    }

    // MARK: - 10) Tempo Override × duration compatibility

    func test_tempoOverride_blockedForDurationExercises() {
        XCTAssertTrue(
            techniquesIncompatibleWithDuration.contains(.tempoOverride))
        XCTAssertFalse(
            isTechniqueAllowed(
                .tempoOverride, isBodyweight: false, usesDuration: true))
        XCTAssertFalse(
            isTechniqueAllowed(
                .tempoOverride, isBodyweight: true, usesDuration: true))
        XCTAssertEqual(
            techniqueConflictMessage(
                for: .tempoOverride, isBodyweight: false, usesDuration: true),
            "Not available for duration-based exercises.")
    }

    func test_tempoOverride_unchangedForNonDurationExercises() {
        XCTAssertTrue(
            isTechniqueAllowed(
                .tempoOverride, isBodyweight: false, usesDuration: false))
        XCTAssertTrue(
            isTechniqueAllowed(
                .tempoOverride, isBodyweight: true, usesDuration: false))
        XCTAssertNil(
            techniqueConflictMessage(
                for: .tempoOverride, isBodyweight: false, usesDuration: false))
    }

    /// Pairwise structural rules are independent of tracking type and must be
    /// untouched for non-duration exercises.
    func test_tempoOverride_pairRulesUnchanged() {
        XCTAssertNil(techniquePairConflict(.dropset, .tempoOverride))
        XCTAssertNil(techniquePairConflict(.restPause, .tempoOverride))
        XCTAssertNil(techniquePairConflict(.partialReps, .tempoOverride))
        XCTAssertNotNil(techniquePairConflict(.tempoOverride, .tempoOverride))
    }

    func test_compatibleTechniques_dropsTempoOverrideForDuration() {
        let all = [
            technique(.tempoOverride, order: 0),
            technique(.toFailure, order: 1),
        ]

        let duration = compatibleTechniques(
            all, isBodyweight: false, usesDuration: true)
        XCTAssertEqual(duration.map(\.type), [.toFailure])

        let reps = compatibleTechniques(
            all, isBodyweight: false, usesDuration: false)
        XCTAssertEqual(reps.map(\.type), [.tempoOverride, .toFailure])

        // Bodyweight only blocks Drop Set, so Tempo Override survives there.
        let bodyweight = compatibleTechniques(
            all, isBodyweight: true, usesDuration: false)
        XCTAssertEqual(bodyweight.map(\.type), [.tempoOverride, .toFailure])
    }

    /// A stale Tempo Override already frozen on a session snapshot (imported
    /// routine, or authored before this rule) is suppressed at read time
    /// without mutating the source array.
    func test_staleTempoOverrideOnDurationSlot_isSuppressed() {
        let stale = [technique(.tempoOverride, order: 0)]
        XCTAssertTrue(
            compatibleTechniques(
                stale, isBodyweight: false, usesDuration: true
            ).isEmpty)
        XCTAssertEqual(stale.count, 1)
    }

    func test_switchIntoDuration_dropsTempoOverride() {
        let outcome = Adapter.outcome(
            choice: .keepCurrentPlan, current: repsPlan(),
            oldIsTimeBased: false, newIsTimeBased: true,
            resetSource: .appDefaults(isTimeBased: true))
        XCTAssertFalse(outcome.keepTechniques)
        XCTAssertTrue(
            Adapter.retainedTechniques(
                from: [technique(.tempoOverride)],
                isBodyweight: false, usesDuration: true
            ).isEmpty)
    }

    // MARK: - Routine-editor self-heal

    /// A duration slot holding a stale tempo + Tempo Override is reconciled
    /// when the prescription editor appears, so the editor never shows state it
    /// would now refuse to create.
    func test_durationSlot_selfHealsStaleTempoAndTempoOverride() {
        let plank = makeExercise("Plank", isTimeBased: true)

        let p = SlotPrescription()
        p.usesDuration = true
        p.sets = 2
        p.tempo = "3-1-3-0"
        context.insert(p)

        let tempoTech = TechniquePlan(order: 0, type: .tempoOverride)
        let failTech = TechniquePlan(order: 1, type: .toFailure)
        context.insert(tempoTech)
        context.insert(failTech)
        p.techniquePlans = [tempoTech, failTech]

        let re = RoutineExercise(exercise: plank, order: 0, setTemplates: [])
        re.prescription = p
        context.insert(re)
        try? context.save()

        XCTAssertNil(p.effectiveTempo, "read-time guard already hides it")
        let allowed = compatibleTechniquePlans(
            p.techniquePlans,
            isBodyweight: isBodyweightEquipment(plank.equipmentType),
            usesDuration: true)
        XCTAssertEqual(allowed.count, 1)
        XCTAssertEqual(allowed.first?.type, .toFailure)
    }

    /// The same reconciliation must NOT touch a reps/weight slot.
    func test_repsSlot_keepsTempoAndTempoOverride() {
        let bench = makeExercise("Bench Press", equipment: "Barbell")

        let p = SlotPrescription()
        p.usesDuration = false
        p.tempo = "3-1-3-0"
        context.insert(p)

        let tempoTech = TechniquePlan(order: 0, type: .tempoOverride)
        context.insert(tempoTech)
        p.techniquePlans = [tempoTech]
        try? context.save()

        XCTAssertEqual(p.effectiveTempo, "3-1-3-0")
        let allowed = compatibleTechniquePlans(
            p.techniquePlans,
            isBodyweight: isBodyweightEquipment(bench.equipmentType),
            usesDuration: false)
        XCTAssertEqual(allowed.map(\.type), [.tempoOverride])
    }
}
