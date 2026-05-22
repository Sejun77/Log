import SwiftData
import XCTest

@testable import Log

/// Phase 9-A — `BackfillService.hydrateEmptySlotPrescriptions(in:)` is the
/// launch-time backfill that hydrates every `RoutineExercise.prescription`
/// whose `hasContent == false` from (in priority order)
/// `re.setTemplates` → `re.exercise?.defaultTemplates` → `AppSettings`
/// defaults. These tests pin the contract before bootstrap wiring lands
/// in 9-A2 and before `Exercise.defaultTemplates` is removed in 9-C/9-E.
///
/// Resolution-side behavior is pinned separately by
/// `SlotPrescriptionResolutionTests`; the golden-behavior test at the
/// bottom of this file is the bridge between the two — it verifies a
/// legacy Class-B slot (`hasContent == false`, empty `setTemplates`,
/// non-empty `defaultTemplates`) resolves to the same working-set
/// `(count, reps, rest, kind)` tuple via Tier 2 post-backfill as it did
/// via Tier 3 pre-backfill.
@MainActor
final class HydrateEmptySlotPrescriptionsTests: SwiftDataTestHarness {

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
        // RoutineExercise.init requires a non-nil Exercise; nil-exercise
        // tests detach afterwards via `re.exercise = nil`.
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

    private func timeWorking(
        seconds: Int, rest: Int? = nil, order: Int
    ) -> SetTemplate {
        let t = SetTemplate(
            kind: .working,
            targetReps: 0,
            targetWeight: nil,
            restSecondsAfter: rest
        )
        t.durationSeconds = seconds
        t.order = order
        return t
    }

    // MARK: - 1. Tier 1 setTemplates rep-based

    func testHydratesFromSetTemplatesRepBased() {
        let ex = makeExercise()
        let p = SlotPrescription()  // empty → hasContent == false
        let overrides = [
            working(reps: 8, rest: 75, order: 0),
            working(reps: 10, rest: 75, order: 1),
            working(reps: 12, rest: 75, order: 2),
        ]
        let re = makeSlot(
            exercise: ex, setTemplates: overrides, prescription: p
        )

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertTrue(re.prescription?.hasContent ?? false)
        XCTAssertEqual(re.prescription?.usesDuration, false)
        XCTAssertEqual(re.prescription?.sets, 3)
        XCTAssertEqual(re.prescription?.repMin, 8)
        XCTAssertEqual(re.prescription?.repMax, 12)
        XCTAssertEqual(re.prescription?.restSecondsBetweenSets, 75)
        XCTAssertNil(re.prescription?.durationMinSeconds)
        XCTAssertNil(re.prescription?.durationMaxSeconds)
        // restSecondsAfterExercise stays nil — source was non-empty.
        XCTAssertNil(re.prescription?.restSecondsAfterExercise)
        // Autoreg never mined.
        XCTAssertNil(re.prescription?.rir)
        XCTAssertNil(re.prescription?.rpe)
    }

    // MARK: - 2. Tier 1 setTemplates time-based

    func testHydratesFromSetTemplatesTimeBased() {
        let ex = makeExercise(name: "Plank", isTimeBased: true)
        let p = SlotPrescription()
        let overrides = [
            timeWorking(seconds: 30, rest: 60, order: 0),
            timeWorking(seconds: 45, rest: 60, order: 1),
        ]
        let re = makeSlot(
            exercise: ex, setTemplates: overrides, prescription: p
        )

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertEqual(re.prescription?.usesDuration, true)
        XCTAssertEqual(re.prescription?.sets, 2)
        XCTAssertEqual(re.prescription?.durationMinSeconds, 30)
        XCTAssertEqual(re.prescription?.durationMaxSeconds, 45)
        XCTAssertEqual(re.prescription?.restSecondsBetweenSets, 60)
        // Reps are not set for time-based slots.
        XCTAssertNil(re.prescription?.repMin)
        XCTAssertNil(re.prescription?.repMax)
    }

    // MARK: - 3. Tier 3 defaultTemplates rep-based

