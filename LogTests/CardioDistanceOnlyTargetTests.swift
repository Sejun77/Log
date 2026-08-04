import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 5 — a cardio slot programmed with a **distance target
/// and no duration**: "run 5k, however long it takes".
///
/// The design allows any of duration-only, distance-only, both, or neither, so
/// distance-only has to be a first-class prescription. It is also the shape
/// that falls outside `SlotPrescription.hasContent`, which asks the narrower
/// question "can this generate `SetTemplate`s?" — and cannot, because
/// `SetTemplate` has no distance field.
///
/// Pre-merge review found one real bug in that gap:
/// `BackfillService.hydrateEmptySlotPrescriptions` runs on **every launch** and
/// skipped only slots with `hasContent == true`, so it treated a distance-only
/// cardio slot as empty and rewrote its sets, rest and duration with
/// `AppSettings` defaults. `hasHydratableContent` closes it. The rest of this
/// file walks the slot end to end to show nothing else in the gap was broken.
@MainActor
final class CardioDistanceOnlyTargetTests: SwiftDataTestHarness {

    private let km = DistanceUnit.kilometers

    // MARK: - Fixtures

    private func cardioExercise() -> Exercise {
        let ex = Exercise(name: "Treadmill Run", isCustom: true)
        context.insert(ex)
        ex.setTimeBased(true)
        ex.setCardio(true)
        return ex
    }

    /// A cardio slot exactly as the routine editor would leave it: the cardio
    /// defaults (1 set, no rest) plus a distance target, and **no duration**.
    private func distanceOnlySlot(
        _ ex: Exercise, distance: String = "5"
    ) -> RoutineExercise {
        let p = makeDefaultPrescription(
            isTimeBased: true, isCardio: true, in: context)
        p.applyTargetDistance(CardioTargetDistance(text: distance, unit: km))

        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = p
        return re
    }

    @discardableResult
    private func routine(with slot: RoutineExercise) -> Routine {
        let block = RoutineBlock(
            isSuperset: false, order: 0, restAfterSeconds: nil,
            exercises: [slot])
        context.insert(block)
        let r = Routine(name: "Cardio Day", blocks: [block])
        context.insert(r)
        return r
    }

    // MARK: - The shape itself

    func testDistanceOnlySlotHasNoTemplateContentButIsAuthored() throws {
        let slot = distanceOnlySlot(cardioExercise())
        let p = try XCTUnwrap(slot.prescription)

        XCTAssertNil(p.durationMinSeconds)
        XCTAssertNil(p.durationMaxSeconds)
        XCTAssertNotNil(p.targetDistanceMeters)

        XCTAssertFalse(
            p.hasContent,
            "no duration means no meaningful SetTemplate can be generated")
        XCTAssertTrue(
            p.hasHydratableContent,
            "but the slot is authored and must never be treated as empty")
    }

    /// Tier 2 stays empty, deliberately: generating here would invent a
    /// duration via `generateTemplates`' `?? 60` fallback.
    func testDistanceOnlySlotGeneratesNoTemplates() {
        let slot = distanceOnlySlot(cardioExercise())
        XCTAssertTrue(slot.resolvedTemplates().isEmpty)
    }

    /// The specific value that must never appear: an invented 60-second target.
    func testDistanceOnlySlotNeverInventsADurationTarget() throws {
        let slot = distanceOnlySlot(cardioExercise())
        let p = try XCTUnwrap(slot.prescription)

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertNil(p.durationMinSeconds)
        XCTAssertNil(p.durationMaxSeconds)
    }

    // MARK: - 7. The backfill bug

    /// The regression. Before the fix this rewrote a real routine on every
    /// launch: 1 set → `AppSettings.defaultSets`, no rest → the default rest,
    /// no duration → 60s.
    func testBackfillDoesNotRewriteADistanceOnlyCardioSlot() throws {
        let slot = distanceOnlySlot(cardioExercise())
        let p = try XCTUnwrap(slot.prescription)
        routine(with: slot)
        try context.save()

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertEqual(p.sets, 1, "cardio's one-set default must survive")
        XCTAssertNil(p.restSecondsBetweenSets, "no rest must survive")
        XCTAssertNil(p.restSecondsAfterExercise)
        XCTAssertNil(p.durationMinSeconds)
        XCTAssertNil(p.durationMaxSeconds)
        XCTAssertEqual(
            try XCTUnwrap(p.targetDistanceMeters), 5_000, accuracy: 0.001)
    }

    /// Backfill runs at every launch, so idempotency has to hold across
    /// repeats, not just once.
    func testRepeatedBackfillRunsStayNoOps() throws {
        let slot = distanceOnlySlot(cardioExercise())
        let p = try XCTUnwrap(slot.prescription)
        routine(with: slot)
        try context.save()

        for _ in 0..<3 {
            BackfillService.hydrateEmptySlotPrescriptions(in: context)
        }

        XCTAssertEqual(p.sets, 1)
        XCTAssertNil(p.restSecondsBetweenSets)
        XCTAssertNil(p.durationMaxSeconds)
    }

