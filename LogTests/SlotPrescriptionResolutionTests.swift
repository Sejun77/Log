import SwiftData
import XCTest

@testable import Log

/// Phase 9-pre stabilization — pins the 3-tier template resolution chain that
/// `RoutineExercise.resolvedTemplates(in:)` and `RoutineExercise.resolvedTemplates()`
/// implement today, plus the `SlotPrescription` building blocks they delegate to.
///
/// These tests are the safety net for the upcoming Phase 9 work that will
/// backfill legacy slots into `SlotPrescription` and eventually retire
/// `Exercise.defaultTemplates`. Pinning the *current* behavior first ensures the
/// backfill does not silently change what existing routines resolve to.
///
/// Resolution precedence (mirrored in both `Entities.swift` and
/// `RoutineExercise+Helpers.swift`):
///   Tier 1 — explicit `RoutineExercise.setTemplates` (non-empty)
///   Tier 2 — `SlotPrescription.generateTemplates()` when `prescription.hasContent`
///   Tier 3 — `Exercise.defaultTemplates` (still load-bearing; see
///            `REFACTOR_PLAN.md` Phase 9 audit notes — do NOT remove yet).
///
/// Also covers `WorkoutResumeService`'s defaults-fallback branch in
/// `planFromWorkoutItems`, which is the cold-resume mirror of Tier 3 and
/// was previously uncovered by `WorkoutResumeServiceTests`.
@MainActor
final class SlotPrescriptionResolutionTests: SwiftDataTestHarness {

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

    func testResolvedInCtx_Tier1WinsOverPrescriptionAndDefaults() {
        let defaults = [working(reps: 99, order: 0)]
        let ex = makeExercise(defaultTemplates: defaults)
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
        let defaults = [working(reps: 99, order: 0)]
        let ex = makeExercise(defaultTemplates: defaults)
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

    // MARK: - resolvedTemplates(in:) — Tier 3 (defaults)

    func testResolvedInCtx_Tier3UsedWhenSetTemplatesEmptyAndPrescriptionNil() {
        let defaults = [
            working(reps: 10, weight: 40, rest: 60, order: 0),
            working(reps: 8, weight: 45, rest: 60, order: 1),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let re = makeSlot(exercise: ex)

        let resolved = re.resolvedTemplates(in: context)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved.map(\.targetReps), [10, 8])
        XCTAssertEqual(resolved.map(\.targetWeight), [40, 45])
    }

    func testResolvedInCtx_Tier3UsedWhenPrescriptionPresentButHasNoContent() {
        // The legacy gap Phase 9 must backfill: an empty SlotPrescription
        // exists but carries no `sets` / `duration`, so resolution must
        // still fall through to Exercise.defaultTemplates rather than
        // returning [] and stranding the slot with zero working sets.
        let defaults = [working(reps: 12, order: 0)]
        let ex = makeExercise(defaultTemplates: defaults)
        let emptyPrescription = SlotPrescription()
        XCTAssertFalse(emptyPrescription.hasContent)

        let re = makeSlot(exercise: ex, prescription: emptyPrescription)

        let resolved = re.resolvedTemplates(in: context)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.targetReps, 12)
    }

    func testResolvedInCtx_Tier3PreservesOrder() {
        let defaults = [
            working(reps: 10, order: 2),
            working(reps: 8, order: 0),
            working(reps: 6, order: 1),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let re = makeSlot(exercise: ex)

        let resolved = re.resolvedTemplates(in: context)
        XCTAssertEqual(resolved.map(\.targetReps), [8, 6, 10])
    }

    func testResolvedInCtx_AllTiersEmptyReturnsEmpty() {
        let ex = makeExercise(defaultTemplates: [])
        let re = makeSlot(exercise: ex)

        XCTAssertTrue(re.resolvedTemplates(in: context).isEmpty)
    }

    // MARK: - resolvedTemplates() — no-context variant

    func testResolvedNoCtx_Tier1WinsOverPrescriptionAndDefaults() {
        let defaults = [working(reps: 99, order: 0)]
        let ex = makeExercise(defaultTemplates: defaults)
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
        let defaults = [working(reps: 99, order: 0)]
        let ex = makeExercise(defaultTemplates: defaults)
        let p = SlotPrescription(sets: 2, repMin: 8, repMax: 8)
        let re = makeSlot(exercise: ex, prescription: p)

        let resolved = re.resolvedTemplates()
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved.map(\.targetReps), [8, 8])
    }