    func testHydratesFromDefaultTemplatesRepBased() {
        let defaults = [
            working(reps: 5, rest: 120, order: 0),
            working(reps: 5, rest: 120, order: 1),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let p = SlotPrescription()
        let re = makeSlot(exercise: ex, prescription: p)

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertEqual(re.prescription?.usesDuration, false)
        XCTAssertEqual(re.prescription?.sets, 2)
        XCTAssertEqual(re.prescription?.repMin, 5)
        XCTAssertEqual(re.prescription?.repMax, 5)
        XCTAssertEqual(re.prescription?.restSecondsBetweenSets, 120)
    }

    // MARK: - 4. Tier 3 defaultTemplates time-based

    func testHydratesFromDefaultTemplatesTimeBased() {
        let defaults = [
            timeWorking(seconds: 20, rest: 30, order: 0),
            timeWorking(seconds: 40, rest: 30, order: 1),
            timeWorking(seconds: 60, rest: 30, order: 2),
        ]
        let ex = makeExercise(
            name: "Hold", isTimeBased: true, defaultTemplates: defaults
        )
        let p = SlotPrescription()
        let re = makeSlot(exercise: ex, prescription: p)

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertEqual(re.prescription?.usesDuration, true)
        XCTAssertEqual(re.prescription?.sets, 3)
        XCTAssertEqual(re.prescription?.durationMinSeconds, 20)
        XCTAssertEqual(re.prescription?.durationMaxSeconds, 60)
        XCTAssertEqual(re.prescription?.restSecondsBetweenSets, 30)
    }

    // MARK: - 5. Tier 1 wins over Tier 3

    func testSetTemplatesWinsOverDefaultTemplates() {
        let defaults = [working(reps: 99, rest: 999, order: 0)]
        let ex = makeExercise(defaultTemplates: defaults)
        let overrides = [
            working(reps: 6, rest: 90, order: 0),
            working(reps: 8, rest: 90, order: 1),
        ]
        let p = SlotPrescription()
        let re = makeSlot(
            exercise: ex, setTemplates: overrides, prescription: p
        )

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        // Mining must use overrides, not defaults — no 99s anywhere.
        XCTAssertEqual(re.prescription?.sets, 2)
        XCTAssertEqual(re.prescription?.repMin, 6)
        XCTAssertEqual(re.prescription?.repMax, 8)
        XCTAssertEqual(re.prescription?.restSecondsBetweenSets, 90)
    }

    // MARK: - 6. AppSettings fallback when both sources empty

    func testAppSettingsFallbackWhenAllSourcesEmpty() {
        let ex = makeExercise(defaultTemplates: [])
        let p = SlotPrescription()
        let re = makeSlot(exercise: ex, prescription: p)

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        // AppSettings defaults are 3 / 8-12 / 90 (per AppSettings.swift).
        XCTAssertEqual(re.prescription?.usesDuration, false)
        XCTAssertEqual(re.prescription?.sets, AppSettings.defaultSets)
        XCTAssertEqual(re.prescription?.repMin, AppSettings.defaultRepMin)
        XCTAssertEqual(re.prescription?.repMax, AppSettings.defaultRepMax)
        XCTAssertEqual(
            re.prescription?.restSecondsBetweenSets,
            AppSettings.defaultRestBetweenSets
        )
    }

    // MARK: - 7. Skips content-bearing prescription

    func testSkipsContentBearingPrescription() {
        let ex = makeExercise(
            defaultTemplates: [working(reps: 99, rest: 99, order: 0)]
        )
        // Pre-populated, content-bearing prescription.
        let p = SlotPrescription(
            sets: 5, repMin: 4, repMax: 6, restSecondsBetweenSets: 180
        )
        let re = makeSlot(exercise: ex, prescription: p)
        XCTAssertTrue(p.hasContent)

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        // Identity preserved + contents untouched.
        XCTAssertTrue(re.prescription === p)
        XCTAssertEqual(re.prescription?.sets, 5)
        XCTAssertEqual(re.prescription?.repMin, 4)
        XCTAssertEqual(re.prescription?.repMax, 6)
        XCTAssertEqual(re.prescription?.restSecondsBetweenSets, 180)
    }

    // MARK: - 8. Idempotent second run

    func testIdempotentSecondRunNoChange() {
        let defaults = [
            working(reps: 10, rest: 60, order: 0),
            working(reps: 8, rest: 60, order: 1),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let p = SlotPrescription()
        let re = makeSlot(exercise: ex, prescription: p)

        BackfillService.hydrateEmptySlotPrescriptions(in: context)
        let snapshotA = (
            re.prescription?.usesDuration,
            re.prescription?.sets,
            re.prescription?.repMin,
            re.prescription?.repMax,
            re.prescription?.restSecondsBetweenSets
        )

        BackfillService.hydrateEmptySlotPrescriptions(in: context)
        let snapshotB = (
            re.prescription?.usesDuration,
            re.prescription?.sets,
            re.prescription?.repMin,
            re.prescription?.repMax,
            re.prescription?.restSecondsBetweenSets
        )

        XCTAssertEqual(snapshotA.0, snapshotB.0)
        XCTAssertEqual(snapshotA.1, snapshotB.1)
        XCTAssertEqual(snapshotA.2, snapshotB.2)
        XCTAssertEqual(snapshotA.3, snapshotB.3)
        XCTAssertEqual(snapshotA.4, snapshotB.4)
    }

    // MARK: - 9. Working filter ignores warmup/dropset rows

    func testWorkingFilterIgnoresWarmupAndDropsetRows() {
        // 2 warmups + 3 working + 1 dropset. `sets` must be 3, not 6.
        let mixed = [
            warmup(reps: 5, order: 0),
            warmup(reps: 5, order: 1),
            working(reps: 8, rest: 90, order: 2),
            working(reps: 8, rest: 90, order: 3),
            working(reps: 8, rest: 90, order: 4),
            dropset(reps: 6, order: 5),
        ]
        let ex = makeExercise(defaultTemplates: mixed)
        let p = SlotPrescription()
        let re = makeSlot(exercise: ex, prescription: p)

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertEqual(re.prescription?.sets, 3)
        XCTAssertEqual(re.prescription?.repMin, 8)
        XCTAssertEqual(re.prescription?.repMax, 8)
    }

    // MARK: - 10. First positive rest wins

    func testFirstPositiveRestWins() {
        // Sequence: nil, 0, 90, 120 → backfill picks 90 (skips nil and 0,
        // does not jump to the 120 later in the list).
        let defaults = [
            working(reps: 5, rest: nil, order: 0),
            working(reps: 5, rest: 0, order: 1),
            working(reps: 5, rest: 90, order: 2),
            working(reps: 5, rest: 120, order: 3),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let p = SlotPrescription()
        let re = makeSlot(exercise: ex, prescription: p)

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertEqual(re.prescription?.restSecondsBetweenSets, 90)
    }

    // MARK: - 11. Creates prescription if nil

    func testCreatesPrescriptionIfNil() {
        let defaults = [working(reps: 12, rest: 45, order: 0)]
        let ex = makeExercise(defaultTemplates: defaults)
        // Deliberately NO prescription — defensive branch (should be empty
        // post-backfillPhase3_1, but pinned so the branch can't drift).
        let re = makeSlot(exercise: ex, prescription: nil)
        XCTAssertNil(re.prescription)

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertNotNil(re.prescription)
        XCTAssertTrue(re.prescription?.hasContent ?? false)
        XCTAssertEqual(re.prescription?.sets, 1)
        XCTAssertEqual(re.prescription?.repMin, 12)
        XCTAssertEqual(re.prescription?.repMax, 12)
        XCTAssertEqual(re.prescription?.restSecondsBetweenSets, 45)
    }

    // MARK: - 12. Nil Exercise falls to AppSettings

    func testNilExerciseFallsToAppSettings() {
        let p = SlotPrescription()
        let re = makeSlot(exercise: nil, prescription: p)
        XCTAssertNil(re.exercise)

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        // No exercise → no isTimeBased signal → defaults to rep-based.
        XCTAssertEqual(re.prescription?.usesDuration, false)
        XCTAssertEqual(re.prescription?.sets, AppSettings.defaultSets)
        XCTAssertEqual(re.prescription?.repMin, AppSettings.defaultRepMin)
        XCTAssertEqual(re.prescription?.repMax, AppSettings.defaultRepMax)
    }

    // MARK: - 13. Does not mutate setTemplates

    func testDoesNotMutateSetTemplates() {
        let ex = makeExercise()
        let overrides = [
            working(reps: 8, weight: 60, rest: 90, order: 0),
            working(reps: 6, weight: 70, rest: 90, order: 1),
        ]
        let p = SlotPrescription()
        let re = makeSlot(
            exercise: ex, setTemplates: overrides, prescription: p
        )
        // Canonical sort by `.order` — SwiftData @Relationship arrays
        // don't guarantee iteration order, so we project to the order
        // the production resolver itself uses.
        let pre = re.setTemplates
            .sorted { $0.order < $1.order }
            .map {
                ($0.order, $0.targetReps, $0.targetWeight, $0.restSecondsAfter)
            }

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        let post = re.setTemplates
            .sorted { $0.order < $1.order }
            .map {
                ($0.order, $0.targetReps, $0.targetWeight, $0.restSecondsAfter)
            }
        XCTAssertEqual(re.setTemplates.count, 2)
        XCTAssertEqual(pre.map(\.0), post.map(\.0))
        XCTAssertEqual(pre.map(\.1), post.map(\.1))
        XCTAssertEqual(pre.map(\.2), post.map(\.2))
        XCTAssertEqual(pre.map(\.3), post.map(\.3))
    }

    // MARK: - 14. Does not mutate defaultTemplates

    func testDoesNotMutateDefaultTemplates() {
        let defaults = [
            working(reps: 10, weight: 40, rest: 60, order: 0),
            working(reps: 10, weight: 45, rest: 60, order: 1),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let p = SlotPrescription()
        _ = makeSlot(exercise: ex, prescription: p)
        // Canonical sort by `.order` — see note in testDoesNotMutateSetTemplates.
        let pre = ex.defaultTemplates
            .sorted { $0.order < $1.order }
            .map {
                ($0.order, $0.targetReps, $0.targetWeight, $0.restSecondsAfter)
            }

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        let post = ex.defaultTemplates
            .sorted { $0.order < $1.order }
            .map {
                ($0.order, $0.targetReps, $0.targetWeight, $0.restSecondsAfter)
            }
        XCTAssertEqual(ex.defaultTemplates.count, 2)
        XCTAssertEqual(pre.map(\.0), post.map(\.0))
        XCTAssertEqual(pre.map(\.1), post.map(\.1))
        XCTAssertEqual(pre.map(\.2), post.map(\.2))
        XCTAssertEqual(pre.map(\.3), post.map(\.3))
    }

    // MARK: - 15. Superset slots hydrate independently

    func testSupersetSlotsHydrateIndependently() {
        // Slot A: hydrate from setTemplates (Tier 1).
        let exA = makeExercise(name: "A")
        let pA = SlotPrescription()
        context.insert(pA)
        let reA = RoutineExercise(
            exercise: exA, order: 0,
            setTemplates: [
                working(reps: 8, rest: 60, order: 0),
                working(reps: 8, rest: 60, order: 1),
            ]
        )
        for t in reA.setTemplates { context.insert(t) }
        context.insert(reA)
        reA.prescription = pA

        // Slot B: hydrate from Exercise.defaultTemplates (Tier 3) with
        // a very different shape so cross-contamination is detectable.
        let exB = makeExercise(
            name: "B",
            defaultTemplates: [
                working(reps: 5, rest: 180, order: 0),
                working(reps: 5, rest: 180, order: 1),
                working(reps: 5, rest: 180, order: 2),
            ]
        )
        let pB = SlotPrescription()
        context.insert(pB)
        let reB = RoutineExercise(
            exercise: exB, order: 1, setTemplates: []
        )
        context.insert(reB)
        reB.prescription = pB

        let block = RoutineBlock(
            isSuperset: true, order: 0, exercises: [reA, reB]
        )
        context.insert(block)
        try? context.save()

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        // A mined from setTemplates: 2 × 8, rest 60.
        XCTAssertEqual(reA.prescription?.sets, 2)
        XCTAssertEqual(reA.prescription?.repMin, 8)
        XCTAssertEqual(reA.prescription?.repMax, 8)
        XCTAssertEqual(reA.prescription?.restSecondsBetweenSets, 60)
        // B mined from defaults: 3 × 5, rest 180. No bleed-through from A.
        XCTAssertEqual(reB.prescription?.sets, 3)
        XCTAssertEqual(reB.prescription?.repMin, 5)
        XCTAssertEqual(reB.prescription?.repMax, 5)
        XCTAssertEqual(reB.prescription?.restSecondsBetweenSets, 180)
    }

    // MARK: - 16. Hydration covers what Tier 3 used to (post Phase 9-C2)

    /// Phase 9-C2 removed the Tier 3 `Exercise.defaultTemplates` fallback
    /// from `resolvedTemplates(in:)`. For a Class-B legacy slot (empty
    /// `setTemplates`, non-empty `defaultTemplates`,
    /// `prescription.hasContent == false`), the resolver therefore
    /// returns `[]` until the hydration runs. Post-hydration the slot
    /// resolves via Tier 2 to the equivalent of the original defaults
    /// on the dimensions Tier 2 preserves: count, kind, targetReps,
    /// restSecondsAfter. `targetWeight` is the known loss the 9-A.5
    /// audit accepted (no `SlotPrescription` landing field — gated on
    /// the 9-pre diagnostic counter for 9-E).
    func testGoldenBehaviorPreservation() {
        // Uniform defaults so a single (reps, rest) pair faithfully
        // round-trips through SlotPrescription.generateTemplates().
        let defaults = [
            working(reps: 10, rest: 60, order: 0),
            working(reps: 10, rest: 60, order: 1),
            working(reps: 10, rest: 60, order: 2),
        ]
        let ex = makeExercise(defaultTemplates: defaults)
        let p = SlotPrescription()  // empty → hasContent == false
        let re = makeSlot(exercise: ex, prescription: p)

        // Pre-backfill (post-9-C2): Tier 1 empty, Tier 2 has no content,
        // Tier 3 removed → resolver returns []. This is exactly why the
        // hydration is load-bearing in production.
        XCTAssertTrue(
            re.resolvedTemplates(in: context).isEmpty,
            "Post-9-C2 the resolver returns [] for unhydrated Class-B slots — "
            + "BackfillService.hydrateEmptySlotPrescriptions is what makes "
            + "them resolve again."
        )

        BackfillService.hydrateEmptySlotPrescriptions(in: context)
        XCTAssertTrue(re.prescription?.hasContent ?? false)

        // Post-backfill: Tier 2 produces the equivalent of the original
        // defaults on the dimensions Tier 2 preserves.
        let post = re.resolvedTemplates(in: context)
        XCTAssertEqual(
            post.count, 3,
            "Tier 2 set count comes from the working-row count of the "
            + "source defaultTemplates."
        )
        XCTAssertTrue(
            post.allSatisfy { $0.kind == .working },
            "Tier 2 emits only .working rows."
        )
        XCTAssertTrue(
            post.allSatisfy { $0.targetReps == 10 },
            "targetReps preserved from defaults via the hydration's repMax."
        )
        XCTAssertTrue(
            post.allSatisfy { $0.restSecondsAfter == 60 },
            "restSecondsAfter preserved via the hydration's "
            + "restSecondsBetweenSets (first positive)."
        )
        // targetWeight is intentionally NOT compared — it has no
        // SlotPrescription landing field. Phase 9-A.5 accepted the loss
        // for the routine flow; 9-E gates the field-deletion decision
        // on the diagnostic's `defaultTemplatesWithTargetWeight` count.
    }
}
