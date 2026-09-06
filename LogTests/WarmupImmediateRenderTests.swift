import SwiftData
import XCTest

@testable import Log

/// Issue: a warm-up step added on a real iPhone sometimes did not appear until
/// the editor was popped and re-pushed, and the `Warmup   N steps` preview on
/// the prescription screen never updated until the whole page was reopened.
///
/// The defect is an observation gap, not a write failure: every mutation
/// reached the store correctly, but the views reading it were never
/// invalidated.
///
///  - `WarmupSchemeEditor` renders from `prescription.warmupScheme?.steps`.
///    `steps` belongs to the `WarmupScheme` — a **grandchild** of the model the
///    view binds — so the only warm-up mutation that invalidates that body is
///    `prescription.warmupScheme = s`, the lazy scheme creation on the very
///    first add. Every later add, edit, delete and move writes only to the
///    scheme and its steps.
///  - `SlotPrescriptionSection` read the preview count two models below its
///    `@Bindable var re`, so nothing the editor did could ever invalidate it.
///
/// The fix is a local revision token in each of those views (the same
/// workaround `RoutineEditor.blockSummaryRefresh` and `SupersetSetCountLabel`
/// already use), bumped from the `onGraphChange` hook every mutation now
/// returns through. The views themselves are not testable here; what *is*
/// testable, and what these tests pin, is the contract they depend on:
///
///  1. every mutation goes through `WarmupSchemeAuthoring`, so exactly one
///     hook site covers add / edit / delete / move;
///  2. `WarmupSummary` — the single list source shared by the editor's list and
///     the row's preview count — reports the change on the very next read, with
///     no reload, refetch or re-hydration in between.
///
/// "Immediately" below therefore means: read straight back off the same live
/// object graph the view renders from, with nothing reopened.
@MainActor
final class WarmupImmediateRenderTests: SwiftDataTestHarness {

    // ==================================================
    // MARK: - Fixtures
    // ==================================================

    private func routineSlotPrescription() -> SlotPrescription {
        let p = SlotPrescription()
        p.sets = 3
        p.repMin = 8
        p.repMax = 12
        context.insert(p)
        try? context.save()
        return p
    }

    /// One add, through the exact call the editor's Add button makes.
    @discardableResult
    private func addStep(
        to prescription: SlotPrescription,
        note: String,
        reps: Int? = 5,
        weight: Double? = 40
    ) -> WarmupStep {
        WarmupSchemeAuthoring.addStep(
            to: prescription,
            kind: .fixedReps,
            reps: reps,
            percentOfWorking: nil,
            restSecondsAfter: nil,
            note: note,
            weight: weight,
            fallbackContext: context)
    }

    /// What the editor's list renders, and what its preview count counts —
    /// read fresh, exactly as a re-evaluated body would.
    private func renderedNotes(_ prescription: SlotPrescription) -> [String] {
        WarmupSummary.steps(of: prescription).compactMap(\.note)
    }

    private func previewCount(_ prescription: SlotPrescription) -> Int {
        WarmupSummary.stepCount(of: prescription)
    }

    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    // ==================================================
    // MARK: - 1. Normal routine slot: add renders immediately
    // ==================================================

    /// Required behavior 1: the *first* step in a normal routine exercise.
    func testFirstAddAppearsInTheListSourceImmediately() {
        let p = routineSlotPrescription()
        XCTAssertTrue(renderedNotes(p).isEmpty)

        addStep(to: p, note: "A")

        XCTAssertEqual(renderedNotes(p), ["A"])
        XCTAssertEqual(previewCount(p), 1)
    }

    /// Every subsequent add too — these are the mutations that write only to
    /// the scheme, which is precisely what the bound prescription never
    /// observed.
    func testSubsequentAddsAppearInTheListSourceImmediately() {
        let p = routineSlotPrescription()

        addStep(to: p, note: "A")
        XCTAssertEqual(renderedNotes(p), ["A"])

        addStep(to: p, note: "B")
        XCTAssertEqual(renderedNotes(p), ["A", "B"])
        XCTAssertEqual(previewCount(p), 2)

        addStep(to: p, note: "C")
        XCTAssertEqual(renderedNotes(p), ["A", "B", "C"])
        XCTAssertEqual(previewCount(p), 3)
    }

