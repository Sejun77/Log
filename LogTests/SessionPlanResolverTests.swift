import XCTest

@testable import Log

/// Phase 11.6-B — `SessionPlanResolver` was extracted out of five
/// private methods on `ActiveWorkoutView` (`effectiveSetCount`,
/// `plannedRepTarget`, `plannedDurationTarget`,
/// `plannedRestBetweenSets`, `plannedRestAfterExercise`). These tests
/// pin the three-tier fallback chain (sessionPlan → snapshot →
/// template / count clamp / nil) and the per-tier `> 0` / `??` filters
/// so future refactors can't silently regress planned-target resolution.
///
/// Pure-XCTest. No SwiftData harness — every value is constructed
/// in-memory via `SessionPlan.init()`, the `PrescriptionSnapshotPayload`
/// test-only init extension below, and `PlanSetTemplate.init`.
final class SessionPlanResolverTests: XCTestCase {

    // MARK: - Helpers

    private func makeTemplate(
        targetReps: Int = 10,
        durationSeconds: Int? = nil
    ) -> PlanSetTemplate {
        PlanSetTemplate(
            id: "t",
            kind: .working,
            targetReps: targetReps,
            targetWeight: nil,
            restSecondsAfter: nil,
            durationSeconds: durationSeconds
        )
    }

    /// SessionPlan has `init()` so we can build via mutation. Helper
    /// keeps test bodies short.
    private func makeSessionPlan(
        sets: Int? = nil,
        repMin: Int? = nil,
        repMax: Int? = nil,
        restSecondsBetweenSets: Int? = nil,
        restSecondsAfterExercise: Int? = nil,
        durationMinSeconds: Int? = nil,
        durationMaxSeconds: Int? = nil
    ) -> SessionPlan {
        var sp = SessionPlan()
        sp.sets = sets
        sp.repMin = repMin
        sp.repMax = repMax
        sp.restSecondsBetweenSets = restSecondsBetweenSets
        sp.restSecondsAfterExercise = restSecondsAfterExercise
        sp.durationMinSeconds = durationMinSeconds
        sp.durationMaxSeconds = durationMaxSeconds
        return sp
    }

    private func makeSnapshot(
        sets: Int? = nil,
        repMin: Int? = nil,
        repMax: Int? = nil,
        restSecondsBetweenSets: Int? = nil,
        restSecondsAfterExercise: Int? = nil,
        durationMinSeconds: Int? = nil,
        durationMaxSeconds: Int? = nil
    ) -> PrescriptionSnapshotPayload {
        PrescriptionSnapshotPayload(
            sets: sets,
            repMin: repMin,
            repMax: repMax,
            restSecondsBetweenSets: restSecondsBetweenSets,
            restSecondsAfterExercise: restSecondsAfterExercise,
            durationMinSeconds: durationMinSeconds,
            durationMaxSeconds: durationMaxSeconds
        )
    }

    // MARK: - effectiveSetCount

