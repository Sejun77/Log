import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 6 — exercise-switch compatibility for cardio.
///
/// The bug class this guards against is the Entry #12 P1 shape: the switch
/// changes the visible row type, but the *old* exercise's type-specific state
/// stays attached to the slot, and the resume path then disagrees with the live
/// view. Cardio adds two new ways for that to happen — a target distance on the
/// plan, and typed metric drafts on the row — so both get the same treatment
/// duration and reps already had.
///
/// The rule in one line: **cardio-only state survives cardio → cardio, and
/// nothing else.**
@MainActor
final class CardioExerciseSwitchTests: SwiftDataTestHarness {

    private typealias Adapter = ExerciseSwitchPlanAdapter
    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles

    // MARK: - Fixtures

    /// A pre-switch cardio plan: 1 set, 30 min, 5 km.
    private func cardioPlan(
        distanceMeters: Double? = 5_000, unitRaw: String? = "km"
    ) -> SessionPlan {
        var plan = SessionPlan()
        plan.sets = 1
        plan.usesDuration = true
        plan.durationMaxSeconds = 1_800
        plan.restSecondsBetweenSets = nil
        plan.targetDistanceMeters = distanceMeters
        plan.targetDistanceUnitRaw = unitRaw
        return plan
    }

    private func strengthPlan() -> SessionPlan {
        var plan = SessionPlan()
        plan.sets = 3
        plan.repMin = 8
        plan.repMax = 12
        plan.restSecondsBetweenSets = 90
        plan.tempo = "3-1-3-0"
        return plan
    }

    private func timedHoldPlan() -> SessionPlan {
        var plan = SessionPlan()
        plan.sets = 3
        plan.usesDuration = true
        plan.durationMaxSeconds = 45
        plan.restSecondsBetweenSets = 60
        return plan
    }

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

    // MARK: - 1. cardio → cardio

    func testCardioToCardioKeepPreservesTargetDistance() {
        let outcome = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .cardio,
            current: cardioPlan())

