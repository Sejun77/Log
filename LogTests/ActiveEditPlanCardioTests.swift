import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 6 patch — the active-workout Edit Plan sheet, and the
/// two switch behaviors manual smoke testing flagged.
///
/// `EditSessionPlanSheet` is a SwiftUI view and cannot be instantiated in a
/// unit test, so what is asserted here is everything the view delegates to:
/// the visibility predicates it branches on, and the exact mutations its rows
/// commit to the bound `SessionPlan`. `SessionTargetDistanceRow.commit()` is
/// two lines over `CardioTargetDistance`; `commitTargetDistance` below is that
/// same expression, so a change to one that is not made to the other shows up
/// as a failure here.
@MainActor
final class ActiveEditPlanCardioTests: SwiftDataTestHarness {

    private typealias Adapter = ExerciseSwitchPlanAdapter
    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles

    // MARK: - Fixtures

    private func cardioPlan(
        distanceMeters: Double? = 5_000, unitRaw: String? = "km"
    ) -> SessionPlan {
        var plan = SessionPlan()
        plan.sets = 1
        plan.usesDuration = true
        plan.durationMaxSeconds = 1_800
        plan.targetDistanceMeters = distanceMeters
        plan.targetDistanceUnitRaw = unitRaw
        return plan
    }

    private func strengthPlan(rir: Double? = 2) -> SessionPlan {
        var plan = SessionPlan()
        plan.sets = 3
        plan.repMin = 8
        plan.repMax = 12
        plan.restSecondsBetweenSets = 90
        plan.rir = rir
        plan.rpe = rir.map { 10 - $0 }
        return plan
    }

    private func timedHoldPlan(rir: Double? = 2) -> SessionPlan {
        var plan = SessionPlan()
        plan.sets = 3
        plan.usesDuration = true
        plan.durationMaxSeconds = 45
        plan.rir = rir
        plan.rpe = rir.map { 10 - $0 }
        return plan
    }

    private func outcome(
        _ choice: Adapter.Choice, from old: TrackingMode, to new: TrackingMode,
        current: SessionPlan?, resetSource: Adapter.ResetSource? = nil
    ) -> Adapter.Outcome {
        Adapter.outcome(
            choice: choice, current: current, oldMode: old, newMode: new,
            resetSource: resetSource ?? .appDefaults(for: new))
    }

    /// Exactly what `SessionTargetDistanceRow.commit()` does.
    private func commitTargetDistance(
        _ plan: inout SessionPlan, text: String, unit: DistanceUnit
    ) {
        let target = CardioTargetDistance(text: text, unit: unit)
        plan.targetDistanceMeters = target?.meters
        plan.targetDistanceUnitRaw = target?.unit.rawValue
    }

    // MARK: - 1–3. Which sections the sheet offers

    /// The sheet branches the target-distance row on `isCardio`, which the call
    /// site now reads from `cardioSlotIDs` directly.
    func testTargetDistanceRowIsOfferedOnlyForCardio() {
        XCTAssertTrue(CardioRoutineRules.showsTargetDistance(.cardio))
        XCTAssertFalse(CardioRoutineRules.showsTargetDistance(.strength))
        XCTAssertFalse(
            CardioRoutineRules.showsTargetDistance(.timedHold),
            "a Plank slot must not offer a distance target")
    }

    /// …and the Intensity section on the inverse predicate, so the two are
    /// mutually exclusive by construction.
    func testIntensitySectionIsHiddenExactlyWhenTargetDistanceIsShown() {
        for mode in [TrackingMode.strength, .timedHold, .cardio] {
            XCTAssertNotEqual(
                CardioRoutineRules.showsTargetDistance(mode),
                WorkoutEffortTargetResolver.isEffortApplicable(to: mode),
                "\(mode)")
        }
    }

    func testIntensityIsHiddenForCardioAndShownOtherwise() {
        XCTAssertFalse(
            WorkoutEffortTargetResolver.isEffortApplicable(to: .cardio))
        XCTAssertTrue(
            WorkoutEffortTargetResolver.isEffortApplicable(to: .strength))
        XCTAssertTrue(
            WorkoutEffortTargetResolver.isEffortApplicable(to: .timedHold))
    }

