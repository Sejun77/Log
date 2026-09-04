import SwiftData
import XCTest

@testable import Log

/// Regression cover for the 1.0 (9) crash: adding a warm-up step to a
/// **prepared alternative** killed the app.
///
/// `SlotAlternativeDetailEditor` binds the real `SlotPrescriptionSection` — and
/// through it the real `WarmupSchemeEditor` — to a scratch slot living in
/// `AlternativeDraftStore`'s own in-memory container. The editor created its
/// `WarmupScheme` in `@Environment(\.modelContext)`, which for the pushed
/// editor is the **app's** context, and then assigned it to the scratch
/// prescription. Relating models across containers is a SwiftData
/// `fatalError` (`PersistentModel.swift`: *attempting to relate model … from
/// destination's model context*), i.e. the reported EXC_BREAKPOINT on
/// `SlotPrescription.warmupScheme.setter`.
///
/// Every test below therefore passes the harness's **app** context as
/// `fallbackContext` — exactly the wrong-store context the environment used to
/// hand the editor. `WarmupSchemeAuthoring` must ignore it whenever the
/// prescription already belongs somewhere else.
@MainActor
final class AlternativeWarmupScratchTests: SwiftDataTestHarness {

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

    /// One added step, through the exact call the editor's Add button makes.
    @discardableResult
    private func addFirstStep(
        to prescription: SlotPrescription
    ) -> WarmupStep {
        WarmupSchemeAuthoring.addStep(
            to: prescription,
            kind: .percentage,
            reps: 8,
            percentOfWorking: 0.5,
            restSecondsAfter: 60,
            note: "ramp",
            weight: nil,
            fallbackContext: context)
    }

    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    /// A slot prescription carrying one prepared alternative, and that
    /// alternative's id.
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
    // MARK: - 1. The scratch prescription starts clean
    // ==================================================

    func testScratchPrescriptionStartsWithNoWarmup() throws {
        let store = try draft()

        XCTAssertNil(
            store.prescription.warmupScheme,
            "a freshly seeded alternative has no warm-up scheme at all — which "
                + "is the branch that used to crash")
        XCTAssertTrue(store.payload().warmupSteps.isEmpty)
        XCTAssertEqual(try count(WarmupScheme.self), 0)
    }

    // ==================================================
    // MARK: - 2. Adding the first step no longer crashes
    // ==================================================

    /// The regression test proper: this call trapped before the fix.
    func testAddingTheFirstWarmupStepToAPreparedAlternativeDoesNotCrash() throws {
        let store = try draft()

        let step = addFirstStep(to: store.prescription)

        XCTAssertEqual(step.order, 0)
        XCTAssertEqual(step.kind, .percentage)
        XCTAssertEqual(step.reps, 8)
        XCTAssertEqual(step.percentOfWorking, 0.5)
        XCTAssertEqual(step.restSecondsAfter, 60)
        XCTAssertEqual(step.note, "ramp")
    }

    /// The scheme and step are created in the draft container, never the user's
    /// store — the leak guarantee `AlternativeDraftStore` is built around.
    func testTheScratchWarmupNeverReachesTheAppStore() throws {
        let store = try draft()
        addFirstStep(to: store.prescription)
        try context.save()

        XCTAssertEqual(try count(WarmupScheme.self), 0)
        XCTAssertEqual(try count(WarmupStep.self), 0)
        XCTAssertIdentical(
            store.prescription.warmupScheme?.modelContext, store.context)
        XCTAssertIdentical(
            store.prescription.warmupScheme?.steps.first?.modelContext,
            store.context)
    }

    /// A second step appends rather than replacing, and keeps ordering.
    func testAddingASecondStepAppends() throws {
        let store = try draft()
        addFirstStep(to: store.prescription)
        WarmupSchemeAuthoring.addStep(
            to: store.prescription, kind: .fixedReps, reps: 5,
            percentOfWorking: nil, restSecondsAfter: nil, note: nil,
            weight: 40, fallbackContext: context)

        XCTAssertEqual(
            store.payload().warmupSteps.map(\.order), [0, 1])
        XCTAssertEqual(try count(WarmupStep.self), 0)
    }

    // ==================================================
    // MARK: - 3. It shows up in the editor immediately
    // ==================================================

