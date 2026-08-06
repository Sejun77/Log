import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 6 pre-merge patch — the two live-update bugs manual
/// smoke testing found after the Edit Plan patch.
///
/// Both had the same shape: Edit Plan wrote the `SessionPlan` correctly, but a
/// piece of visible state was derived from something *else* and only caught up
/// on the next resume.
///
///  1. The cardio row's distance draft was seeded at session start and never
///     re-seeded, so a target edit was invisible until a resume happened to
///     re-run seeding.
///  2. The Plan card and the per-set row labels both derived effort from the
///     immutable **snapshot**, so a freshly set intensity never appeared — and
///     for a slot switched out of cardio, whose adapted snapshot carries no
///     effort at all, it could never appear.
///
/// `ActiveWorkoutView` cannot be instantiated in a test, so what is asserted
/// here is the logic it now delegates to — `WorkoutEffortTargetResolver`
/// `.effectiveFields` directly, and the seeding precedence rule reproduced step
/// for step from `applyCardioTargetSeeding`.
@MainActor
final class ActiveEditPlanLiveUpdateTests: SwiftDataTestHarness {

    private typealias Resolver = WorkoutEffortTargetResolver
    private typealias Adapter = ExerciseSwitchPlanAdapter
    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles

    // MARK: - Seeding harness

    /// Reproduces `ActiveWorkoutView.applyCardioTargetSeeding` exactly.
    ///
    /// The discriminator is the real one: a seeded draft is never written to
    /// `ParentDraftStore`, a typed one always is (on every keystroke, including
    /// an empty string when the field is cleared). So a persisted cardio
    /// snapshot means "the user touched this".
    private func applySeeding(
        drafts: inout [Int: CardioEntryDraft],
        target: CardioTargetDistance?,
        setCount: Int,
        loggedSets: Set<Int> = [],
        store: ParentDraftStore?,
        slotID: UUID,
        replacingUnedited: Bool,
        fallbackUnit: DistanceUnit = .kilometers
    ) {
        guard target != nil || replacingUnedited else { return }
        for i in 0..<setCount {
            if loggedSets.contains(i) { continue }
            if drafts[i] == nil {
                guard let target else { continue }
                drafts[i] = CardioEntryDraft(
                    unit: target.unit, distance: target.valueText ?? "")
                continue
            }
            guard replacingUnedited else { continue }
            let userTyped =
                store?.load(slotID: slotID, setIndex: i)?.hasCardio ?? false
            if userTyped { continue }
            var draft = drafts[i] ?? CardioEntryDraft(unit: fallbackUnit)
            draft.unit = target?.unit ?? fallbackUnit
            draft.distance = target?.valueText ?? ""
            drafts[i] = draft
        }
    }

