import SwiftData
import XCTest

@testable import Log

/// Regression tests for `resolvedActiveSetupNotes` — the pure helper behind
/// the active workout's "Equipment & Setup" Setup row after in-workout
/// setup-notes editing was added.
///
/// Contract under test:
///  * While the library `Exercise` still exists, the row displays the LIVE
///    `Exercise.setupDefaults` — so a `SetupNotesEditSheet` edit (including
///    clearing the notes) is visible immediately, mirroring how the Exercise
///    Notes section reads live `Exercise.notes`.
///  * The session-start snapshot value is only the fallback when the library
///    exercise was deleted mid-session (nothing live to read or edit).
///
/// Snapshot/History propagation of a committed edit is covered separately by
/// `ActiveSetupNotesEditPropagationTests` below.
final class ActiveSetupNotesResolutionTests: XCTestCase {

    // MARK: - Live exercise exists → live value wins

    func testLiveExerciseShowsLiveSetupNotes() {
        XCTAssertEqual(
            resolvedActiveSetupNotes(
                liveExerciseExists: true,
                liveSetupNotes: "Seat height 4",
                snapshotSetupNotes: "Seat height 2"
            ),
            "Seat height 4",
            "Edited live setup notes must display immediately over the session snapshot"
        )
    }

    func testLiveExerciseWithClearedNotesShowsNilNotSnapshot() {
        XCTAssertNil(
            resolvedActiveSetupNotes(
                liveExerciseExists: true,
                liveSetupNotes: nil,
                snapshotSetupNotes: "Seat height 2"
            ),
            "Clearing setup notes in-workout must not resurrect the stale snapshot value"
        )
    }

    func testLiveExerciseAddingNotesWhereSnapshotWasEmpty() {
        XCTAssertEqual(
            resolvedActiveSetupNotes(
                liveExerciseExists: true,
                liveSetupNotes: "Cable at shoulder",
                snapshotSetupNotes: nil
            ),
            "Cable at shoulder",
            "Newly added setup notes must display even when the session started without any"
        )
    }

    // MARK: - Deleted exercise → snapshot fallback

    func testDeletedExerciseFallsBackToSnapshot() {
        XCTAssertEqual(
            resolvedActiveSetupNotes(
                liveExerciseExists: false,
                liveSetupNotes: nil,
                snapshotSetupNotes: "Seat height 2"
            ),
            "Seat height 2",
            "A slot whose exercise was deleted mid-session must keep showing the snapshot"
        )
    }

    func testDeletedExerciseWithNoSnapshotShowsNothing() {
        XCTAssertNil(
            resolvedActiveSetupNotes(
                liveExerciseExists: false,
                liveSetupNotes: nil,
                snapshotSetupNotes: nil
            )
        )
    }
}