    /// The sharpest form of the report's "sometimes": deleting the last step
    /// leaves the scheme attached (`deleteRule: .nullify`), so the *next* add
    /// no longer assigns `prescription.warmupScheme` and no longer produces the
    /// one mutation the bound prescription used to notice. The list source must
    /// still report it.
    func testAddAfterDeletingEveryStepStillRendersImmediately() {
        let p = routineSlotPrescription()
        addStep(to: p, note: "A")

        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet(integer: 0), in: p, fallbackContext: context)
        XCTAssertTrue(renderedNotes(p).isEmpty)
        XCTAssertNotNil(
            p.warmupScheme,
            "the emptied scheme stays attached — this is what makes the next "
                + "add invisible to the prescription's own observation")

        addStep(to: p, note: "B")

        XCTAssertEqual(renderedNotes(p), ["B"])
        XCTAssertEqual(previewCount(p), 1)
    }

    // ==================================================
    // MARK: - 2. Normal routine slot: edit / delete / move
    // ==================================================

    /// Required behavior 2 (edit).
    func testEditUpdatesTheListSourceImmediately() throws {
        let p = routineSlotPrescription()
        addStep(to: p, note: "A")
        addStep(to: p, note: "B")

        let first = try XCTUnwrap(WarmupSummary.steps(of: p).first)
        WarmupSchemeAuthoring.updateStep(
            first,
            in: p,
            kind: .percentage,
            reps: 8,
            percentOfWorking: 0.5,
            restSecondsAfter: 60,
            note: "A edited",
            weight: nil,
            fallbackContext: context)

        XCTAssertEqual(renderedNotes(p), ["A edited", "B"])
        let rendered = try XCTUnwrap(WarmupSummary.steps(of: p).first)
        XCTAssertEqual(rendered.kind, .percentage)
        XCTAssertEqual(rendered.reps, 8)
        XCTAssertEqual(rendered.percentOfWorking, 0.5)
        XCTAssertEqual(rendered.restSecondsAfter, 60)
        XCTAssertNil(rendered.weight)
        XCTAssertEqual(rendered.order, 0, "an edit never moves a step")
        XCTAssertEqual(previewCount(p), 2, "an edit never changes the count")
    }

    /// Required behavior 2 (delete).
    func testDeleteUpdatesTheListSourceImmediately() {
        let p = routineSlotPrescription()
        addStep(to: p, note: "A")
        addStep(to: p, note: "B")
        addStep(to: p, note: "C")

        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet(integer: 1), in: p, fallbackContext: context)

        XCTAssertEqual(renderedNotes(p), ["A", "C"])
        XCTAssertEqual(previewCount(p), 2)
        XCTAssertEqual(
            WarmupSummary.steps(of: p).map(\.order), [0, 1],
            "survivors are renumbered contiguously")
    }

    /// Required behavior 2 (move).
    func testMoveUpdatesTheListSourceImmediately() {
        let p = routineSlotPrescription()
        addStep(to: p, note: "A")
        addStep(to: p, note: "B")
        addStep(to: p, note: "C")

        // Drag C to the top.
        WarmupSchemeAuthoring.moveSteps(
            fromOffsets: IndexSet(integer: 2), toOffset: 0,
            in: p, fallbackContext: context)

        XCTAssertEqual(renderedNotes(p), ["C", "A", "B"])
        XCTAssertEqual(WarmupSummary.steps(of: p).map(\.order), [0, 1, 2])
        XCTAssertEqual(previewCount(p), 3, "a move never changes the count")
    }

    /// A move records position in `order`, which is the *only* record of it:
    /// SwiftData does not promise any ordering for a to-many relationship
    /// array, and `scheme.steps` is observed to come back permuted after a save
    /// (this assertion caught exactly that). The display list must therefore be
    /// correct however the raw array happens to be arranged.
    func testMoveIsRecordedInOrderNotInTheRelationshipArray() throws {
        let p = routineSlotPrescription()
        addStep(to: p, note: "A")
        addStep(to: p, note: "B")
        addStep(to: p, note: "C")

        WarmupSchemeAuthoring.moveSteps(
            fromOffsets: IndexSet(integer: 0), toOffset: 3,
            in: p, fallbackContext: context)
        try context.save()

        let scheme = try XCTUnwrap(p.warmupScheme)
        XCTAssertEqual(
            WarmupSummary.steps(of: scheme).compactMap(\.note),
            ["B", "C", "A"])
        XCTAssertEqual(
            WarmupSummary.steps(of: scheme).map(\.order), [0, 1, 2])
        // The same list the pushed editor renders and the row counts.
        XCTAssertEqual(renderedNotes(p), ["B", "C", "A"])
        XCTAssertEqual(previewCount(p), 3)
    }

    // ==================================================
    // MARK: - 3. Normal routine slot: preview count
    // ==================================================

    /// Required behavior 3, the half that never worked at all: the preview
    /// count moves on an add…
    func testPreviewCountChangesAfterAdd() {
        let p = routineSlotPrescription()
        XCTAssertEqual(previewCount(p), 0)

        addStep(to: p, note: "A")
        XCTAssertEqual(previewCount(p), 1)

        addStep(to: p, note: "B")
        XCTAssertEqual(previewCount(p), 2)
    }

    /// …and on a delete, back down to the `None` case.
    func testPreviewCountChangesAfterDelete() {
        let p = routineSlotPrescription()
        addStep(to: p, note: "A")
        addStep(to: p, note: "B")
        XCTAssertEqual(previewCount(p), 2)

        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet(integer: 0), in: p, fallbackContext: context)
        XCTAssertEqual(previewCount(p), 1)

        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet(integer: 0), in: p, fallbackContext: context)
        XCTAssertEqual(
            previewCount(p), 0,
            "an emptied-but-attached scheme reads as None, not as a stale 1")
    }

    /// The row's count and the editor's list are the same value by
    /// construction — the row can never claim a count the screen it pushes
    /// does not show.
    func testPreviewCountAndListSourceNeverDisagree() {
        let p = routineSlotPrescription()
        for note in ["A", "B", "C", "D"] { addStep(to: p, note: note) }

        XCTAssertEqual(previewCount(p), WarmupSummary.steps(of: p).count)

        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet([0, 2]), in: p, fallbackContext: context)
        XCTAssertEqual(previewCount(p), WarmupSummary.steps(of: p).count)
        XCTAssertEqual(renderedNotes(p), ["B", "D"])
    }

    /// A slot that never had a warm-up reads as zero, not as a crash — the
    /// `None` branch of the row.
    func testPreviewCountOfASlotWithNoSchemeIsZero() {
        let p = routineSlotPrescription()
        XCTAssertNil(p.warmupScheme)
        XCTAssertEqual(previewCount(p), 0)
        XCTAssertTrue(WarmupSummary.steps(of: p).isEmpty)
        XCTAssertEqual(WarmupSummary.stepCount(of: nil), 0)
        XCTAssertTrue(WarmupSummary.steps(of: nil as SlotPrescription?).isEmpty)
    }

    /// The list source sorts by `order`, never by the raw relationship array —
    /// the invariant the editor's rows and the session freeze both rely on.
    func testListSourceSortsByOrderNotByRelationshipArray() {
        let p = routineSlotPrescription()
        let scheme = WarmupScheme(name: "Warmup")
        context.insert(scheme)
        let c = WarmupStep(order: 2, kind: .noteOnly, note: "C")
        let a = WarmupStep(order: 0, kind: .noteOnly, note: "A")
        let b = WarmupStep(order: 1, kind: .noteOnly, note: "B")
        for step in [c, a, b] { context.insert(step) }
        scheme.steps = [c, a, b]
        p.warmupScheme = scheme
        try? context.save()

        XCTAssertEqual(renderedNotes(p), ["A", "B", "C"])
    }

    // ==================================================
    // MARK: - 4. Prepared alternative: the same, on the scratch slot
    // ==================================================

    /// A slot carrying one prepared alternative, and that alternative's id.
    private func slotWithAlternative() throws -> (SlotPrescription, UUID) {
        let p = routineSlotPrescription()
        let added = SlotAlternativeAuthoring.append(
            exerciseID: UUID(),
            exerciseName: "Machine Chest Press",
            prescription: AlternativeDraftStore.defaultPayload(for: .strength),
            to: p)
        try context.save()
        return (p, added.id)
    }

    /// The draft the detail editor builds on appear.
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

    /// The full nested-editor gesture: mutate the scratch graph, then run the
    /// `onGraphChange` hook — which commits the draft *and*, in the view layer,
    /// bumps both revision tokens.
    @discardableResult
    private func commit(
        _ store: AlternativeDraftStore,
        to p: SlotPrescription,
        alternativeID: UUID
    ) -> Bool {
        AlternativeDraftCommit.commit(
            draft: store,
            alternativeID: alternativeID,
            isEnabled: true,
            note: "",
            into: p,
            context: context)
    }

    private func storedSteps(
        _ p: SlotPrescription, _ id: UUID
    ) throws -> [WarmupStepSnapshot] {
        try XCTUnwrap(p.slotAlternatives.first(where: { $0.id == id }))
            .prescription.warmupSteps
    }

    /// Required behavior 4 + 6: the first step on a prepared alternative shows
    /// in the scratch list source and in the scratch preview count at once, and
    /// the commit reaches the stored payload.
    func testAlternativeFirstAddRendersAndCommitsImmediately() throws {
        let (p, id) = try slotWithAlternative()
        let store = try openEditor(p, id)
        XCTAssertEqual(previewCount(store.prescription), 0)

        addStep(to: store.prescription, note: "ramp")
        XCTAssertTrue(
            commit(store, to: p, alternativeID: id),
            "the hook commits the alternative it is editing")

        // The scratch slot — what the pushed editor and the alternative's own
        // prescription row both render.
        XCTAssertEqual(renderedNotes(store.prescription), ["ramp"])
        XCTAssertEqual(previewCount(store.prescription), 1)
        // And the stored payload.
        XCTAssertEqual(try storedSteps(p, id).count, 1)
        XCTAssertEqual(try storedSteps(p, id).first?.note, "ramp")
    }

    /// Required behavior 5 + 6: edit, move and delete on the alternative, each
    /// visible in the scratch list source and committed on the spot.
    func testAlternativeEditMoveDeleteRenderAndCommitImmediately() throws {
        let (p, id) = try slotWithAlternative()
        let store = try openEditor(p, id)
        let scratch = store.prescription

        addStep(to: scratch, note: "A")
        addStep(to: scratch, note: "B")
        commit(store, to: p, alternativeID: id)
        XCTAssertEqual(renderedNotes(scratch), ["A", "B"])
        XCTAssertEqual(previewCount(scratch), 2)
        XCTAssertEqual(try storedSteps(p, id).count, 2)

        // Edit.
        let first = try XCTUnwrap(WarmupSummary.steps(of: scratch).first)
        WarmupSchemeAuthoring.updateStep(
            first, in: scratch, kind: .fixedReps, reps: 12,
            percentOfWorking: nil, restSecondsAfter: 30, note: "A edited",
            weight: 25, fallbackContext: context)
        commit(store, to: p, alternativeID: id)
        XCTAssertEqual(renderedNotes(scratch), ["A edited", "B"])
        XCTAssertEqual(try storedSteps(p, id).first?.note, "A edited")
        XCTAssertEqual(try storedSteps(p, id).first?.reps, 12)

        // Move.
        WarmupSchemeAuthoring.moveSteps(
            fromOffsets: IndexSet(integer: 0), toOffset: 2,
            in: scratch, fallbackContext: context)
        commit(store, to: p, alternativeID: id)
        XCTAssertEqual(renderedNotes(scratch), ["B", "A edited"])
        XCTAssertEqual(
            try storedSteps(p, id).map(\.note), ["B", "A edited"])
        XCTAssertEqual(try storedSteps(p, id).map(\.order), [0, 1])

        // Delete.
        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet(integer: 0), in: scratch, fallbackContext: context)
        commit(store, to: p, alternativeID: id)
        XCTAssertEqual(renderedNotes(scratch), ["A edited"])
        XCTAssertEqual(previewCount(scratch), 1)
        XCTAssertEqual(try storedSteps(p, id).map(\.note), ["A edited"])
    }

    /// Required behavior 6, the delete half: the alternative's preview count
    /// falls back to `None` and the payload empties with it.
    func testAlternativePreviewCountDropsToZeroOnDelete() throws {
        let (p, id) = try slotWithAlternative()
        let store = try openEditor(p, id)

        addStep(to: store.prescription, note: "only")
        commit(store, to: p, alternativeID: id)
        XCTAssertEqual(previewCount(store.prescription), 1)

        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet(integer: 0), in: store.prescription,
            fallbackContext: context)
        commit(store, to: p, alternativeID: id)

        XCTAssertEqual(previewCount(store.prescription), 0)
        XCTAssertTrue(try storedSteps(p, id).isEmpty)
    }

    // ==================================================
    // MARK: - 5. Leaving and coming back
    // ==================================================

    /// Required behavior 7 + 8: the immediate-render fix is a view-state
    /// change, so what is *stored* must be exactly what it was — reopening the
    /// alternative (a fresh draft, as a tab switch and a re-push produce) still
    /// hydrates the same steps.
    func testReopeningTheAlternativeStillShowsTheSavedSteps() throws {
        let (p, id) = try slotWithAlternative()
        var first: AlternativeDraftStore? = try openEditor(p, id)
        let store = try XCTUnwrap(first)
        addStep(to: store.prescription, note: "ramp")
        addStep(to: store.prescription, note: "second")
        commit(store, to: p, alternativeID: id)
        first = nil  // back to the routine, then a tab switch

        let reopened = try openEditor(p, id)
        XCTAssertEqual(renderedNotes(reopened.prescription), ["ramp", "second"])
        XCTAssertEqual(previewCount(reopened.prescription), 2)
        XCTAssertEqual(reopened.payload().warmupSteps.map(\.order), [0, 1])
    }

    /// The same for a normal routine slot: the steps are in the user's store,
    /// so a refetched prescription renders them.
    func testRoutineSlotWarmupSurvivesAReopen() throws {
        let p = routineSlotPrescription()
        addStep(to: p, note: "A")
        addStep(to: p, note: "B")
        try context.save()

        let refetched = try XCTUnwrap(
            context.model(for: p.persistentModelID) as? SlotPrescription)
        XCTAssertEqual(renderedNotes(refetched), ["A", "B"])
        XCTAssertEqual(previewCount(refetched), 2)
    }

    // ==================================================
    // MARK: - 6. Into the workout
    // ==================================================

    /// Required behavior 9: applying the prepared alternative still carries the
    /// warm-up the user just authored into the active workout.
    func testAppliedAlternativeStillCarriesTheWarmupIntoTheWorkout() throws {
        let (p, id) = try slotWithAlternative()
        let store = try openEditor(p, id)
        WarmupSchemeAuthoring.addStep(
            to: store.prescription, kind: .percentage, reps: 8,
            percentOfWorking: 0.5, restSecondsAfter: 60, note: "ramp",
            weight: nil, fallbackContext: context)
        commit(store, to: p, alternativeID: id)

        let payload = try XCTUnwrap(
            p.slotAlternatives.first(where: { $0.id == id })).prescription
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
    // MARK: - 7. Blast radius
    // ==================================================

    /// Required behavior 10: the parent routine slot never receives the
    /// alternative's warm-up, and nothing the scratch editor created reaches
    /// the user's store.
    func testAlternativeWarmupNeverReachesTheParentSlot() throws {
        let (p, id) = try slotWithAlternative()
        let store = try openEditor(p, id)

        addStep(to: store.prescription, note: "ramp")
        WarmupSchemeAuthoring.moveSteps(
            fromOffsets: IndexSet(integer: 0), toOffset: 1,
            in: store.prescription, fallbackContext: context)
        commit(store, to: p, alternativeID: id)

        XCTAssertNil(
            p.warmupScheme,
            "the alternative's warm-up must never become the slot's own")
        XCTAssertEqual(previewCount(p), 0)
        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
        XCTAssertEqual(try count(WarmupScheme.self), 0)
        XCTAssertEqual(try count(WarmupStep.self), 0)
    }

    /// Required behavior 11: sibling alternatives are untouched by a warm-up
    /// edit — including the delete and move paths this slice rewrote.
    func testSiblingAlternativesAreUntouchedByAWarmupEdit() throws {
        let p = routineSlotPrescription()
        var ids: [UUID] = []
        for name in ["First", "Second", "Third"] {
            ids.append(
                SlotAlternativeAuthoring.append(
                    exerciseID: UUID(),
                    exerciseName: name,
                    prescription: AlternativeDraftStore.defaultPayload(
                        for: .strength),
                    to: p
                ).id)
        }
        SlotAlternativeAuthoring.update(id: ids[2], in: p) {
            $0.isEnabled = false
        }
        SlotAlternativeAuthoring.update(id: ids[1], in: p) {
            $0.note = "if the rack is busy"
        }
        try context.save()
        let before = p.slotAlternatives

        // Edit the first alternative's warm-up through every mutation path.
        let store = try openEditor(p, ids[0])
        addStep(to: store.prescription, note: "A")
        addStep(to: store.prescription, note: "B")
        WarmupSchemeAuthoring.moveSteps(
            fromOffsets: IndexSet(integer: 1), toOffset: 0,
            in: store.prescription, fallbackContext: context)
        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet(integer: 1), in: store.prescription,
            fallbackContext: context)
        commit(store, to: p, alternativeID: ids[0])

        let after = p.slotAlternatives
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.order), [0, 1, 2])
        XCTAssertEqual(
            after.map(\.exerciseName), ["First", "Second", "Third"])

        let second = try XCTUnwrap(after.first { $0.id == ids[1] })
        XCTAssertEqual(second.note, "if the rack is busy")
        XCTAssertTrue(second.isEnabled)
        XCTAssertTrue(second.prescription.warmupSteps.isEmpty)

        let third = try XCTUnwrap(after.first { $0.id == ids[2] })
        XCTAssertFalse(third.isEnabled, "a disabled sibling stays disabled")
        XCTAssertTrue(third.prescription.warmupSteps.isEmpty)

        // Only the edited one changed, and it kept just the surviving step.
        XCTAssertEqual(try storedSteps(p, ids[0]).map(\.note), ["B"])
    }

    /// A warm-up edit on a routine slot leaves that slot's own plan alone — the
    /// mutations only ever touch the scheme and its steps.
    func testRoutineWarmupEditingDoesNotDisturbTheSlotsPlan() {
        let p = routineSlotPrescription()
        p.restSecondsBetweenSets = 90
        p.rir = 2
        try? context.save()

        addStep(to: p, note: "A")
        addStep(to: p, note: "B")
        WarmupSchemeAuthoring.moveSteps(
            fromOffsets: IndexSet(integer: 0), toOffset: 2,
            in: p, fallbackContext: context)
        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet(integer: 0), in: p, fallbackContext: context)

        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
        XCTAssertEqual(p.restSecondsBetweenSets, 90)
        XCTAssertEqual(p.rir, 2)
        XCTAssertNil(
            p.alternativesData,
            "a slot with no alternatives gains no payload from its own editing")
    }

    // ==================================================
    // MARK: - 8. Delete hygiene
    // ==================================================

    /// The deleted rows really leave the store — the whole-array reassignment
    /// replaced an in-place `removeAll`, and must not have turned a delete into
    /// an orphan.
    func testDeletedStepsAreRemovedFromTheStore() throws {
        let p = routineSlotPrescription()
        addStep(to: p, note: "A")
        addStep(to: p, note: "B")
        addStep(to: p, note: "C")
        try context.save()
        XCTAssertEqual(try count(WarmupStep.self), 3)

        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet([0, 2]), in: p, fallbackContext: context)
        try context.save()

        XCTAssertEqual(try count(WarmupStep.self), 1)
        XCTAssertEqual(renderedNotes(p), ["B"])
        XCTAssertEqual(
            try count(WarmupScheme.self), 1,
            "the scheme itself survives an emptying delete")
    }

    /// An out-of-range offset is ignored rather than trapping — the list source
    /// and the offsets the swipe action builds are computed one render apart.
    func testOutOfRangeDeleteOffsetIsIgnored() {
        let p = routineSlotPrescription()
        addStep(to: p, note: "A")

        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet(integer: 5), in: p, fallbackContext: context)

        XCTAssertEqual(renderedNotes(p), ["A"])
        XCTAssertEqual(previewCount(p), 1)
    }

    /// Deleting from a prescription that never had a scheme is a no-op.
    func testDeleteOnASlotWithNoSchemeIsANoOp() {
        let p = routineSlotPrescription()
        WarmupSchemeAuthoring.deleteSteps(
            at: IndexSet(integer: 0), in: p, fallbackContext: context)
        XCTAssertNil(p.warmupScheme)
        XCTAssertEqual(previewCount(p), 0)
    }
}