    func testAddedStepAppearsInTheScratchPrescription() throws {
        let store = try draft()
        addFirstStep(to: store.prescription)

        XCTAssertEqual(store.prescription.warmupScheme?.steps.count, 1)
        let payload = store.payload()
        XCTAssertEqual(payload.warmupSteps.count, 1)
        XCTAssertEqual(payload.warmupSteps.first?.reps, 8)
        XCTAssertEqual(payload.warmupSteps.first?.percentOfWorking, 0.5)
    }

    // ==================================================
    // MARK: - 4. It is encoded back into the payload
    // ==================================================

    func testCommittingTheDraftEncodesTheWarmupIntoTheAlternative() throws {
        let (p, id) = try slotWithAlternative()
        let stored = try XCTUnwrap(p.slotAlternatives.first).prescription

        let store = try draft(stored)
        addFirstStep(to: store.prescription)

        // What `SlotAlternativeDetailEditor.commit(payload:)` does.
        SlotAlternativeAuthoring.update(id: id, in: p) {
            $0.prescription = store.payload()
        }
        try context.save()

        let written = try XCTUnwrap(p.slotAlternatives.first).prescription
        XCTAssertEqual(written.warmupSteps.count, 1)
        XCTAssertEqual(written.warmupSteps.first?.kind, .percentage)
        XCTAssertEqual(written.warmupSteps.first?.reps, 8)
        XCTAssertEqual(written.warmupSteps.first?.percentOfWorking, 0.5)
        XCTAssertEqual(written.warmupSteps.first?.restSecondsAfter, 60)
        XCTAssertEqual(written.warmupSteps.first?.note, "ramp")
    }

    // ==================================================
    // MARK: - 5. Reopening the alternative shows it
    // ==================================================

    func testReopeningTheAlternativeShowsTheWarmupStep() throws {
        let (p, id) = try slotWithAlternative()
        let first = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)
        addFirstStep(to: first.prescription)
        SlotAlternativeAuthoring.update(id: id, in: p) {
            $0.prescription = first.payload()
        }
        try context.save()