/// Regression tests for `applyActiveSetupNotesEdit` — the Done-commit
/// propagation that makes the CURRENT workout's finished History record the
/// setup notes corrected while training, without ever touching past
/// (finished) workouts.
///
/// Contract under test (mirrors `SetupNotesEditSheet` Done / Cancel):
///  * Done updates `Exercise.setupDefaults` (future sessions) AND the
///    current session's snapshots: the in-memory plan payload for
///    non-swapped slots plus any already-persisted
///    `WorkoutItem.plannedPrescriptionSnapshot` for slots running the
///    edited exercise.
///  * A swapped slot's payload still describes the slot's ORIGINAL exercise
///    and is left untouched; only its persisted item snapshot updates.
///  * Cancel invokes no write path — exercise and snapshots stay unchanged.
///  * A finished workout's snapshot rows are frozen: later library edits to
///    `Exercise.setupDefaults` never reach them.
@MainActor
final class ActiveSetupNotesEditPropagationTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    /// `PersistentIdentifier` cannot be constructed via a public API outside
    /// SwiftData; `applyActiveSetupNotesEdit` never inspects it, so the
    /// JSON-decoded placeholder used by `PlanSlotLookupTests` is safe here.
    private func makeFakePersistentID() -> PersistentIdentifier {
        let json =
            "{\"implementation\":{\"primaryKey\":\"x\",\"uriRepresentation\":\"x://test\",\"isTemporary\":true,\"entityName\":\"\"}}"
        let data = json.data(using: .utf8)!
        return try! JSONDecoder().decode(PersistentIdentifier.self, from: data)
    }

    private func makePayload(setupNotes: String?) -> PrescriptionSnapshotPayload {
        let p = SlotPrescription()
        let ex = Exercise(name: "payload-source", setupDefaults: setupNotes)
        return PrescriptionSnapshotPayload(from: p, exercise: ex)
    }

    private func makePlanExercise(
        originalExerciseID: UUID,
        currentExerciseID: UUID,
        routineSlotID: UUID,
        payloadSetupNotes: String?
    ) -> PlanExercise {
        PlanExercise(
            id: currentExerciseID,
            routineExerciseID: makeFakePersistentID(),
            originalExerciseID: originalExerciseID,
            currentExerciseID: currentExerciseID,
            name: "Slot",
            notes: nil,
            templates: [],
            isTimeBased: false,
            routineSlotID: routineSlotID,
            templateNotesSnapshot: nil,
            prescriptionSnapshot: makePayload(setupNotes: payloadSetupNotes),
            techniquePlansSnapshot: [],
            warmupStepsSnapshot: []
        )
    }

    private func makePlan(_ exercises: [PlanExercise]) -> WorkoutPlan {
        WorkoutPlan(
            routineID: UUID(),
            routineName: "Test",
            routineVariantID: nil,
            blocks: [
                PlanBlock(
                    isSuperset: false,
                    restAfterSeconds: nil,
                    supersetRoundRestSeconds: nil,
                    exercises: exercises
                )
            ]
        )
    }

    /// A persisted WorkoutItem with a frozen setup snapshot, the shape
    /// `populateSnapshotFields` produces at the slot's first log.
    private func makeItem(
        exercise: Exercise, snapshotSetupNotes: String?
    ) -> WorkoutItem {
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        let snap = PlannedPrescriptionSnapshot(setupNotes: snapshotSetupNotes)
        context.insert(snap)
        item.plannedPrescriptionSnapshot = snap
        context.insert(item)
        return item
    }

    // MARK: - (a) Done updates the current session snapshot

    func testDoneUpdatesPlanPayloadAndPersistedItemSnapshot() throws {
        let ex = Exercise(name: "Leg Press", setupDefaults: "Seat 2")
        context.insert(ex)
        let slotID = UUID()
        var plan = makePlan([
            makePlanExercise(
                originalExerciseID: ex.id,
                currentExerciseID: ex.id,
                routineSlotID: slotID,
                payloadSetupNotes: "Seat 2"
            )
        ])
        let item = makeItem(exercise: ex, snapshotSetupNotes: "Seat 2")

        // Mirror the sheet's Done commit: exercise write + propagation.
        let normalized = normalizedOptionalNote("Seat 4, back pad 1")
        ex.setupDefaults = normalized
        let matched = applyActiveSetupNotesEdit(
            normalized,
            editedExerciseID: ex.id,
            plan: &plan,
            itemsBySlotID: [slotID: item]
        )
        try context.save()

        XCTAssertEqual(matched, 1)
        XCTAssertEqual(ex.setupDefaults, "Seat 4, back pad 1")
        XCTAssertEqual(
            plan.blocks[0].exercises[0].prescriptionSnapshot?.setupNotes,
            "Seat 4, back pad 1",
            "A WorkoutItem created after the edit must freeze the corrected value"
        )
        XCTAssertEqual(
            item.plannedPrescriptionSnapshot?.setupNotes,
            "Seat 4, back pad 1",
            "This workout's History reads the item snapshot — it must carry the corrected value"
        )
    }

    func testDoneUpdatesEverySlotRunningTheEditedExerciseOnly() {
        let edited = Exercise(name: "Bench", setupDefaults: "old")
        let other = Exercise(name: "Row", setupDefaults: "row setup")
        context.insert(edited)
        context.insert(other)
        let slotA = UUID()
        let slotB = UUID()
        let slotC = UUID()
        var plan = makePlan([
            makePlanExercise(
                originalExerciseID: edited.id, currentExerciseID: edited.id,
                routineSlotID: slotA, payloadSetupNotes: "old"),
            makePlanExercise(
                originalExerciseID: edited.id, currentExerciseID: edited.id,
                routineSlotID: slotB, payloadSetupNotes: "old"),
            makePlanExercise(
                originalExerciseID: other.id, currentExerciseID: other.id,
                routineSlotID: slotC, payloadSetupNotes: "row setup"),
        ])
        let itemC = makeItem(exercise: other, snapshotSetupNotes: "row setup")

        let matched = applyActiveSetupNotesEdit(
            "new",
            editedExerciseID: edited.id,
            plan: &plan,
            itemsBySlotID: [slotC: itemC]
        )

        XCTAssertEqual(matched, 2)
        XCTAssertEqual(
            plan.blocks[0].exercises[0].prescriptionSnapshot?.setupNotes, "new")
        XCTAssertEqual(
            plan.blocks[0].exercises[1].prescriptionSnapshot?.setupNotes, "new")
        XCTAssertEqual(
            plan.blocks[0].exercises[2].prescriptionSnapshot?.setupNotes,
            "row setup",
            "Slots running a different exercise must be untouched"
        )
        XCTAssertEqual(itemC.plannedPrescriptionSnapshot?.setupNotes, "row setup")
    }

    func testSwappedSlotUpdatesItemSnapshotButKeepsOriginalPayload() {
        // Slot originally ran A, was swapped to B this session. Editing B's
        // setup notes must update the slot's persisted item snapshot (what
        // History reads) but leave the payload — which still describes A,
        // the keep-plan swap contract — untouched.
        let originalID = UUID()
        let swappedIn = Exercise(name: "Incline DB Press", setupDefaults: "30°")
        context.insert(swappedIn)
        let slotID = UUID()
        var plan = makePlan([
            makePlanExercise(
                originalExerciseID: originalID,
                currentExerciseID: swappedIn.id,
                routineSlotID: slotID,
                payloadSetupNotes: "original A setup"
            )
        ])
        let item = makeItem(exercise: swappedIn, snapshotSetupNotes: "30°")

        let matched = applyActiveSetupNotesEdit(
            "45°, feet flat",
            editedExerciseID: swappedIn.id,
            plan: &plan,
            itemsBySlotID: [slotID: item]
        )

        XCTAssertEqual(matched, 1)
        XCTAssertEqual(item.plannedPrescriptionSnapshot?.setupNotes, "45°, feet flat")
        XCTAssertEqual(
            plan.blocks[0].exercises[0].prescriptionSnapshot?.setupNotes,
            "original A setup",
            "Swapped slot's payload still describes the original exercise and must not change"
        )
    }

    // MARK: - (b) Cancel writes nothing

    func testCancelLeavesExerciseAndSnapshotsUnchanged() throws {
        // Cancel dismisses without invoking the exercise write or
        // `applyActiveSetupNotesEdit` (see `SetupNotesEditSheet`) — the only
        // two write paths for setup notes. With neither invoked, everything
        // must hold its pre-sheet value, even after a context save.
        let ex = Exercise(name: "Squat", setupDefaults: "Bar height 5")
        context.insert(ex)
        let slotID = UUID()
        let plan = makePlan([
            makePlanExercise(
                originalExerciseID: ex.id, currentExerciseID: ex.id,
                routineSlotID: slotID, payloadSetupNotes: "Bar height 5")
        ])
        let item = makeItem(exercise: ex, snapshotSetupNotes: "Bar height 5")

        // (draft typing happens only in sheet-local @State; no commit calls)
        try context.save()

        XCTAssertEqual(ex.setupDefaults, "Bar height 5")
        XCTAssertEqual(
            plan.blocks[0].exercises[0].prescriptionSnapshot?.setupNotes,
            "Bar height 5")
        XCTAssertEqual(item.plannedPrescriptionSnapshot?.setupNotes, "Bar height 5")
    }

    // MARK: - (c) Past completed History stays frozen

    func testFinishedWorkoutSnapshotUnaffectedByLaterLibraryEdit() throws {
        // A completed workout's item snapshot is a frozen row. A later edit
        // to Exercise.setupDefaults (from the library, or from a later
        // workout's SetupNotesEditSheet — which only propagates into that
        // later session's plan/items) must never reach it.
        let ex = Exercise(name: "Deadlift", setupDefaults: "Plates 45")
        context.insert(ex)
        let finishedItem = makeItem(exercise: ex, snapshotSetupNotes: "Plates 45")
        let workout = Workout(date: .now, items: [finishedItem])
        context.insert(workout)
        try context.save()

        // Later library edit (no active-session propagation targets this item).
        ex.setupDefaults = "Plates 45 + straps"
        try context.save()

        XCTAssertEqual(
            finishedItem.plannedPrescriptionSnapshot?.setupNotes,
            "Plates 45",
            "Completed History must not change retroactively"
        )
    }

    // MARK: - (d) Future workouts pick up the edited definition

    func testFutureSessionSnapshotUsesEditedSetupDefaults() {
        // Future sessions build their payload from the live Exercise at
        // session start (`PrescriptionSnapshotPayload(from:exercise:)`), so
        // an in-workout edit to setupDefaults flows into the next workout's
        // snapshot.
        let ex = Exercise(name: "Lat Pulldown", setupDefaults: "Knee pad 3")
        context.insert(ex)
        ex.setupDefaults = "Knee pad 2, wide grip"  // in-workout edit committed

        let payload = PrescriptionSnapshotPayload(
            from: SlotPrescription(), exercise: ex)

        XCTAssertEqual(payload.setupNotes, "Knee pad 2, wide grip")
    }
}
