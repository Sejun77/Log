import SwiftData
import XCTest

@testable import Log

/// Issue A — a warm-up step or technique added to a prepared alternative
/// sometimes vanished after leaving the screen.
///
/// `SlotAlternativeDetailEditor` edits a scratch slot in
/// `AlternativeDraftStore`'s own in-memory container and writes the result back
/// into the `SlotAlternative` payload. That write-back used to be *incidental*:
/// the editor read `store.payload()` inside its `body` and let `.onChange`
/// notice the value had moved.
///
/// The warm-up and technique editors are **pushed on top of** that view, so an
/// edit made there mutates the scratch graph while the view owning the commit
/// is off-screen. Leave by a route that never brings it back — switch tabs, pop
/// straight to the routine list — and the body never re-evaluates, the commit
/// never fires, and the draft container is deallocated with the edit still in
/// it. Pop back one level first and the very same edit *is* saved, which is the
/// "sometimes" in the report.
///
/// The fix makes the commit a call: the nested editors take an `onGraphChange`
/// hook that runs `AlternativeDraftCommit.commit`. These tests exercise that
/// call directly — the view layer is not testable here, but the rule it now
/// depends on is.
@MainActor
final class AlternativeNestedEditorCommitTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func slotWithAlternatives(
        _ names: [String] = ["Machine Chest Press"]
    ) throws -> (SlotPrescription, [UUID]) {
        let p = SlotPrescription()
        p.sets = 3
        p.repMin = 8
        p.repMax = 12
        context.insert(p)
        var ids: [UUID] = []
        for name in names {
            let added = SlotAlternativeAuthoring.append(
                exerciseID: UUID(),
                exerciseName: name,
                prescription: AlternativeDraftStore.defaultPayload(for: .strength),
                to: p)
            ids.append(added.id)
        }
        try context.save()
        return (p, ids)
    }

    /// The draft the detail editor builds on appear, hydrated from what is
    /// stored for that alternative right now.
    private func openEditor(
        _ p: SlotPrescription, _ id: UUID
    ) throws -> AlternativeDraftStore {
        let stored = try XCTUnwrap(
            p.slotAlternatives.first(where: { $0.id == id })
        ).prescription
        return try AlternativeDraftStore(
            exerciseName: "Machine Chest Press",
            trackingMode: .strength,
            equipmentType: nil,
            includesBodyweightInLoad: false,
            payload: stored)
    }

    /// What the nested warm-up editor's Add button now does: mutate the scratch
    /// graph, then call the hook.
    private func addWarmupThroughNestedEditor(
        _ store: AlternativeDraftStore,
        commitTo p: SlotPrescription,
        alternativeID: UUID
    ) {
        WarmupSchemeAuthoring.addStep(
            to: store.prescription, kind: .percentage, reps: 8,
            percentOfWorking: 0.5, restSecondsAfter: 60, note: "ramp",
            weight: nil, fallbackContext: context)
        commit(store, to: p, alternativeID: alternativeID)
    }

    private func addTechniqueThroughNestedEditor(
        _ store: AlternativeDraftStore,
        commitTo p: SlotPrescription,
        alternativeID: UUID
    ) {
        TechniquePlanAuthoring.addPlan(
            type: .dropset, to: store.prescription, fallbackContext: context)
        commit(store, to: p, alternativeID: alternativeID)
    }

    @discardableResult
    private func commit(
        _ store: AlternativeDraftStore?,
        to p: SlotPrescription,
        alternativeID: UUID,
        isEnabled: Bool = true,
        note: String = ""
    ) -> Bool {
        AlternativeDraftCommit.commit(
            draft: store,
            alternativeID: alternativeID,
            isEnabled: isEnabled,
            note: note,
            into: p,
            context: context)
    }

    private func stored(
        _ p: SlotPrescription, _ id: UUID
    ) throws -> AlternativePrescriptionPayload {
        try XCTUnwrap(p.slotAlternatives.first(where: { $0.id == id }))
            .prescription
    }

    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    // ==================================================
    // MARK: - The bug, and the fix
    // ==================================================

    /// The pre-fix shape, kept as the reason this file exists: a nested edit
    /// that is never committed dies with the draft container. Nothing observes
    /// the scratch graph from outside it.
    func testANestedEditThatIsNeverCommittedIsLostWithTheDraft() throws {
        let (p, ids) = try slotWithAlternatives()
        var store: AlternativeDraftStore? = try openEditor(p, ids[0])

        WarmupSchemeAuthoring.addStep(
            to: try XCTUnwrap(store).prescription, kind: .fixedReps, reps: 5,
            percentOfWorking: nil, restSecondsAfter: nil, note: nil,
            weight: 40, fallbackContext: context)
        // No commit — the user switched tabs.
        store = nil

        XCTAssertTrue(
            try stored(p, ids[0]).warmupSteps.isEmpty,
            "This is the reported data loss; the hook exists to prevent it")
    }

    /// The same edit, with the hook the nested editor now calls.
    func testWarmupAddedThroughTheNestedEditorIsCommitted() throws {
        let (p, ids) = try slotWithAlternatives()
        let store = try openEditor(p, ids[0])

        addWarmupThroughNestedEditor(store, commitTo: p, alternativeID: ids[0])

        let payload = try stored(p, ids[0])
        XCTAssertEqual(payload.warmupSteps.count, 1)
        XCTAssertEqual(payload.warmupSteps.first?.kind, .percentage)
        XCTAssertEqual(payload.warmupSteps.first?.reps, 8)
        XCTAssertEqual(payload.warmupSteps.first?.percentOfWorking, 0.5)
        XCTAssertEqual(payload.warmupSteps.first?.restSecondsAfter, 60)
        XCTAssertEqual(payload.warmupSteps.first?.note, "ramp")
    }

    func testTechniqueAddedThroughTheNestedEditorIsCommitted() throws {
        let (p, ids) = try slotWithAlternatives()
        let store = try openEditor(p, ids[0])

        addTechniqueThroughNestedEditor(store, commitTo: p, alternativeID: ids[0])

        let payload = try stored(p, ids[0])
        XCTAssertEqual(payload.techniques.count, 1)
        XCTAssertEqual(payload.techniques.first?.type, .dropset)
        XCTAssertEqual(payload.techniques.first?.dropPercent, 20)
    }

    // ==================================================
    // MARK: - Leaving and coming back
    // ==================================================

    /// The reported sequence: add a warm-up in the nested editor, leave the
    /// whole screen (the draft container dies), come back, and the step is
    /// there — both in the alternative and in the nested editor reopened from
    /// it.
    func testWarmupSurvivesLeavingAndReopeningTheAlternative() throws {
        let (p, ids) = try slotWithAlternatives()

        var first: AlternativeDraftStore? = try openEditor(p, ids[0])
        addWarmupThroughNestedEditor(
            try XCTUnwrap(first), commitTo: p, alternativeID: ids[0])
        first = nil  // back to the routine, then a tab switch

        // Reopening the alternative rebuilds the draft from what is stored.
        let reopened = try openEditor(p, ids[0])
        XCTAssertEqual(reopened.payload().warmupSteps.count, 1)

        // And the nested warm-up editor reads that same scratch graph.
        XCTAssertEqual(reopened.prescription.warmupScheme?.steps.count, 1)
        XCTAssertEqual(reopened.prescription.warmupScheme?.steps.first?.reps, 8)
    }

    func testTechniqueSurvivesLeavingAndReopeningTheAlternative() throws {
        let (p, ids) = try slotWithAlternatives()

        var first: AlternativeDraftStore? = try openEditor(p, ids[0])
        addTechniqueThroughNestedEditor(
            try XCTUnwrap(first), commitTo: p, alternativeID: ids[0])
        first = nil

        let reopened = try openEditor(p, ids[0])
        XCTAssertEqual(reopened.payload().techniques.count, 1)
        XCTAssertEqual(reopened.prescription.techniquePlans.count, 1)
        XCTAssertEqual(
            reopened.prescription.techniquePlans.first?.type, .dropset)
    }

    /// Edit and delete go through the same hook, so a second visit sees the
    /// second round of edits too.
    func testEditAndDeleteAcrossTwoVisitsBothStick() throws {
        let (p, ids) = try slotWithAlternatives()

        var visit: AlternativeDraftStore? = try openEditor(p, ids[0])
        addWarmupThroughNestedEditor(
            try XCTUnwrap(visit), commitTo: p, alternativeID: ids[0])
        addTechniqueThroughNestedEditor(
            try XCTUnwrap(visit), commitTo: p, alternativeID: ids[0])
        visit = nil

        // Second visit: edit the step, delete the technique, commit each time.
        var second: AlternativeDraftStore? = try openEditor(p, ids[0])
        let store = try XCTUnwrap(second)
        let step = try XCTUnwrap(store.prescription.warmupScheme?.steps.first)
        step.reps = 12
        commit(store, to: p, alternativeID: ids[0])

        let plan = try XCTUnwrap(store.prescription.techniquePlans.first)
        TechniquePlanAuthoring.delete(
            [plan], from: store.prescription, fallbackContext: context)
        commit(store, to: p, alternativeID: ids[0])
        second = nil

        let payload = try stored(p, ids[0])
        XCTAssertEqual(payload.warmupSteps.first?.reps, 12)
        XCTAssertTrue(payload.techniques.isEmpty)
    }

    // ==================================================
    // MARK: - Into the workout
    // ==================================================

    func testApplyingTheAlternativeCarriesBothWarmupAndTechnique() throws {
        let (p, ids) = try slotWithAlternatives()
        var store: AlternativeDraftStore? = try openEditor(p, ids[0])
        addWarmupThroughNestedEditor(
            try XCTUnwrap(store), commitTo: p, alternativeID: ids[0])
        addTechniqueThroughNestedEditor(
            try XCTUnwrap(store), commitTo: p, alternativeID: ids[0])
        store = nil

        let outcome = ExerciseSwitchPlanAdapter.outcome(
            choice: .useAlternative(try stored(p, ids[0])),
            current: SessionPlan(),
            oldMode: .strength,
            newMode: .strength,
            resetSource: .appDefaults(for: .strength))

        XCTAssertEqual(
            try XCTUnwrap(outcome.replacementWarmupSteps).count, 1)
        XCTAssertEqual(
            try XCTUnwrap(outcome.replacementWarmupSteps).first?.reps, 8)
        XCTAssertEqual(
            try XCTUnwrap(outcome.replacementTechniques).count, 1)
        XCTAssertEqual(
            try XCTUnwrap(outcome.replacementTechniques).first?.type, .dropset)
        XCTAssertFalse(outcome.keepWarmupSteps)
        XCTAssertFalse(outcome.keepTechniques)
    }

    // ==================================================
    // MARK: - Blast radius
    // ==================================================

    /// A commit rewrites one alternative. The slot's own prescription keeps its
    /// plan and gains no warm-up or technique of its own, and nothing the
    /// scratch editors created reaches the user's store.
    func testCommittingDoesNotTouchTheParentSlot() throws {
        let (p, ids) = try slotWithAlternatives()
        var store: AlternativeDraftStore? = try openEditor(p, ids[0])
        addWarmupThroughNestedEditor(
            try XCTUnwrap(store), commitTo: p, alternativeID: ids[0])
        addTechniqueThroughNestedEditor(
            try XCTUnwrap(store), commitTo: p, alternativeID: ids[0])
        store = nil

        XCTAssertNil(p.warmupScheme)
        XCTAssertTrue(p.techniquePlans.isEmpty)
        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
        XCTAssertEqual(try count(WarmupScheme.self), 0)
        XCTAssertEqual(try count(WarmupStep.self), 0)
        XCTAssertEqual(try count(TechniquePlan.self), 0)
    }

    /// Sibling alternatives — including a disabled one — keep their id, order,
    /// enabled flag, note and prescription byte-for-byte.
    func testCommittingDoesNotTouchOtherAlternatives() throws {
        let (p, ids) = try slotWithAlternatives(["First", "Second", "Third"])

        // Turn the third one off and give the second a note, so the test has
        // real state to preserve rather than three identical rows.
        SlotAlternativeAuthoring.update(id: ids[2], in: p) {
            $0.isEnabled = false
        }
        SlotAlternativeAuthoring.update(id: ids[1], in: p) {
            $0.note = "if the rack is busy"
        }
        try context.save()
        let before = p.slotAlternatives

        var store: AlternativeDraftStore? = try openEditor(p, ids[0])
        addWarmupThroughNestedEditor(
            try XCTUnwrap(store), commitTo: p, alternativeID: ids[0])
        store = nil

        let after = p.slotAlternatives
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.order), [0, 1, 2])
        XCTAssertEqual(after.map(\.exerciseName), ["First", "Second", "Third"])

        let second = try XCTUnwrap(after.first { $0.id == ids[1] })
        XCTAssertEqual(second.note, "if the rack is busy")
        XCTAssertTrue(second.isEnabled)
        XCTAssertTrue(second.prescription.warmupSteps.isEmpty)

        let third = try XCTUnwrap(after.first { $0.id == ids[2] })
        XCTAssertFalse(
            third.isEnabled, "a disabled sibling stays disabled")
        XCTAssertTrue(third.prescription.warmupSteps.isEmpty)

        XCTAssertEqual(try stored(p, ids[0]).warmupSteps.count, 1)
    }

    /// Editing the *second* alternative commits to the second, not the first.
    func testCommitTargetsTheAlternativeBeingEdited() throws {
        let (p, ids) = try slotWithAlternatives(["First", "Second"])
        var store: AlternativeDraftStore? = try openEditor(p, ids[1])
        addWarmupThroughNestedEditor(
            try XCTUnwrap(store), commitTo: p, alternativeID: ids[1])
        store = nil

        XCTAssertTrue(try stored(p, ids[0]).warmupSteps.isEmpty)
        XCTAssertEqual(try stored(p, ids[1]).warmupSteps.count, 1)
    }

    // ==================================================
    // MARK: - Commit rules
    // ==================================================

    /// An alternative deleted on another screen while this editor was open must
    /// not be resurrected by the commit that follows.
    func testCommittingAnUnknownAlternativeWritesNothing() throws {
        let (p, ids) = try slotWithAlternatives()
        let store = try openEditor(p, ids[0])

        SlotAlternativeAuthoring.delete(
            atOffsets: IndexSet(integer: 0), in: p)
        try context.save()

        XCTAssertFalse(
            commit(store, to: p, alternativeID: ids[0]),
            "a stale editor must not re-add a deleted alternative")
        XCTAssertTrue(p.slotAlternatives.isEmpty)
    }

    /// The metadata half commits with no draft at all — the state the editor is
    /// in before its scratch store finishes loading.
    func testCommittingWithNoDraftWritesMetadataOnly() throws {
        let (p, ids) = try slotWithAlternatives()
        let seeded = try stored(p, ids[0])

        XCTAssertTrue(
            commit(nil, to: p, alternativeID: ids[0],
                   isEnabled: false, note: "shoulder day"))

        let after = try XCTUnwrap(p.slotAlternatives.first)
        XCTAssertFalse(after.isEnabled)
        XCTAssertEqual(after.note, "shoulder day")
        XCTAssertEqual(
            after.prescription, seeded,
            "with no draft the prescription must be left exactly as stored")
    }

    /// Committing twice with no edit in between rewrites identical bytes — the
    /// property that lets the hook, the value observer and `onDisappear` all
    /// fire without fighting each other.
    func testCommittingIsIdempotent() throws {
        let (p, ids) = try slotWithAlternatives()
        let store = try openEditor(p, ids[0])
        addWarmupThroughNestedEditor(store, commitTo: p, alternativeID: ids[0])

        let once = p.alternativesData
        commit(store, to: p, alternativeID: ids[0])
        commit(store, to: p, alternativeID: ids[0])

        XCTAssertEqual(p.alternativesData, once)
        XCTAssertEqual(try stored(p, ids[0]).warmupSteps.count, 1)
    }

    // ==================================================
    // MARK: - Normal routine editing is untouched
    // ==================================================

    /// A routine slot's prescription *is* the stored model, so its editors pass
    /// no hook and nothing is committed anywhere — the warm-up and technique go
    /// straight into the user's store, exactly as before.
    func testNormalRoutineEditingNeedsNoCommit() throws {
        let p = SlotPrescription()
        context.insert(p)

        WarmupSchemeAuthoring.addStep(
            to: p, kind: .fixedReps, reps: 5, percentOfWorking: nil,
            restSecondsAfter: nil, note: nil, weight: 40,
            fallbackContext: context)
        TechniquePlanAuthoring.addPlan(
            type: .dropset, to: p, fallbackContext: context)
        try context.save()

        XCTAssertEqual(p.warmupScheme?.steps.count, 1)
        XCTAssertEqual(p.techniquePlans.count, 1)
        XCTAssertEqual(try count(WarmupStep.self), 1)
        XCTAssertEqual(try count(TechniquePlan.self), 1)
        XCTAssertNil(
            p.alternativesData,
            "a slot with no alternatives gains no payload from its own editing")
    }
}
