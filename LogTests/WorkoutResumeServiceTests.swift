import SwiftData
import XCTest

@testable import Log

/// Phase 7 stabilization — pins the cold-restart resume contract that
/// `Save & Exit` relies on. `WorkoutResumeService.rebuildPlan(for:in:)` is the
/// pure entry point both `RootTabView.checkForActiveSession` and the in-memory
/// resume banner ultimately delegate to. These tests cover:
///   • primary path (`Routine` still exists)
///   • fallback path (`Routine` deleted / `routineID` nil)
///   • swap reconciliation via matching `routineSlotID`
///   • `exerciseNameSnapshot` fallback when the swapped `Exercise` is deleted
///   • template reconstruction from `SetLog`s
///   • template reconstruction from `PlannedPrescriptionSnapshot`
@MainActor
final class WorkoutResumeServiceTests: SwiftDataTestHarness {

    // MARK: - Fixture helpers

    @discardableResult
    private func makeExercise(name: String, isTimeBased: Bool = false) -> Exercise {
        let e = Exercise(name: name, isCustom: true)
        e.isTimeBased = isTimeBased
        context.insert(e)
        return e
    }

    /// Builds a one-block / one-exercise routine with the given setTemplates
    /// (Tier 1 explicit overrides — deterministic, avoids prescription tiers).
    @discardableResult
    private func makeRoutine(
        name: String,
        slotExercise: Exercise,
        setTemplates: [SetTemplate]
    ) -> (routine: Routine, block: RoutineBlock, re: RoutineExercise) {
        for tpl in setTemplates { context.insert(tpl) }
        let re = RoutineExercise(
            exercise: slotExercise, order: 0, setTemplates: setTemplates
        )
        context.insert(re)
        let block = RoutineBlock(
            isSuperset: false, order: 0, exercises: [re]
        )
        context.insert(block)
        let routine = Routine(name: name, blocks: [block])
        context.insert(routine)
        return (routine, block, re)
    }

    @discardableResult
    private func makeWorkout(
        routineName: String? = nil,
        routineID: UUID? = nil,
        items: [WorkoutItem] = []
    ) -> Workout {
        let w = Workout(
            routineName: routineName,
            routineID: routineID,
            routineVariantID: nil,
            items: items
        )
        context.insert(w)
        return w
    }

    // MARK: - 1) Nil return when no routineID and no items

    func testRebuildPlanReturnsNilWhenNoRoutineIDAndNoItems() {
        let w = makeWorkout(routineName: nil, routineID: nil, items: [])
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        XCTAssertNil(plan)
    }

    // MARK: - 2) Primary path — routineID set and Routine exists

    func testRebuildPlanUsesRoutinePathWhenRoutineExists() {
        let ex = makeExercise(name: "Bench Press")
        let tpl = SetTemplate(kind: .working, targetReps: 8, targetWeight: 60)
        let (routine, _, _) = makeRoutine(
            name: "Push", slotExercise: ex, setTemplates: [tpl]
        )
        let w = makeWorkout(
            routineName: "Push", routineID: routine.id, items: []
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.routineID, routine.id)
        XCTAssertEqual(plan?.routineName, "Push")
        XCTAssertEqual(plan?.blocks.count, 1)
        XCTAssertEqual(plan?.blocks.first?.exercises.count, 1)

        let planEx = plan?.blocks.first?.exercises.first
        XCTAssertEqual(planEx?.name, "Bench Press")
        XCTAssertEqual(planEx?.currentExerciseID, ex.id)
        XCTAssertEqual(planEx?.originalExerciseID, ex.id)
        XCTAssertEqual(planEx?.templates.count, 1)
        XCTAssertEqual(planEx?.templates.first?.targetReps, 8)
        XCTAssertEqual(planEx?.templates.first?.targetWeight, 60)
        XCTAssertEqual(planEx?.templates.first?.kind, .working)
    }

    // MARK: - 3) Fallback path — routineID points at a deleted routine