    func testEffectiveSetCountSessionPlanWinsOverSnapshotAndTemplates() {
        let sp = makeSessionPlan(sets: 7)
        let snap = makeSnapshot(sets: 4)
        let templates = (0..<3).map { _ in makeTemplate() }
        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: sp, snapshot: snap, resolvedTemplates: templates),
            7
        )
    }

    func testEffectiveSetCountSnapshotUsedWhenSessionPlanNil() {
        let snap = makeSnapshot(sets: 4)
        let templates = (0..<3).map { _ in makeTemplate() }
        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: nil, snapshot: snap, resolvedTemplates: templates),
            4
        )
    }

    func testEffectiveSetCountSnapshotUsedWhenSessionPlanSetsIsNil() {
        let sp = makeSessionPlan(sets: nil, repMin: 5)  // sets unset, but plan exists
        let snap = makeSnapshot(sets: 4)
        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: sp, snapshot: snap, resolvedTemplates: []),
            4
        )
    }

    func testEffectiveSetCountTemplateCountFallback() {
        let templates = (0..<3).map { _ in makeTemplate() }
        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: nil, snapshot: nil, resolvedTemplates: templates),
            3
        )
    }

    func testEffectiveSetCountClampsToOneWhenTemplatesEmpty() {
        // The `max(1, …)` clamp is load-bearing — UI must render ≥1 row.
        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: nil, snapshot: nil, resolvedTemplates: []),
            1
        )
    }

    func testEffectiveSetCountZeroSessionPlanSetsCascadesToSnapshot() {
        // `s > 0` filter on sessionPlan.sets — a stored 0 falls through.
        let sp = makeSessionPlan(sets: 0)
        let snap = makeSnapshot(sets: 5)
        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: sp, snapshot: snap, resolvedTemplates: []),
            5
        )
    }

    func testEffectiveSetCountZeroSnapshotSetsCascadesToTemplateClamp() {
        // `s > 0` filter on snapshot.sets too.
        let snap = makeSnapshot(sets: 0)
        let templates = (0..<2).map { _ in makeTemplate() }
        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: nil, snapshot: snap, resolvedTemplates: templates),
            2
        )
    }

    // MARK: - plannedRepTarget

    func testRepTargetSessionPlanRepMaxWins() {
        let sp = makeSessionPlan(repMin: 5, repMax: 12)
        let snap = makeSnapshot(repMin: 8, repMax: 10)
        XCTAssertEqual(
            SessionPlanResolver.plannedRepTarget(
                sessionPlan: sp, snapshot: snap, template: makeTemplate(targetReps: 3)),
            12
        )
    }

    func testRepTargetSessionPlanRepMinUsedWhenRepMaxNil() {
        let sp = makeSessionPlan(repMin: 5)  // repMax nil
        let snap = makeSnapshot(repMax: 10)
        XCTAssertEqual(
            SessionPlanResolver.plannedRepTarget(
                sessionPlan: sp, snapshot: snap, template: makeTemplate(targetReps: 3)),
            5
        )
    }

    func testRepTargetSnapshotUsedWhenSessionPlanRepsAllNil() {
        let sp = makeSessionPlan(sets: 5)  // repMin/repMax both nil
        let snap = makeSnapshot(repMax: 10)
        XCTAssertEqual(
            SessionPlanResolver.plannedRepTarget(
                sessionPlan: sp, snapshot: snap, template: makeTemplate(targetReps: 3)),
            10
        )
    }

    func testRepTargetTemplateFallback() {
        XCTAssertEqual(
            SessionPlanResolver.plannedRepTarget(
                sessionPlan: nil, snapshot: nil, template: makeTemplate(targetReps: 8)),
            8
        )
    }

    func testRepTargetSessionPlanRepMaxZeroIsAccepted() {
        // The `??` chain treats nil as "fall through" but accepts any
        // stored Int including 0 — preserve that.
        let sp = makeSessionPlan(repMax: 0)
        let snap = makeSnapshot(repMax: 10)
        XCTAssertEqual(
            SessionPlanResolver.plannedRepTarget(
                sessionPlan: sp, snapshot: snap, template: makeTemplate(targetReps: 3)),
            0
        )
    }

    // MARK: - plannedDurationTarget

    func testDurationTargetSessionPlanMaxWins() {
        let sp = makeSessionPlan(durationMinSeconds: 30, durationMaxSeconds: 60)
        let snap = makeSnapshot(durationMaxSeconds: 90)
        XCTAssertEqual(
            SessionPlanResolver.plannedDurationTarget(
                sessionPlan: sp, snapshot: snap, template: makeTemplate(durationSeconds: 45)),
            60
        )
    }

    func testDurationTargetSnapshotUsedWhenSessionPlanDurationsNil() {
        let sp = makeSessionPlan(sets: 5)  // no duration fields
        let snap = makeSnapshot(durationMaxSeconds: 90)
        XCTAssertEqual(
            SessionPlanResolver.plannedDurationTarget(
                sessionPlan: sp, snapshot: snap, template: makeTemplate(durationSeconds: 45)),
            90
        )
    }

    func testDurationTargetTemplateFallback() {
        XCTAssertEqual(
            SessionPlanResolver.plannedDurationTarget(
                sessionPlan: nil, snapshot: nil, template: makeTemplate(durationSeconds: 45)),
            45
        )
    }

    func testDurationTargetNilWhenAllTiersEmpty() {
        XCTAssertNil(
            SessionPlanResolver.plannedDurationTarget(
                sessionPlan: nil, snapshot: nil, template: makeTemplate(durationSeconds: nil))
        )
    }

    // MARK: - plannedRestBetweenSets

    func testRestBetweenSessionPlanWins() {
        let sp = makeSessionPlan(restSecondsBetweenSets: 75)
        let snap = makeSnapshot(restSecondsBetweenSets: 60)
        XCTAssertEqual(
            SessionPlanResolver.plannedRestBetweenSets(
                sessionPlan: sp, snapshot: snap),
            75
        )
    }

    func testRestBetweenSnapshotUsedWhenSessionPlanIsZero() {
        // `> 0` filter — 0 cascades.
        let sp = makeSessionPlan(restSecondsBetweenSets: 0)
        let snap = makeSnapshot(restSecondsBetweenSets: 60)
        XCTAssertEqual(
            SessionPlanResolver.plannedRestBetweenSets(
                sessionPlan: sp, snapshot: snap),
            60
        )
    }

    func testRestBetweenNilWhenBothTiersZeroOrMissing() {
        let sp = makeSessionPlan(restSecondsBetweenSets: 0)
        let snap = makeSnapshot(restSecondsBetweenSets: 0)
        XCTAssertNil(
            SessionPlanResolver.plannedRestBetweenSets(
                sessionPlan: sp, snapshot: snap))
        XCTAssertNil(
            SessionPlanResolver.plannedRestBetweenSets(
                sessionPlan: nil, snapshot: nil))
    }

    // MARK: - plannedRestAfterExercise

    func testRestAfterSessionPlanWins() {
        let sp = makeSessionPlan(restSecondsAfterExercise: 120)
        let snap = makeSnapshot(restSecondsAfterExercise: 90)
        XCTAssertEqual(
            SessionPlanResolver.plannedRestAfterExercise(
                sessionPlan: sp, snapshot: snap),
            120
        )
    }

    func testRestAfterSnapshotUsedWhenSessionPlanIsZero() {
        let sp = makeSessionPlan(restSecondsAfterExercise: 0)
        let snap = makeSnapshot(restSecondsAfterExercise: 90)
        XCTAssertEqual(
            SessionPlanResolver.plannedRestAfterExercise(
                sessionPlan: sp, snapshot: snap),
            90
        )
    }

    func testRestAfterNilWhenBothTiersZeroOrMissing() {
        XCTAssertNil(
            SessionPlanResolver.plannedRestAfterExercise(
                sessionPlan: makeSessionPlan(restSecondsAfterExercise: 0),
                snapshot: makeSnapshot(restSecondsAfterExercise: 0)))
        XCTAssertNil(
            SessionPlanResolver.plannedRestAfterExercise(
                sessionPlan: nil, snapshot: nil))
    }

    func testRestAfterAndBetweenAreIndependent() {
        // Pin: rest-after and rest-between use independent fields and
        // don't cross-fall-through to each other.
        let sp = makeSessionPlan(restSecondsBetweenSets: 60)
        XCTAssertNil(
            SessionPlanResolver.plannedRestAfterExercise(
                sessionPlan: sp, snapshot: nil))
        XCTAssertEqual(
            SessionPlanResolver.plannedRestBetweenSets(
                sessionPlan: sp, snapshot: nil),
            60
        )
    }
}