    // MARK: - 4–6. Editing the target in the active plan

    func testEditingTargetDistanceUpdatesBothPlanFields() throws {
        var plan = cardioPlan(distanceMeters: nil, unitRaw: nil)
        commitTargetDistance(&plan, text: "5", unit: km)

        XCTAssertEqual(try XCTUnwrap(plan.targetDistanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(plan.targetDistanceUnitRaw, "km")
        XCTAssertEqual(
            plan.targetDistance(displayUnit: km)?.displayText, "5 km")
    }

    func testEditingTargetDistanceInMilesStoresCanonicalMeters() throws {
        var plan = cardioPlan(distanceMeters: nil, unitRaw: nil)
        commitTargetDistance(&plan, text: "3.1", unit: mi)

        XCTAssertEqual(
            try XCTUnwrap(plan.targetDistanceMeters), 3.1 * 1_609.344,
            accuracy: 0.001)
        XCTAssertEqual(plan.targetDistanceUnitRaw, "mi")
    }

    func testClearingTargetDistanceNilsBothFields() {
        var plan = cardioPlan()
        commitTargetDistance(&plan, text: "", unit: km)

        XCTAssertNil(plan.targetDistanceMeters)
        XCTAssertNil(
            plan.targetDistanceUnitRaw,
            "clearing the distance must clear its unit too")
    }

    func testInvalidTargetDistanceNormalizesToNil() {
        for text in ["abc", "-5", "0", "0.0", ".", "1001", " "] {
            var plan = cardioPlan()
            commitTargetDistance(&plan, text: text, unit: km)
            XCTAssertNil(plan.targetDistanceMeters, "\"\(text)\"")
            XCTAssertNil(plan.targetDistanceUnitRaw, "\"\(text)\"")
        }
    }

    /// Switching the unit re-reads the same stored distance rather than
    /// converting the typed number — the field text is the source of truth
    /// while the sheet is open.
    func testSwitchingUnitReinterpretsTheTypedNumber() throws {
        var plan = cardioPlan(distanceMeters: nil, unitRaw: nil)
        commitTargetDistance(&plan, text: "5", unit: km)
        let asKm = try XCTUnwrap(plan.targetDistanceMeters)
        commitTargetDistance(&plan, text: "5", unit: mi)
        let asMi = try XCTUnwrap(plan.targetDistanceMeters)

        XCTAssertEqual(asKm, 5_000, accuracy: 0.001)
        XCTAssertEqual(asMi, 5 * 1_609.344, accuracy: 0.001)
        XCTAssertEqual(plan.targetDistanceUnitRaw, "mi")
    }

    /// A round trip through the row's seed and commit leaves the plan
    /// unchanged, so merely opening and closing the sheet cannot alter it.
    ///
    /// Seeded in the same unit it was authored in — which, under the
    /// Settings-only policy, is the only case where the row commits on reopen.
    /// Reopening under the *other* preference re-seeds the text but
    /// deliberately does not write; see
    /// `DistanceUnitSettingTests.testChangingThePreferenceDoesNotRewriteStoredMeters`.
    func testSeedAndCommitRoundTripIsLossless() throws {
        for (text, unit) in [("5", km), ("6.25", km), ("3.1", mi)] {
            var plan = cardioPlan(distanceMeters: nil, unitRaw: nil)
            commitTargetDistance(&plan, text: text, unit: unit)
            let before = plan

            // Reopen: seed from the plan, commit the seeded text unchanged.
            let seeded = try XCTUnwrap(plan.targetDistance(displayUnit: unit))
            commitTargetDistance(
                &plan, text: try XCTUnwrap(seeded.valueText), unit: seeded.unit)

            XCTAssertEqual(plan, before)
        }
    }

    /// The edit has to reach the plan summary, which is what the Plan card
    /// renders behind the sheet.
    func testEditedTargetAppearsInThePlanSummary() {
        var plan = cardioPlan(distanceMeters: nil, unitRaw: nil)
        XCTAssertFalse(plan.primarySummary(distanceUnit: .kilometers).contains("km"))

        commitTargetDistance(&plan, text: "5", unit: km)
        XCTAssertTrue(plan.primarySummary(distanceUnit: .kilometers).contains("5 km"))

        commitTargetDistance(&plan, text: "", unit: km)
        XCTAssertFalse(plan.primarySummary(distanceUnit: .kilometers).contains("km"))
    }

    // MARK: - Issue 2 — the full cardio → cardio Keep pipeline

    /// Smoke testing reported a cleared target for cardio → cardio "Keep".
    /// The adapter unit test already covered the adapter in isolation, so this
    /// walks the whole chain the app actually runs — routine prescription →
    /// snapshot payload → session plan → switch → adapted snapshot → frozen
    /// `@Model` snapshot — asserting the target at every hop.
    func testCardioToCardioKeepPreservesTargetThroughTheWholePipeline() throws {
        let source = SlotPrescription(usesDuration: true)
        source.sets = 1
        source.durationMaxSeconds = 1_800
        source.applyTargetDistance(CardioTargetDistance(text: "5", unit: km))
        context.insert(source)

        // Session start.
        let payload = PrescriptionSnapshotPayload(from: source, exercise: nil)
        XCTAssertEqual(payload.targetDistanceMeters, 5_000)

        // `initializeSessionPlans`.
        let live = SessionPlan(from: payload, notes: nil)
        XCTAssertEqual(live.targetDistanceMeters, 5_000)

        // The switch.
        let switched = outcome(
            .keepCurrentPlan, from: .cardio, to: .cardio, current: live)
        XCTAssertEqual(switched.sessionPlan.targetDistanceMeters, 5_000)
        XCTAssertEqual(switched.sessionPlan.targetDistanceUnitRaw, "km")
        XCTAssertEqual(switched.sessionPlan.sets, 1)
        XCTAssertEqual(switched.sessionPlan.durationMaxSeconds, 1_800)

        // `applySwitchOutcome` rewrites tier 2 …
        let adapted = Adapter.adaptedSnapshot(
            from: switched, base: payload, equipment: nil, setupNotes: nil)
        XCTAssertEqual(adapted.targetDistanceMeters, 5_000)

        // … and `populateSnapshotFields` freezes it for History / resume.
        let frozen = adapted.toModel()
        context.insert(frozen)
        XCTAssertEqual(
            frozen.targetDistance(displayUnit: km)?.displayText, "5 km")

        // Resume rebuilds the payload from the frozen row.
        let restored = PrescriptionSnapshotPayload(from: frozen)
        XCTAssertEqual(restored.targetDistanceMeters, 5_000)
        XCTAssertEqual(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: switched.sessionPlan, snapshot: restored,
                displayUnit: km)?.displayText,
            "5 km")
    }

    /// A session plan persisted by a build that predates the target fields
    /// decodes with nil and, once it overwrites the freshly-initialized plan on
    /// resume, takes the target with it. This is the one path that genuinely
    /// loses a target across a switch — and it is a one-time migration
    /// artifact of an in-flight workout, not a rule of the switch.
    func testLegacyPersistedSessionPlanHasNoTargetToPreserve() throws {
        let legacy = try JSONDecoder().decode(
            SessionPlan.self,
            from: Data(
                #"{"sets":1,"usesDuration":true,"durationMaxSeconds":1800}"#
                    .utf8))
        XCTAssertNil(legacy.targetDistanceMeters)

        let switched = outcome(
            .keepCurrentPlan, from: .cardio, to: .cardio, current: legacy)
        XCTAssertNil(
            switched.sessionPlan.targetDistanceMeters,
            "nothing to preserve — the loss happened before the switch")
    }

    // MARK: - 7–13. Switch target-distance matrix

    func testCardioToCardioKeepPreservesTarget() {
        let plan = outcome(
            .keepCurrentPlan, from: .cardio, to: .cardio, current: cardioPlan()
        ).sessionPlan
        XCTAssertEqual(plan.targetDistanceMeters, 5_000)
        XCTAssertEqual(plan.targetDistanceUnitRaw, "km")
    }

    func testCardioToCardioResetUsesSourceTargetOrClears() {
        var withTarget = Adapter.ResetSource.appDefaults(for: .cardio)
        withTarget.targetDistanceMeters = 10_000
        withTarget.targetDistanceUnitRaw = "km"

        XCTAssertEqual(
            outcome(
                .resetPlan, from: .cardio, to: .cardio, current: cardioPlan(),
                resetSource: withTarget
            ).sessionPlan.targetDistanceMeters, 10_000)

        XCTAssertNil(
            outcome(
                .resetPlan, from: .cardio, to: .cardio, current: cardioPlan()
            ).sessionPlan.targetDistanceMeters)
    }

    func testSwitchingAwayFromCardioClearsTheTarget() {
        for newMode in [TrackingMode.strength, .timedHold] {
            for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
                let plan = outcome(
                    choice, from: .cardio, to: newMode, current: cardioPlan()
                ).sessionPlan
                XCTAssertNil(
                    plan.targetDistanceMeters, "\(newMode) \(choice)")
                XCTAssertNil(
                    plan.targetDistanceUnitRaw, "\(newMode) \(choice)")
            }
        }
    }