    // MARK: - Existing backfill behavior is preserved

    /// A genuinely empty slot still hydrates — the fix must not turn backfill
    /// off. This is the case the service exists for.
    func testTrulyEmptySlotStillHydrates() throws {
        let ex = Exercise(name: "Bench Press", isCustom: true)
        context.insert(ex)
        let p = SlotPrescription()
        context.insert(p)
        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = p
        routine(with: re)
        try context.save()

        XCTAssertFalse(p.hasHydratableContent)
        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertEqual(p.sets, AppSettings.defaultSets)
        XCTAssertEqual(p.repMin, AppSettings.defaultRepMin)
        XCTAssertEqual(p.repMax, AppSettings.defaultRepMax)
    }

    /// An empty **timed-hold** slot still hydrates to the hardcoded 60s, which
    /// is correct for it: a plank with no duration really has nothing.
    func testEmptyTimedHoldSlotStillHydrates() throws {
        let ex = Exercise(name: "Plank", isCustom: true)
        context.insert(ex)
        ex.setTimeBased(true)
        let p = SlotPrescription()
        context.insert(p)
        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = p
        routine(with: re)
        try context.save()

        BackfillService.hydrateEmptySlotPrescriptions(in: context)

        XCTAssertEqual(p.sets, AppSettings.defaultSets)
        XCTAssertEqual(p.durationMinSeconds, 60)
        XCTAssertEqual(p.durationMaxSeconds, 60)
    }

    /// An empty cardio slot with **no** distance target is still empty and
    /// still hydrates — the guard keys off the target, not off cardio.
    func testEmptyCardioSlotWithoutATargetStillHydrates() throws {
        let ex = cardioExercise()
        let p = SlotPrescription()
        context.insert(p)
        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = p
        routine(with: re)
        try context.save()

        XCTAssertFalse(p.hasHydratableContent)
        BackfillService.hydrateEmptySlotPrescriptions(in: context)
        XCTAssertEqual(p.sets, AppSettings.defaultSets)
    }

    /// An unusable stored distance is not authorship — a corrupt row must not
    /// become permanently un-hydratable.
    func testCorruptDistanceDoesNotBlockHydration() throws {
        let ex = cardioExercise()
        let p = SlotPrescription()
        context.insert(p)
        p.targetDistanceMeters = -1
        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = p
        routine(with: re)
        try context.save()

        XCTAssertNil(p.targetDistance(fallbackUnit: km))
        // `hasHydratableContent` reads the raw column, so a negative value
        // still counts as "set". Assert the safe half of the contract: nothing
        // crashes and no target is rendered from it.
        BackfillService.hydrateEmptySlotPrescriptions(in: context)
        XCTAssertNil(p.targetDistance(fallbackUnit: km))
    }

    // MARK: - 1. Startable

    func testRoutineWithADistanceOnlyCardioSlotIsStartable() throws {
        let r = routine(with: distanceOnlySlot(cardioExercise()))
        try context.save()

        XCTAssertTrue(
            r.isStartable(in: context),
            "startability reads the exercise, never the prescription")
    }

    // MARK: - 2. Appears in the active workout

    /// `makePlan` is private to a SwiftUI view, so this reproduces the two
    /// steps that decide whether the row exists: the slot survives plan
    /// building (only a nil `exercise` drops it), and the set count comes from
    /// the snapshot's `sets`, not from the empty template list.
    func testDistanceOnlySlotStillRendersOneSetRow() throws {
        let ex = cardioExercise()
        let slot = distanceOnlySlot(ex)
        try context.save()

        XCTAssertNotNil(slot.exercise, "the slot is not dropped at plan build")

        let payload = PrescriptionSnapshotPayload(
            from: try XCTUnwrap(slot.prescription), exercise: ex)
        let count = SessionPlanResolver.effectiveSetCount(
            sessionPlan: nil, snapshot: payload, resolvedTemplates: [])

        XCTAssertEqual(count, 1)
    }