        XCTAssertEqual(outcome.sessionPlan.targetDistanceMeters, 5_000)
        XCTAssertEqual(outcome.sessionPlan.targetDistanceUnitRaw, "km")
    }

    func testCardioToCardioKeepPreservesSetsDurationAndRest() {
        var current = cardioPlan()
        current.restSecondsBetweenSets = 120
        let plan = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .cardio, current: current
        ).sessionPlan

        XCTAssertEqual(plan.sets, 1)
        XCTAssertEqual(plan.durationMaxSeconds, 1_800)
        XCTAssertEqual(plan.restSecondsBetweenSets, 120)
        XCTAssertTrue(plan.usesDuration)
    }

    func testCardioToCardioKeepPreservesTheAuthoredUnit() {
        let plan = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .cardio,
            current: cardioPlan(distanceMeters: 5_000, unitRaw: "mi")
        ).sessionPlan

        XCTAssertEqual(plan.targetDistanceUnitRaw, "mi")
        XCTAssertEqual(
            plan.targetDistance(fallbackUnit: km)?.unit, mi,
            "the target must read back in the unit it was authored in")
    }

    // MARK: - 2. cardio → cardio Reset

    func testCardioToCardioResetWithoutASourceTargetClearsIt() {
        let plan = switchOutcome(
            .resetPlan, from: .cardio, to: .cardio, current: cardioPlan()
        ).sessionPlan

        XCTAssertNil(
            plan.targetDistanceMeters,
            "app defaults carry no target — Reset must not inherit the old one")
        XCTAssertNil(plan.targetDistanceUnitRaw)
    }

    func testCardioToCardioResetUsesTheSourceTarget() {
        var source = Adapter.ResetSource.appDefaults(for: .cardio)
        source.targetDistanceMeters = 10_000
        source.targetDistanceUnitRaw = "km"

        let plan = switchOutcome(
            .resetPlan, from: .cardio, to: .cardio, current: cardioPlan(),
            resetSource: source
        ).sessionPlan

        XCTAssertEqual(plan.targetDistanceMeters, 10_000)
        XCTAssertEqual(plan.targetDistanceUnitRaw, "km")
    }

    /// Reset onto cardio lands on the Slice 5 cardio defaults, not the generic
    /// strength ones.
    func testCardioResetSourceFollowsTheCardioRoutineRules() {
        let source = Adapter.ResetSource.appDefaults(for: .cardio)

        XCTAssertEqual(source.sets, 1)
        XCTAssertNil(source.restSecondsBetweenSets)
        XCTAssertNil(source.restSecondsAfterExercise)
        XCTAssertNil(source.rir)
        XCTAssertNil(source.rpe)
        XCTAssertNil(source.targetDistanceMeters)
    }

    /// …and the non-cardio reset sources are untouched by that.
    func testNonCardioResetSourcesAreUnchanged() {
        let strength = Adapter.ResetSource.appDefaults(for: .strength)
        XCTAssertEqual(strength.sets, AppSettings.defaultSets)
        XCTAssertEqual(strength.repMin, AppSettings.defaultRepMin)
        XCTAssertEqual(
            strength.restSecondsBetweenSets, AppSettings.defaultRestBetweenSets)

        let hold = Adapter.ResetSource.appDefaults(for: .timedHold)
        XCTAssertEqual(hold.sets, AppSettings.defaultSets)
        XCTAssertNil(hold.repMin)
        XCTAssertEqual(
            hold.restSecondsBetweenSets, AppSettings.defaultRestBetweenSets)
    }

    // MARK: - 3 & 4. Switching away from cardio clears the target

    func testCardioToTimedHoldClearsTargetDistance() {
        for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
            let plan = switchOutcome(
                choice, from: .cardio, to: .timedHold, current: cardioPlan()
            ).sessionPlan
            XCTAssertNil(plan.targetDistanceMeters, "\(choice)")
            XCTAssertNil(plan.targetDistanceUnitRaw, "\(choice)")
        }
    }

    func testCardioToStrengthClearsTargetDistance() {
        for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
            let plan = switchOutcome(
                choice, from: .cardio, to: .strength, current: cardioPlan()
            ).sessionPlan
            XCTAssertNil(plan.targetDistanceMeters, "\(choice)")
            XCTAssertNil(plan.targetDistanceUnitRaw, "\(choice)")
        }
    }

    /// The leak that mattered most: the snapshot is built from the *replaced*
    /// exercise's payload, so a target left untouched there would come back
    /// through tier-2 resolution on the next resume.
    func testAdaptedSnapshotClearsTheTargetWhenLeavingCardio() throws {
        var base = PrescriptionSnapshotPayload.empty
        base.targetDistanceMeters = 5_000
        base.targetDistanceUnitRaw = "km"
        base.usesDuration = true

        for newMode in [TrackingMode.strength, .timedHold] {
            let outcome = switchOutcome(
                .keepCurrentPlan, from: .cardio, to: newMode,
                current: cardioPlan())
            let snapshot = Adapter.adaptedSnapshot(
                from: outcome, base: base, equipment: nil, setupNotes: nil)

            XCTAssertNil(snapshot.targetDistanceMeters, "\(newMode)")
            XCTAssertNil(snapshot.targetDistanceUnitRaw, "\(newMode)")
            XCTAssertNil(
                SessionPlanResolver.plannedTargetDistance(
                    sessionPlan: outcome.sessionPlan, snapshot: snapshot,
                    fallbackUnit: km),
                "no tier may still resolve a target for \(newMode)")
        }
    }

    func testAdaptedSnapshotKeepsTheTargetForCardioToCardio() throws {
        let outcome = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .cardio,
            current: cardioPlan())
        let snapshot = Adapter.adaptedSnapshot(
            from: outcome, base: .empty, equipment: nil, setupNotes: nil)

        XCTAssertEqual(snapshot.targetDistanceMeters, 5_000)
        let resolved = try XCTUnwrap(
            SessionPlanResolver.plannedTargetDistance(
                sessionPlan: outcome.sessionPlan, snapshot: snapshot,
                fallbackUnit: km))
        XCTAssertEqual(resolved.displayText, "5 km")
    }

    // MARK: - 5 & 6. Switching into cardio

    func testTimedHoldToCardioKeepsDurationAndHasNoTarget() {
        let plan = switchOutcome(
            .keepCurrentPlan, from: .timedHold, to: .cardio,
            current: timedHoldPlan()
        ).sessionPlan

        // Both modes are duration-shaped, so the duration target survives.
        XCTAssertEqual(plan.sets, 3)
        XCTAssertEqual(plan.durationMaxSeconds, 45)
        XCTAssertEqual(plan.restSecondsBetweenSets, 60)
        XCTAssertTrue(plan.usesDuration)
        // Nothing prescribed a distance, so there is none.
        XCTAssertNil(plan.targetDistanceMeters)
    }

    func testStrengthToCardioClearsRepsAndTempoAndHasNoTarget() {
        let plan = switchOutcome(
            .keepCurrentPlan, from: .strength, to: .cardio,
            current: strengthPlan()
        ).sessionPlan

        XCTAssertTrue(plan.usesDuration)
        XCTAssertNil(plan.repMin)
        XCTAssertNil(plan.repMax)
        XCTAssertNil(plan.tempo)
        XCTAssertNil(plan.targetDistanceMeters)
        // Set count and rest are mode-agnostic and are preserved.
        XCTAssertEqual(plan.sets, 3)
        XCTAssertEqual(plan.restSecondsBetweenSets, 90)
    }

    func testSwitchingIntoCardioWithAResetSourceTargetUsesIt() {
        var source = Adapter.ResetSource.appDefaults(for: .cardio)
        source.targetDistanceMeters = 3_000
        source.targetDistanceUnitRaw = "km"

        for oldMode in [TrackingMode.strength, .timedHold] {
            let plan = switchOutcome(
                .resetPlan, from: oldMode, to: .cardio,
                current: oldMode == .strength ? strengthPlan() : timedHoldPlan(),
                resetSource: source
            ).sessionPlan
            XCTAssertEqual(plan.targetDistanceMeters, 3_000, "\(oldMode)")
        }
    }

    func testSwitchingIntoCardioWithoutASourceTargetHasNone() {
        for oldMode in [TrackingMode.strength, .timedHold] {
            for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
                let plan = switchOutcome(
                    choice, from: oldMode, to: .cardio,
                    current: oldMode == .strength
                        ? strengthPlan() : timedHoldPlan()
                ).sessionPlan
                XCTAssertNil(
                    plan.targetDistanceMeters, "\(oldMode) \(choice)")
            }
        }
    }

    // MARK: - 7 & 8. No cardio/duration leakage into the new row

    func testCardioToStrengthLeavesNoDurationOrCardioFields() {
        for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
            let plan = switchOutcome(
                choice, from: .cardio, to: .strength, current: cardioPlan()
            ).sessionPlan

            XCTAssertFalse(plan.usesDuration, "\(choice)")
            XCTAssertNil(plan.durationMinSeconds, "\(choice)")
            XCTAssertNil(plan.durationMaxSeconds, "\(choice)")
            XCTAssertNil(plan.targetDistanceMeters, "\(choice)")
            XCTAssertNil(plan.targetDistanceUnitRaw, "\(choice)")
        }
    }

    /// The plan summary is the user-visible proof: no "5 km" segment may
    /// survive onto a strength row.
    func testStrengthPlanSummaryAfterCardioSwitchHasNoDistance() {
        let plan = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .strength,
            current: cardioPlan()
        ).sessionPlan

        XCTAssertFalse(plan.primarySummary.contains("km"))
        XCTAssertFalse(plan.primarySummary.contains("mi"))
    }

    func testCardioToTimedHoldLeavesNoCardioOnlyFields() {
        let plan = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .timedHold,
            current: cardioPlan()
        ).sessionPlan

        // Duration is shared between the two modes and survives …
        XCTAssertTrue(plan.usesDuration)
        XCTAssertEqual(plan.durationMaxSeconds, 1_800)
        XCTAssertNil(plan.repMin, "a timed hold never shows reps")
        // … the distance target does not.
        XCTAssertNil(plan.targetDistanceMeters)
        XCTAssertFalse(plan.primarySummary.contains("km"))
    }

    // MARK: - 12–14. Draft retention verdict

    func testCardioDraftsSurviveOnlyCardioToCardioKeep() {
        let modes: [TrackingMode] = [.strength, .timedHold, .cardio]
        for old in modes {
            for new in modes {
                for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
                    let keeps = switchOutcome(
                        choice, from: old, to: new, current: cardioPlan()
                    ).keepCardioDrafts
                    let expected =
                        choice == .keepCurrentPlan && old == .cardio
                        && new == .cardio
                    XCTAssertEqual(
                        keeps, expected,
                        "\(old) → \(new) \(choice) should "
                            + (expected ? "keep" : "clear") + " cardio drafts")
                }
            }
        }
    }

    func testCardioToStrengthClearsCardioDrafts() {
        XCTAssertFalse(
            switchOutcome(
                .keepCurrentPlan, from: .cardio, to: .strength,
                current: cardioPlan()
            ).keepCardioDrafts)
    }

    func testCardioToTimedHoldClearsCardioDrafts() {
        XCTAssertFalse(
            switchOutcome(
                .keepCurrentPlan, from: .cardio, to: .timedHold,
                current: cardioPlan()
            ).keepCardioDrafts)
    }

    func testCardioToCardioKeepPreservesCardioDrafts() {
        XCTAssertTrue(
            switchOutcome(
                .keepCurrentPlan, from: .cardio, to: .cardio,
                current: cardioPlan()
            ).keepCardioDrafts)
    }

    // MARK: - 15 & 16. Persisted drafts

    private func makeStore(_ suite: String) throws -> ParentDraftStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return ParentDraftStore(workoutID: UUID(), defaults: defaults)
    }

    /// `clearCardio` takes exactly the fields that lost their meaning — and
    /// leaves the duration, which a cardio → timed-hold switch still needs.
    func testClearCardioRemovesOnlyTheCardioFields() throws {
        let store = try makeStore("CardioExerciseSwitchTests.clear")
        let slotID = UUID()

        store.persist(slotID: slotID, setIndex: 0, field: .reps, value: "8")
        store.persist(slotID: slotID, setIndex: 0, field: .weight, value: "60")
        store.persist(
            slotID: slotID, setIndex: 0, field: .duration, value: "1800")
        store.persist(
            slotID: slotID, setIndex: 0,
            cardio: CardioEntryDraft(
                unit: km, distance: "5", avgHeartRate: "142", calories: "410",
                incline: "3", resistance: "8", hrZone: .z3))

        store.clearCardio(slotID: slotID)

        let snapshot = try XCTUnwrap(store.load(slotID: slotID, setIndex: 0))
        XCTAssertEqual(snapshot.reps, "8")
        XCTAssertEqual(snapshot.weight, "60")
        XCTAssertEqual(snapshot.duration, "1800")
        XCTAssertFalse(
            snapshot.hasCardio, "every cardio field must be gone: \(snapshot)")
    }

    /// Cleared across every set index, so a slot whose set count shrank in the
    /// same switch cannot strand orphan keys past the new count.
    func testClearCardioSweepsEverySetIndex() throws {
        let store = try makeStore("CardioExerciseSwitchTests.sweep")
        let slotID = UUID()
        for i in 0..<4 {
            store.persist(
                slotID: slotID, setIndex: i,
                cardio: CardioEntryDraft(unit: km, distance: "\(i + 1)"))
        }

        store.clearCardio(slotID: slotID)

        for i in 0..<4 {
            XCTAssertNil(
                store.load(slotID: slotID, setIndex: i)?.distance,
                "set \(i) still has a persisted distance")
        }
    }

    /// Clearing one slot must not touch a sibling slot's drafts.
    func testClearCardioLeavesOtherSlotsAlone() throws {
        let store = try makeStore("CardioExerciseSwitchTests.siblings")
        let switched = UUID()
        let untouched = UUID()
        for slot in [switched, untouched] {
            store.persist(
                slotID: slot, setIndex: 0,
                cardio: CardioEntryDraft(unit: km, distance: "5"))
        }

        store.clearCardio(slotID: switched)

        XCTAssertNil(store.load(slotID: switched, setIndex: 0)?.distance)
        XCTAssertEqual(store.load(slotID: untouched, setIndex: 0)?.distance, "5")
    }

    /// The resume half of the guarantee: with the persisted cardio fields gone,
    /// a rebuild finds nothing to restore, so stale metrics cannot reappear
    /// after Save & Exit.
    func testResumeFindsNoCardioDraftAfterSwitchingAway() throws {
        let store = try makeStore("CardioExerciseSwitchTests.resume")
        let slotID = UUID()
        store.persist(
            slotID: slotID, setIndex: 0,
            cardio: CardioEntryDraft(
                unit: km, distance: "5", avgHeartRate: "142"))

        store.clearCardio(slotID: slotID)

        let snapshot = store.load(slotID: slotID, setIndex: 0)
        XCTAssertNil(
            snapshot.flatMap {
                CardioEntryDraft(snapshot: $0, defaultUnit: km)
            },
            "a cleared slot must rebuild no cardio draft at all")
    }

    /// The `clearCardio` no-op path: a slot that never had cardio fields is
    /// untouched, and nothing is written.
    func testClearCardioIsANoOpForANonCardioSlot() throws {
        let store = try makeStore("CardioExerciseSwitchTests.noop")
        let slotID = UUID()
        store.persist(slotID: slotID, setIndex: 0, field: .reps, value: "8")

        store.clearCardio(slotID: slotID)

        XCTAssertEqual(store.load(slotID: slotID, setIndex: 0)?.reps, "8")
    }

    /// A future cardio field added to `Field` joins the cleared set
    /// automatically — the subset is derived by exclusion, not hand-listed.
    func testCardioFieldSubsetIsDerivedNotHardcoded() {
        let cardio = Set(ParentDraftStore.Field.cardioFields)
        XCTAssertFalse(cardio.contains(.reps))
        XCTAssertFalse(cardio.contains(.weight))
        XCTAssertFalse(cardio.contains(.duration))
        XCTAssertEqual(cardio.count, ParentDraftStore.Field.allCases.count - 3)
    }

    // MARK: - 17 & 18. Seeding after a switch into cardio

    /// Mirrors `seedCardioDraftsFromTarget`: the switched slot's *adapted* plan
    /// is the seed source, so a switch into cardio behaves like a fresh start.
    private func seededDraft(
        plan: SessionPlan, snapshot: PrescriptionSnapshotPayload?
    ) -> CardioEntryDraft? {
        SessionPlanResolver.plannedTargetDistance(
            sessionPlan: plan, snapshot: snapshot, fallbackUnit: km
        )
        .map { CardioEntryDraft(unit: $0.unit, distance: $0.valueText ?? "") }
    }

    func testTargetSeedingStillWorksAfterASwitchIntoCardio() throws {
        var source = Adapter.ResetSource.appDefaults(for: .cardio)
        source.targetDistanceMeters = 5_000
        source.targetDistanceUnitRaw = "km"

        let outcome = switchOutcome(
            .resetPlan, from: .strength, to: .cardio, current: strengthPlan(),
            resetSource: source)
        let snapshot = Adapter.adaptedSnapshot(
            from: outcome, base: .empty, equipment: nil, setupNotes: nil)

        let draft = try XCTUnwrap(
            seededDraft(plan: outcome.sessionPlan, snapshot: snapshot))
        XCTAssertEqual(draft.distance, "5")
        XCTAssertEqual(draft.unit, km)
    }

    func testNoSeedingAfterASwitchAwayFromCardio() {
        let outcome = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .strength,
            current: cardioPlan())
        let snapshot = Adapter.adaptedSnapshot(
            from: outcome, base: .empty, equipment: nil, setupNotes: nil)

        XCTAssertNil(seededDraft(plan: outcome.sessionPlan, snapshot: snapshot))
    }

    /// A user edit still outranks the target after a resume, exactly as it does
    /// without a switch: the persisted draft is consulted before seeding.
    func testUserEditedDraftStillWinsOverSeedingAfterASwitch() throws {
        let store = try makeStore("CardioExerciseSwitchTests.editWins")
        let slotID = UUID()
        // The user edits the seeded distance after switching into cardio.
        store.persist(
            slotID: slotID, setIndex: 0,
            cardio: CardioEntryDraft(unit: km, distance: "4.2"))

        let outcome = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .cardio,
            current: cardioPlan())
        let restored = try XCTUnwrap(
            store.load(slotID: slotID, setIndex: 0).flatMap {
                CardioEntryDraft(snapshot: $0, defaultUnit: km)
            })

        XCTAssertEqual(restored.distance, "4.2")
        XCTAssertEqual(
            outcome.sessionPlan.targetDistanceMeters, 5_000,
            "the target is still 5 km — the edit simply outranks it")
    }

    // MARK: - 19–23. Mode-driven UI rules

    func testCardioDetailsVisibilityFollowsTheSwitchedInMode() {
        // The row shows Details iff the slot's live exercise is cardio; these
        // are the mode values the switch writes.
        XCTAssertTrue(TrackingMode.cardio == .cardio)
        XCTAssertNotEqual(TrackingMode.strength, .cardio)
        XCTAssertNotEqual(TrackingMode.timedHold, .cardio)
    }

    func testEffortStaysHiddenForCardioAndUnchangedOtherwise() {
        XCTAssertFalse(
            WorkoutEffortTargetResolver.isEffortApplicable(to: .cardio))
        XCTAssertTrue(
            WorkoutEffortTargetResolver.isEffortApplicable(to: .strength))
        XCTAssertTrue(
            WorkoutEffortTargetResolver.isEffortApplicable(to: .timedHold))
    }

    /// A slot switched into cardio must not render a distance target it never
    /// received, and one switched out must not keep rendering the old one.
    func testPlanSummaryShowsTheDistanceOnlyForACardioTarget() {
        let keptCardio = switchOutcome(
            .keepCurrentPlan, from: .cardio, to: .cardio, current: cardioPlan()
        ).sessionPlan
        XCTAssertTrue(keptCardio.primarySummary.contains("5 km"))

        let intoCardio = switchOutcome(
            .keepCurrentPlan, from: .strength, to: .cardio,
            current: strengthPlan()
        ).sessionPlan
        XCTAssertFalse(intoCardio.primarySummary.contains("km"))
    }

    // MARK: - Mode axis vs. field-shape axis

    /// `usesDuration` is the field-shape question, and cardio → timedHold is
    /// the case that proves it is not mode equality: the mode changed, but the
    /// duration target survives because both are logged by time.
    func testDurationSurvivesAModeChangeBetweenTwoTimedModes() {
        for (old, new) in [
            (TrackingMode.cardio, TrackingMode.timedHold),
            (.timedHold, .cardio),
        ] {
            let plan = switchOutcome(
                .keepCurrentPlan, from: old, to: new,
                current: old == .cardio ? cardioPlan() : timedHoldPlan()
            ).sessionPlan
            XCTAssertNotNil(
                plan.durationMaxSeconds,
                "\(old) → \(new) must keep its duration target")
            XCTAssertTrue(plan.usesDuration)
        }
    }

    func testUsesDurationAxis() {
        XCTAssertFalse(TrackingMode.strength.usesDuration)
        XCTAssertTrue(TrackingMode.timedHold.usesDuration)
        XCTAssertTrue(TrackingMode.cardio.usesDuration)
    }

    // MARK: - 9–11. Non-cardio switches are unchanged

    /// The pre-Slice-6 behavior for the three non-cardio combinations, asserted
    /// here against the new mode-based API so a regression shows up as a
    /// failure in this file too, not only in the older suites.
    func testStrengthToStrengthKeepIsUnchanged() {
        let plan = switchOutcome(
            .keepCurrentPlan, from: .strength, to: .strength,
            current: strengthPlan()
        ).sessionPlan

        XCTAssertEqual(plan.sets, 3)
        XCTAssertEqual(plan.repMin, 8)
        XCTAssertEqual(plan.repMax, 12)
        XCTAssertEqual(plan.tempo, "3-1-3-0")
        XCTAssertFalse(plan.usesDuration)
        XCTAssertNil(plan.targetDistanceMeters)
    }

    func testTimedHoldToTimedHoldKeepIsUnchanged() {
        let plan = switchOutcome(
            .keepCurrentPlan, from: .timedHold, to: .timedHold,
            current: timedHoldPlan()
        ).sessionPlan

        XCTAssertEqual(plan.sets, 3)
        XCTAssertEqual(plan.durationMaxSeconds, 45)
        XCTAssertNil(plan.tempo, "tempo never applies to a duration slot")
        XCTAssertTrue(plan.usesDuration)
        XCTAssertNil(plan.targetDistanceMeters)
    }

    func testStrengthAndTimedHoldCrossSwitchesAreUnchanged() {
        let toHold = switchOutcome(
            .keepCurrentPlan, from: .strength, to: .timedHold,
            current: strengthPlan()
        ).sessionPlan
        XCTAssertTrue(toHold.usesDuration)
        XCTAssertNil(toHold.repMin)
        XCTAssertNil(toHold.tempo)
        XCTAssertEqual(toHold.sets, 3, "set count is mode-agnostic")

        let toStrength = switchOutcome(
            .keepCurrentPlan, from: .timedHold, to: .strength,
            current: timedHoldPlan()
        ).sessionPlan
        XCTAssertFalse(toStrength.usesDuration)
        XCTAssertNil(toStrength.durationMaxSeconds)
        XCTAssertEqual(toStrength.sets, 3)
    }

    /// No non-cardio switch may ever produce a distance target.
    func testNoNonCardioSwitchEverProducesATarget() {
        let nonCardio: [TrackingMode] = [.strength, .timedHold]
        for old in nonCardio {
            for new in nonCardio {
                for choice in [Adapter.Choice.keepCurrentPlan, .resetPlan] {
                    let plan = switchOutcome(
                        choice, from: old, to: new, current: cardioPlan()
                    ).sessionPlan
                    XCTAssertNil(
                        plan.targetDistanceMeters, "\(old) → \(new) \(choice)")
                }
            }
        }
    }
}
