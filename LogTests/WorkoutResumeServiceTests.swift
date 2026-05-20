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
}