    private func makeStore(_ suite: String) throws -> ParentDraftStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return ParentDraftStore(workoutID: UUID(), defaults: defaults)
    }

    private func target(_ text: String, _ unit: DistanceUnit = .kilometers)
        -> CardioTargetDistance?
    { CardioTargetDistance(text: text, unit: unit) }

    private func cardioPlan(meters: Double? = 5_000, unitRaw: String? = "km")
        -> SessionPlan
    {
        var plan = SessionPlan()
        plan.sets = 1
        plan.usesDuration = true
        plan.durationMaxSeconds = 1_800
        plan.targetDistanceMeters = meters
        plan.targetDistanceUnitRaw = unitRaw
        return plan
    }

    // MARK: - 1. The edit reaches the plan

    func testEditingTargetDistanceUpdatesThePlanFields() throws {
        var plan = cardioPlan(meters: nil, unitRaw: nil)
        let edited = CardioTargetDistance(text: "8", unit: km)
        plan.targetDistanceMeters = edited?.meters
        plan.targetDistanceUnitRaw = edited?.unit.rawValue

        XCTAssertEqual(try XCTUnwrap(plan.targetDistanceMeters), 8_000, accuracy: 0.001)
        XCTAssertEqual(plan.targetDistanceUnitRaw, "km")
        XCTAssertTrue(plan.primarySummary(distanceUnit: .kilometers).contains("8 km"))
    }

    /// The Plan card's line 1 reads the live `SessionPlan`, so it was never the
    /// broken half — pinned so a future refactor cannot quietly make it stale.
    func testPlanSummaryReflectsTheEditImmediately() {
        var plan = cardioPlan()
        XCTAssertTrue(plan.primarySummary(distanceUnit: .kilometers).contains("5 km"))

        plan.targetDistanceMeters = 8_000
        XCTAssertTrue(plan.primarySummary(distanceUnit: .kilometers).contains("8 km"))

        plan.targetDistanceMeters = nil
        plan.targetDistanceUnitRaw = nil
        XCTAssertFalse(plan.primarySummary(distanceUnit: .kilometers).contains("km"))
    }

    // MARK: - 2. An untouched draft follows the target

    func testTargetEditReplacesAnUntouchedSeededDraft() throws {
        let store = try makeStore("LiveUpdate.untouched")
        let slotID = UUID()
        var drafts: [Int: CardioEntryDraft] = [:]

        // Session start seeds 5 km.
        applySeeding(
            drafts: &drafts, target: target("5"), setCount: 1, store: store,
            slotID: slotID, replacingUnedited: false)
        XCTAssertEqual(drafts[0]?.distance, "5")

        // Edit Plan changes it to 8 km.
        applySeeding(
            drafts: &drafts, target: target("8"), setCount: 1, store: store,
            slotID: slotID, replacingUnedited: true)
        XCTAssertEqual(drafts[0]?.distance, "8")
    }

    func testTargetEditUpdatesTheDraftUnitToo() throws {
        let store = try makeStore("LiveUpdate.unit")
        let slotID = UUID()
        var drafts: [Int: CardioEntryDraft] = [:]

        applySeeding(
            drafts: &drafts, target: target("5", km), setCount: 1, store: store,
            slotID: slotID, replacingUnedited: false)
        applySeeding(
            drafts: &drafts, target: target("3.1", mi), setCount: 1,
            store: store, slotID: slotID, replacingUnedited: true)

        XCTAssertEqual(drafts[0]?.distance, "3.1")
        XCTAssertEqual(drafts[0]?.unit, mi)
    }

    func testTargetEditSeedsEverySetOfTheSlot() throws {
        let store = try makeStore("LiveUpdate.allSets")
        let slotID = UUID()
        var drafts: [Int: CardioEntryDraft] = [:]

        applySeeding(
            drafts: &drafts, target: target("5"), setCount: 3, store: store,
            slotID: slotID, replacingUnedited: false)
        applySeeding(
            drafts: &drafts, target: target("8"), setCount: 3, store: store,
            slotID: slotID, replacingUnedited: true)

        for i in 0..<3 { XCTAssertEqual(drafts[i]?.distance, "8", "set \(i)") }
    }

    // MARK: - 3 & 5. A typed draft always wins

    func testTargetEditDoesNotOverwriteAUserEditedDraft() throws {
        let store = try makeStore("LiveUpdate.typed")
        let slotID = UUID()
        var drafts: [Int: CardioEntryDraft] = [:]

        applySeeding(
            drafts: &drafts, target: target("5"), setCount: 1, store: store,
            slotID: slotID, replacingUnedited: false)

        // The user types over the seed — which persists it.
        let typed = CardioEntryDraft(unit: km, distance: "4.2")
        drafts[0] = typed
        store.persist(slotID: slotID, setIndex: 0, cardio: typed)

        applySeeding(
            drafts: &drafts, target: target("8"), setCount: 1, store: store,
            slotID: slotID, replacingUnedited: true)

        XCTAssertEqual(
            drafts[0]?.distance, "4.2",
            "a target edit must never overwrite a number the user entered")
    }

    /// The harder half: a user who *cleared* the field has still touched it, so
    /// a target edit must not refill it.
    func testTargetEditDoesNotRefillADeliberatelyClearedDraft() throws {
        let store = try makeStore("LiveUpdate.cleared")
        let slotID = UUID()
        var drafts: [Int: CardioEntryDraft] = [:]

        let cleared = CardioEntryDraft(unit: km, distance: "")
        drafts[0] = cleared
        store.persist(slotID: slotID, setIndex: 0, cardio: cleared)

        applySeeding(
            drafts: &drafts, target: target("8"), setCount: 1, store: store,
            slotID: slotID, replacingUnedited: true)

        XCTAssertEqual(drafts[0]?.distance, "")
    }

    func testClearingTheTargetDoesNotEraseAUserEditedDraft() throws {
        let store = try makeStore("LiveUpdate.clearVsTyped")
        let slotID = UUID()
        var drafts: [Int: CardioEntryDraft] = [:]

        let typed = CardioEntryDraft(unit: km, distance: "4.2")
        drafts[0] = typed
        store.persist(slotID: slotID, setIndex: 0, cardio: typed)

        applySeeding(
            drafts: &drafts, target: nil, setCount: 1, store: store,
            slotID: slotID, replacingUnedited: true)

        XCTAssertEqual(drafts[0]?.distance, "4.2")
    }

    /// Only the target-derived fields move; anything else the user entered on
    /// the same row stays put.
    func testTargetEditLeavesOtherCardioFieldsAlone() throws {
        let store = try makeStore("LiveUpdate.otherFields")
        let slotID = UUID()
        var drafts: [Int: CardioEntryDraft] = [
            0: CardioEntryDraft(
                unit: km, distance: "5", avgHeartRate: "142", calories: "410",
                incline: "3", resistance: "8", hrZone: .z3)
        ]

        applySeeding(
            drafts: &drafts, target: target("8"), setCount: 1, store: store,
            slotID: slotID, replacingUnedited: true)

        let draft = try XCTUnwrap(drafts[0])
        XCTAssertEqual(draft.distance, "8")
        XCTAssertEqual(draft.avgHeartRate, "142")
        XCTAssertEqual(draft.calories, "410")
        XCTAssertEqual(draft.incline, "3")
        XCTAssertEqual(draft.resistance, "8")
        XCTAssertEqual(draft.hrZone, .z3)
    }

    // MARK: - 4. Clearing the target empties an untouched draft

    func testClearingTheTargetClearsAnUntouchedSeededDraft() throws {
        let store = try makeStore("LiveUpdate.clearSeeded")
        let slotID = UUID()
        var drafts: [Int: CardioEntryDraft] = [:]

        applySeeding(
            drafts: &drafts, target: target("5"), setCount: 1, store: store,
            slotID: slotID, replacingUnedited: false)
        applySeeding(
            drafts: &drafts, target: nil, setCount: 1, store: store,
            slotID: slotID, replacingUnedited: true)

        XCTAssertEqual(
            drafts[0]?.distance, "",
            "removing the target must visibly empty the row")
    }

    /// A logged set's fields are read-only until Undo, and its draft mirrors
    /// what was recorded — a target edit must not rewrite history.
    func testTargetEditNeverTouchesALoggedSet() throws {
        let store = try makeStore("LiveUpdate.logged")
        let slotID = UUID()
        var drafts: [Int: CardioEntryDraft] = [
            0: CardioEntryDraft(unit: km, distance: "4.9")
        ]

        applySeeding(
            drafts: &drafts, target: target("8"), setCount: 1,
            loggedSets: [0], store: store, slotID: slotID,
            replacingUnedited: true)

        XCTAssertEqual(drafts[0]?.distance, "4.9")
    }

    // MARK: - 6. Live and resume agree

    /// After a target edit, a resume must reproduce the live state exactly:
    /// the untouched row re-seeds to the new target, the typed row restores
    /// from the store.
    func testResumeReproducesTheLiveStateAfterATargetEdit() throws {
        let store = try makeStore("LiveUpdate.resume")
        let slotID = UUID()

        // Live: set 0 typed, set 1 left seeded; the target is then edited.
        var live: [Int: CardioEntryDraft] = [:]
        applySeeding(
            drafts: &live, target: target("5"), setCount: 2, store: store,
            slotID: slotID, replacingUnedited: false)
        let typed = CardioEntryDraft(unit: km, distance: "4.2")
        live[0] = typed
        store.persist(slotID: slotID, setIndex: 0, cardio: typed)
        applySeeding(
            drafts: &live, target: target("8"), setCount: 2, store: store,
            slotID: slotID, replacingUnedited: true)

        // Resume: restore persisted drafts, then seed the absent ones.
        var resumed: [Int: CardioEntryDraft] = [:]
        for i in 0..<2 {
            if let snapshot = store.load(slotID: slotID, setIndex: i),
                let restored = CardioEntryDraft(
                    snapshot: snapshot, displayUnit: km)
            {
                resumed[i] = restored
            }
        }
        applySeeding(
            drafts: &resumed, target: target("8"), setCount: 2, store: store,
            slotID: slotID, replacingUnedited: false)

        XCTAssertEqual(live[0]?.distance, "4.2")
        XCTAssertEqual(live[1]?.distance, "8")
        XCTAssertEqual(resumed[0]?.distance, live[0]?.distance)
        XCTAssertEqual(resumed[1]?.distance, live[1]?.distance)
    }

    // MARK: - 7–9. Intensity display refresh

    private func labels(
        snapshot: PrescriptionSnapshotPayload?, plan: SessionPlan,
        setCount: Int = 3, autoreg: AutoregMode = .rir
    ) -> [String?] {
        Resolver.perRowLabels(
            setKinds: Array(repeating: .working, count: setCount),
            fields: Resolver.effectiveFields(
                snapshot: snapshot.map { Resolver.Fields(payload: $0) },
                sessionRIR: plan.rir, sessionRPE: plan.rpe),
            autoregMode: autoreg)
    }

    private func summary(
        snapshot: PrescriptionSnapshotPayload?, plan: SessionPlan,
        autoreg: AutoregMode = .rir
    ) -> String? {
        Resolver.summary(
            fields: Resolver.effectiveFields(
                snapshot: snapshot.map { Resolver.Fields(payload: $0) },
                sessionRIR: plan.rir, sessionRPE: plan.rpe),
            autoregMode: autoreg)
    }

    private func strengthPlan(rir: Double?) -> SessionPlan {
        var plan = SessionPlan()
        plan.sets = 3
        plan.repMin = 8
        plan.repMax = 12
        plan.rir = rir
        plan.rpe = rir.map { 10 - $0 }
        return plan
    }

    func testSettingIntensityUpdatesThePlanSummaryImmediately() {
        XCTAssertNil(summary(snapshot: .empty, plan: strengthPlan(rir: nil)))
        XCTAssertEqual(
            summary(snapshot: .empty, plan: strengthPlan(rir: 2)), "RIR 2")
    }

    func testSettingIntensityUpdatesTheSetCardLabelsImmediately() {
        XCTAssertEqual(
            labels(snapshot: .empty, plan: strengthPlan(rir: nil)),
            [nil, nil, nil])
        XCTAssertEqual(
            labels(snapshot: .empty, plan: strengthPlan(rir: 2)),
            ["RIR 2", "RIR 2", "RIR 2"])
    }

    /// The card and the rows are the same question with one answer now — they
    /// used to disagree for a `.single` snapshot, where the card summarized the
    /// session override and the rows resolved from the snapshot.
    func testPlanCardAndSetCardsAgreeAfterAnEdit() {
        var snapshot = PrescriptionSnapshotPayload.empty
        snapshot.rir = 3

        let edited = strengthPlan(rir: 1)
        XCTAssertEqual(summary(snapshot: snapshot, plan: edited), "RIR 1")
        XCTAssertEqual(
            labels(snapshot: snapshot, plan: edited),
            ["RIR 1", "RIR 1", "RIR 1"],
            "the rows must show the edited value, not the snapshot's")
    }

    func testClearingIntensityRemovesItFromBothSites() {
        var snapshot = PrescriptionSnapshotPayload.empty
        snapshot.rir = 3
        let cleared = strengthPlan(rir: nil)

        XCTAssertNil(summary(snapshot: snapshot, plan: cleared))
        XCTAssertEqual(labels(snapshot: snapshot, plan: cleared), [nil, nil, nil])
    }

    func testIntensityRefreshWorksInRPEMode() {
        var plan = SessionPlan()
        plan.rpe = 8
        plan.rir = 2
        XCTAssertEqual(
            summary(snapshot: .empty, plan: plan, autoreg: .rpe), "RPE 8")
        XCTAssertEqual(
            labels(snapshot: .empty, plan: plan, autoreg: .rpe),
            ["RPE 8", "RPE 8", "RPE 8"])
    }

    /// In-session progression editing is still deferred, so a progression
    /// snapshot keeps its ramp and is not downgraded to a flat single value.
    func testProgressionSnapshotIsNotOverlaid() {
        var snapshot = PrescriptionSnapshotPayload.empty
        snapshot.effortModeRaw = "progression"
        snapshot.rirStart = 3
        snapshot.rirEnd = 1

        let fields = Resolver.effectiveFields(
            snapshot: Resolver.Fields(payload: snapshot),
            sessionRIR: 0, sessionRPE: 10)

        XCTAssertEqual(Resolver.effortMode(for: fields), .progression)
        XCTAssertEqual(fields.rirStart, 3)
        XCTAssertEqual(fields.rirEnd, 1)
    }

    func testEffectiveFieldsClearsStaleProgressionWhenOverlaid() {
        var snapshot = PrescriptionSnapshotPayload.empty
        snapshot.rir = 3
        snapshot.rirStart = 3
        snapshot.rirEnd = 0

        let fields = Resolver.effectiveFields(
            snapshot: Resolver.Fields(payload: snapshot),
            sessionRIR: 1, sessionRPE: 9)

        XCTAssertEqual(Resolver.effortMode(for: fields), .single)
        XCTAssertNil(fields.rirStart)
        XCTAssertNil(fields.rirEnd)
    }

    func testEffectiveFieldsWithNoSnapshotAndNoSessionValueIsNone() {
        let fields = Resolver.effectiveFields(
            snapshot: nil, sessionRIR: nil, sessionRPE: nil)
        XCTAssertEqual(Resolver.effortMode(for: fields), .none)
    }

    // MARK: - 10 & 11. After switching out of cardio

    /// The exact reported case: the adapted snapshot carries no effort at all,
    /// so before the fix the derived mode was `.none` and nothing the user set
    /// could ever appear.
    func testIntensitySetAfterCardioToStrengthShowsImmediately() {
        var cardio = SessionPlan()
        cardio.sets = 1
        cardio.usesDuration = true
        let switched = Adapter.outcome(
            choice: .keepCurrentPlan, current: cardio, oldMode: .cardio,
            newMode: .strength, resetSource: .appDefaults(for: .strength))
        let snapshot = Adapter.adaptedSnapshot(
            from: switched, base: .empty, equipment: nil, setupNotes: nil)

        XCTAssertEqual(
            Resolver.effortMode(for: .init(payload: snapshot)), .none,
            "precondition: the switched slot has no snapshot effort")

        var plan = switched.sessionPlan
        plan.rir = 2
        plan.rpe = 8

        XCTAssertEqual(summary(snapshot: snapshot, plan: plan), "RIR 2")
        XCTAssertEqual(
            labels(snapshot: snapshot, plan: plan, setCount: 2),
            ["RIR 2", "RIR 2"])
    }

    func testIntensitySetAfterCardioToTimedHoldShowsImmediately() {
        var cardio = SessionPlan()
        cardio.sets = 1
        cardio.usesDuration = true
        let switched = Adapter.outcome(
            choice: .keepCurrentPlan, current: cardio, oldMode: .cardio,
            newMode: .timedHold, resetSource: .appDefaults(for: .timedHold))
        let snapshot = Adapter.adaptedSnapshot(
            from: switched, base: .empty, equipment: nil, setupNotes: nil)

        var plan = switched.sessionPlan
        plan.rir = 1
        plan.rpe = 9

        XCTAssertEqual(summary(snapshot: snapshot, plan: plan), "RIR 1")
        XCTAssertEqual(
            labels(snapshot: snapshot, plan: plan, setCount: 1), ["RIR 1"])
    }

    // MARK: - 12 & 13. Cardio still hides and clears intensity

    func testSwitchingIntoCardioStillClearsIntensity() {
        for oldMode in [TrackingMode.strength, .timedHold] {
            let switched = Adapter.outcome(
                choice: .keepCurrentPlan, current: strengthPlan(rir: 2),
                oldMode: oldMode, newMode: .cardio,
                resetSource: .appDefaults(for: .cardio))
            XCTAssertNil(switched.sessionPlan.rir, "\(oldMode)")
            XCTAssertNil(switched.sessionPlan.rpe, "\(oldMode)")

            let snapshot = Adapter.adaptedSnapshot(
                from: switched, base: .empty, equipment: nil, setupNotes: nil)
            XCTAssertEqual(
                Resolver.effortMode(for: .init(payload: snapshot)), .none,
                "\(oldMode)")
        }
    }

    /// The display gate is unchanged and still comes first: even if a cardio
    /// slot somehow held an effort value, neither site may render it.
    func testCardioNeverRendersIntensityEvenWithAValuePresent() {
        XCTAssertFalse(Resolver.isEffortApplicable(to: .cardio))

        // `effectiveFields` is deliberately mode-agnostic — the cardio gate
        // lives at the call site (`showsEffortUI`), which returns before this
        // is ever consulted. Assert the gate, not the resolver.
        var plan = SessionPlan()
        plan.rir = 2
        for mode in [TrackingMode.strength, .timedHold] {
            XCTAssertTrue(Resolver.isEffortApplicable(to: mode), "\(mode)")
        }
        XCTAssertNotNil(
            summary(snapshot: .empty, plan: plan),
            "the resolver itself still resolves — cardio is filtered above it")
    }
}