    func testSwitchingIntoCardioWithKeepDoesNotInventATarget() {
        for oldMode in [TrackingMode.strength, .timedHold] {
            let plan = outcome(
                .keepCurrentPlan, from: oldMode, to: .cardio,
                current: oldMode == .strength ? strengthPlan() : timedHoldPlan()
            ).sessionPlan
            XCTAssertNil(plan.targetDistanceMeters, "\(oldMode)")
        }
    }

    func testSwitchingIntoCardioWithResetUsesTheSourceTarget() {
        var source = Adapter.ResetSource.appDefaults(for: .cardio)
        source.targetDistanceMeters = 3_000
        source.targetDistanceUnitRaw = "km"

        for oldMode in [TrackingMode.strength, .timedHold] {
            let plan = outcome(
                .resetPlan, from: oldMode, to: .cardio,
                current: oldMode == .strength ? strengthPlan() : timedHoldPlan(),
                resetSource: source
            ).sessionPlan
            XCTAssertEqual(plan.targetDistanceMeters, 3_000, "\(oldMode)")
            XCTAssertEqual(plan.targetDistanceUnitRaw, "km", "\(oldMode)")
        }
    }

    // MARK: - 14–17. Stale intensity is cleared on the way into cardio

    func testStrengthToCardioClearsEffort() {
        for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
            let plan = outcome(
                choice, from: .strength, to: .cardio, current: strengthPlan()
            ).sessionPlan
            XCTAssertNil(plan.rir, "\(choice)")
            XCTAssertNil(plan.rpe, "\(choice)")
        }
    }

    func testTimedHoldToCardioClearsEffort() {
        for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
            let plan = outcome(
                choice, from: .timedHold, to: .cardio, current: timedHoldPlan()
            ).sessionPlan
            XCTAssertNil(plan.rir, "\(choice)")
            XCTAssertNil(plan.rpe, "\(choice)")
        }
    }

    func testCardioToCardioHasNoEffortToCarry() {
        let plan = outcome(
            .keepCurrentPlan, from: .cardio, to: .cardio, current: cardioPlan()
        ).sessionPlan
        XCTAssertNil(plan.rir)
        XCTAssertNil(plan.rpe)
    }

    /// The snapshot matters as much as the plan: effort *progression* fields
    /// live only there, and a stale pair would still derive `.progression` and
    /// summarize a target the cardio row does not display.
    func testSwitchingIntoCardioClearsSnapshotEffortProgression() {
        var base = PrescriptionSnapshotPayload.empty
        base.effortModeRaw = "progression"
        base.rirStart = 3
        base.rirEnd = 0
        base.rpeStart = 7
        base.rpeEnd = 10
        base.rir = 2

        for oldMode in [TrackingMode.strength, .timedHold] {
            let switched = outcome(
                .keepCurrentPlan, from: oldMode, to: .cardio,
                current: strengthPlan())
            let snapshot = Adapter.adaptedSnapshot(
                from: switched, base: base, equipment: nil, setupNotes: nil)

            XCTAssertNil(snapshot.effortModeRaw, "\(oldMode)")
            XCTAssertNil(snapshot.rirStart, "\(oldMode)")
            XCTAssertNil(snapshot.rirEnd, "\(oldMode)")
            XCTAssertNil(snapshot.rpeStart, "\(oldMode)")
            XCTAssertNil(snapshot.rpeEnd, "\(oldMode)")
            XCTAssertNil(snapshot.rir, "\(oldMode)")

            XCTAssertEqual(
                WorkoutEffortTargetResolver.effortMode(
                    for: .init(payload: snapshot)),
                .none,
                "a cardio slot must derive no effort mode at all")
        }
    }

    /// Requirement 16 stated end-to-end: no summary of a switched-into-cardio
    /// slot may mention RIR or RPE.
    func testCardioSummariesShowNoStaleEffortAfterSwitchingIn() {
        var base = PrescriptionSnapshotPayload.empty
        base.effortModeRaw = "progression"
        base.rirStart = 3
        base.rirEnd = 0

        let switched = outcome(
            .keepCurrentPlan, from: .strength, to: .cardio,
            current: strengthPlan())
        let snapshot = Adapter.adaptedSnapshot(
            from: switched, base: base, equipment: nil, setupNotes: nil)

        for autoreg in [AutoregMode.rir, .rpe] {
            XCTAssertNil(
                WorkoutEffortTargetResolver.summary(
                    fields: .init(payload: snapshot), autoregMode: autoreg),
                "\(autoreg)")
        }
        let line2 = switched.sessionPlan.secondarySummary(effortSummary: nil)
        XCTAssertFalse(line2.contains("RIR"))
        XCTAssertFalse(line2.contains("RPE"))
    }

    /// Non-cardio switches keep the effort they always did — the clearing rule
    /// keys off cardio, not off the switch itself.
    func testNonCardioSwitchesStillPreserveEffort() {
        let nonCardio: [TrackingMode] = [.strength, .timedHold]
        for old in nonCardio {
            for new in nonCardio {
                let plan = outcome(
                    .keepCurrentPlan, from: old, to: new,
                    current: strengthPlan(rir: 2)
                ).sessionPlan
                XCTAssertEqual(plan.rir, 2, "\(old) → \(new)")
            }
        }
    }

    // MARK: - 18–25. The non-cardio intensity editor

    /// The sheet's Intensity section is editable when the derived effort mode
    /// is `.single` **or** `.none`. `.none` is the case that was read-only
    /// before this patch, and it is exactly the state a slot lands in after
    /// cardio → strength — which is why there was no way to set intensity.
    private func intensityIsEditable(
        snapshot: PrescriptionSnapshotPayload?, isCardio: Bool
    ) -> Bool {
        guard !isCardio else { return false }
        let mode =
            snapshot.map {
                WorkoutEffortTargetResolver.effortMode(for: .init(payload: $0))
            } ?? .none
        return mode == .single || mode == .none
    }

    /// Mirrors `doubleStepperRow`'s write: set the active metric and mirror the
    /// paired one; a value below the range clears both.
    private func setEffort(
        _ plan: inout SessionPlan, rir: Double?
    ) {
        plan.rir = rir
        plan.rpe = rir.map { 10 - $0 }
    }

    func testStrengthCanSetIntensityAfterSwitchingFromCardio() {
        let switched = outcome(
            .keepCurrentPlan, from: .cardio, to: .strength,
            current: cardioPlan())
        let snapshot = Adapter.adaptedSnapshot(
            from: switched, base: .empty, equipment: nil, setupNotes: nil)

        XCTAssertEqual(
            WorkoutEffortTargetResolver.effortMode(for: .init(payload: snapshot)),
            .none,
            "precondition: the switched slot has no effort target yet")
        XCTAssertTrue(
            intensityIsEditable(snapshot: snapshot, isCardio: false),
            "the user must be able to set intensity after cardio → strength")

        var plan = switched.sessionPlan
        setEffort(&plan, rir: 2)
        XCTAssertEqual(plan.rir, 2)
        XCTAssertEqual(plan.rpe, 8)
    }

    func testTimedHoldCanSetIntensityAfterSwitchingFromCardio() {
        let switched = outcome(
            .keepCurrentPlan, from: .cardio, to: .timedHold,
            current: cardioPlan())
        let snapshot = Adapter.adaptedSnapshot(
            from: switched, base: .empty, equipment: nil, setupNotes: nil)

        XCTAssertTrue(intensityIsEditable(snapshot: snapshot, isCardio: false))

        var plan = switched.sessionPlan
        setEffort(&plan, rir: 1)
        XCTAssertEqual(plan.rir, 1)
        XCTAssertEqual(plan.rpe, 9)
    }

    func testIntensityCanBeClearedBackToNone() {
        var plan = strengthPlan(rir: 2)
        setEffort(&plan, rir: nil)

        XCTAssertNil(plan.rir)
        XCTAssertNil(plan.rpe)
    }

    func testIntensityRemainsEditableForAnOrdinaryStrengthSlot() {
        var single = PrescriptionSnapshotPayload.empty
        single.rir = 2
        XCTAssertTrue(intensityIsEditable(snapshot: single, isCardio: false))
        XCTAssertTrue(intensityIsEditable(snapshot: .empty, isCardio: false))
        XCTAssertTrue(intensityIsEditable(snapshot: nil, isCardio: false))
    }

    /// Progression stays read-only — in-session progression editing is still
    /// deferred, and this patch did not change that.
    func testProgressionIntensityStaysReadOnly() {
        var progression = PrescriptionSnapshotPayload.empty
        progression.effortModeRaw = "progression"
        progression.rirStart = 3
        progression.rirEnd = 0

        XCTAssertEqual(
            WorkoutEffortTargetResolver.effortMode(
                for: .init(payload: progression)),
            .progression)
        XCTAssertFalse(
            intensityIsEditable(snapshot: progression, isCardio: false))
    }

    func testCardioNeverOffersTheIntensityEditor() {
        var single = PrescriptionSnapshotPayload.empty
        single.rir = 2
        for snapshot in [single, .empty, nil] as [PrescriptionSnapshotPayload?] {
            XCTAssertFalse(intensityIsEditable(snapshot: snapshot, isCardio: true))
        }
    }

    func testEditedIntensityReachesThePlanSummary() {
        var plan = strengthPlan(rir: nil)
        XCTAssertNil(
            WorkoutEffortTargetResolver.summary(
                fields: .init(rir: plan.rir, rpe: plan.rpe),
                autoregMode: .rir))

        setEffort(&plan, rir: 2)
        let summary = WorkoutEffortTargetResolver.summary(
            fields: .init(rir: plan.rir, rpe: plan.rpe), autoregMode: .rir)
        XCTAssertEqual(summary, "RIR 2")
        XCTAssertTrue(
            plan.secondarySummary(effortSummary: summary).contains("RIR 2"))
    }

    // MARK: - Dirty tracking and apply-back

    /// A target-distance-only edit has to count as a change, or "Update slot
    /// prescription" is never offered for it.
    func testTargetDistanceEditIsADirtyChange() {
        let original = cardioPlan(distanceMeters: nil, unitRaw: nil)
        var edited = original
        commitTargetDistance(&edited, text: "5", unit: km)

        XCTAssertNotEqual(
            edited.targetDistanceMeters, original.targetDistanceMeters)
        XCTAssertNotEqual(
            edited.targetDistanceUnitRaw, original.targetDistanceUnitRaw)
    }

    /// And the apply-back path must actually carry it onto the routine slot —
    /// mirrors `applySessionPlansToSlotPrescriptions`.
    func testApplyBackCarriesTheTargetOntoTheRoutineSlot() throws {
        let rx = SlotPrescription(usesDuration: true)
        rx.sets = 1
        context.insert(rx)

        var plan = cardioPlan(distanceMeters: nil, unitRaw: nil)
        commitTargetDistance(&plan, text: "5", unit: km)

        rx.targetDistanceMeters = plan.targetDistanceMeters
        rx.targetDistanceUnitRaw = plan.targetDistanceUnitRaw
        try context.save()

        XCTAssertEqual(
            rx.targetDistance(displayUnit: km)?.displayText, "5 km")
    }
}