    func testResolvedNoCtx_Tier3WhenSetTemplatesEmptyAndPrescriptionNil() {
        let defaults = [
            working(reps: 10, order: 0),
            working(reps: 8, order: 1),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let re = makeSlot(exercise: ex)

        let resolved = re.resolvedTemplates()
        XCTAssertEqual(resolved.map(\.targetReps), [10, 8])
    }

    func testResolvedNoCtx_Tier3WhenPrescriptionPresentButHasNoContent() {
        let defaults = [working(reps: 12, order: 0)]
        let ex = makeExercise(defaultTemplates: defaults)
        let re = makeSlot(exercise: ex, prescription: SlotPrescription())

        let resolved = re.resolvedTemplates()
        XCTAssertEqual(resolved.map(\.targetReps), [12])
    }

    func testResolvedNoCtx_NilExerciseReturnsEmpty() {
        // Building a RoutineExercise then nulling its exercise relationship
        // simulates a deleted Exercise (`.nullify` rule on Exercise.routineUsages
        // would normally clear this). Tier 3 needs `exercise` to be non-nil.
        let ex = makeExercise(defaultTemplates: [working(reps: 5, order: 0)])
        let re = makeSlot(exercise: ex)
        re.exercise = nil
        try? context.save()

        XCTAssertTrue(re.resolvedTemplates().isEmpty)
    }

    // MARK: - Superset set-count helper (Exercise.defaultTemplates working count)

    /// `SupersetPicker.setCount(for:)` is private, but its rule is just
    /// `defaultTemplates.filter { $0.kind == .working }.count` (with a
    /// fallback to `AppSettings.defaultSets` when zero). Pinning the
    /// underlying count keeps the picker's compatibility logic from
    /// silently drifting if Phase 9 backfill rewrites defaultTemplates.
    func testExerciseDefaultTemplatesWorkingCountReflectsKindFilter() {
        let warmup = SetTemplate(kind: .warmup, targetReps: 5)
        warmup.order = 0
        let w1 = working(reps: 8, order: 1)
        let w2 = working(reps: 8, order: 2)
        let drop = SetTemplate(kind: .dropset, targetReps: 6)
        drop.order = 3
        let ex = makeExercise(
            defaultTemplates: [warmup, w1, w2, drop]
        )

        let workingCount = ex.defaultTemplates
            .filter { $0.kind == .working }.count
        XCTAssertEqual(workingCount, 2)
    }

    // MARK: - WorkoutResumeService fallback Tier 3 (defaults)

    /// `WorkoutResumeService.planFromWorkoutItems` is the cold-resume mirror
    /// of `resolvedTemplates` Tier 3: when a WorkoutItem has no logs and
    /// no `PlannedPrescriptionSnapshot`, it seeds the plan from
    /// `Exercise.defaultTemplates`. This branch was previously uncovered
    /// in `WorkoutResumeServiceTests` (which only pinned the snapshot and
    /// logs branches), so Phase 9 cannot remove defaultTemplates without
    /// regressing cold-resume of legacy in-flight workouts.
    func testWorkoutResumeFallsBackToExerciseDefaultsWhenNoLogsAndNoSnapshot() {
        let defaults = [
            working(reps: 10, weight: 40, rest: 60, order: 0),
            working(reps: 8, weight: 45, rest: 60, order: 1),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let item = WorkoutItem(exercise: ex, setLogs: [])
        // Crucially: no plannedPrescriptionSnapshot, no setLogs.
        context.insert(item)
        let workout = Workout(
            routineName: "Resumed",
            routineID: nil,
            routineVariantID: nil,
            items: [item],
            notes: nil
        )
        context.insert(workout)
        try? context.save()

        let plan = WorkoutResumeService.rebuildPlan(for: workout, in: context)
        let templates = plan?.blocks.first?.exercises.first?.templates ?? []
        XCTAssertEqual(templates.count, 2)
        XCTAssertEqual(templates.map(\.targetReps), [10, 8])
        XCTAssertEqual(templates.map(\.targetWeight), [40, 45])
        XCTAssertEqual(templates.map(\.restSecondsAfter), [60, 60])
    }
}
