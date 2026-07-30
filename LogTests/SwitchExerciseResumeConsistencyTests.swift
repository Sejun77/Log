import SwiftData
import XCTest

@testable import Log

/// Entry #12 P1 — resume consistency after a mid-workout exercise switch.
///
/// The reported bug had two halves. The switch itself corrupted the slot's set
/// count (covered value-level in `ExerciseSwitchPlanAdapterTests`), and the two
/// ways back into a running workout disagreed about what the plan even was:
///
///   * "Resume workout" pushed `ActiveWorkoutGuard.activePlan` — the live plan.
///   * `StartWorkoutFromRoutineView` always called
///     `WorkoutResumeService.rebuildPlan(...)`, reconstructing from the ROUTINE
///     TEMPLATE — so a switched slot came back with the template's set count and
///     the replaced exercise's tracking type (duration fields on a reps/weight
///     exercise).
///
/// These pin both halves of the fix: the routing decision
/// (`activeWorkoutPlanSource`) and the cold-restart rebuild's new
/// session-snapshot sourcing.
@MainActor
final class SwitchExerciseResumeConsistencyTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    @discardableResult
    private func makeExercise(
        _ name: String,
        isTimeBased: Bool = false,
        equipment: String? = nil
    ) -> Exercise {
        let e = Exercise(name: name, isCustom: true)
        e.isTimeBased = isTimeBased
        e.equipmentType = equipment
        context.insert(e)
        return e
    }

    /// A one-slot routine whose slot carries a full duration-based prescription
    /// (the "Plank programmed for 2 × 30–45s" case from the bug report).
    private func makeDurationRoutine(
        slotExercise: Exercise
    ) -> (routine: Routine, re: RoutineExercise) {
        let p = SlotPrescription()
        p.usesDuration = true
        p.sets = 2
        p.durationMinSeconds = 30
        p.durationMaxSeconds = 45
        p.restSecondsBetweenSets = 90
        p.tempo = "3-1-3-0"
        context.insert(p)

        let re = RoutineExercise(
            exercise: slotExercise, order: 0, setTemplates: [])
        re.prescription = p
        re.templateNotes = "Elbows under shoulders"
        context.insert(re)

        let block = RoutineBlock(isSuperset: false, order: 0, exercises: [re])
        context.insert(block)
        let routine = Routine(name: "Core", blocks: [block])
        context.insert(routine)
        return (routine, re)
    }

    /// The `WorkoutItem` a switch writes for the swapped-in exercise, carrying
    /// the adapted session snapshot that `populateSnapshotFields` freezes.
    @discardableResult
    private func makeSwappedItem(
        exercise: Exercise,
        slotID: UUID,
        snapshot: PlannedPrescriptionSnapshot?,
        templateNotes: String? = nil
    ) -> WorkoutItem {
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        item.routineSlotID = slotID
        item.exerciseNameSnapshot = exercise.name
        item.templateNotesSnapshot = templateNotes
        if let snapshot {
            context.insert(snapshot)
            item.plannedPrescriptionSnapshot = snapshot
        }
        context.insert(item)
        return item
    }

    /// The snapshot a Plank → Bench Press "Keep current plan" switch produces:
    /// set count and rest preserved, tracking type flipped, duration + tempo
    /// cleared.
    private func adaptedBenchSnapshot() -> PlannedPrescriptionSnapshot {
        PlannedPrescriptionSnapshot(
            sets: 2,
            repMin: nil,
            repMax: nil,
            restSecondsBetweenSets: 90,
            restSecondsAfterExercise: nil,
            rir: 2,
            rpe: nil,
            tempo: nil,
            durationMinSeconds: nil,
            durationMaxSeconds: nil,
            usesDuration: false,
            equipment: "Barbell",
            setupNotes: nil
        )
    }

    private func makeWorkout(
        routine: Routine, items: [WorkoutItem]
    ) -> Workout {
        let w = Workout(
            routineName: routine.name,
            routineID: routine.id,
            routineVariantID: nil,
            items: items
        )
        context.insert(w)
        return w
    }

    // MARK: - 6) Resume routing: no entry point re-derives a live session

    func test_planSource_activeSessionAlwaysUsesLivePlan() {
        // A running session with its in-memory plan intact: BOTH entry points
        // resolve to the live plan, so neither can reinterpret it.
        XCTAssertEqual(
            activeWorkoutPlanSource(
                hasActiveWorkoutForThisRoutine: true, hasLiveActivePlan: true),
            .liveActiveSession)
    }

    func test_planSource_rebuildOnlyAfterColdRestart() {
        // The in-memory plan is gone — a rebuild is the only option left, and
        // is the ONLY case that may reconstruct.
        XCTAssertEqual(
            activeWorkoutPlanSource(
                hasActiveWorkoutForThisRoutine: true, hasLiveActivePlan: false),
            .coldRestartRebuild)
    }

    func test_planSource_noActiveSessionStartsFresh() {
        XCTAssertEqual(
            activeWorkoutPlanSource(
                hasActiveWorkoutForThisRoutine: false, hasLiveActivePlan: true),
            .freshStart)
        XCTAssertEqual(
            activeWorkoutPlanSource(
                hasActiveWorkoutForThisRoutine: false, hasLiveActivePlan: false),
            .freshStart)
    }

    // MARK: - 6/7) Cold-restart rebuild honors the switched session plan

    func test_rebuild_swappedSlot_restoresSessionSnapshotNotTemplate() {
        // Plank (2 × 30–45s, duration) programmed; switched to Bench Press
        // mid-session with "Keep current plan".
        let plank = makeExercise("Plank", isTimeBased: true)
        let bench = makeExercise("Bench Press", equipment: "Barbell")
        let (routine, re) = makeDurationRoutine(slotExercise: plank)

        let item = makeSwappedItem(
            exercise: bench, slotID: re.slotID,
            snapshot: adaptedBenchSnapshot())
        let w = makeWorkout(routine: routine, items: [item])
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let slot = plan?.blocks.first?.exercises.first
        XCTAssertNotNil(slot)

        // The switched-in exercise, in ITS tracking type.
        XCTAssertEqual(slot?.name, "Bench Press")
        XCTAssertEqual(slot?.currentExerciseID, bench.id)
        XCTAssertEqual(slot?.isTimeBased, false)

        // The snapshot restored is the SESSION's, not the routine template's:
        // no duration, no tempo, and the template's Plank prescription is
        // nowhere to be seen.
        XCTAssertEqual(slot?.prescriptionSnapshot?.usesDuration, false)
        XCTAssertNil(slot?.prescriptionSnapshot?.durationMinSeconds)
        XCTAssertNil(slot?.prescriptionSnapshot?.durationMaxSeconds)
        XCTAssertNil(slot?.prescriptionSnapshot?.tempo)
        XCTAssertEqual(slot?.prescriptionSnapshot?.equipment, "Barbell")

        // Set count survives the round trip (the reported 2 → 3 regression).
        XCTAssertEqual(slot?.prescriptionSnapshot?.sets, 2)
        XCTAssertEqual(slot?.templates.count, 2)
        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: nil,
                snapshot: slot?.prescriptionSnapshot,
                resolvedTemplates: slot?.templates ?? []),
            2)
    }

    func test_rebuild_swappedSlot_dropsTemplateWarmupsTechniquesAndNote() {
        // The routine slot carries a warm-up, a technique, and a slot note that
        // all describe the REPLACED exercise. A switched slot must not
        // resurrect them from the template on resume.
        let plank = makeExercise("Plank", isTimeBased: true)
        let bench = makeExercise("Bench Press", equipment: "Barbell")
        let (routine, re) = makeDurationRoutine(slotExercise: plank)

        let step = WarmupStep(
            order: 0, kind: .percentage, reps: 10,
            percentOfWorking: 50)
        context.insert(step)
        let scheme = WarmupScheme(name: "Standard", steps: [step])
        context.insert(scheme)
        re.prescription?.warmupScheme = scheme

        let tp = TechniquePlan(order: 0, type: .toFailure)
        context.insert(tp)
        re.prescription?.techniquePlans = [tp]

        // The switch cleared all three, so the frozen item carries none.
        let item = makeSwappedItem(
            exercise: bench, slotID: re.slotID,
            snapshot: adaptedBenchSnapshot(), templateNotes: nil)
        let w = makeWorkout(routine: routine, items: [item])
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let slot = plan?.blocks.first?.exercises.first

        XCTAssertEqual(slot?.warmupStepsSnapshot.count, 0)
        XCTAssertEqual(slot?.techniquePlansSnapshot.count, 0)
        XCTAssertNil(slot?.templateNotesSnapshot)
        XCTAssertNotEqual(
            slot?.templateNotesSnapshot, "Elbows under shoulders")
    }

    /// A slot that was never switched must behave exactly as before — the
    /// template remains its source, warm-ups and notes included.
    func test_rebuild_nonSwappedSlot_stillReadsTemplate() {
        let plank = makeExercise("Plank", isTimeBased: true)
        let (routine, re) = makeDurationRoutine(slotExercise: plank)

        let step = WarmupStep(
            order: 0, kind: .percentage, reps: 10, percentOfWorking: 50)
        context.insert(step)
        let scheme = WarmupScheme(name: "Standard", steps: [step])
        context.insert(scheme)
        re.prescription?.warmupScheme = scheme

        let w = makeWorkout(routine: routine, items: [])
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let slot = plan?.blocks.first?.exercises.first

        XCTAssertEqual(slot?.name, "Plank")
        XCTAssertEqual(slot?.isTimeBased, true)
        XCTAssertEqual(slot?.prescriptionSnapshot?.usesDuration, true)
        XCTAssertEqual(slot?.prescriptionSnapshot?.durationMaxSeconds, 45)
        XCTAssertEqual(slot?.prescriptionSnapshot?.sets, 2)
        XCTAssertEqual(slot?.warmupStepsSnapshot.count, 1)
        XCTAssertEqual(slot?.templateNotesSnapshot, "Elbows under shoulders")
    }

    /// A session switched BEFORE this fix shipped has no frozen session
    /// snapshot. The rebuild must still heal it into a single-mode
    /// prescription rather than restoring the replaced exercise's duration
    /// fields onto a reps/weight exercise.
    func test_rebuild_legacySwapWithoutSessionSnapshot_adaptsTrackingType() {
        let plank = makeExercise("Plank", isTimeBased: true)
        let bench = makeExercise("Bench Press", equipment: "Barbell")
        let (routine, re) = makeDurationRoutine(slotExercise: plank)

        // No plannedPrescriptionSnapshot — the pre-fix shape.
        let item = makeSwappedItem(
            exercise: bench, slotID: re.slotID, snapshot: nil)
        let w = makeWorkout(routine: routine, items: [item])
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let slot = plan?.blocks.first?.exercises.first

        XCTAssertEqual(slot?.name, "Bench Press")
        XCTAssertEqual(slot?.isTimeBased, false)
        // Adapted, not mixed: the Plank duration + tempo do not survive.
        XCTAssertEqual(slot?.prescriptionSnapshot?.usesDuration, false)
        XCTAssertNil(slot?.prescriptionSnapshot?.durationMinSeconds)
        XCTAssertNil(slot?.prescriptionSnapshot?.durationMaxSeconds)
        XCTAssertNil(slot?.prescriptionSnapshot?.tempo)
        // Set count and rest are still the ones the user was training with.
        XCTAssertEqual(slot?.prescriptionSnapshot?.sets, 2)
        XCTAssertEqual(slot?.prescriptionSnapshot?.restSecondsBetweenSets, 90)
    }

    // MARK: - 7) Set-count persistence across leave/return

    /// `persistSessionPlans` / `restoreSessionPlansFromAppState` round-trip the
    /// slot plan through `AppState.sessionPlansJSON`. The switch now writes
    /// through this path immediately, so leaving and returning to the workout
    /// restores the switched plan — not the pre-switch one.
    func test_sessionPlanJSON_roundTripsSwitchedPlan() {
        let slotID = UUID()
        let outcome = ExerciseSwitchPlanAdapter.outcome(
            choice: .keepCurrentPlan,
            current: {
                var p = SessionPlan()
                p.usesDuration = true
                p.sets = 2
                p.durationMaxSeconds = 45
                p.restSecondsBetweenSets = 90
                p.rir = 2
                p.tempo = "3-1-3-0"
                p.slotNotes = "Elbows under shoulders"
                return p
            }(),
            oldIsTimeBased: true,
            newIsTimeBased: false,
            resetSource: .appDefaults(isTimeBased: false)
        )

        // Encode exactly as `persistSessionPlans` does.
        let encoded = try? JSONEncoder().encode(
            [slotID.uuidString: outcome.sessionPlan])
        XCTAssertNotNil(encoded)

        // Decode exactly as `restoreSessionPlansFromAppState` does.
        let decoded = try? JSONDecoder().decode(
            [String: SessionPlan].self, from: encoded ?? Data())
        let restored = decoded?[slotID.uuidString]

        XCTAssertEqual(restored?.sets, 2, "set count must survive leave/return")
        XCTAssertEqual(restored?.restSecondsBetweenSets, 90)
        XCTAssertEqual(restored?.rir, 2)
        XCTAssertEqual(restored?.usesDuration, false)
        XCTAssertNil(restored?.durationMaxSeconds)
        XCTAssertNil(restored?.tempo)
        XCTAssertNil(restored?.slotNotes)
    }

    /// Switch-time last-performance prefill is draft-only, so it must not
    /// change what either resume path restores. The switched-in exercise has
    /// history that differs sharply from the plan; the rebuilt plan must still
    /// report the frozen session values.
    func test_rebuild_afterSwitchWithPrefill_restoresPlanNotHistory() {
        let plank = makeExercise("Plank", isTimeBased: true)
        let bench = makeExercise("Bench Press", equipment: "Barbell")
        let (routine, re) = makeDurationRoutine(slotExercise: plank)

        // Bench Press history that prefill would surface: 5 sets of 12 × 95.
        let past = Workout(
            date: Date(timeIntervalSinceReferenceDate: 86_400), items: [])
        past.completedAt = Date(timeIntervalSinceReferenceDate: 90_000)
        context.insert(past)
        let pastLog = SetLog(
            indexInExercise: 0, kind: .working, reps: 12, weight: 95,
            durationSeconds: nil, subIndex: nil)
        context.insert(pastLog)
        let pastItem = WorkoutItem(exercise: bench, setLogs: [pastLog])
        context.insert(pastItem)
        past.items.append(pastItem)

        // The live session: switched to Bench Press, plan kept at 2 sets.
        let item = makeSwappedItem(
            exercise: bench, slotID: re.slotID,
            snapshot: adaptedBenchSnapshot())
        let w = makeWorkout(routine: routine, items: [item])
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let slot = plan?.blocks.first?.exercises.first

        // The plan is the switch's, not the history's.
        XCTAssertEqual(slot?.prescriptionSnapshot?.sets, 2)
        XCTAssertEqual(slot?.templates.count, 2)
        XCTAssertNil(
            slot?.prescriptionSnapshot?.repMin,
            "prefill must not write a rep range into the plan")
        XCTAssertNil(slot?.prescriptionSnapshot?.repMax)
        XCTAssertEqual(slot?.prescriptionSnapshot?.restSecondsBetweenSets, 90)
        XCTAssertEqual(slot?.prescriptionSnapshot?.rir, 2)
        XCTAssertEqual(slot?.prescriptionSnapshot?.usesDuration, false)

        // Meanwhile the history prefill WOULD have drawn on is really there —
        // proving the plan's independence isn't just an absence of data.
        let suggestions = LastPerformancePrefillService.suggestions(
            forExerciseID: bench.id, in: [past])
        XCTAssertEqual(suggestions[0]?.reps, 12)
        XCTAssertEqual(suggestions[0]?.weight, 95)
    }

    /// Finished History records the values actually logged, while the frozen
    /// plan snapshot still records the switched plan — prefill influences
    /// neither. Logged values here match none of: the plan, or the history
    /// prefill would have suggested.
    func test_history_recordsLoggedValuesNotPlanOrPrefill() {
        let plank = makeExercise("Plank", isTimeBased: true)
        let bench = makeExercise("Bench Press", equipment: "Barbell")
        let (routine, re) = makeDurationRoutine(slotExercise: plank)

        let item = makeSwappedItem(
            exercise: bench, slotID: re.slotID,
            snapshot: adaptedBenchSnapshot())

        // The user edited the prefilled drafts before logging.
        let logged = SetLog(
            indexInExercise: 0, kind: .working, reps: 7, weight: 72.5,
            durationSeconds: nil, subIndex: nil)
        context.insert(logged)
        item.setLogs = [logged]

        let w = makeWorkout(routine: routine, items: [item])
        w.completedAt = Date()
        try? context.save()

        // History shows what was performed.
        let savedLog = w.items.first?.setLogs.first
        XCTAssertEqual(savedLog?.reps, 7)
        XCTAssertEqual(savedLog?.weight, 72.5)
        XCTAssertNil(savedLog?.durationSeconds)

        // And the frozen plan is still the switched plan — unchanged by either
        // prefill or the logged values.
        let snap = w.items.first?.plannedPrescriptionSnapshot
        XCTAssertEqual(snap?.sets, 2)
        XCTAssertEqual(snap?.restSecondsBetweenSets, 90)
        XCTAssertEqual(snap?.usesDuration, false)
        XCTAssertNil(snap?.repMin)
        XCTAssertNil(snap?.repMax)
        XCTAssertNil(snap?.tempo)
        XCTAssertNil(snap?.durationMaxSeconds)
    }

    /// AppState can actually hold the encoded plans (the field the switch now
    /// writes through on every swap, not just on Edit Plan dismiss).
    func test_appState_persistsSessionPlansJSON() {
        let appState = AppState()
        context.insert(appState)

        var plan = SessionPlan()
        plan.sets = 2
        plan.usesDuration = false
        let slotID = UUID()
        appState.sessionPlansJSON =
            (try? JSONEncoder().encode([slotID.uuidString: plan]))
            .flatMap { String(data: $0, encoding: .utf8) }
        try? context.save()

        let fetched = try? context.fetch(FetchDescriptor<AppState>()).first
        XCTAssertNotNil(fetched?.sessionPlansJSON)
        let data = fetched?.sessionPlansJSON?.data(using: .utf8) ?? Data()
        let decoded = try? JSONDecoder().decode(
            [String: SessionPlan].self, from: data)
        XCTAssertEqual(decoded?[slotID.uuidString]?.sets, 2)
    }

    // MARK: - 12) History

    /// A finished workout's History row reads the frozen session snapshot, so a
    /// switched slot records the plan the user actually trained — the switched
    /// exercise's tracking type, set count, and (cleared) note.
    func test_history_recordsSwitchedSessionPlan() {
        let plank = makeExercise("Plank", isTimeBased: true)
        let bench = makeExercise("Bench Press", equipment: "Barbell")
        let (routine, re) = makeDurationRoutine(slotExercise: plank)

        let item = makeSwappedItem(
            exercise: bench, slotID: re.slotID,
            snapshot: adaptedBenchSnapshot(), templateNotes: nil)
        let w = makeWorkout(routine: routine, items: [item])
        w.completedAt = Date()
        try? context.save()

        let snap = w.items.first?.plannedPrescriptionSnapshot
        XCTAssertEqual(w.items.first?.exercise?.name, "Bench Press")
        XCTAssertEqual(snap?.usesDuration, false)
        XCTAssertEqual(snap?.sets, 2)
        XCTAssertNil(snap?.durationMaxSeconds)
        XCTAssertNil(snap?.tempo)
        XCTAssertNil(w.items.first?.templateNotesSnapshot)
        XCTAssertNotEqual(
            w.items.first?.templateNotesSnapshot, "Elbows under shoulders")
    }

    /// Old completed History is append-only: editing the routine template after
    /// the fact (or the fix shipping at all) must not rewrite a finished row.
    func test_history_oldCompletedWorkoutUnchangedByTemplateEdit() {
        let plank = makeExercise("Plank", isTimeBased: true)
        let (routine, re) = makeDurationRoutine(slotExercise: plank)

        let frozen = PlannedPrescriptionSnapshot(
            sets: 2, repMin: nil, repMax: nil,
            restSecondsBetweenSets: 90, restSecondsAfterExercise: nil,
            rir: nil, rpe: nil, tempo: nil,
            durationMinSeconds: 30, durationMaxSeconds: 45,
            usesDuration: true, equipment: nil, setupNotes: nil)
        let item = makeSwappedItem(
            exercise: plank, slotID: re.slotID, snapshot: frozen,
            templateNotes: "Elbows under shoulders")
        let w = makeWorkout(routine: routine, items: [item])
        w.completedAt = Date()
        try? context.save()

        // Mutate the template afterwards, the way a later routine edit would.
        re.prescription?.sets = 5
        re.prescription?.durationMaxSeconds = 90
        re.templateNotes = "Rewritten note"
        try? context.save()

        let snap = w.items.first?.plannedPrescriptionSnapshot
        XCTAssertEqual(snap?.sets, 2, "finished History must stay frozen")
        XCTAssertEqual(snap?.durationMaxSeconds, 45)
        XCTAssertEqual(snap?.usesDuration, true)
        XCTAssertEqual(
            w.items.first?.templateNotesSnapshot, "Elbows under shoulders")
    }

    // MARK: - 8) Duration tempo cleanup at the persistence boundary

    /// A duration-based slot never freezes tempo into a NEW session snapshot,
    /// so nothing downstream (active workout, History) can render one.
    func test_snapshotPayload_dropsTempoForDurationPrescription() {
        let plank = makeExercise("Plank", isTimeBased: true)
        let p = SlotPrescription()
        p.usesDuration = true
        p.sets = 2
        p.tempo = "3-1-3-0"  // stale value from before the slot became timed
        context.insert(p)
        try? context.save()

        XCTAssertNil(p.effectiveTempo)
        let payload = PrescriptionSnapshotPayload(from: p, exercise: plank)
        XCTAssertNil(payload.tempo)

        // Non-duration behavior is unchanged.
        let bench = makeExercise("Bench Press")
        let rp = SlotPrescription()
        rp.usesDuration = false
        rp.tempo = "3-1-3-0"
        context.insert(rp)
        XCTAssertEqual(rp.effectiveTempo, "3-1-3-0")
        XCTAssertEqual(
            PrescriptionSnapshotPayload(from: rp, exercise: bench).tempo,
            "3-1-3-0")
    }

    /// Stale tempo already frozen on an OLD History row is suppressed at read
    /// time without rewriting the stored value.
    func test_frozenSnapshot_staleTempoIgnoredNotRewritten() {
        let stale = PlannedPrescriptionSnapshot(
            sets: 2, repMin: nil, repMax: nil,
            restSecondsBetweenSets: nil, restSecondsAfterExercise: nil,
            rir: nil, rpe: nil, tempo: "3-1-3-0",
            durationMinSeconds: 30, durationMaxSeconds: 45,
            usesDuration: true, equipment: nil, setupNotes: nil)
        context.insert(stale)

        XCTAssertNil(stale.effectiveTempo, "duration row must not show tempo")
        XCTAssertEqual(
            stale.tempo, "3-1-3-0", "stored History value must not be rewritten")
    }
}
