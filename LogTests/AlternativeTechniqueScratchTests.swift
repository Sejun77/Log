import SwiftData
import XCTest

@testable import Log

/// The technique-plan half of the Alternative Exercises scratch-context fix —
/// the sibling of `AlternativeWarmupScratchTests`.
///
/// `SlotAlternativeDetailEditor` binds the real `SlotPrescriptionSection` — and
/// through it the real `TechniquePlanEditor` — to a scratch slot living in
/// `AlternativeDraftStore`'s own in-memory container. The editor created its
/// `TechniquePlan` in `@Environment(\.modelContext)`, which for the pushed
/// editor is the **app's** context.
///
/// `techniquePlans` is to-many, so unlike the to-one `warmupScheme` this never
/// trapped — SwiftData accepted the cross-container relate silently. It instead
/// saved a `TechniquePlan` row into the user's store for every technique added
/// to a prepared alternative, owned by no cascade and reachable from no screen,
/// and made `ModelContext.delete` a no-op for a draft-owned plan.
///
/// Every test below passes the harness's **app** context as `fallbackContext` —
/// exactly the wrong-store context the environment used to hand the editor.
@MainActor
final class AlternativeTechniqueScratchTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func appPrescription() -> SlotPrescription {
        let p = SlotPrescription()
        context.insert(p)
        return p
    }

    private func draft(
        _ payload: AlternativePrescriptionPayload? = nil,
        mode: TrackingMode = .strength
    ) throws -> AlternativeDraftStore {
        try AlternativeDraftStore(
            exerciseName: "Machine Chest Press",
            trackingMode: mode,
            equipmentType: nil,
            includesBodyweightInLoad: false,
            payload: payload ?? AlternativeDraftStore.defaultPayload(for: mode))
    }

    /// The exact call the editor's type-picker sheet makes.
    @discardableResult
    private func addPlan(
        _ type: TechniqueType = .dropset, to prescription: SlotPrescription
    ) -> TechniquePlan {
        TechniquePlanAuthoring.addPlan(
            type: type, to: prescription, fallbackContext: context)
    }

    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    private func slotWithAlternative() throws -> (SlotPrescription, UUID) {
        let p = appPrescription()
        let added = SlotAlternativeAuthoring.append(
            exerciseID: UUID(),
            exerciseName: "Machine Chest Press",
            prescription: AlternativeDraftStore.defaultPayload(for: .strength),
            to: p)
        try context.save()
        return (p, added.id)
    }

    // ==================================================
    // MARK: - 1/2. Adding into the scratch context
    // ==================================================

    func testAddingTheFirstTechniqueToAPreparedAlternativeDoesNotCrash() throws {
        let store = try draft()

        XCTAssertTrue(store.prescription.techniquePlans.isEmpty)

        let plan = addPlan(.dropset, to: store.prescription)

        XCTAssertEqual(plan.order, 0)
        XCTAssertEqual(plan.type, .dropset)
        XCTAssertEqual(plan.dropPercent, 20)
        XCTAssertEqual(plan.dropCount, 1)
        XCTAssertEqual(plan.dropsetEffortRaw, "amrap")
        XCTAssertEqual(store.prescription.techniquePlans.count, 1)
    }

    func testTheAddedTechniqueBelongsToTheDraftContext() throws {
        let store = try draft()
        let plan = addPlan(.restPause, to: store.prescription)

        XCTAssertIdentical(plan.modelContext, store.context)
        XCTAssertNotIdentical(plan.modelContext, context)
        XCTAssertEqual(
            try store.context.fetchCount(FetchDescriptor<TechniquePlan>()), 1)
    }

    /// The leak guarantee `AlternativeDraftStore` is built around: nothing the
    /// scratch editors create may reach the user's store.
    func testNothingReachesTheAppContextDuringScratchEditing() throws {
        let store = try draft()
        addPlan(.dropset, to: store.prescription)
        addPlan(.cluster, to: store.prescription)
        try context.save()

        XCTAssertEqual(try count(TechniquePlan.self), 0)
        XCTAssertEqual(try count(SlotPrescription.self), 0)
    }

    /// Per-type seeding is unchanged by the move into the service.
    func testPerTypeSeedingIsUnchanged() throws {
        let store = try draft()

        let partial = addPlan(.partialReps, to: store.prescription)
        XCTAssertEqual(partial.reps, 8)
        XCTAssertNil(partial.partialRangeRaw)

        let restPause = addPlan(.restPause, to: store.prescription)
        XCTAssertEqual(restPause.restSeconds, 15)
        XCTAssertEqual(restPause.rounds, 2)

        let cluster = addPlan(.cluster, to: store.prescription)
        XCTAssertEqual(cluster.reps, 3)
        XCTAssertEqual(cluster.restSeconds, 10)
        XCTAssertEqual(cluster.rounds, 3)

        let amrap = addPlan(.amrap, to: store.prescription)
        XCTAssertNil(amrap.reps)

        XCTAssertEqual(
            store.prescription.techniquePlans
                .sorted { $0.order < $1.order }.map(\.order),
            [0, 1, 2, 3],
            "order continues from the highest existing plan")
    }

    // ==================================================
    // MARK: - 3/4/5. Editing, deleting, reordering
    // ==================================================

    /// Editing writes onto the plan itself, so it is safe in either store — and
    /// the resolved save context is the draft's, not the app's.
    func testEditingATechniqueInsideAnAlternativeIsSafe() throws {
        let store = try draft()
        let plan = addPlan(.dropset, to: store.prescription)

        plan.dropPercent = 30
        plan.dropCount = 3
        plan.note = "to the pin"
        try? (plan.modelContext ?? context).save()

        XCTAssertEqual(store.payload().techniques.first?.dropPercent, 30)
        XCTAssertEqual(store.payload().techniques.first?.dropCount, 3)
        XCTAssertEqual(store.payload().techniques.first?.note, "to the pin")
        XCTAssertIdentical(plan.modelContext, store.context)
    }

    /// Deleting must actually destroy the row in the context that holds it —
    /// through the app context it was a silent no-op.
    func testDeletingATechniqueUsesTheOwningContext() throws {
        let store = try draft()
        let keep = addPlan(.dropset, to: store.prescription)
        let doomed = addPlan(.restPause, to: store.prescription)

        TechniquePlanAuthoring.delete(
            [doomed], from: store.prescription, fallbackContext: context)

        // Checked before the save: `isDeleted` reports the *pending* delete,
        // and the row is gone from the context entirely once it commits. Through
        // the app context this stayed false — the no-op the fix removes.
        XCTAssertTrue(doomed.isDeleted)

        try store.context.save()

        XCTAssertEqual(store.prescription.techniquePlans.count, 1)
        XCTAssertEqual(store.prescription.techniquePlans.first?.id, keep.id)
        XCTAssertEqual(
            try store.context.fetchCount(FetchDescriptor<TechniquePlan>()), 1)
        XCTAssertEqual(store.payload().techniques.count, 1)
        XCTAssertEqual(store.payload().techniques.first?.type, .dropset)
    }

    /// The scratch prescription survives a delete intact — no lost siblings, no
    /// disturbed fields.
    func testDeletingDoesNotCorruptTheScratchPrescription() throws {
        var seeded = AlternativeDraftStore.defaultPayload(for: .strength)
        seeded.sets = 4
        seeded.repMin = 10
        seeded.repMax = 15
        let store = try draft(seeded)
        let doomed = addPlan(.dropset, to: store.prescription)
        addPlan(.cluster, to: store.prescription)

        TechniquePlanAuthoring.delete(
            [doomed], from: store.prescription, fallbackContext: context)

        let after = store.payload()
        XCTAssertEqual(after.sets, 4)
        XCTAssertEqual(after.repMin, 10)
        XCTAssertEqual(after.repMax, 15)
        XCTAssertEqual(after.techniques.count, 1)
        XCTAssertEqual(after.techniques.first?.type, .cluster)
    }

    /// Reordering only writes `order` onto plans already in the graph, so it
    /// stays safe — and read-back honours the new order.
    func testReorderingInsideAnAlternativeIsSafe() throws {
        let store = try draft()
        let first = addPlan(.dropset, to: store.prescription)
        let second = addPlan(.cluster, to: store.prescription)

        first.order = 1
        second.order = 0

        XCTAssertEqual(
            store.payload().techniques.map(\.type), [.cluster, .dropset])
        XCTAssertEqual(store.payload().techniques.map(\.order), [0, 1])
    }

    // ==================================================
    // MARK: - 6/7. Commit and reopen
    // ==================================================

    func testCommittingTheDraftEncodesTheTechniqueIntoTheAlternative() throws {
        let (p, id) = try slotWithAlternative()
        let store = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)
        addPlan(.dropset, to: store.prescription)

        // What `SlotAlternativeDetailEditor.commit(payload:)` does.
        SlotAlternativeAuthoring.update(id: id, in: p) {
            $0.prescription = store.payload()
        }
        try context.save()

        let written = try XCTUnwrap(p.slotAlternatives.first).prescription
        XCTAssertEqual(written.techniques.count, 1)
        XCTAssertEqual(written.techniques.first?.type, .dropset)
        XCTAssertEqual(written.techniques.first?.dropPercent, 20)
        XCTAssertEqual(written.techniques.first?.dropCount, 1)
        XCTAssertEqual(written.techniques.first?.order, 0)
    }

    func testReopeningTheAlternativeShowsTheTechnique() throws {
        let (p, id) = try slotWithAlternative()
        let first = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)
        addPlan(.restPause, to: first.prescription)
        SlotAlternativeAuthoring.update(id: id, in: p) {
            $0.prescription = first.payload()
        }
        try context.save()

        // Second open: a brand-new draft store, hydrated from the stored
        // payload exactly as `load()` does.
        let reopened = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)

        XCTAssertEqual(reopened.prescription.techniquePlans.count, 1)
        XCTAssertEqual(
            reopened.prescription.techniquePlans.first?.type, .restPause)
        XCTAssertEqual(
            reopened.prescription.techniquePlans.first?.restSeconds, 15)
        XCTAssertEqual(reopened.payload().techniques.count, 1)
        XCTAssertEqual(try count(TechniquePlan.self), 0)
    }

    // ==================================================
    // MARK: - 8. It reaches the active workout
    // ==================================================

    func testApplyingThePreparedAlternativeCarriesTheTechniqueIntoTheWorkout()
        throws
    {
        let (p, id) = try slotWithAlternative()
        let store = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)
        addPlan(.dropset, to: store.prescription)
        SlotAlternativeAuthoring.update(id: id, in: p) {
            $0.prescription = store.payload()
        }
        try context.save()

        let payload = try XCTUnwrap(p.slotAlternatives.first).prescription
        let outcome = ExerciseSwitchPlanAdapter.outcome(
            choice: .useAlternative(payload),
            current: SessionPlan(),
            oldMode: .strength,
            newMode: .strength,
            resetSource: .appDefaults(for: .strength))

        let replacements = try XCTUnwrap(outcome.replacementTechniques)
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(replacements.first?.type, .dropset)
        XCTAssertEqual(replacements.first?.dropPercent, 20)
        XCTAssertEqual(replacements.first?.dropCount, 1)
        XCTAssertFalse(outcome.keepTechniques)
    }

    // ==================================================
    // MARK: - 9. Normal routine technique editing is unchanged
    // ==================================================

    /// A real routine slot's prescription is registered in the app's context,
    /// so the resolved write context *is* the environment's — the rows land in
    /// the user's store exactly as before.
    func testNormalRoutineTechniqueInsertionIsUnchanged() throws {
        let p = appPrescription()

        XCTAssertIdentical(
            TechniquePlanAuthoring.writeContext(for: p, fallback: context),
            context)

        let plan = addPlan(.dropset, to: p)
        try context.save()

        XCTAssertIdentical(plan.modelContext, context)
        XCTAssertEqual(try count(TechniquePlan.self), 1)
        XCTAssertEqual(p.techniquePlans.count, 1)
        XCTAssertEqual(p.techniquePlans.first?.order, 0)
    }

    func testNormalRoutineTechniqueDeletionIsUnchanged() throws {
        let p = appPrescription()
        let keep = addPlan(.dropset, to: p)
        let doomed = addPlan(.cluster, to: p)
        try context.save()
        XCTAssertEqual(try count(TechniquePlan.self), 2)

        TechniquePlanAuthoring.delete(
            [doomed], from: p, fallbackContext: context)
        try context.save()

        XCTAssertEqual(try count(TechniquePlan.self), 1)
        XCTAssertEqual(p.techniquePlans.map(\.id), [keep.id])
    }

    /// A prescription that is not registered anywhere yet falls back to the
    /// caller's context — the pre-fix behavior for that case, unchanged.
    func testAnUnregisteredPrescriptionFallsBackToTheCallersContext() {
        let orphan = SlotPrescription()

        XCTAssertIdentical(
            TechniquePlanAuthoring.writeContext(for: orphan, fallback: context),
            context)
    }

    // ==================================================
    // MARK: - 10. The parent slot is untouched
    // ==================================================

    func testScratchTechniqueDoesNotTouchTheParentPrescription() throws {
        let (p, id) = try slotWithAlternative()
        p.sets = 3
        p.repMin = 8
        p.repMax = 12
        try context.save()

        let store = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)
        addPlan(.dropset, to: store.prescription)
        SlotAlternativeAuthoring.update(id: id, in: p) {
            $0.prescription = store.payload()
        }
        try context.save()

        XCTAssertTrue(
            p.techniquePlans.isEmpty,
            "the alternative's technique must never become the slot's own")
        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
        XCTAssertEqual(try count(TechniquePlan.self), 0)
        XCTAssertEqual(
            try XCTUnwrap(p.slotAlternatives.first).prescription
                .techniques.count,
            1)
    }

    /// Dropping the draft store (the editor screen going away) leaves nothing
    /// behind and does not disturb what was committed.
    func testDroppingTheDraftStoreLeavesNothingBehind() throws {
        let (p, id) = try slotWithAlternative()
        var store: AlternativeDraftStore? = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)
        addPlan(.cluster, to: try XCTUnwrap(store).prescription)
        SlotAlternativeAuthoring.update(id: id, in: p) {
            $0.prescription = try! XCTUnwrap(store).payload()
        }
        try context.save()

        store = nil

        XCTAssertEqual(try count(TechniquePlan.self), 0)
        XCTAssertEqual(try count(SlotPrescription.self), 1)
        XCTAssertEqual(
            try XCTUnwrap(p.slotAlternatives.first).prescription
                .techniques.count,
            1,
            "the committed payload survives the scratch graph it came from")
    }

    /// Warm-ups and techniques are edited through the same scratch graph, so
    /// adding one must not disturb the other.
    func testWarmupAndTechniqueCoexistInTheSameScratchGraph() throws {
        let store = try draft()

        WarmupSchemeAuthoring.addStep(
            to: store.prescription, kind: .percentage, reps: 8,
            percentOfWorking: 0.5, restSecondsAfter: 60, note: nil,
            weight: nil, fallbackContext: context)
        addPlan(.dropset, to: store.prescription)

        let payload = store.payload()
        XCTAssertEqual(payload.warmupSteps.count, 1)
        XCTAssertEqual(payload.techniques.count, 1)
        XCTAssertEqual(try count(WarmupScheme.self), 0)
        XCTAssertEqual(try count(WarmupStep.self), 0)
        XCTAssertEqual(try count(TechniquePlan.self), 0)
    }
}
