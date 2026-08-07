import SwiftData
import XCTest

@testable import Log

/// Structured Cardio Slice 12D — carrying a segment plan from the routine slot
/// into the active workout, and back out again across an exercise switch.
///
/// The plan travels four hops, and this file pins each one:
///
///     SlotPrescription  →  PrescriptionSnapshotPayload  →  SessionPlan
///                                     ↓
///                       PlannedPrescriptionSnapshot (frozen for History)
///
/// Two invariants run through all of it:
///
///  1. **The payload is carried, never re-encoded.** A plan this build would
///     normalize — or cannot parse at all — rides through the session
///     byte-for-byte, exactly as `RoutineDuplicator` copies it. Decoding is the
///     read site's job, and every read site is tolerant.
///  2. **A structured plan changes nothing else.** Set count, duration target,
///     and distance target resolve identically with and without segments,
///     because the bout is still one aggregate cardio `SetLog`.
@MainActor
final class StructuredCardioSessionPlanTests: SwiftDataTestHarness {

    private typealias Adapter = ExerciseSwitchPlanAdapter

    // MARK: - Fixtures

    private func segment(
        _ kind: CardioSegmentKind, duration: Int? = nil,
        distance: Double? = nil
    ) throws -> CardioSegment {
        try CardioSegment(
            kind: kind, durationSeconds: duration, distanceMeters: distance)
    }