    func testRebuildPlanFallsBackToItemsWhenRoutineDeleted() {
        let ex = makeExercise(name: "Curl")
        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: 10, weight: 20, restSeconds: 60
        )
        context.insert(log)
        let item = WorkoutItem(exercise: ex, setLogs: [log])
        context.insert(item)
        // routineID points at a UUID that doesn't exist in the store.
        let w = makeWorkout(
            routineName: "Resumed", routineID: UUID(), items: [item]
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.blocks.count, 1)
        XCTAssertEqual(plan?.blocks.first?.exercises.count, 1)
        XCTAssertEqual(plan?.blocks.first?.exercises.first?.name, "Curl")
        XCTAssertEqual(plan?.routineName, "Resumed")
    }

    // MARK: - 4) Swap reconciliation — WorkoutItem.exercise differs from slot exercise

    func testRebuildPlanReconcilesExerciseSwapFromWorkoutItem() {
        let original = makeExercise(name: "Incline Press")
        let swappedIn = makeExercise(name: "Flat Press")
        let tpl = SetTemplate(kind: .working, targetReps: 8, targetWeight: 50)
        let (routine, _, re) = makeRoutine(
            name: "Push", slotExercise: original, setTemplates: [tpl]
        )
        // WorkoutItem carries the post-swap exercise + matches the slot's slotID.
        let item = WorkoutItem(exercise: swappedIn, setLogs: [])
        item.routineSlotID = re.slotID
        context.insert(item)
        let w = makeWorkout(
            routineName: "Push", routineID: routine.id, items: [item]
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let planEx = plan?.blocks.first?.exercises.first
        XCTAssertEqual(planEx?.name, "Flat Press")
        XCTAssertEqual(planEx?.currentExerciseID, swappedIn.id)
        // originalExerciseID still points at the routine slot's exercise.
        XCTAssertEqual(planEx?.originalExerciseID, original.id)
    }

    // MARK: - 4b) Swap reconciliation — isTimeBased + notes follow the swapped exercise

    /// Phase 9-B2 bug-fix: pre-fix `planFromRoutine` left `isTimeBased` and
    /// `notes` reading from the routine slot's original exercise even when
    /// a swap was reconciled, so a rep ↔ duration swap would show the
    /// swapped name but the old mode after a cold-restart resume. The fix
    /// reads `isTimeBased` and `notes` from the swapped exercise too.
    func testRebuildPlanReconcilesSwapIsTimeBasedAndNotesFromSwappedExercise() {
        // Original: rep-based Bench Press.
        let original = makeExercise(name: "Bench Press", isTimeBased: false)
        original.notes = "Original notes"

        // Swap target: time-based Plank with different notes.
        let swappedIn = makeExercise(name: "Plank", isTimeBased: true)
        swappedIn.notes = "Hold straight"

        let tpl = SetTemplate(kind: .working, targetReps: 8, targetWeight: 60)
        let (routine, _, re) = makeRoutine(
            name: "Mixed", slotExercise: original, setTemplates: [tpl]
        )
        // WorkoutItem points at the swapped (time-based) exercise.
        let item = WorkoutItem(exercise: swappedIn, setLogs: [])
        item.routineSlotID = re.slotID
        context.insert(item)
        let w = makeWorkout(
            routineName: "Mixed", routineID: routine.id, items: [item]
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let planEx = plan?.blocks.first?.exercises.first

        // Name + currentExerciseID follow the swap (pre-fix behavior).
        XCTAssertEqual(planEx?.name, "Plank")
        XCTAssertEqual(planEx?.currentExerciseID, swappedIn.id)
        // isTimeBased + notes also follow the swap (this slice's fix).
        XCTAssertEqual(planEx?.isTimeBased, true)
        XCTAssertEqual(planEx?.notes, "Hold straight")
        // originalExerciseID still points at the routine slot's exercise.
        XCTAssertEqual(planEx?.originalExerciseID, original.id)
    }

    // MARK: - 4c) Swap reconciliation — templates rebuild from the slot prescription

    /// Phase 9-B2 bug-fix: pre-fix `planFromRoutine` always built templates
    /// from `re.resolvedTemplates()` regardless of swap state, so a swap
    /// into a time-based exercise still produced rep-based templates with
    /// the original `targetWeight`. The fix routes swap templates through
    /// `makeSwapDefaultTemplates(...)` driven by the slot's prescription —
    /// mirroring what `ActiveWorkoutView.swapExercise` does in-process.
    /// Pinned contract: kind=.working everywhere, targetWeight=nil, count
    /// from slot prescription, duration set for time-based swaps.
    func testRebuildPlanReconcilesSwapTemplatesFromSlotPrescription() {
        let original = makeExercise(name: "Bench Press", isTimeBased: false)
        let swappedIn = makeExercise(name: "Plank", isTimeBased: true)

        // Pre-existing Tier-1 setTemplates with a non-nil targetWeight —
        // would have leaked into the resumed plan pre-fix.
        let tpl = SetTemplate(
            kind: .working, targetReps: 8, targetWeight: 60
        )
        let (routine, _, re) = makeRoutine(
            name: "Mixed", slotExercise: original, setTemplates: [tpl]
        )
        // Slot prescription dictates the expected count + duration hints
        // after the swap.
        let p = SlotPrescription(
            sets: 4,
            restSecondsBetweenSets: 30,
            durationMinSeconds: 45,
            durationMaxSeconds: 45,
            usesDuration: true
        )
        context.insert(p)
        re.prescription = p

        let item = WorkoutItem(exercise: swappedIn, setLogs: [])
        item.routineSlotID = re.slotID
        context.insert(item)
        let w = makeWorkout(
            routineName: "Mixed", routineID: routine.id, items: [item]
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let planEx = plan?.blocks.first?.exercises.first
        let templates = planEx?.templates ?? []

        XCTAssertEqual(
            templates.count, 4,
            "Template count must come from the slot prescription's `sets`, "
            + "not the pre-existing setTemplates row count (which was 1)."
        )
        XCTAssertTrue(
            templates.allSatisfy { $0.kind == .working },
            "Swap-reconciled templates are uniform .working rows."
        )
        XCTAssertTrue(
            templates.allSatisfy { $0.targetWeight == nil },
            "9-A.5 contract: swap templates never carry targetWeight, even "
            + "when the routine's setTemplates row had one."
        )
        XCTAssertTrue(
            templates.allSatisfy { $0.durationSeconds == 45 },
            "Time-based swap derives duration from the slot prescription."
        )
        XCTAssertTrue(
            templates.allSatisfy { $0.restSecondsAfter == 30 },
            "Rest derives from the slot prescription's restSecondsBetweenSets."
        )
    }

    // MARK: - 5) Snapshot fallback when the swapped Exercise is deleted

    func testRebuildPlanUsesNameSnapshotWhenSwappedExerciseIsNil() {
        let original = makeExercise(name: "Squat")
        let swappedIn = makeExercise(name: "Front Squat")
        let tpl = SetTemplate(kind: .working, targetReps: 5, targetWeight: 100)
        let (routine, _, re) = makeRoutine(
            name: "Legs", slotExercise: original, setTemplates: [tpl]
        )
        // Snapshot captured at WorkoutItem init time = "Front Squat".
        let item = WorkoutItem(exercise: swappedIn, setLogs: [])
        item.routineSlotID = re.slotID
        XCTAssertEqual(item.exerciseNameSnapshot, "Front Squat")
        // Simulate post-swap deletion of Front Squat — `Exercise.workoutItems`
        // has deleteRule .nullify, so the relationship clears but the snapshot
        // string survives.
        item.exercise = nil
        context.insert(item)
        let w = makeWorkout(
            routineName: "Legs", routineID: routine.id, items: [item]
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let planEx = plan?.blocks.first?.exercises.first
        // currentName falls through to the snapshot; currentExerciseID stays
        // at the routine slot's original exercise (which still exists).
        XCTAssertEqual(planEx?.name, "Front Squat")
        XCTAssertEqual(planEx?.currentExerciseID, original.id)
    }

    // MARK: - 6) Fallback reconstructs templates from SetLogs

    func testFallbackReconstructsTemplatesFromSetLogs() {
        let ex = makeExercise(name: "Row")
        let log0 = SetLog(
            indexInExercise: 0, kind: .working, reps: 10, weight: 40, restSeconds: 90
        )
        let log1 = SetLog(
            indexInExercise: 1, kind: .working, reps: 8, weight: 45, restSeconds: 90
        )
        let log2 = SetLog(
            indexInExercise: 2, kind: .working, reps: 6, weight: 50, restSeconds: 120
        )
        context.insert(log0); context.insert(log1); context.insert(log2)
        // Inserted out of order to verify the service sorts by indexInExercise.
        let item = WorkoutItem(exercise: ex, setLogs: [log2, log0, log1])
        context.insert(item)
        let w = makeWorkout(
            routineName: "Pull", routineID: nil, items: [item]
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let templates = plan?.blocks.first?.exercises.first?.templates ?? []
        XCTAssertEqual(templates.count, 3)
        XCTAssertEqual(templates[0].targetReps, 10)
        XCTAssertEqual(templates[0].targetWeight, 40)
        XCTAssertEqual(templates[0].restSecondsAfter, 90)
        XCTAssertEqual(templates[1].targetReps, 8)
        XCTAssertEqual(templates[1].targetWeight, 45)
        XCTAssertEqual(templates[2].targetReps, 6)
        XCTAssertEqual(templates[2].targetWeight, 50)
        XCTAssertEqual(templates[2].restSecondsAfter, 120)
    }

    // MARK: - 7) Fallback seeds templates from PlannedPrescriptionSnapshot when no logs

    func testFallbackSeedsTemplatesFromPrescriptionSnapshotWhenNoLogs() {
        let ex = makeExercise(name: "Deadlift")
        let snap = PlannedPrescriptionSnapshot(
            sets: 3,
            repMin: 5,
            repMax: 5,
            restSecondsBetweenSets: 180
        )
        context.insert(snap)
        let item = WorkoutItem(exercise: ex, setLogs: [])
        item.plannedPrescriptionSnapshot = snap
        context.insert(item)
        let w = makeWorkout(
            routineName: "Pull", routineID: nil, items: [item]
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let templates = plan?.blocks.first?.exercises.first?.templates ?? []
        XCTAssertEqual(templates.count, 3)
        for t in templates {
            XCTAssertEqual(t.targetReps, 5)  // repMax wins; repMin == repMax here
            XCTAssertEqual(t.restSecondsAfter, 180)
            XCTAssertEqual(t.kind, .working)
            XCTAssertNil(t.targetWeight)
        }
    }

    // MARK: - 8) Orphan fallback (no logs, no snapshot) — Phase 9-C1

    /// Phase 9-C1 contract: when an orphan `WorkoutItem` has neither
    /// `setLogs` nor a `PlannedPrescriptionSnapshot`, the resume fallback
    /// synthesizes N uniform `.working` rows at AppSettings defaults
    /// (via `makeSwapDefaultTemplates(...)`). Pre-9-C1 the fallback
    /// read `Exercise.defaultTemplates`; that field was deleted in 9-E2,
    /// so the sentinel-leak version of this test was simplified to a
    /// pure AppSettings-defaults assertion.
    func testOrphanFallbackUsesAppSettingsDefaultsRepBased() {
        let ex = makeExercise(name: "Curl", isTimeBased: false)

        // Orphan WorkoutItem: no logs, no snapshot.
        let item = WorkoutItem(exercise: ex, setLogs: [])
        context.insert(item)
        let w = makeWorkout(
            routineName: "Pull", routineID: nil, items: [item]
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let templates = plan?.blocks.first?.exercises.first?.templates ?? []

        XCTAssertEqual(templates.count, AppSettings.defaultSets)
        XCTAssertTrue(templates.allSatisfy { $0.kind == .working })
        XCTAssertTrue(templates.allSatisfy { $0.targetWeight == nil })
        XCTAssertTrue(
            templates.allSatisfy { $0.targetReps == 0 },
            "Orphan fallback targetReps is 0; SessionPlanResolver fills "
            + "in the real value at row-render time."
        )
        XCTAssertTrue(
            templates.allSatisfy {
                $0.restSecondsAfter == AppSettings.defaultRestBetweenSets
            }
        )
        XCTAssertTrue(
            templates.allSatisfy { $0.durationSeconds == nil },
            "Rep-based orphan fallback must not carry a duration."
        )
    }

    /// Phase 9-C1: time-based orphan fallback uses the
    /// `makeSwapDefaultTemplates(...)` 60s duration fallback when neither
    /// `defaultTemplates` nor a snapshot supplies a duration.
    func testOrphanFallbackTimeBasedGetsDefaultDuration() {
        let ex = makeExercise(name: "Plank", isTimeBased: true)
        // No defaultTemplates rows at all — purest orphan path.

        let item = WorkoutItem(exercise: ex, setLogs: [])
        context.insert(item)
        let w = makeWorkout(
            routineName: "Core", routineID: nil, items: [item]
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        let templates = plan?.blocks.first?.exercises.first?.templates ?? []

        XCTAssertEqual(templates.count, AppSettings.defaultSets)
        XCTAssertTrue(
            templates.allSatisfy { $0.kind == .working },
            "Time-based orphan fallback emits only .working rows."
        )
        XCTAssertTrue(
            templates.allSatisfy { $0.durationSeconds == 60 },
            "Time-based orphan fallback uses the makeSwapDefaultTemplates "
            + "60s duration fallback when no hint is set (matches the "
            + "BackfillService 9-A1 fallback)."
        )
        XCTAssertTrue(
            templates.allSatisfy { $0.targetWeight == nil },
            "Orphan fallback never carries targetWeight."
        )
    }

    /// Phase 9-C1: when the orphan `WorkoutItem.exercise` is nil (the
    /// `Exercise` was deleted post-start), the block is skipped — the
    /// existing `guard let ex = item.exercise else { return nil }` keeps
    /// the resume safe (no crash, no fabricated plan with a placeholder
    /// exercise). If every block is dropped, the whole plan is nil.
    func testOrphanFallbackSkipsBlockWhenExerciseIsNil() {
        let ex = makeExercise(name: "Squat")
        let item = WorkoutItem(exercise: ex, setLogs: [])
        // Simulate post-delete nullify: relationship cleared, snapshot
        // string survives but the orphan branch only fires when there
        // are no logs and no snapshot, which is the case here.
        item.exercise = nil
        context.insert(item)
        let w = makeWorkout(
            routineName: "Legs", routineID: nil, items: [item]
        )
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: w, in: context)
        // Block was skipped (the guard returned nil); with no other
        // items, the entire plan is nil.
        XCTAssertNil(plan)
    }
}