// MARK: - Test-only memberwise init for PrescriptionSnapshotPayload
//
// `PrescriptionSnapshotPayload`'s only production initializers are
// `init(from: SlotPrescription)` and `init(from: PlannedPrescriptionSnapshot)`
// — both require SwiftData instances. Tests want pure value
// construction. Swift forbids an extension on a struct from adding a
// new initializer that assigns to stored properties directly (the
// extension init must delegate to an existing init via `self.init(...)`).
//
// `PlannedPrescriptionSnapshot` is a SwiftData `@Model` final class,
// but its compiler-generated init can be invoked WITHOUT a
// `ModelContext` — the resulting instance simply lives in memory until
// inserted (which we never do here). That lets the test-only init
// below stay SwiftData-free at the harness level: no model container,
// no in-memory store, no fetch.

extension PrescriptionSnapshotPayload {
    init(
        sets: Int? = nil,
        repMin: Int? = nil,
        repMax: Int? = nil,
        restSecondsBetweenSets: Int? = nil,
        restSecondsAfterExercise: Int? = nil,
        rir: Double? = nil,
        rpe: Double? = nil,
        tempo: String? = nil,
        durationMinSeconds: Int? = nil,
        durationMaxSeconds: Int? = nil,
        usesDuration: Bool = false,
        equipment: String? = nil,
        setupNotes: String? = nil
    ) {
        let source = PlannedPrescriptionSnapshot(
            sets: sets,
            repMin: repMin,
            repMax: repMax,
            restSecondsBetweenSets: restSecondsBetweenSets,
            restSecondsAfterExercise: restSecondsAfterExercise,
            rir: rir,
            rpe: rpe,
            tempo: tempo,
            durationMinSeconds: durationMinSeconds,
            durationMaxSeconds: durationMaxSeconds,
            usesDuration: usesDuration,
            equipment: equipment,
            setupNotes: setupNotes
        )
        self.init(from: source)
    }
}
