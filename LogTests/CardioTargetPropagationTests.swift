import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 5 — the target distance's journey from a routine slot
/// to the active-workout row, and the summaries along the way.
///
/// The path is `SlotPrescription` → `PrescriptionSnapshotPayload` (frozen at
/// session start) → `PlannedPrescriptionSnapshot` (persisted) → `SessionPlan`
/// (session-scoped, editable). Every hop is asserted, because a value that
/// silently stops at one of them looks exactly like a value that was never set.
@MainActor
final class CardioTargetPropagationTests: SwiftDataTestHarness {

    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles

    private func cardioPrescription(
        durationSeconds: Int? = 1_800,
        distanceText: String? = "5",
        unit: DistanceUnit = .kilometers
    ) -> SlotPrescription {
        let p = SlotPrescription()
        context.insert(p)
        p.usesDuration = true
        p.sets = 1
        p.durationMaxSeconds = durationSeconds
        if let distanceText {
            p.applyTargetDistance(
                CardioTargetDistance(text: distanceText, unit: unit))
        }
        return p
    }

    // MARK: - 26–29. Block summary

    func testSummaryShowsDurationOnly() {
        let summary = BlockPrescriptionSummary(
            sets: 1, durationSeconds: 1_800, usesDuration: true)
        XCTAssertEqual(summary.subtitle, "1 × 1800s")
    }

    func testSummaryShowsDistanceOnly() {
        let summary = BlockPrescriptionSummary(
            sets: 1, usesDuration: true, targetDistance: "5 km")
        XCTAssertEqual(summary.subtitle, "1 set · 5 km")
    }

    func testSummaryShowsDurationAndDistance() {
        let summary = BlockPrescriptionSummary(
            sets: 1, durationSeconds: 1_800, usesDuration: true,
            targetDistance: "5 km")
        XCTAssertEqual(summary.subtitle, "1 × 1800s · 5 km")
    }

    func testSummaryOmitsAbsentValuesWithoutPlaceholders() {
        let summary = BlockPrescriptionSummary(sets: 1, usesDuration: true)
        XCTAssertEqual(summary.subtitle, "1 set")
        XCTAssertFalse(summary.subtitle.contains("—"))
        XCTAssertFalse(summary.subtitle.contains("km"))
    }

    func testSummarySegmentOrderPutsDistanceBeforeRestAndEffort() {
        let summary = BlockPrescriptionSummary(
            sets: 1, durationSeconds: 1_800, usesDuration: true,
            targetDistance: "5 km", restSeconds: 60, effort: "RIR 2")
        XCTAssertEqual(summary.subtitle, "1 × 1800s · 5 km · 60s rest · RIR 2")
    }

    /// Built from a live block, the distance renders in the slot's **own**
    /// stored unit — a routine authored in miles keeps reading in miles
    /// whatever the current global preference is.
    func testSummaryFromLiveBlockUsesTheStoredUnit() throws {
        let ex = Exercise(name: "Treadmill Run")
        context.insert(ex)
        ex.setTimeBased(true)
        ex.setCardio(true)

        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = cardioPrescription(distanceText: "3.1", unit: mi)

        let block = RoutineBlock(
            isSuperset: false, order: 0, restAfterSeconds: nil, exercises: [re])
        context.insert(block)
        try context.save()

        // Fallback deliberately km — the stored "mi" must win.
        let summary = BlockPrescriptionSummary(block: block, fallbackUnit: km)
        XCTAssertEqual(summary.subtitle, "1 × 1800s · 3.1 mi")
    }

    /// Strength and timed-hold blocks render exactly as they did before this
    /// slice existed.
    func testStrengthAndTimedHoldSummariesAreUnchanged() throws {
        let bench = Exercise(name: "Bench Press")
        context.insert(bench)
        let benchRE = RoutineExercise(exercise: bench, order: 0, setTemplates: [])
        context.insert(benchRE)
        benchRE.prescription = SlotPrescription(
            sets: 3, repMin: 8, repMax: 12, restSecondsBetweenSets: 90)
        context.insert(try XCTUnwrap(benchRE.prescription))
        let benchBlock = RoutineBlock(
            isSuperset: false, order: 0, restAfterSeconds: nil,
            exercises: [benchRE])
        context.insert(benchBlock)

        let plank = Exercise(name: "Plank")
        context.insert(plank)
        plank.setTimeBased(true)
        let plankRE = RoutineExercise(exercise: plank, order: 0, setTemplates: [])
        context.insert(plankRE)
        let plankP = SlotPrescription(
            durationMaxSeconds: 45, usesDuration: true)
        plankP.sets = 3
        context.insert(plankP)
        plankRE.prescription = plankP
        let plankBlock = RoutineBlock(
            isSuperset: false, order: 1, restAfterSeconds: nil,
            exercises: [plankRE])
        context.insert(plankBlock)
        try context.save()

        XCTAssertEqual(
            BlockPrescriptionSummary(block: benchBlock).subtitle,
            "3 × 8–12 · 90s rest")
        XCTAssertEqual(
            BlockPrescriptionSummary(block: plankBlock).subtitle, "3 × 45s")
    }