    /// 5 min warm-up → 20 min work → 5 min cool-down.
    private func flatPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                segment(.warmUp, duration: 300),
                segment(.work, duration: 1_200),
                segment(.coolDown, duration: 300),
            ])
        ])
    }

    /// 5 × (1 min work / 2 min recovery).
    private func repeatedPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(
                segments: [
                    segment(.work, duration: 60),
                    segment(.recovery, duration: 120),
                ],
                repeatCount: 5)
        ])
    }

    private func encoded(_ plan: CardioSegmentPlan) throws -> Data {
        try JSONEncoder().encode(plan)
    }

    /// A cardio slot: one set, 30 minutes, 5 km, plus an optional plan.
    private func cardioPrescription(
        plan: CardioSegmentPlan? = nil
    ) -> SlotPrescription {
        let p = SlotPrescription()
        p.sets = 1
        p.usesDuration = true
        p.durationMaxSeconds = 1_800
        p.targetDistanceMeters = 5_000
        p.targetDistanceUnitRaw = DistanceUnit.kilometers.rawValue
        p.setStructuredCardioPlan(plan)
        context.insert(p)
        return p
    }

    private func strengthPrescription() -> SlotPrescription {
        let p = SlotPrescription()
        p.sets = 3
        p.repMin = 8
        p.repMax = 12
        context.insert(p)
        return p
    }

    private func timedHoldPrescription() -> SlotPrescription {
        let p = SlotPrescription()
        p.sets = 3
        p.usesDuration = true
        p.durationMaxSeconds = 45
        context.insert(p)
        return p
    }

    private func sessionPlan(
        from prescription: SlotPrescription
    ) -> SessionPlan {
        SessionPlan(
            from: PrescriptionSnapshotPayload(
                from: prescription, exercise: nil),
            notes: nil)
    }

    // ==================================================
    // MARK: - 1. SlotPrescription → SessionPlan
    // ==================================================

    func testCardioSlotWithSegmentsResolvesIntoTheSessionPlan() throws {
        // Built once and held: every fixture call mints fresh segment ids, so
        // the comparison has to be against *this* plan, not another like it.
        let authored = try flatPlan()
        let rx = cardioPrescription(plan: authored)
        let plan = sessionPlan(from: rx)

        XCTAssertEqual(
            plan.cardioSegmentsData, rx.cardioSegmentsData,
            "the session carries the slot's payload, byte-for-byte")
        XCTAssertEqual(
            plan.structuredCardioPlan, authored.normalizedForComparison,
            "including the segment ids the checklist ticks are keyed by")
        XCTAssertEqual(plan.structuredCardioPlan?.expandedCount, 3)
    }

    /// The payload is copied raw rather than decoded and re-encoded, so a
    /// column this build would normalize on the way out survives the session
    /// unchanged — the same rule `RoutineDuplicator.copyPrescription` follows.
    func testTheSessionCarriesThePayloadWithoutReEncodingIt() throws {
        let rx = cardioPrescription()
        // A payload with an out-of-range repeat count and an unknown kind: both
        // are repaired by the *decoder*, so a re-encode would rewrite the
        // column. Carrying it raw must not.
        let raw = Data(
            #"{"version":1,"groups":[{"id":"\#(UUID().uuidString)","repeatCount":99,"segments":[{"id":"\#(UUID().uuidString)","kind":"sprint","durationSeconds":60}]}]}"#
                .utf8)
        rx.cardioSegmentsData = raw

        let plan = sessionPlan(from: rx)
        XCTAssertEqual(plan.cardioSegmentsData, raw)
        // …and the read site repairs it, exactly as the routine editor's does.
        let decoded = try XCTUnwrap(plan.structuredCardioPlan)
        XCTAssertEqual(decoded.groups.first?.repeatCount, 20)
        XCTAssertEqual(decoded.groups.first?.segments.first?.kind, .work)
    }

    func testCardioSlotWithoutSegmentsCarriesNoPlan() {
        let plan = sessionPlan(from: cardioPrescription())

        XCTAssertNil(plan.cardioSegmentsData)
        XCTAssertNil(plan.structuredCardioPlan)
    }

    func testStrengthSlotCarriesNoStructuredPlan() {
        let plan = sessionPlan(from: strengthPrescription())

        XCTAssertNil(plan.cardioSegmentsData)
        XCTAssertNil(plan.structuredCardioPlan)
        XCTAssertFalse(
            CardioRoutineRules.showsCardioSegments(.strength),
            "the authoring gate is unchanged: strength slots never see segments")
    }

    func testTimedHoldSlotCarriesNoStructuredPlan() {
        let plan = sessionPlan(from: timedHoldPrescription())

        XCTAssertNil(plan.cardioSegmentsData)
        XCTAssertNil(plan.structuredCardioPlan)
        XCTAssertFalse(CardioRoutineRules.showsCardioSegments(.timedHold))
    }

    /// A `SessionPlan` written by a build that predates this field decodes with
    /// nil rather than failing — synthesized `Codable` reads an `Optional` with
    /// `decodeIfPresent`, which is what makes `AppState.sessionPlansJSON`
    /// forward-compatible.
    func testASessionPlanJSONWithoutTheFieldStillDecodes() throws {
        let legacy = Data(
            #"{"usesDuration":true,"sets":1,"durationMaxSeconds":1800}"#.utf8)
        let plan = try JSONDecoder().decode(SessionPlan.self, from: legacy)

        XCTAssertNil(plan.cardioSegmentsData)
        XCTAssertNil(plan.structuredCardioPlan)
        XCTAssertEqual(plan.sets, 1)
    }

    /// Save & Exit / cold resume round-trip: the plan survives the JSON hop
    /// through `AppState.sessionPlansJSON`.
    func testSessionPlanRoundTripsThroughJSON() throws {
        let original = sessionPlan(from: cardioPrescription(plan: try flatPlan()))
        let restored = try JSONDecoder().decode(
            SessionPlan.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.structuredCardioPlan?.expandedCount, 3)
    }

    // ==================================================
    // MARK: - 2. PlannedPrescriptionSnapshot (frozen copy)
    // ==================================================

    func testSnapshotModelPreservesTheSegmentPayload() throws {
        let rx = cardioPrescription(plan: try flatPlan())
        let payload = PrescriptionSnapshotPayload(from: rx, exercise: nil)

        let frozen = payload.toModel()
        context.insert(frozen)
        try context.save()

        XCTAssertEqual(frozen.cardioSegmentsData, rx.cardioSegmentsData)
        // …and back out again, which is the resume path.
        let reread = PrescriptionSnapshotPayload(from: frozen)
        XCTAssertEqual(reread.cardioSegmentsData, rx.cardioSegmentsData)
        XCTAssertEqual(reread.structuredCardioPlan?.expandedCount, 3)
    }

    func testSnapshotModelBuiltDirectlyFromAPrescriptionPreservesThePayload()
        throws
    {
        let rx = cardioPrescription(plan: try flatPlan())
        let frozen = PlannedPrescriptionSnapshot(from: rx, exercise: nil)

        XCTAssertEqual(frozen.cardioSegmentsData, rx.cardioSegmentsData)
    }

    /// The snapshot is a *copy*: editing the routine mid-session cannot reach
    /// the plan the session is showing. `Data` is a value type, which is what
    /// makes this structural rather than a matter of ordering.
    func testEditingTheRoutineAfterSnapshotDoesNotChangeTheFrozenPlan() throws {
        let rx = cardioPrescription(plan: try flatPlan())
        let frozen = PlannedPrescriptionSnapshot(from: rx, exercise: nil)
        let session = sessionPlan(from: rx)

        rx.setStructuredCardioPlan(try repeatedPlan())

        XCTAssertEqual(frozen.cardioSegmentsData, session.cardioSegmentsData)
        XCTAssertEqual(frozen.structuredCardioPlan?.expandedCount, 3)
        XCTAssertEqual(session.structuredCardioPlan?.expandedCount, 3)
        XCTAssertEqual(
            rx.structuredCardioPlan?.expandedCount, 10,
            "the routine did change — the session simply is not looking at it")
    }

    // ==================================================
    // MARK: - 3. Corrupt / empty payloads
    // ==================================================

    func testCorruptPayloadResolvesAsNoPlanEverywhere() {
        let rx = cardioPrescription()
        rx.cardioSegmentsData = Data("not json at all".utf8)

        let payload = PrescriptionSnapshotPayload(from: rx, exercise: nil)
        let plan = SessionPlan(from: payload, notes: nil)

        XCTAssertNil(rx.structuredCardioPlan)
        XCTAssertNil(payload.structuredCardioPlan)
        XCTAssertNil(plan.structuredCardioPlan)
        XCTAssertNil(
            SessionPlanResolver.plannedCardioSegments(
                sessionPlan: plan, snapshot: payload))
    }

    func testAPayloadWhoseSegmentsAllNormalizeAwayResolvesAsNoPlan() {
        let rx = cardioPrescription()
        // A group whose only segment carries no target at all: the decoder
        // drops the segment, then the group, leaving an empty plan.
        rx.cardioSegmentsData = Data(
            #"{"version":1,"groups":[{"id":"\#(UUID().uuidString)","repeatCount":1,"segments":[{"id":"\#(UUID().uuidString)","kind":"work"}]}]}"#
                .utf8)

        let payload = PrescriptionSnapshotPayload(from: rx, exercise: nil)
        XCTAssertNil(payload.structuredCardioPlan)
        XCTAssertNil(SessionPlan(from: payload, notes: nil).structuredCardioPlan)
    }

    func testAnEmptyPlanIsStoredAsNoPayload() {
        let rx = cardioPrescription()
        rx.setStructuredCardioPlan(.empty)

        XCTAssertNil(rx.cardioSegmentsData)
        XCTAssertNil(sessionPlan(from: rx).cardioSegmentsData)
    }

    // ==================================================
    // MARK: - 4. SessionPlanResolver
    // ==================================================

    func testResolverPrefersTheSessionPlanOverTheSnapshot() throws {
        var session = SessionPlan()
        session.cardioSegmentsData = try encoded(repeatedPlan())
        var snapshot = PrescriptionSnapshotPayload.empty
        snapshot.cardioSegmentsData = try encoded(flatPlan())

        let resolved = SessionPlanResolver.plannedCardioSegments(
            sessionPlan: session, snapshot: snapshot)

        XCTAssertEqual(resolved?.expandedCount, 10, "tier 1 wins")
    }

    func testResolverFallsBackToTheFrozenSnapshot() throws {
        var snapshot = PrescriptionSnapshotPayload.empty
        snapshot.cardioSegmentsData = try encoded(flatPlan())

        let resolved = SessionPlanResolver.plannedCardioSegments(
            sessionPlan: SessionPlan(), snapshot: snapshot)

        XCTAssertEqual(resolved?.expandedCount, 3)
    }

    /// A corrupt tier-1 payload falls through to the frozen snapshot rather
    /// than resolving to "no plan" — the snapshot is the better answer, and
    /// neither tier may throw.
    func testACorruptSessionPayloadFallsThroughToTheSnapshot() throws {
        var session = SessionPlan()
        session.cardioSegmentsData = Data("{".utf8)
        var snapshot = PrescriptionSnapshotPayload.empty
        snapshot.cardioSegmentsData = try encoded(flatPlan())

        XCTAssertEqual(
            SessionPlanResolver.plannedCardioSegments(
                sessionPlan: session, snapshot: snapshot)?.expandedCount, 3)
    }

    func testResolverReturnsNilWhenNeitherTierHasAPlan() {
        XCTAssertNil(
            SessionPlanResolver.plannedCardioSegments(
                sessionPlan: SessionPlan(), snapshot: .empty))
        XCTAssertNil(
            SessionPlanResolver.plannedCardioSegments(
                sessionPlan: nil, snapshot: nil))
    }

    // ==================================================
    // MARK: - 5. The plan changes nothing else
    // ==================================================

    /// The headline regression: every other resolved target is identical with
    /// and without segments. If this ever fails, the aggregate `SetLog` a
    /// structured bout writes has stopped matching an unstructured one.
    func testAStructuredPlanDoesNotChangeAnyOtherResolvedTarget() throws {
        let plain = sessionPlan(from: cardioPrescription())
        let structured = sessionPlan(
            from: cardioPrescription(plan: try flatPlan()))
        let template = PlanSetTemplate(
            id: "t", kind: .working, targetReps: 0, targetWeight: nil,
            restSecondsAfter: nil, durationSeconds: 600)

        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: plain, snapshot: nil, resolvedTemplates: []),
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: structured, snapshot: nil, resolvedTemplates: []))
        XCTAssertEqual(
            SessionPlanResolver.plannedDurationTarget(
                sessionPlan: plain, snapshot: nil, template: template),
            SessionPlanResolver.plannedDurationTarget(
                sessionPlan: structured, snapshot: nil, template: template))
        XCTAssertEqual(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: plain, snapshot: nil,
                displayUnit: .kilometers)?.meters,
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: structured, snapshot: nil,
                displayUnit: .kilometers)?.meters)
        XCTAssertEqual(
            plain.primarySummary(distanceUnit: .kilometers),
            structured.primarySummary(distanceUnit: .kilometers),
            "the Plan card summary is unchanged by a structured plan")
    }

    /// One set, always. A 5 × (work/recovery) session is one bout with shape,
    /// not five sets — the rule that keeps every Phase 1 cardio feature working.
    func testARepeatedPlanStillResolvesToOneSet() throws {
        let structured = sessionPlan(
            from: cardioPrescription(plan: try repeatedPlan()))

        XCTAssertEqual(structured.structuredCardioPlan?.expandedCount, 10)
        XCTAssertEqual(
            SessionPlanResolver.effectiveSetCount(
                sessionPlan: structured, snapshot: nil, resolvedTemplates: []),
            1)
    }

    // ==================================================
    // MARK: - 6. Expansion (what the checklist renders)
    // ==================================================

    func testExpandedSegmentsRenderInPlannedOrder() throws {
        let plan = try XCTUnwrap(
            sessionPlan(from: cardioPrescription(plan: try flatPlan()))
                .structuredCardioPlan)

        XCTAssertEqual(
            plan.expandedSegments().map(\.segment.kind),
            [.warmUp, .work, .coolDown])
        XCTAssertEqual(plan.expandedSegments().map(\.index), [0, 1, 2])
    }

    /// Each round is its own row with its own id, so ticking round 1 cannot
    /// tick round 2 — the reason `ResolvedCardioSegment.id` carries the round.
    func testRepeatedSegmentsGetIndependentResolvedIDs() throws {
        let plan = try XCTUnwrap(
            sessionPlan(from: cardioPrescription(plan: try repeatedPlan()))
                .structuredCardioPlan)
        let expanded = plan.expandedSegments()

        XCTAssertEqual(expanded.count, 10)
        XCTAssertEqual(Set(expanded.map(\.id)).count, 10)
        XCTAssertEqual(
            expanded.map(\.round), [1, 1, 2, 2, 3, 3, 4, 4, 5, 5])
        XCTAssertTrue(expanded.allSatisfy { $0.roundCount == 5 })
        XCTAssertTrue(expanded.allSatisfy(\.isRepeated))
        // The two rounds of the SAME authored segment differ only by round.
        XCTAssertNotEqual(expanded[0].id, expanded[2].id)
        XCTAssertEqual(expanded[0].segment.id, expanded[2].segment.id)
    }

    /// The checklist can never be handed an unbounded list: both construction
    /// and decoding cap the expansion, so a hand-written oversized payload is
    /// truncated on the way in.
    func testAnOversizedPayloadStaysWithinTheExpansionBound() throws {
        let rx = cardioPrescription()
        let segments = (0..<3).map { _ in
            #"{"id":"\#(UUID().uuidString)","kind":"work","durationSeconds":60}"#
        }.joined(separator: ",")
        let groups = (0..<5).map { _ in
            #"{"id":"\#(UUID().uuidString)","repeatCount":20,"segments":[\#(segments)]}"#
        }.joined(separator: ",")
        rx.cardioSegmentsData = Data(
            #"{"version":1,"groups":[\#(groups)]}"#.utf8)

        let plan = try XCTUnwrap(sessionPlan(from: rx).structuredCardioPlan)
        XCTAssertLessThanOrEqual(
            plan.expandedSegments().count,
            CardioPlanLimits.maxExpandedSegments)
    }

    // ==================================================
    // MARK: - 7. Exercise switch
    // ==================================================

    private func switchOutcome(
        _ choice: Adapter.Choice,
        from oldMode: TrackingMode,
        to newMode: TrackingMode,
        current: SessionPlan?,
        resetSource: Adapter.ResetSource? = nil
    ) -> Adapter.Outcome {
        Adapter.outcome(
            choice: choice, current: current, oldMode: oldMode,
            newMode: newMode,
            resetSource: resetSource ?? .appDefaults(for: newMode))
    }

    private func structuredCardioSessionPlan() throws -> SessionPlan {
        sessionPlan(from: cardioPrescription(plan: try flatPlan()))
    }

    func testCardioToCardioKeepPreservesTheStructuredPlan() throws {
        let current = try structuredCardioSessionPlan()
        let outcome = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .cardio, current: current)

        XCTAssertEqual(
            outcome.sessionPlan.cardioSegmentsData, current.cardioSegmentsData)
        XCTAssertTrue(
            outcome.keepCardioDrafts,
            "the flag that also gates the checklist ticks")
    }

    /// Keep preserves the ticks because it preserves the *plan*: every
    /// resolved id still exists, so the caller's reconciliation keeps them all.
    func testCardioToCardioKeepPreservesEveryTickedSegmentID() throws {
        let current = try structuredCardioSessionPlan()
        let ticked = Set(
            try XCTUnwrap(current.structuredCardioPlan)
                .expandedSegments().prefix(2).map(\.id))

        let after = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .cardio, current: current
        ).sessionPlan
        let live = Set(
            try XCTUnwrap(after.structuredCardioPlan)
                .expandedSegments().map(\.id))

        XCTAssertEqual(ticked.intersection(live), ticked)
    }

    func testCardioToCardioResetDropsThePlanWhenTheSourceHasNone() throws {
        let after = switchOutcome(
            .resetPlan, from: .cardio, to: .cardio,
            current: try structuredCardioSessionPlan()
        ).sessionPlan

        XCTAssertNil(
            after.cardioSegmentsData,
            "app defaults carry no plan — Reset must not inherit the old one")
        XCTAssertFalse(
            switchOutcome(
                .resetPlan, from: .cardio, to: .cardio,
                current: try structuredCardioSessionPlan()
            ).keepCardioDrafts)
    }

    /// Reset uses the replacement plan, and the previous ticks no longer name
    /// anything in it — which is how "clears mismatched checked states" falls
    /// out of the id scheme rather than needing its own rule.
    func testCardioToCardioResetUsesTheSourcePlanAndOrphansOldTicks() throws {
        let current = try structuredCardioSessionPlan()
        let oldTicks = Set(
            try XCTUnwrap(current.structuredCardioPlan)
                .expandedSegments().map(\.id))

        var source = Adapter.ResetSource.appDefaults(for: .cardio)
        source.cardioSegmentsData = try encoded(repeatedPlan())

        let after = switchOutcome(
            .resetPlan, from: .cardio, to: .cardio, current: current,
            resetSource: source
        ).sessionPlan
        let live = Set(
            try XCTUnwrap(after.structuredCardioPlan)
                .expandedSegments().map(\.id))

        XCTAssertEqual(after.structuredCardioPlan?.expandedCount, 10)
        XCTAssertTrue(
            oldTicks.intersection(live).isEmpty,
            "none of the old ids survive into the replacement plan")
    }

    func testCardioToStrengthDropsTheStructuredPlan() throws {
        for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
            let outcome = switchOutcome(
                choice, from: .cardio, to: .strength,
                current: try structuredCardioSessionPlan())

            XCTAssertNil(
                outcome.sessionPlan.cardioSegmentsData,
                "a strength slot has nowhere to put a cardio plan (\(choice))")
            XCTAssertFalse(outcome.keepCardioDrafts)
        }
    }

    func testCardioToTimedHoldDropsTheStructuredPlan() throws {
        let outcome = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .timedHold,
            current: try structuredCardioSessionPlan())

        XCTAssertNil(outcome.sessionPlan.cardioSegmentsData)
        XCTAssertFalse(outcome.keepCardioDrafts)
    }

    func testStrengthToCardioSeedsNoPlanFromAppDefaults() {
        var strength = SessionPlan()
        strength.sets = 3
        strength.repMax = 10

        let after = switchOutcome(
            .keepCurrentPlan, from: .strength, to: .cardio, current: strength
        ).sessionPlan

        XCTAssertNil(
            after.cardioSegmentsData,
            "the slot starts unstructured; the checklist stays hidden")
    }

    func testStrengthToCardioResetTakesTheSourcePlanWhenThereIsOne() throws {
        var source = Adapter.ResetSource.appDefaults(for: .cardio)
        source.cardioSegmentsData = try encoded(flatPlan())

        let after = switchOutcome(
            .resetPlan, from: .strength, to: .cardio, current: SessionPlan(),
            resetSource: source
        ).sessionPlan

        XCTAssertEqual(after.structuredCardioPlan?.expandedCount, 3)
    }

    // MARK: - 7a. Reset, resolved the way the checklist sees it

    /// What the view's visibility gate actually reads after a switch: the
    /// adapted session plan **and** the adapted snapshot, through
    /// `plannedCardioSegments`. Asserting on `outcome.sessionPlan` alone would
    /// miss a stale tier-2 payload resurrecting a plan the switch dropped.
    private func resolvedPlanAfterSwitch(
        _ choice: Adapter.Choice,
        from oldMode: TrackingMode,
        to newMode: TrackingMode,
        current: SessionPlan?,
        resetSource: Adapter.ResetSource? = nil
    ) -> CardioSegmentPlan? {
        let outcome = switchOutcome(
            choice, from: oldMode, to: newMode, current: current,
            resetSource: resetSource)
        var base = PrescriptionSnapshotPayload.empty
        base.cardioSegmentsData = current?.cardioSegmentsData
        return SessionPlanResolver.plannedCardioSegments(
            sessionPlan: outcome.sessionPlan,
            snapshot: Adapter.adaptedSnapshot(
                from: outcome, base: base, equipment: nil, setupNotes: nil))
    }

    /// **Reset onto a cardio exercise whose source carries a plan → that plan
    /// is what the checklist shows.**
    func testResetToCardioWithAStructuredSourcePlanShowsTheReplacementPlan()
        throws
    {
        var source = Adapter.ResetSource.appDefaults(for: .cardio)
        source.cardioSegmentsData = try encoded(repeatedPlan())

        let resolved = try XCTUnwrap(
            resolvedPlanAfterSwitch(
                .resetPlan, from: .cardio, to: .cardio,
                current: try structuredCardioSessionPlan(),
                resetSource: source))

        XCTAssertEqual(resolved.expandedCount, 10)
        XCTAssertEqual(
            resolved.groups.first?.repeatCount, 5,
            "the replacement plan, not the one the slot had")
    }

    /// **Reset onto a cardio exercise with no source plan → no checklist.**
    ///
    /// This is the reviewed "the plan disappears" observation, and it is
    /// correct: a structured plan lives on the routine *slot*, not on an
    /// `Exercise`, so a switched-in exercise brings none, and
    /// `ResetSource.appDefaults` deliberately supplies none — the same rule
    /// that makes Reset drop the target distance (Slice 6).
    func testResetToCardioWithoutASourcePlanHidesTheChecklist() throws {
        XCTAssertNil(
            resolvedPlanAfterSwitch(
                .resetPlan, from: .cardio, to: .cardio,
                current: try structuredCardioSessionPlan()),
            "no source plan means no checklist — expected, not a regression")
    }

    /// Pins the reason: app defaults carry no structured plan, by design.
    func testAppDefaultsCarryNoStructuredPlanForAnyMode() {
        for mode in [TrackingMode.cardio, .strength, .timedHold] {
            XCTAssertNil(
                Adapter.ResetSource.appDefaults(for: mode).cardioSegmentsData,
                "app defaults never invent a session structure (\(mode))")
        }
    }

    /// The Keep counterpart, resolved the same way — so the pair of
    /// expectations the review asked about is asserted against one code path.
    func testKeepOnCardioToCardioStillResolvesToTheSamePlan() throws {
        let current = try structuredCardioSessionPlan()

        let resolved = try XCTUnwrap(
            resolvedPlanAfterSwitch(
                .keepCurrentPlan, from: .cardio, to: .cardio, current: current))

        XCTAssertEqual(resolved, current.structuredCardioPlan)
    }

    /// A corrupt payload behaves as no plan on the reset path too — the gate
    /// the checklist reads must never throw.
    func testResetWithACorruptSourcePayloadResolvesAsNoPlan() throws {
        var source = Adapter.ResetSource.appDefaults(for: .cardio)
        source.cardioSegmentsData = Data("{{{".utf8)

        XCTAssertNil(
            resolvedPlanAfterSwitch(
                .resetPlan, from: .cardio, to: .cardio,
                current: try structuredCardioSessionPlan(),
                resetSource: source))
    }

    /// Reset must still clear the cardio drafts and the target distance — the
    /// Slice 5/6 behaviour the structured plan rides alongside.
    func testResetStillClearsTargetDistanceAndCardioDrafts() throws {
        var source = Adapter.ResetSource.appDefaults(for: .cardio)
        source.cardioSegmentsData = try encoded(flatPlan())

        let outcome = switchOutcome(
            .resetPlan, from: .cardio, to: .cardio,
            current: try structuredCardioSessionPlan(), resetSource: source)

        XCTAssertNil(outcome.sessionPlan.targetDistanceMeters)
        XCTAssertFalse(
            outcome.keepCardioDrafts,
            "an explicit Reset discards typed metrics and ticks alike")
    }

    /// Tier 2 must agree with tier 1 after a switch. Leaving the replaced
    /// exercise's segments on the snapshot is exactly how a cleared plan would
    /// reappear on the next resume.
    func testTheAdaptedSnapshotIsRewrittenFromTheAdaptedPlan() throws {
        let current = try structuredCardioSessionPlan()
        var base = PrescriptionSnapshotPayload.empty
        base.cardioSegmentsData = current.cardioSegmentsData

        let toStrength = Adapter.adaptedSnapshot(
            from: switchOutcome(
                .keepCurrentPlan, from: .cardio, to: .strength,
                current: current),
            base: base, equipment: nil, setupNotes: nil)
        XCTAssertNil(toStrength.cardioSegmentsData)
        XCTAssertNil(toStrength.structuredCardioPlan)

        let staysCardio = Adapter.adaptedSnapshot(
            from: switchOutcome(
                .keepCurrentPlan, from: .cardio, to: .cardio, current: current),
            base: base, equipment: nil, setupNotes: nil)
        XCTAssertEqual(
            staysCardio.cardioSegmentsData, current.cardioSegmentsData)
    }

    /// No switch path may throw or trap on a payload it cannot read.
    func testASwitchWithACorruptPayloadIsSafe() {
        var current = SessionPlan()
        current.usesDuration = true
        current.cardioSegmentsData = Data("<<not json>>".utf8)

        for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
            for newMode in [TrackingMode.cardio, .strength, .timedHold] {
                let outcome = switchOutcome(
                    choice, from: .cardio, to: newMode, current: current)
                XCTAssertNil(
                    outcome.sessionPlan.structuredCardioPlan,
                    "an unreadable payload is never a plan (\(choice), \(newMode))")
            }
        }
    }

    /// The Slice 5/6 target-distance rules are untouched by the new field.
    func testTargetDistanceSwitchBehaviorIsUnchanged() throws {
        let current = try structuredCardioSessionPlan()

        XCTAssertEqual(
            switchOutcome(
                .keepCurrentPlan, from: .cardio, to: .cardio, current: current
            ).sessionPlan.targetDistanceMeters, 5_000)
        XCTAssertNil(
            switchOutcome(
                .keepCurrentPlan, from: .cardio, to: .strength, current: current
            ).sessionPlan.targetDistanceMeters)
        XCTAssertNil(
            switchOutcome(
                .resetPlan, from: .cardio, to: .cardio, current: current
            ).sessionPlan.targetDistanceMeters)
    }
}

// MARK: - Test-only helpers

extension CardioSegmentPlan {
    /// A plan round-tripped through its own encoder, so a comparison against a
    /// decoded plan compares what was *stored* rather than what was authored.
    /// (Authoring and decoding normalize identically, so this is the identity
    /// in every case that matters — it exists to make that explicit.)
    fileprivate var normalizedForComparison: CardioSegmentPlan {
        guard let data = try? JSONEncoder().encode(self),
            let decoded = try? JSONDecoder().decode(
                CardioSegmentPlan.self, from: data)
        else { return self }
        return decoded
    }
}

// `PlannedPrescriptionSnapshot.structuredPlanForTest` was removed in Slice
// 12E: History needs to decode the frozen plan for real, so the accessor now
// ships in `SlotPrescription+StructuredCardio.swift` as
// `PlannedPrescriptionSnapshot.structuredCardioPlan` and these tests use it.
