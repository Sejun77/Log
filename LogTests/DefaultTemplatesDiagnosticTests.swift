import SwiftData
import XCTest

@testable import Log

/// Phase 9 pre-9-C / pre-9-E diagnostic — pure helper
/// `BackfillService.diagnoseDefaultTemplatesRisk(in:)` and its
/// `DefaultTemplatesDiagnostics` value-type return. Counters gate
/// concrete audit decisions documented on the helper:
///   - `defaultTemplatesWithTargetWeight` → 9-E weight migration
///   - `defaultTemplatesNonWorkingKind` → 9-E warmup/dropset migration
///   - `slotsNeedingTier3` / `residualEmptyContentSlots` → 9-C "no slot
///     stranded" guarantee (both should read 0 post-9-A2 hydration)
///   - `slotsOrphanedNoSource` → routine-editor "unprogrammed slot" UX
///
/// Helper is read-only; tests never assert side effects on the model.
@MainActor
final class DefaultTemplatesDiagnosticTests: SwiftDataTestHarness {

    // MARK: - Fixture helpers

    @discardableResult
    private func makeExercise(
        name: String = "Bench Press",
        isTimeBased: Bool = false,
        defaultTemplates: [SetTemplate] = []
    ) -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        ex.isTimeBased = isTimeBased
        context.insert(ex)
        for tpl in defaultTemplates { context.insert(tpl) }
        ex.defaultTemplates = defaultTemplates
        return ex
    }

    @discardableResult
    private func makeSlot(
        exercise: Exercise?,
        setTemplates: [SetTemplate] = [],
        prescription: SlotPrescription? = nil
    ) -> RoutineExercise {
        for tpl in setTemplates { context.insert(tpl) }
        let stand = exercise ?? makeExercise(name: "__placeholder")
        let re = RoutineExercise(
            exercise: stand, order: 0, setTemplates: setTemplates
        )
        context.insert(re)
        if let p = prescription {
            context.insert(p)
            re.prescription = p
        }
        try? context.save()
        if exercise == nil { re.exercise = nil }
        return re
    }

    private func working(reps: Int, weight: Double? = nil, order: Int)
        -> SetTemplate
    {
        let t = SetTemplate(
            kind: .working, targetReps: reps, targetWeight: weight
        )
        t.order = order
        return t
    }

    private func warmup(reps: Int, order: Int) -> SetTemplate {
        let t = SetTemplate(kind: .warmup, targetReps: reps)
        t.order = order
        return t
    }

    private func dropset(reps: Int, order: Int) -> SetTemplate {
        let t = SetTemplate(kind: .dropset, targetReps: reps)
        t.order = order
        return t
    }

    // MARK: - Empty store baseline

    func testEmptyStoreReturnsZeroDiagnostics() {
        let d = BackfillService.diagnoseDefaultTemplatesRisk(in: context)
        XCTAssertEqual(d, .zero)
    }

    // MARK: - exercisesWithDefaultTemplates

    func testCountsExercisesWithNonEmptyDefaultTemplates() {
        _ = makeExercise(name: "Bench", defaultTemplates: [
            working(reps: 8, order: 0)
        ])
        _ = makeExercise(name: "Squat", defaultTemplates: [
            working(reps: 5, order: 0),
            working(reps: 5, order: 1),
        ])
        _ = makeExercise(name: "Plank")  // empty defaultTemplates
        try? context.save()

        let d = BackfillService.diagnoseDefaultTemplatesRisk(in: context)
        XCTAssertEqual(d.exercisesWithDefaultTemplates, 2)
    }

    // MARK: - defaultTemplatesWithTargetWeight (9-E weight migration gate)

    func testCountsDefaultTemplateRowsWithPositiveTargetWeight() {
        _ = makeExercise(
            name: "Weighted",
            defaultTemplates: [
                working(reps: 8, weight: 60, order: 0),
                working(reps: 8, weight: 70, order: 1),
                working(reps: 8, weight: nil, order: 2),   // skip
                working(reps: 8, weight: 0, order: 3),     // skip (non-positive)
            ]
        )
        try? context.save()

        let d = BackfillService.diagnoseDefaultTemplatesRisk(in: context)
        XCTAssertEqual(d.defaultTemplatesWithTargetWeight, 2)
    }

    // MARK: - defaultTemplatesNonWorkingKind (9-E warmup/dropset migration gate)

    func testCountsNonWorkingKindRowsAcrossDefaultTemplates() {
        _ = makeExercise(
            name: "Mixed",
            defaultTemplates: [
                warmup(reps: 5, order: 0),
                working(reps: 8, order: 1),
                working(reps: 8, order: 2),
                dropset(reps: 6, order: 3),
            ]
        )
        try? context.save()

        let d = BackfillService.diagnoseDefaultTemplatesRisk(in: context)
        // 1 warmup + 1 dropset = 2 non-working rows.
        XCTAssertEqual(d.defaultTemplatesNonWorkingKind, 2)
        // Working rows are not counted here (orthogonal metric).
        XCTAssertEqual(d.defaultTemplatesWithTargetWeight, 0)
    }

    // MARK: - slotsNeedingTier3 (9-C strand guard — should be 0 post-9-A2)

    func testSlotNeedingTier3WhenPrescriptionEmptyAndDefaultsPresent() {
        // Class-B legacy slot: empty prescription + empty setTemplates +
        // non-empty defaultTemplates. Pre-9-A2 this would have resolved
        // via Tier 3. Post-9-A2 it should be hydrated (so this counter
        // returns 0). This test exercises the COUNTER, not 9-A2 itself —
        // we don't call hydrateEmptySlotPrescriptions here, so it counts 1.
        let ex = makeExercise(defaultTemplates: [working(reps: 10, order: 0)])
        let empty = SlotPrescription()  // hasContent == false
        _ = makeSlot(exercise: ex, prescription: empty)

        let d = BackfillService.diagnoseDefaultTemplatesRisk(in: context)
        XCTAssertEqual(d.slotsNeedingTier3, 1)
        XCTAssertEqual(d.residualEmptyContentSlots, 1)
    }

    func testSlotNotNeedingTier3WhenSetTemplatesNonEmpty() {
        // Tier 1 carries the slot; defaults wouldn't be reached even
        // without hydration. Counter should be 0.
        let ex = makeExercise(defaultTemplates: [working(reps: 10, order: 0)])
        let empty = SlotPrescription()
        _ = makeSlot(
            exercise: ex,
            setTemplates: [working(reps: 8, order: 0)],
            prescription: empty
        )

        let d = BackfillService.diagnoseDefaultTemplatesRisk(in: context)
        XCTAssertEqual(d.slotsNeedingTier3, 0)
        // Still empty-content prescription though, so this counter fires.
        XCTAssertEqual(d.residualEmptyContentSlots, 1)
    }

    func testHydratedSlotIsNeitherNeedingTier3NorResidualEmpty() {
        // Post-9-A2 happy path: prescription has content → both counters 0.
        let ex = makeExercise(defaultTemplates: [working(reps: 10, order: 0)])
        let _ = makeSlot(exercise: ex, prescription: nil)
        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        let d = BackfillService.diagnoseDefaultTemplatesRisk(in: context)
        XCTAssertEqual(d.slotsNeedingTier3, 0)
        XCTAssertEqual(d.residualEmptyContentSlots, 0)
    }

    // MARK: - slotsOrphanedNoSource (nil-Exercise + empty prescription)

    func testSlotsOrphanedNoSourceCountsNilExerciseAndEmptyPrescription() {
        // Nil exercise + empty prescription = renders [] today.
        let empty = SlotPrescription()
        _ = makeSlot(exercise: nil, prescription: empty)

        // Nil exercise + content-bearing prescription = NOT orphaned.
        let contentful = SlotPrescription(sets: 3, repMin: 8, repMax: 12)
        _ = makeSlot(exercise: nil, prescription: contentful)

        let d = BackfillService.diagnoseDefaultTemplatesRisk(in: context)
        XCTAssertEqual(d.slotsOrphanedNoSource, 1)
    }

    // MARK: - residualEmptyContentSlots (top-line 9-C gate)

    func testResidualEmptyContentSlotsCountsAllNonContentBearingSlots() {
        let ex = makeExercise()
        // 3 empty prescriptions, 1 content-bearing, 1 nil prescription.
        _ = makeSlot(exercise: ex, prescription: SlotPrescription())
        _ = makeSlot(exercise: ex, prescription: SlotPrescription())
        _ = makeSlot(exercise: ex, prescription: SlotPrescription())
        _ = makeSlot(
            exercise: ex,
            prescription: SlotPrescription(sets: 3, repMin: 8, repMax: 12)
        )
        _ = makeSlot(exercise: ex, prescription: nil)

        let d = BackfillService.diagnoseDefaultTemplatesRisk(in: context)
        // 3 empty + 1 nil = 4 non-content-bearing.
        XCTAssertEqual(d.residualEmptyContentSlots, 4)
    }

    // MARK: - End-to-end: counters compose

    func testComplexFixtureProducesIndependentlyCorrectCounters() {
        // Exercise A: 1 working + 1 warmup default, no weights.
        let exA = makeExercise(
            name: "A",
            defaultTemplates: [warmup(reps: 5, order: 0), working(reps: 8, order: 1)]
        )
        // Exercise B: 2 working defaults with weights, 1 dropset.
        _ = makeExercise(
            name: "B",
            defaultTemplates: [
                working(reps: 5, weight: 100, order: 0),
                working(reps: 5, weight: 105, order: 1),
                dropset(reps: 3, order: 2),
            ]
        )
        // Exercise C: no defaults.
        let exC = makeExercise(name: "C")

        // Slot 1: Tier-3-dependent (Exercise A, empty prescription).
        _ = makeSlot(exercise: exA, prescription: SlotPrescription())
        // Slot 2: hydrated (Exercise C, content-bearing prescription).
        _ = makeSlot(
            exercise: exC,
            prescription: SlotPrescription(sets: 3, repMin: 8, repMax: 12)
        )
        // Slot 3: orphaned (nil Exercise + empty prescription).
        _ = makeSlot(exercise: nil, prescription: SlotPrescription())

        try? context.save()

        let d = BackfillService.diagnoseDefaultTemplatesRisk(in: context)

        // 2 exercises have defaultTemplates (A + B); C does not.
        // (Slot 3's stand-in placeholder Exercise from makeSlot also
        // exists but has no defaultTemplates → doesn't add to the count.)
        XCTAssertEqual(d.exercisesWithDefaultTemplates, 2)
        // 2 weighted rows on Exercise B; 0 on A.
        XCTAssertEqual(d.defaultTemplatesWithTargetWeight, 2)
        // 1 warmup on A + 1 dropset on B = 2.
        XCTAssertEqual(d.defaultTemplatesNonWorkingKind, 2)
        // Only slot 1 needs Tier 3 (A has defaults; slot 1's prescription
        // is empty and setTemplates are empty). Slot 2 is hydrated. Slot
        // 3's exercise is nil so the Tier-3 branch's `let ex = re.exercise`
        // guard fails — does NOT count toward slotsNeedingTier3.
        XCTAssertEqual(d.slotsNeedingTier3, 1)
        // Slot 3 alone (nil exercise + empty prescription).
        XCTAssertEqual(d.slotsOrphanedNoSource, 1)
        // Slot 1 + Slot 3 are non-content-bearing.
        XCTAssertEqual(d.residualEmptyContentSlots, 2)
    }

    // MARK: - Side-effect-free read

    func testDiagnosticDoesNotMutateModel() {
        let ex = makeExercise(defaultTemplates: [working(reps: 10, order: 0)])
        let empty = SlotPrescription()
        let re = makeSlot(exercise: ex, prescription: empty)
        // Snapshot fields that the diagnostic could plausibly affect.
        let preExerciseDefaultsCount = ex.defaultTemplates.count
        let preSlotSetTemplatesCount = re.setTemplates.count
        let preHasContent = re.prescription?.hasContent ?? false

        _ = BackfillService.diagnoseDefaultTemplatesRisk(in: context)
        _ = BackfillService.diagnoseDefaultTemplatesRisk(in: context)

        XCTAssertEqual(ex.defaultTemplates.count, preExerciseDefaultsCount)
        XCTAssertEqual(re.setTemplates.count, preSlotSetTemplatesCount)
        XCTAssertEqual(re.prescription?.hasContent ?? false, preHasContent)
    }
}