    // MARK: - 30. Snapshot at session start

    func testStartingAWorkoutSnapshotsTheTargetDistance() throws {
        let ex = Exercise(name: "Treadmill Run")
        context.insert(ex)
        ex.setTimeBased(true)
        ex.setCardio(true)
        let source = cardioPrescription()

        // Plan-build time: the value-type copy carried in `PlanExercise`.
        let payload = PrescriptionSnapshotPayload(from: source, exercise: ex)
        XCTAssertEqual(
            try XCTUnwrap(payload.targetDistanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(payload.targetDistanceUnitRaw, "km")

        // WorkoutItem creation: the persisted `@Model` snapshot.
        let model = payload.toModel()
        context.insert(model)
        XCTAssertEqual(
            try XCTUnwrap(model.targetDistanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(model.targetDistanceUnitRaw, "km")

        // Resume: the payload rebuilt from the persisted snapshot.
        let restored = PrescriptionSnapshotPayload(from: model)
        XCTAssertEqual(
            try XCTUnwrap(restored.targetDistanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(restored.targetDistanceUnitRaw, "km")
    }

    /// The `@Model` convenience init copies it too — that is the path a real
    /// session start takes.
    func testModelSnapshotInitCopiesTheTarget() throws {
        let source = cardioPrescription(distanceText: "3.1", unit: mi)
        let snapshot = PlannedPrescriptionSnapshot(from: source, exercise: nil)
        context.insert(snapshot)

        let target = try XCTUnwrap(snapshot.targetDistance(fallbackUnit: km))
        XCTAssertEqual(target.unit, mi)
        XCTAssertEqual(target.displayText, "3.1 mi")
    }

    /// A frozen snapshot is immutable: editing the routine afterwards must not
    /// change the workout that is already running.
    func testEditingTheRoutineDoesNotRewriteAFrozenSnapshot() throws {
        let source = cardioPrescription()
        let snapshot = PlannedPrescriptionSnapshot(from: source, exercise: nil)
        context.insert(snapshot)

        source.applyTargetDistance(CardioTargetDistance(text: "10", unit: km))
        try context.save()

        XCTAssertEqual(
            try XCTUnwrap(snapshot.targetDistanceMeters), 5_000, accuracy: 0.001)
    }

    func testNonCardioSlotSnapshotsNoTarget() {
        let p = SlotPrescription(sets: 3, repMin: 8, repMax: 12)
        context.insert(p)
        let payload = PrescriptionSnapshotPayload(from: p, exercise: nil)
        XCTAssertNil(payload.targetDistanceMeters)
        XCTAssertNil(payload.targetDistanceUnitRaw)
    }

    // MARK: - SessionPlan

    func testSessionPlanCarriesTheTargetFromTheSnapshot() throws {
        let payload = PrescriptionSnapshotPayload(
            from: cardioPrescription(), exercise: nil)
        let plan = SessionPlan(from: payload, notes: nil)

        let target = try XCTUnwrap(plan.targetDistance(fallbackUnit: km))
        XCTAssertEqual(target.displayText, "5 km")
    }

    /// A `SessionPlan` persisted by a build that predates these keys must still
    /// decode — the fields are `Optional`, so synthesized decoding uses
    /// `decodeIfPresent`.
    func testLegacySessionPlanJSONDecodesWithNilTarget() throws {
        let legacy = """
            {"sets":1,"usesDuration":true,"durationMaxSeconds":1800}
            """
        let plan = try JSONDecoder().decode(
            SessionPlan.self, from: Data(legacy.utf8))

        XCTAssertEqual(plan.sets, 1)
        XCTAssertNil(plan.targetDistanceMeters)
        XCTAssertNil(plan.targetDistanceUnitRaw)
        XCTAssertNil(plan.targetDistance(fallbackUnit: km))
    }

    func testSessionPlanRoundTripsThroughJSON() throws {
        var plan = SessionPlan()
        plan.sets = 1
        plan.usesDuration = true
        plan.targetDistanceMeters = 5_000
        plan.targetDistanceUnitRaw = "km"

        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(SessionPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
    }

    func testSessionPlanPrimarySummaryIncludesTheDistance() {
        var plan = SessionPlan()
        plan.sets = 1
        plan.usesDuration = true
        plan.durationMaxSeconds = 1_800
        plan.targetDistanceMeters = 5_000
        plan.targetDistanceUnitRaw = "km"

        XCTAssertEqual(plan.primarySummary, "1 sets · 1800s · 5 km")
    }

    func testSessionPlanPrimarySummaryIsUnchangedWithoutADistance() {
        var strength = SessionPlan()
        strength.sets = 3
        strength.repMin = 8
        strength.repMax = 12
        XCTAssertEqual(strength.primarySummary, "3 sets · 8–12 reps")

        var hold = SessionPlan()
        hold.sets = 3
        hold.usesDuration = true
        hold.durationMaxSeconds = 45
        XCTAssertEqual(hold.primarySummary, "3 sets · 45s")
    }

    // MARK: - 31. Resolver precedence

    func testResolverPrefersTheSessionPlanOverTheSnapshot() throws {
        var plan = SessionPlan()
        plan.targetDistanceMeters = 10_000
        plan.targetDistanceUnitRaw = "km"
        let snapshot = PrescriptionSnapshotPayload(
            from: cardioPrescription(), exercise: nil)

        let resolved = try XCTUnwrap(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: plan, snapshot: snapshot, fallbackUnit: km))
        XCTAssertEqual(resolved.displayText, "10 km")
    }

    func testResolverFallsBackToTheSnapshot() throws {
        let snapshot = PrescriptionSnapshotPayload(
            from: cardioPrescription(), exercise: nil)

        let resolved = try XCTUnwrap(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: SessionPlan(), snapshot: snapshot,
                fallbackUnit: km))
        XCTAssertEqual(resolved.displayText, "5 km")
    }

    func testResolverReturnsNilWhenNoTierHasATarget() {
        XCTAssertNil(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: nil, snapshot: nil, fallbackUnit: km))
        XCTAssertNil(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: SessionPlan(), snapshot: .empty, fallbackUnit: km))
    }

    // MARK: - 31–32. Draft seeding precedence

    /// `ActiveWorkoutView.rehydrateCardioDrafts` is unreachable from a test (a
    /// 3900-line SwiftUI view with no view model), so these reproduce its
    /// precedence chain exactly: a logged set wins, then a persisted draft,
    /// then — and only then — the routine target.
    private func resolveDraft(
        logged: SetLog?,
        snapshot: ParentDraftStore.Snapshot?,
        target: CardioTargetDistance?,
        defaultUnit: DistanceUnit
    ) -> CardioEntryDraft? {
        if let logged, logged.hasCardioMetrics {
            return CardioEntryDraft(logged: logged, defaultUnit: defaultUnit)
        }
        if logged == nil, let snapshot,
            let restored = CardioEntryDraft(
                snapshot: snapshot, defaultUnit: defaultUnit)
        {
            return restored
        }
        if let target {
            return CardioEntryDraft(
                unit: target.unit, distance: target.valueText ?? "")
        }
        return nil
    }

    private func target(_ text: String, _ unit: DistanceUnit = .kilometers)
        -> CardioTargetDistance?
    {
        CardioTargetDistance(text: text, unit: unit)
    }

    func testUntouchedFieldSeedsFromTheRoutineTarget() throws {
        let draft = try XCTUnwrap(
            resolveDraft(
                logged: nil, snapshot: nil, target: target("5"),
                defaultUnit: km))

        XCTAssertEqual(draft.distance, "5")
        XCTAssertEqual(draft.unit, km)
        // Only the distance is seeded — the outcome metrics stay empty.
        XCTAssertEqual(draft.avgHeartRate, "")
        XCTAssertEqual(draft.calories, "")
        XCTAssertNil(draft.hrZone)
    }

    func testSeedUsesTheTargetsOwnUnit() throws {
        let draft = try XCTUnwrap(
            resolveDraft(
                logged: nil, snapshot: nil, target: target("3.1", mi),
                defaultUnit: km))

        XCTAssertEqual(draft.unit, mi)
        XCTAssertEqual(draft.distance, "3.1")
    }

    func testNoTargetLeavesTheDraftUnseeded() {
        XCTAssertNil(
            resolveDraft(
                logged: nil, snapshot: nil, target: nil, defaultUnit: km))
    }

    /// The Save & Exit → Resume guarantee: a persisted draft always beats the
    /// target, so an edit is never reverted to the prescription.
    func testUserEditedDraftWinsOverTheTarget() throws {
        var snapshot = ParentDraftStore.Snapshot()
        snapshot.distance = "7.5"
        snapshot.distanceUnit = "km"

        let draft = try XCTUnwrap(
            resolveDraft(
                logged: nil, snapshot: snapshot, target: target("5"),
                defaultUnit: km))
        XCTAssertEqual(draft.distance, "7.5")
    }

    /// The harder half of the same guarantee: a user who *clears* the field has
    /// still touched it. The store writes empty strings rather than skipping
    /// them, so the cleared draft is restored as cleared — the target must not
    /// creep back in.
    func testDeliberatelyClearedDistanceIsNotRefilledByTheTarget() throws {
        var snapshot = ParentDraftStore.Snapshot()
        snapshot.distance = ""
        snapshot.distanceUnit = "km"

        let draft = try XCTUnwrap(
            resolveDraft(
                logged: nil, snapshot: snapshot, target: target("5"),
                defaultUnit: km))
        XCTAssertEqual(
            draft.distance, "",
            "a cleared field must stay cleared across a resume")
    }

    /// The store round-trips a real persisted draft, so the precedence above is
    /// exercised against the actual persistence layer, not just a hand-built
    /// snapshot.
    func testPersistedDraftRoundTripsAndStillWins() throws {
        let store = ParentDraftStore(
            workoutID: UUID(),
            defaults: try XCTUnwrap(
                UserDefaults(suiteName: "CardioTargetPropagationTests")))
        let slotID = UUID()
        store.persist(
            slotID: slotID, setIndex: 0,
            cardio: CardioEntryDraft(unit: mi, distance: "2"))
        defer { store.clearAll() }

        let snapshot = try XCTUnwrap(store.load(slotID: slotID, setIndex: 0))
        let draft = try XCTUnwrap(
            resolveDraft(
                logged: nil, snapshot: snapshot, target: target("5"),
                defaultUnit: km))

        XCTAssertEqual(draft.distance, "2")
        XCTAssertEqual(draft.unit, mi)
    }

    /// A logged set is the strongest tier: what was recorded wins over both the
    /// draft and the target.
    func testLoggedSetWinsOverTheTarget() throws {
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: 4_200, distanceUnit: km))

        let draft = try XCTUnwrap(
            resolveDraft(
                logged: log, snapshot: nil, target: target("5"),
                defaultUnit: km))
        XCTAssertEqual(draft.distance, "4.2")
    }

    // MARK: - 33–34. What actually gets logged

    /// A seeded target that the user accepts is logged as performed distance —
    /// on `SetLog`, in the performed fields, with no target field anywhere near
    /// it.
    func testLoggingASeededDraftStoresPerformedDistance() throws {
        let draft = try XCTUnwrap(
            resolveDraft(
                logged: nil, snapshot: nil, target: target("5"),
                defaultUnit: km))

        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(draft.metrics)
        try context.save()

        XCTAssertEqual(
            try XCTUnwrap(log.distanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(log.distanceUnitRaw, "km")
    }

    /// Duration-only cardio still works when there is no distance target: the
    /// draft is unseeded, the metrics are empty, and the row logs as it always
    /// has.
    func testDurationOnlyCardioLoggingIsUnaffected() throws {
        let draft =
            resolveDraft(logged: nil, snapshot: nil, target: nil, defaultUnit: km)
            ?? CardioEntryDraft(unit: km)

        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(draft.metrics)
        try context.save()

        XCTAssertNil(log.distanceMeters)
        XCTAssertNil(log.distanceUnitRaw)
        XCTAssertFalse(log.hasCardioMetrics)
        XCTAssertEqual(log.durationSeconds, 1_800)
    }

    /// An edited seed logs the edit, not the target.
    func testEditedDistanceIsLoggedOverTheTarget() throws {
        var draft = try XCTUnwrap(
            resolveDraft(
                logged: nil, snapshot: nil, target: target("5"),
                defaultUnit: km))
        draft.distance = "4.2"

        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(draft.metrics)

        XCTAssertEqual(
            try XCTUnwrap(log.distanceMeters), 4_200, accuracy: 0.001)
    }
}