        // Second open: a brand-new draft store, hydrated from the stored
        // payload exactly as `load()` does.
        let reopened = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)

        XCTAssertEqual(reopened.prescription.warmupScheme?.steps.count, 1)
        XCTAssertEqual(
            reopened.prescription.warmupScheme?.steps.first?.reps, 8)
        XCTAssertEqual(reopened.payload().warmupSteps.count, 1)
    }

    // ==================================================
    // MARK: - 6. It reaches the active workout
    // ==================================================

    /// Applying the prepared alternative mid-workout must carry the warm-up the
    /// user just authored into the session plan.
    func testApplyingThePreparedAlternativeCarriesTheWarmupIntoTheWorkout() throws {
        let (p, id) = try slotWithAlternative()
        let store = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)
        addFirstStep(to: store.prescription)
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

        XCTAssertEqual(
            outcome.replacementWarmupSteps,
            [
                WarmupStepSnapshot(
                    order: 0, kind: .percentage, reps: 8,
                    percentOfWorking: 0.5, note: "ramp",
                    restSecondsAfter: 60, weight: nil)
            ])
        XCTAssertFalse(outcome.keepWarmupSteps)
    }

    // ==================================================
    // MARK: - 7. Normal routine warm-up editing is unchanged
    // ==================================================

    /// A real routine slot's prescription is registered in the app's context,
    /// so the resolved write context *is* the environment's — the rows land in
    /// the user's store exactly as before.
    func testNormalRoutineWarmupInsertionIsUnchanged() throws {
        let p = appPrescription()

        XCTAssertIdentical(
            WarmupSchemeAuthoring.writeContext(for: p, fallback: context),
            context)

        addFirstStep(to: p)
        try context.save()

        XCTAssertEqual(try count(WarmupScheme.self), 1)
        XCTAssertEqual(try count(WarmupStep.self), 1)
        XCTAssertEqual(p.warmupScheme?.steps.count, 1)
        XCTAssertEqual(p.warmupScheme?.name, "Warmup")
        XCTAssertEqual(p.warmupScheme?.steps.first?.order, 0)
    }

    /// A prescription that is not registered anywhere yet falls back to the
    /// caller's context — the pre-fix behavior for that case, unchanged.
    func testAnUnregisteredPrescriptionFallsBackToTheCallersContext() throws {
        let orphan = SlotPrescription()

        XCTAssertIdentical(
            WarmupSchemeAuthoring.writeContext(for: orphan, fallback: context),
            context)
    }

    // ==================================================
    // MARK: - 8/9. Scratch lifecycle
    // ==================================================

    /// Editing an alternative's warm-up leaves the parent slot's own
    /// prescription completely alone — no scheme, no steps, no field changes.
    func testScratchWarmupDoesNotTouchTheParentPrescription() throws {
        let (p, id) = try slotWithAlternative()
        p.sets = 3
        p.repMin = 8
        p.repMax = 12
        try context.save()

        let store = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)
        addFirstStep(to: store.prescription)
        SlotAlternativeAuthoring.update(id: id, in: p) {
            $0.prescription = store.payload()
        }
        try context.save()

        XCTAssertNil(
            p.warmupScheme,
            "the alternative's warm-up must never become the slot's own")
        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
        XCTAssertEqual(try count(WarmupScheme.self), 0)
        XCTAssertEqual(try count(WarmupStep.self), 0)
    }

    /// Dropping the draft store (the editor screen going away) leaves nothing
    /// behind in the user's store and does not disturb what was committed.
    func testDroppingTheDraftStoreLeavesNothingBehind() throws {
        let (p, id) = try slotWithAlternative()
        var store: AlternativeDraftStore? = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)
        addFirstStep(to: try XCTUnwrap(store).prescription)
        SlotAlternativeAuthoring.update(id: id, in: p) {
            $0.prescription = try! XCTUnwrap(store).payload()
        }
        try context.save()

        store = nil

        XCTAssertEqual(try count(WarmupScheme.self), 0)
        XCTAssertEqual(try count(WarmupStep.self), 0)
        XCTAssertEqual(try count(SlotPrescription.self), 1)
        XCTAssertEqual(
            try XCTUnwrap(p.slotAlternatives.first).prescription
                .warmupSteps.count,
            1,
            "the committed payload survives the scratch graph it came from")
    }

    /// The scratch graph stays live for as long as the editor holds it, so a
    /// SwiftUI binding pointing at a step it just added keeps resolving — the
    /// "cleanup happened too early" failure mode.
    func testScratchStepsStayReadableAfterCommitting() throws {
        let (p, id) = try slotWithAlternative()
        let store = try draft(
            try XCTUnwrap(p.slotAlternatives.first).prescription)
        let step = addFirstStep(to: store.prescription)

        SlotAlternativeAuthoring.update(id: id, in: p) {
            $0.prescription = store.payload()
        }
        try context.save()

        XCTAssertFalse(step.isDeleted)
        XCTAssertEqual(step.reps, 8)
        XCTAssertIdentical(step.modelContext, store.context)
        XCTAssertEqual(store.prescription.warmupScheme?.steps.count, 1)
    }

    // ==================================================
    // MARK: - 10. Everything else in the alternative is untouched
    // ==================================================

    /// Adding a warm-up must not disturb the sets / reps / rest / effort /
    /// technique / cardio / note fields the alternative already carried.
    func testAddingAWarmupLeavesTheRestOfTheAlternativeAlone() throws {
        var seeded = AlternativeDraftStore.defaultPayload(for: .strength)
        seeded.sets = 4
        seeded.repMin = 10
        seeded.repMax = 15
        seeded.restSecondsBetweenSets = 75
        seeded.rir = 3
        seeded.slotNotes = "seat height 4"
        seeded.techniques = [
            TechniquePlanSnapshot(
                order: 0, type: .dropset, dropPercent: 20, dropCount: 2,
                rounds: nil, restSeconds: 15, partialRangeNote: nil,
                note: nil, reps: nil)
        ]

        let store = try draft(seeded)
        addFirstStep(to: store.prescription)
        let after = store.payload()

        XCTAssertEqual(after.sets, 4)
        XCTAssertEqual(after.repMin, 10)
        XCTAssertEqual(after.repMax, 15)
        XCTAssertEqual(after.restSecondsBetweenSets, 75)
        XCTAssertEqual(after.rir, 3)
        XCTAssertEqual(after.slotNotes, "seat height 4")
        XCTAssertEqual(after.techniques.count, 1)
        XCTAssertEqual(after.techniques.first?.type, .dropset)
        XCTAssertEqual(after.warmupSteps.count, 1)
    }
}
