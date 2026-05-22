import SwiftData
import XCTest

@testable import Log

/// Pins the 2-tier template resolution chain that
/// `RoutineExercise.resolvedTemplates(in:)` and `RoutineExercise.resolvedTemplates()`
/// implement post-Phase-9-C2, plus the `SlotPrescription` building blocks
/// they delegate to.
///
/// Resolution precedence (mirrored in both `Entities.swift` and
/// `RoutineExercise+Helpers.swift`):
///   Tier 1 — explicit `RoutineExercise.setTemplates` (non-empty)
///   Tier 2 — `SlotPrescription.generateTemplates()` when `prescription.hasContent`
///   Else: `[]` — Tier 3 (`Exercise.defaultTemplates`) was removed in
///   Phase 9-C2. Legacy slots without prescription content are hydrated
///   at bootstrap by `BackfillService.hydrateEmptySlotPrescriptions`,
///   so the Tier 2 branch covers what Tier 3 used to.
///
/// Also covers `WorkoutResumeService`'s orphan-fallback contract
/// (Phase 9-C1) and the `defaultTemplates`-working-count rule used by
/// `SupersetPicker`.
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

    // MARK: - resolvedTemplates(in:) — Tier 3 removed in Phase 9-C2

    /// Phase 9-C2: when Tier 1 is empty AND prescription is nil, the
    /// resolver returns `[]` even though the Exercise has non-empty
    /// `defaultTemplates`. Pre-9-C2 this branch fell through to Tier 3
    /// and surfaced the defaults; the fixture loads sentinel values
    /// that would have been observable under the old code path so the
    /// assertion actively catches a regression.
    func testResolvedInCtx_ReturnsEmptyWhenSetTemplatesEmptyAndPrescriptionNilEvenWithDefaults() {
        let defaults = [
            working(reps: 10, weight: 40, rest: 60, order: 0),
            working(reps: 8, weight: 45, rest: 60, order: 1),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let re = makeSlot(exercise: ex)

        XCTAssertTrue(
            re.resolvedTemplates(in: context).isEmpty,
            "Phase 9-C2: Tier 3 removed — `defaultTemplates` must not surface"
        )
    }

    /// Phase 9-C2: a prescription that exists but has no content no
    /// longer falls through to `defaultTemplates` — it returns `[]`.
    /// Legacy slots in this shape are hydrated at bootstrap by
    /// `BackfillService.hydrateEmptySlotPrescriptions`, so production
    /// users never see this state in practice.
    func testResolvedInCtx_ReturnsEmptyWhenPrescriptionHasNoContentEvenWithDefaults() {
        let defaults = [working(reps: 12, order: 0)]
        let ex = makeExercise(defaultTemplates: defaults)
        let emptyPrescription = SlotPrescription()
        XCTAssertFalse(emptyPrescription.hasContent)

        let re = makeSlot(exercise: ex, prescription: emptyPrescription)

        XCTAssertTrue(
            re.resolvedTemplates(in: context).isEmpty,
            "Phase 9-C2: empty-content prescription no longer falls through "
            + "to Exercise.defaultTemplates"
        )
    }

    /// Phase 9-C2: the pre-9-C2 Tier 3 arm also normalized
    /// `ex.defaultTemplates[i].order` via `normalizeOrderIfNeeded` and
    /// persisted the fix. With Tier 3 gone the resolver must NOT touch
    /// `defaultTemplates` orders. The companion editor-side healer
    /// (`ExercisesView.normalizeTemplateOrderIfNeeded`) was also removed
    /// in Phase 9-D alongside the Exercise-tab Sets editor — nothing
    /// reads `defaultTemplates[i].order` at runtime anymore (the field
    /// stays load-bearing through 9-E only for `BackfillService`
    /// hydration + diagnostic counters, neither of which depends on
    /// row order).
    func testResolvedInCtx_NoLongerNormalizesExerciseDefaultTemplatesOrder() {
        // All three rows share order=0; pre-9-C2 the resolver would
        // renormalize to [0, 1, 2] as a side effect of returning Tier 3.
        let a = working(reps: 5, order: 0)
        let b = working(reps: 5, order: 0)
        let c = working(reps: 5, order: 0)
        let ex = makeExercise(defaultTemplates: [a, b, c])
        let re = makeSlot(exercise: ex)

        _ = re.resolvedTemplates(in: context)

        XCTAssertEqual(
            ex.defaultTemplates.map(\.order), [0, 0, 0],
            "Phase 9-C2: resolver must not normalize defaultTemplates orders "
            + "anymore — that side effect lived on the removed Tier 3 arm."
        )
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

    /// Phase 9-C2 mirror of the `(in:)` variant test: with Tier 1
    /// empty AND prescription nil, the no-context resolver also returns
    /// `[]` even when `defaultTemplates` are present.
    func testResolvedNoCtx_ReturnsEmptyWhenSetTemplatesEmptyAndPrescriptionNilEvenWithDefaults() {
        let defaults = [
            working(reps: 10, order: 0),
            working(reps: 8, order: 1),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let re = makeSlot(exercise: ex)

        XCTAssertTrue(
            re.resolvedTemplates().isEmpty,
            "Phase 9-C2: no-context resolver no longer reads "
            + "Exercise.defaultTemplates"
        )
    }

    /// Phase 9-C2 mirror: empty-content prescription returns `[]` for
    /// the no-context resolver as well.
    func testResolvedNoCtx_ReturnsEmptyWhenPrescriptionHasNoContentEvenWithDefaults() {
        let defaults = [working(reps: 12, order: 0)]
        let ex = makeExercise(defaultTemplates: defaults)
        let re = makeSlot(exercise: ex, prescription: SlotPrescription())

        XCTAssertTrue(re.resolvedTemplates().isEmpty)
    }

    /// Phase 9-C2: nil-exercise still resolves to `[]` — but now the
    /// `[]` comes from Tier 1 + Tier 2 both being empty rather than
    /// from the old `guard let ex = exercise else { return [] }` at
    /// the head of the Tier 3 arm. Pre-9-C2 this test pinned a Tier 3
    /// edge case; post-9-C2 it pins that nulling the exercise
    /// relationship is still safe (no crash, no fabricated rows).
    func testResolvedNoCtx_NilExerciseStillReturnsEmpty() {
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

    // MARK: - WorkoutResumeService fallback (Phase 9-C1 — no defaultTemplates)

    /// Phase 9-C1 replaced the prior `defaultTemplates` read in
    /// `WorkoutResumeService.planFromWorkoutItems` with a call to
    /// `makeSwapDefaultTemplates(...)`. When a `WorkoutItem` has no logs
    /// and no `PlannedPrescriptionSnapshot`, the orphan fallback now
    /// synthesizes N uniform `.working` rows at AppSettings defaults
    /// regardless of what `Exercise.defaultTemplates` carries.
    ///
    /// Accepted losses vs. pre-9-C1 (documented on
    /// `makeSwapDefaultTemplates` and mirrored here):
    ///   - `targetWeight` is always nil
    ///   - `targetReps` is 0 (SessionPlanResolver fills it at row-render time)
    ///   - per-row rest values from `defaultTemplates` are not preserved
    ///   - the count is `AppSettings.defaultSets`, not
    ///     `defaultTemplates.count`
    ///
    /// Companion coverage in `WorkoutResumeServiceTests`:
    /// `testOrphanFallbackIgnoresExerciseDefaultTemplatesRepBased`,
    /// `testOrphanFallbackTimeBasedGetsDefaultDuration`, and
    /// `testOrphanFallbackSkipsBlockWhenExerciseIsNil`.
    func testWorkoutResumeOrphanFallbackIgnoresDefaultTemplates() {
        // Load defaultTemplates with values that would have leaked under
        // the pre-9-C1 path; assert none of them appear in the plan.
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
        XCTAssertEqual(
            templates.count, AppSettings.defaultSets,
            "Row count comes from AppSettings.defaultSets, not "
            + "defaultTemplates.count (which was 2)."
        )
        XCTAssertTrue(
            templates.allSatisfy { $0.targetReps == 0 },
            "Phase 9-C1 contract: targetReps is 0; SessionPlanResolver "
            + "fills the real value at row-render time."
        )
        XCTAssertTrue(
            templates.allSatisfy { $0.targetWeight == nil },
            "Phase 9-C1 accepted loss: targetWeight from defaultTemplates "
            + "no longer leaks into the resumed plan."
        )
        XCTAssertTrue(
            templates.allSatisfy {
                $0.restSecondsAfter == AppSettings.defaultRestBetweenSets
            },
            "Rest is sourced from AppSettings, not the per-row values "
            + "on defaultTemplates."
        )
    }
}