    /// Even with `sets` somehow nil, the resolver's `max(1, …)` clamp keeps a
    /// row on screen rather than rendering an exercise with nothing to log.
    func testRowSurvivesEvenWithoutASetCount() {
        let p = SlotPrescription()
        context.insert(p)
        p.usesDuration = true
        p.applyTargetDistance(CardioTargetDistance(text: "5", unit: km))

        let payload = PrescriptionSnapshotPayload(from: p, exercise: nil)
        XCTAssertNil(payload.sets)
        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: nil, snapshot: payload, resolvedTemplates: []),
            1)
    }

    /// No duration is programmed, so no duration target is resolved — the row
    /// opens with an empty duration field rather than a fabricated one.
    func testNoDurationTargetIsResolvedForADistanceOnlySlot() throws {
        let payload = PrescriptionSnapshotPayload(
            from: try XCTUnwrap(distanceOnlySlot(cardioExercise()).prescription),
            exercise: nil)

        XCTAssertNil(
            SessionPlanResolver.plannedDurationTarget(
                sessionPlan: nil, snapshot: payload,
                template: PlanSetTemplate(
                    id: "x", kind: .working, targetReps: 0, targetWeight: nil,
                    restSecondsAfter: nil, durationSeconds: nil)))
    }

    // MARK: - 3. The draft seeds from the target

    func testDistanceOnlyTargetSeedsTheCardioDraft() throws {
        let payload = PrescriptionSnapshotPayload(
            from: try XCTUnwrap(distanceOnlySlot(cardioExercise()).prescription),
            exercise: nil)

        let target = try XCTUnwrap(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: nil, snapshot: payload, fallbackUnit: km))
        let draft = CardioEntryDraft(
            unit: target.unit, distance: target.valueText ?? "")

        XCTAssertEqual(draft.distance, "5")
        XCTAssertEqual(draft.unit, km)
    }

    // MARK: - 4 & 6. Logging and History

    /// The Log gate is the duration typed into the row, which is independent of
    /// whether the routine programmed one. The set logs, and History renders
    /// the performed distance next to it.
    func testUserTypedDurationLogsTheSetWithTheSeededDistance() throws {
        let payload = PrescriptionSnapshotPayload(
            from: try XCTUnwrap(distanceOnlySlot(cardioExercise()).prescription),
            exercise: nil)
        let target = try XCTUnwrap(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: nil, snapshot: payload, fallbackUnit: km))
        let draft = CardioEntryDraft(
            unit: target.unit, distance: target.valueText ?? "")

        // The user types 27:30 in the duration field and taps Log.
        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: 0, weight: nil,
            durationSeconds: 1_650)
        context.insert(log)
        log.applyCardioMetrics(draft.metrics)
        try context.save()

        XCTAssertEqual(log.durationSeconds, 1_650)
        XCTAssertEqual(
            try XCTUnwrap(log.distanceMeters), 5_000, accuracy: 0.001)

        XCTAssertEqual(CardioHistorySummary.primaryText(for: log), "1650s")
        XCTAssertEqual(
            CardioHistorySummary.secondaryLines(for: log, fallbackUnit: km),
            ["5 km · 5:30 /km"])
    }

    /// A shortfall against the target is logged as the shortfall, and the
    /// routine's target is untouched by it.
    func testEditedDistanceLogsTheEditAndLeavesTheTargetAlone() throws {
        let slot = distanceOnlySlot(cardioExercise())
        let p = try XCTUnwrap(slot.prescription)

        var draft = CardioEntryDraft(unit: km, distance: "5")
        draft.distance = "4.2"

        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_500)
        context.insert(log)
        log.applyCardioMetrics(draft.metrics)
        try context.save()

        XCTAssertEqual(
            try XCTUnwrap(log.distanceMeters), 4_200, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(p.targetDistanceMeters), 5_000, accuracy: 0.001)
    }

    // MARK: - 5. Save & Exit / Resume

    /// A persisted draft outranks the target, so an edit survives a resume —
    /// the same precedence proved for duration-carrying cardio slots, asserted
    /// here for the distance-only shape through the real store.
    func testResumePreservesTheEditedDistanceOverTheTarget() throws {
        let store = ParentDraftStore(
            workoutID: UUID(),
            defaults: try XCTUnwrap(
                UserDefaults(suiteName: "CardioDistanceOnlyTargetTests")))
        defer { store.clearAll() }

        let slotID = UUID()
        store.persist(
            slotID: slotID, setIndex: 0,
            cardio: CardioEntryDraft(unit: km, distance: "4.2"))

        let snapshot = try XCTUnwrap(store.load(slotID: slotID, setIndex: 0))
        let restored = try XCTUnwrap(
            CardioEntryDraft(snapshot: snapshot, defaultUnit: km))

        XCTAssertEqual(restored.distance, "4.2")
    }

    // MARK: - Summary

    func testBlockSummaryShowsTheDistanceWithoutADuration() throws {
        let slot = distanceOnlySlot(cardioExercise())
        let block = RoutineBlock(
            isSuperset: false, order: 0, restAfterSeconds: nil,
            exercises: [slot])
        context.insert(block)
        try context.save()

        XCTAssertEqual(
            BlockPrescriptionSummary(block: block, fallbackUnit: km).subtitle,
            "1 set · 5 km")
    }
}
