import SwiftData
import XCTest

@testable import Log

/// Pins the 2-tier template resolution chain that
/// `RoutineExercise.resolvedTemplates(in:)` and `RoutineExercise.resolvedTemplates()`
/// implement, plus the `SlotPrescription` building blocks they delegate to.
///
/// Resolution precedence (mirrored in both `Entities.swift` and
/// `RoutineExercise+Helpers.swift`):
///   Tier 1 — explicit `RoutineExercise.setTemplates` (non-empty)
///   Tier 2 — `SlotPrescription.generateTemplates()` when `prescription.hasContent`
///   Else: `[]`. Legacy slots without prescription content are hydrated
///   at bootstrap by `BackfillService.hydrateEmptySlotPrescriptions`.
///   The former Tier 3 (`Exercise.defaultTemplates`) source was removed
///   in Phase 9-C2 (resolver) and the model field deleted in 9-E2.
@MainActor
final class SlotPrescriptionResolutionTests: SwiftDataTestHarness {

    // MARK: - Fixture helpers

    @discardableResult
    private func makeExercise(
        name: String = "Bench Press",
        isTimeBased: Bool = false
    ) -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        ex.isTimeBased = isTimeBased
        context.insert(ex)
        return ex
    }

    @discardableResult
    private func makeSlot(
        exercise: Exercise,
        setTemplates: [SetTemplate] = [],
        prescription: SlotPrescription? = nil
    ) -> RoutineExercise {
        for tpl in setTemplates { context.insert(tpl) }
        let re = RoutineExercise(
            exercise: exercise, order: 0, setTemplates: setTemplates
        )
        context.insert(re)
        if let p = prescription {
            context.insert(p)
            re.prescription = p
        }
        // safeExercise(in:) only resolves once the RoutineExercise is
        // attached to the context and discoverable via FetchDescriptor —
        // a save flushes the pending insert so the in-test fetch hits.
        try? context.save()
        return re
    }

    private func working(
        reps: Int,
        weight: Double? = nil,
        rest: Int? = nil,
        order: Int
    ) -> SetTemplate {
        let t = SetTemplate(
            kind: .working,
            targetReps: reps,
            targetWeight: weight,
            restSecondsAfter: rest
        )
        t.order = order
        return t
    }

    // MARK: - SlotPrescription.hasContent

    func testHasContentFalseForEmptyPrescription() {
        let p = SlotPrescription()
        XCTAssertFalse(p.hasContent)
    }

    func testHasContentTrueWhenSetsPresent() {
        let p = SlotPrescription(sets: 3, repMin: 8, repMax: 12)
        XCTAssertTrue(p.hasContent)
    }

    func testHasContentTrueWhenUsesDurationWithDuration() {
        let p = SlotPrescription(
            durationMinSeconds: 30, durationMaxSeconds: 45, usesDuration: true
        )
        XCTAssertTrue(p.hasContent)
    }

    func testHasContentFalseWhenUsesDurationButNoDuration() {
        let p = SlotPrescription(usesDuration: true)
        XCTAssertFalse(p.hasContent)
    }

    func testHasContentFalseWhenSetsNilAndNotDuration() {
        // repMin/repMax alone are not enough — `sets` is the canonical signal
        // for rep-based prescriptions.
        let p = SlotPrescription(repMin: 8, repMax: 12)
        XCTAssertFalse(p.hasContent)
    }

    // MARK: - SlotPrescription.generateTemplates

    func testGenerateTemplatesRepBasedUsesRepMaxWhenAvailable() {
        let p = SlotPrescription(
            sets: 4, repMin: 6, repMax: 10, restSecondsBetweenSets: 90
        )
        let templates = p.generateTemplates()
        XCTAssertEqual(templates.count, 4)
        for (i, t) in templates.enumerated() {
            XCTAssertEqual(t.order, i, "templates must be ordered 0..N-1")
            XCTAssertEqual(t.kind, .working)
            XCTAssertEqual(t.targetReps, 10, "repMax wins when present")
            XCTAssertEqual(t.restSecondsAfter, 90)
            XCTAssertNil(t.targetWeight)
            XCTAssertNil(t.durationSeconds)
        }
    }

    func testGenerateTemplatesRepBasedFallsBackToRepMinThen8() {
        let onlyMin = SlotPrescription(sets: 2, repMin: 5)
        XCTAssertEqual(onlyMin.generateTemplates().map(\.targetReps), [5, 5])

        let neither = SlotPrescription(sets: 2)
        XCTAssertEqual(neither.generateTemplates().map(\.targetReps), [8, 8])
    }

    func testGenerateTemplatesTimeBasedUsesMaxDurationThenMinThen60() {
        let withMax = SlotPrescription(
            sets: 2, durationMinSeconds: 30, durationMaxSeconds: 45,
            usesDuration: true
        )
        let withMin = SlotPrescription(
            sets: 2, durationMinSeconds: 20, usesDuration: true
        )
        // `sets: 2` ensures we're exercising the chooser, not the count clamp.
        let neither = SlotPrescription(sets: 2, usesDuration: true)

        XCTAssertEqual(
            withMax.generateTemplates().map(\.durationSeconds), [45, 45]
        )
        XCTAssertEqual(
            withMin.generateTemplates().map(\.durationSeconds), [20, 20]
        )
        XCTAssertEqual(
            neither.generateTemplates().map(\.durationSeconds), [60, 60]
        )
        // Time-based templates carry zero `targetReps` and the same rest as
        // rep-based templates (sourced from restSecondsBetweenSets).
        for t in withMax.generateTemplates() {
            XCTAssertEqual(t.targetReps, 0)
            XCTAssertEqual(t.kind, .working)
        }
    }

    func testGenerateTemplatesClampsCountToAtLeastOne() {
        // sets == nil → max(1, sets ?? 3) → 3
        let nilSets = SlotPrescription()
        XCTAssertEqual(nilSets.generateTemplates().count, 3)

        // sets == 0 → max(1, 0) → 1
        let zeroSets = SlotPrescription(sets: 0)
        XCTAssertEqual(zeroSets.generateTemplates().count, 1)
    }

    // MARK: - resolvedTemplates(in:) — Tier 1 wins

    func testResolvedInCtx_Tier1WinsOverPrescription() {
        let ex = makeExercise()
        let p = SlotPrescription(sets: 5, repMin: 8, repMax: 12)
        let overrides = [
            working(reps: 8, weight: 60, rest: 90, order: 0),
            working(reps: 6, weight: 70, rest: 120, order: 1),
        ]
        let re = makeSlot(
            exercise: ex, setTemplates: overrides, prescription: p
        )

        let resolved = re.resolvedTemplates(in: context)
        XCTAssertEqual(resolved.count, 2, "Tier 1 (setTemplates) must win")
        XCTAssertEqual(resolved.map(\.targetReps), [8, 6])
        XCTAssertEqual(resolved.map(\.targetWeight), [60, 70])
    }

    func testResolvedInCtx_Tier1PreservesOrder() {
        let ex = makeExercise()
        let overrides = [
            working(reps: 10, order: 2),
            working(reps: 8, order: 0),
            working(reps: 6, order: 1),
        ]
        let re = makeSlot(exercise: ex, setTemplates: overrides)

        let resolved = re.resolvedTemplates(in: context)
        XCTAssertEqual(resolved.map(\.targetReps), [8, 6, 10])
    }

    func testResolvedInCtx_Tier1NormalizesDuplicateOrders() {
        // All three templates share order == 0. The (in:) variant must
        // renormalize them to a stable 0,1,2 sequence so downstream
        // active-workout indexing stays gap-free.
        let ex = makeExercise()
        let a = working(reps: 5, order: 0)
        let b = working(reps: 5, order: 0)
        let c = working(reps: 5, order: 0)
        let re = makeSlot(exercise: ex, setTemplates: [a, b, c])

        let resolved = re.resolvedTemplates(in: context)
        XCTAssertEqual(resolved.count, 3)
        XCTAssertEqual(resolved.map(\.order), [0, 1, 2])
    }

    // MARK: - resolvedTemplates(in:) — Tier 2 (prescription)

    func testResolvedInCtx_Tier2UsedWhenSetTemplatesEmptyAndPrescriptionHasContent() {
        let ex = makeExercise()
        let p = SlotPrescription(
            sets: 3, repMin: 6, repMax: 8, restSecondsBetweenSets: 75
        )
        let re = makeSlot(exercise: ex, prescription: p)

        let resolved = re.resolvedTemplates(in: context)
        XCTAssertEqual(resolved.count, 3)
        XCTAssertEqual(resolved.map(\.targetReps), [8, 8, 8])
        XCTAssertEqual(resolved.map(\.restSecondsAfter), [75, 75, 75])
        XCTAssertEqual(resolved.map(\.order), [0, 1, 2])
    }

    func testResolvedInCtx_Tier2TimeBasedProducesDurationTemplates() {
        let ex = makeExercise(isTimeBased: true)
        let p = SlotPrescription(
            sets: 2, durationMinSeconds: 30, durationMaxSeconds: 45,
            usesDuration: true
        )
        let re = makeSlot(exercise: ex, prescription: p)

        let resolved = re.resolvedTemplates(in: context)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved.map(\.durationSeconds), [45, 45])
        XCTAssertEqual(resolved.map(\.targetReps), [0, 0])
    }

    // MARK: - resolvedTemplates(in:) — empty-tier behavior

    /// When Tier 1 (`setTemplates`) is empty AND prescription is nil,
    /// the resolver returns `[]`. Phase 9-C2 removed the prior Tier 3
    /// `Exercise.defaultTemplates` fallback, and 9-E2 deleted the field
    /// entirely so this branch has nothing left to fall through to.
    func testResolvedInCtx_ReturnsEmptyWhenSetTemplatesEmptyAndPrescriptionNil() {
        let ex = makeExercise()
        let re = makeSlot(exercise: ex)

        XCTAssertTrue(re.resolvedTemplates(in: context).isEmpty)
    }

    /// A prescription that exists but has no content also returns `[]`.
    /// Legacy slots in this shape are hydrated at bootstrap by
    /// `BackfillService.hydrateEmptySlotPrescriptions`, so production
    /// users never see this state in practice.
    func testResolvedInCtx_ReturnsEmptyWhenPrescriptionHasNoContent() {
        let ex = makeExercise()
        let emptyPrescription = SlotPrescription()
        XCTAssertFalse(emptyPrescription.hasContent)

        let re = makeSlot(exercise: ex, prescription: emptyPrescription)

        XCTAssertTrue(re.resolvedTemplates(in: context).isEmpty)
    }

    func testResolvedInCtx_AllTiersEmptyReturnsEmpty() {
        let ex = makeExercise()
        let re = makeSlot(exercise: ex)

        XCTAssertTrue(re.resolvedTemplates(in: context).isEmpty)
    }

    // MARK: - resolvedTemplates() — no-context variant

    func testResolvedNoCtx_Tier1WinsOverPrescription() {
        let ex = makeExercise()
        let p = SlotPrescription(sets: 5, repMin: 8, repMax: 12)
        let overrides = [
            working(reps: 8, weight: 60, rest: 90, order: 0),
            working(reps: 6, weight: 70, rest: 120, order: 1),
        ]
        let re = makeSlot(
            exercise: ex, setTemplates: overrides, prescription: p
        )

        let resolved = re.resolvedTemplates()
        XCTAssertEqual(resolved.map(\.targetReps), [8, 6])
    }

    func testResolvedNoCtx_Tier2WhenSetTemplatesEmpty() {
        let ex = makeExercise()
        let p = SlotPrescription(sets: 2, repMin: 8, repMax: 8)
        let re = makeSlot(exercise: ex, prescription: p)

        let resolved = re.resolvedTemplates()
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved.map(\.targetReps), [8, 8])
    }

    /// Mirror of the `(in:)` variant: with Tier 1 empty and prescription
    /// nil, the no-context resolver also returns `[]`.
    func testResolvedNoCtx_ReturnsEmptyWhenSetTemplatesEmptyAndPrescriptionNil() {
        let ex = makeExercise()
        let re = makeSlot(exercise: ex)

        XCTAssertTrue(re.resolvedTemplates().isEmpty)
    }

    /// Mirror: empty-content prescription returns `[]` for the
    /// no-context resolver as well.
    func testResolvedNoCtx_ReturnsEmptyWhenPrescriptionHasNoContent() {
        let ex = makeExercise()
        let re = makeSlot(exercise: ex, prescription: SlotPrescription())

        XCTAssertTrue(re.resolvedTemplates().isEmpty)
    }

    /// Nulling the exercise relationship is safe (no crash, no
    /// fabricated rows). Tier 1 + Tier 2 are both empty so the resolver
    /// returns `[]`.
    func testResolvedNoCtx_NilExerciseStillReturnsEmpty() {
        let ex = makeExercise()
        let re = makeSlot(exercise: ex)
        re.exercise = nil
        try? context.save()

        XCTAssertTrue(re.resolvedTemplates().isEmpty)
    }

    // Phase 9-E2: `testExerciseDefaultTemplatesWorkingCountReflectsKindFilter`
    // and `testWorkoutResumeOrphanFallbackIgnoresDefaultTemplates` were
    // deleted alongside the `Exercise.defaultTemplates` model field.
    // The orphan-fallback contract is still covered by
    // `WorkoutResumeServiceTests.testOrphanFallback{TimeBasedGetsDefaultDuration,
    // SkipsBlockWhenExerciseIsNil}`.
}
