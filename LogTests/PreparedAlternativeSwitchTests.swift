import SwiftData
import XCTest

@testable import Log

/// Alternative Exercises Phase F1 — offering and applying a prepared
/// alternative during a workout.
///
/// Two halves, both pure:
///
///  1. **What the sheet offers** — `PreparedAlternatives`, the visibility
///     rules (disabled hidden, same-exercise hidden, deleted marked).
///  2. **What applying one does** — `ExerciseSwitchPlanAdapter` with
///     `.useAlternative`, which is the *reset* path with a richer source. The
///     rule this file really pins is that a prepared alternative is neither
///     Keep nor Reset: unlike `appDefaults` it carries warm-ups, techniques, a
///     distance, a Cardio Plan and a note, and unlike Keep it never inherits
///     anything from the exercise it replaced.
///
/// The destructive-confirmation half lives with the existing switch tests,
/// because the gate is a function of logged sets alone and is untouched by
/// which plan the switch will apply.
final class PreparedAlternativeSwitchTests: XCTestCase {

    private typealias Adapter = ExerciseSwitchPlanAdapter

    // MARK: - Fixtures

    private let benchID = UUID()
    private let machineID = UUID()
    private let treadmillID = UUID()

    private func cardioPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                CardioSegment(kind: .warmUp, durationSeconds: 300),
                CardioSegment(kind: .work, durationSeconds: 1_200),
            ])
        ])
    }

    private func warmup() -> WarmupStepSnapshot {
        WarmupStepSnapshot(
            order: 0, kind: .percentage, reps: 10, percentOfWorking: 50)
    }

    private func dropset() -> TechniquePlanSnapshot {
        TechniquePlanSnapshot(
            order: 0, type: .dropset, dropPercent: 20, dropCount: 2,
            rounds: nil, restSeconds: 15, partialRangeNote: nil, note: nil,
            reps: nil)
    }

    private func alternative(
        _ name: String,
        exerciseID: UUID,
        order: Int = 0,
        enabled: Bool = true,
        note: String? = nil,
        prescription: AlternativePrescriptionPayload = .init()
    ) -> SlotAlternative {
        SlotAlternative(
            order: order, isEnabled: enabled, exerciseID: exerciseID,
            exerciseName: name, note: note, prescription: prescription)
    }

    /// A strength alternative with everything a slot can carry.
    private func richPayload() throws -> AlternativePrescriptionPayload {
        var p = AlternativePrescriptionPayload(
            sets: 4, repMin: 10, repMax: 15,
            restSecondsBetweenSets: 75, restSecondsAfterExercise: 150,
            rir: 3, tempo: "3-0-1-0",
            slotNotes: "seat height 4")
        p.warmupSteps = [warmup()]
        p.techniques = [dropset()]
        return p
    }

    /// The pre-switch plan of a 3 × 8–12 bench slot with an RIR-2 target.
    private func currentStrengthPlan() -> SessionPlan {
        var plan = SessionPlan()
        plan.sets = 3
        plan.repMin = 8
        plan.repMax = 12
        plan.restSecondsBetweenSets = 180
        plan.rir = 2
        plan.tempo = "2-0-1-0"
        plan.slotNotes = "arch the back"
        return plan
    }

    private func outcome(
        applying payload: AlternativePrescriptionPayload,
        current: SessionPlan? = nil,
        oldMode: TrackingMode = .strength,
        newMode: TrackingMode = .strength
    ) -> Adapter.Outcome {
        Adapter.outcome(
            choice: .useAlternative(payload),
            current: current,
            oldMode: oldMode,
            newMode: newMode,
            // Deliberately the *wrong* source: `.useAlternative` must ignore it
            // and use the payload it carries.
            resetSource: .appDefaults(for: newMode))
    }

    // ==================================================
    // MARK: - 1. What the sheet offers
    // ==================================================

    func testASlotWithNoAlternativesOffersNothing() {
        XCTAssertEqual(
            PreparedAlternatives.offers(
                from: [], currentExerciseID: benchID,
                availableExerciseIDs: [benchID, machineID]),
            [])
        XCTAssertFalse(
            PreparedAlternatives.hasOffers(
                from: [], currentExerciseID: benchID,
                availableExerciseIDs: [benchID, machineID]),
            "no offers keeps the pre-F1 flow: picker first, no new sheet")
    }

    func testDisabledAlternativesAreHidden() {
        let offers = PreparedAlternatives.offers(
            from: [
                alternative("Machine", exerciseID: machineID, order: 0),
                alternative(
                    "Treadmill", exerciseID: treadmillID, order: 1,
                    enabled: false),
            ],
            currentExerciseID: benchID,
            availableExerciseIDs: [benchID, machineID, treadmillID])

        XCTAssertEqual(offers.map(\.exerciseName), ["Machine"])
    }

    func testTheSlotsOwnExerciseIsHidden() {
        let offers = PreparedAlternatives.offers(
            from: [
                alternative("Bench", exerciseID: benchID, order: 0),
                alternative("Machine", exerciseID: machineID, order: 1),
            ],
            currentExerciseID: benchID,
            availableExerciseIDs: [benchID, machineID])

        XCTAssertEqual(offers.map(\.exerciseName), ["Machine"])
    }

    /// After applying one alternative, *that* one is now the slot's exercise
    /// and drops out of the list — while the others stay switchable.
    func testAnAppliedAlternativeDropsOutOfTheList() {
        let list = [
            alternative("Machine", exerciseID: machineID, order: 0),
            alternative("Treadmill", exerciseID: treadmillID, order: 1),
        ]

        let offers = PreparedAlternatives.offers(
            from: list, currentExerciseID: machineID,
            availableExerciseIDs: [benchID, machineID, treadmillID])

        XCTAssertEqual(offers.map(\.exerciseName), ["Treadmill"])
    }

    /// A deleted exercise is shown, marked unavailable, and not tappable —
    /// never silently dropped (§8.7).
    func testADeletedExerciseIsOfferedAsUnavailable() {
        let offers = PreparedAlternatives.offers(
            from: [alternative("Machine", exerciseID: machineID)],
            currentExerciseID: benchID,
            availableExerciseIDs: [benchID])

        XCTAssertEqual(offers.count, 1)
        XCTAssertFalse(offers[0].isAvailable)
        XCTAssertEqual(
            offers[0].exerciseName, "Machine",
            "the frozen name is what makes the row legible at all")
    }

    func testOrderAndNotesSurviveIntoTheOffer() {
        let offers = PreparedAlternatives.offers(
            from: [
                alternative(
                    "Machine", exerciseID: machineID, order: 0,
                    note: "when the rack is busy"),
                alternative("Treadmill", exerciseID: treadmillID, order: 1),
            ],
            currentExerciseID: benchID,
            availableExerciseIDs: [benchID, machineID, treadmillID])

        XCTAssertEqual(offers.map(\.exerciseName), ["Machine", "Treadmill"])
        XCTAssertEqual(offers[0].note, "when the rack is busy")
        XCTAssertNil(offers[1].note)
    }

    /// The row's second line is the same summary the routine editor shows, so
    /// what the user prepared is what they see when choosing.
    func testTheOfferSummaryComesFromTheAlternativesPrescription() throws {
        let offer = try XCTUnwrap(
            PreparedAlternatives.offers(
                from: [
                    alternative(
                        "Machine", exerciseID: machineID,
                        prescription: try richPayload())
                ],
                currentExerciseID: benchID,
                availableExerciseIDs: [machineID]
            ).first)

        XCTAssertEqual(
            SlotAlternativeSummary.subtitle(
                for: offer.alternative, effortMetric: .rir),
            "4 × 10–15 · 75s rest · RIR 3 · Warmup · Techniques")
    }

    // ==================================================
    // MARK: - 2. Applying: strength
    // ==================================================

    func testApplyingAStrengthAlternativeReplacesTheWholePlan() throws {
        let result = outcome(
            applying: try richPayload(), current: currentStrengthPlan())
        let plan = result.sessionPlan

        XCTAssertEqual(plan.sets, 4)
        XCTAssertEqual(plan.repMin, 10)
        XCTAssertEqual(plan.repMax, 15)
        XCTAssertEqual(plan.restSecondsBetweenSets, 75)
        XCTAssertEqual(plan.restSecondsAfterExercise, 150)
        XCTAssertEqual(plan.rir, 3)
        XCTAssertEqual(plan.tempo, "3-0-1-0")
        XCTAssertFalse(plan.usesDuration)
        XCTAssertEqual(
            plan.slotNotes, "seat height 4",
            "the alternative's note applies; the replaced exercise's never does")
    }

    func testWarmupsAndTechniquesAreReplacedNotInherited() throws {
        let result = outcome(
            applying: try richPayload(), current: currentStrengthPlan())

        XCTAssertEqual(result.replacementWarmupSteps, [warmup()])
        XCTAssertEqual(result.replacementTechniques, [dropset()])
        XCTAssertFalse(
            result.keepWarmupSteps,
            "the flags stay false; the replacements are what the caller uses")
        XCTAssertFalse(result.keepTechniques)
    }

    /// An alternative authored *without* a warm-up clears the slot's, rather
    /// than leaving the replaced exercise's ramp in place.
    func testAnAlternativeWithNoWarmupsClearsThem() {
        let result = outcome(
            applying: AlternativePrescriptionPayload(sets: 3),
            current: currentStrengthPlan())

        XCTAssertEqual(result.replacementWarmupSteps, [])
        XCTAssertEqual(result.replacementTechniques, [])
    }

    /// The effort target is the alternative's, always — including when the
    /// alternative deliberately has none.
    func testAnAlternativeWithNoEffortTargetDoesNotInheritOne() {
        let result = outcome(
            applying: AlternativePrescriptionPayload(sets: 3, repMin: 8, repMax: 12),
            current: currentStrengthPlan())

        XCTAssertNil(result.sessionPlan.rir)
        XCTAssertNil(result.sessionPlan.rpe)
        XCTAssertTrue(result.clearsEffortProgression)
    }

    /// A progression authored on an alternative survives into the snapshot,
    /// where `WorkoutEffortTargetResolver` reads it — a `SessionPlan` carries
    /// only a single value and would otherwise drop it.
    func testAnAlternativesEffortProgressionLandsOnTheSnapshot() {
        var payload = AlternativePrescriptionPayload(sets: 3, repMin: 8, repMax: 12)
        payload.effortModeRaw = EffortMode.progression.rawValue
        payload.rirStart = 3
        payload.rirEnd = 1

        let snapshot = Adapter.adaptedSnapshot(
            from: outcome(applying: payload, current: currentStrengthPlan()),
            base: PrescriptionSnapshotPayload(
                effortModeRaw: EffortMode.single.rawValue, rirStart: 9,
                rirEnd: 9),
            equipment: nil, setupNotes: nil)

        XCTAssertEqual(snapshot.effortModeRaw, EffortMode.progression.rawValue)
        XCTAssertEqual(snapshot.rirStart, 3)
        XCTAssertEqual(snapshot.rirEnd, 1)
    }

    func testTheResetSourceArgumentIsIgnoredForAnAlternative() throws {
        let result = Adapter.outcome(
            choice: .useAlternative(try richPayload()),
            current: currentStrengthPlan(),
            oldMode: .strength,
            newMode: .strength,
            resetSource: Adapter.ResetSource(sets: 99, repMin: 99, repMax: 99))

        XCTAssertEqual(result.sessionPlan.sets, 4)
        XCTAssertEqual(result.sessionPlan.repMin, 10)
    }

    // ==================================================
    // MARK: - 3. Applying: tracking-mode changes
    // ==================================================

    func testApplyingATimedHoldAlternativeAppliesTheDurationTarget() {
        var payload = AlternativePrescriptionPayload(sets: 3)
        payload.usesDuration = true
        payload.durationMinSeconds = 45
        payload.durationMaxSeconds = 60
        payload.tempo = "3-0-1-0"

        let plan = outcome(
            applying: payload, current: currentStrengthPlan(),
            oldMode: .strength, newMode: .timedHold
        ).sessionPlan

        XCTAssertTrue(plan.usesDuration)
        XCTAssertEqual(plan.durationMinSeconds, 45)
        XCTAssertEqual(plan.durationMaxSeconds, 60)
        XCTAssertNil(plan.repMin, "no reps on a duration slot")
        XCTAssertNil(plan.repMax)
        XCTAssertNil(plan.tempo, "tempo describes rep phases")
        XCTAssertEqual(plan.sets, 3)
    }

    func testApplyingACardioAlternativeAppliesDistanceAndPlan() throws {
        let authored = try cardioPlan()
        var payload = AlternativePrescriptionPayload(sets: 1)
        payload.usesDuration = true
        payload.durationMaxSeconds = 1_800
        payload.targetDistanceMeters = 5_000
        payload.targetDistanceUnitRaw = DistanceUnit.kilometers.rawValue
        payload.cardioSegments = authored

        let result = outcome(
            applying: payload, current: currentStrengthPlan(),
            oldMode: .strength, newMode: .cardio)
        let plan = result.sessionPlan

        XCTAssertEqual(plan.targetDistanceMeters, 5_000)
        XCTAssertEqual(plan.targetDistanceUnitRaw, "km")
        XCTAssertEqual(plan.structuredCardioPlan, authored)
        XCTAssertEqual(plan.durationMaxSeconds, 1_800)
        XCTAssertNil(plan.rir, "cardio shows no effort control")
        XCTAssertNil(plan.rpe)
        XCTAssertFalse(
            result.keepCardioDrafts,
            "the replaced exercise's typed metrics never describe a new bout")
    }

    /// The mode gate still belongs to the adapter: a distance and a segment
    /// plan authored on an alternative land **only** if the exercise is cardio
    /// today, which is how an alternative whose exercise was later edited into
    /// another mode degrades safely (§8.4).
    func testCardioOnlyFieldsAreDroppedOnANonCardioExercise() throws {
        var payload = AlternativePrescriptionPayload(sets: 3, repMin: 8, repMax: 12)
        payload.targetDistanceMeters = 5_000
        payload.cardioSegments = try cardioPlan()

        let plan = outcome(
            applying: payload, current: currentStrengthPlan(),
            oldMode: .strength, newMode: .strength
        ).sessionPlan

        XCTAssertNil(plan.targetDistanceMeters)
        XCTAssertNil(plan.cardioSegmentsData)
        XCTAssertEqual(plan.sets, 3)
    }

    func testApplyingAStrengthAlternativeFromACardioSlotClearsCardioState() throws {
        var current = SessionPlan()
        current.usesDuration = true
        current.targetDistanceMeters = 5_000
        current.cardioSegmentsData = try JSONEncoder().encode(try cardioPlan())

        let result = outcome(
            applying: AlternativePrescriptionPayload(
                sets: 3, repMin: 8, repMax: 12),
            current: current, oldMode: .cardio, newMode: .strength)

        XCTAssertNil(result.sessionPlan.targetDistanceMeters)
        XCTAssertNil(result.sessionPlan.cardioSegmentsData)
        XCTAssertFalse(result.sessionPlan.usesDuration)
        XCTAssertEqual(result.sessionPlan.repMin, 8)
        XCTAssertFalse(result.keepCardioDrafts)
    }

    /// The snapshot projection agrees with the plan, so tier-2 resolution and a
    /// later resume report the alternative's numbers rather than the replaced
    /// exercise's.
    func testTheAdaptedSnapshotAgreesWithTheAppliedAlternative() throws {
        var payload = AlternativePrescriptionPayload(sets: 1)
        payload.usesDuration = true
        payload.targetDistanceMeters = 5_000
        payload.cardioSegments = try cardioPlan()

        let result = outcome(
            applying: payload, current: currentStrengthPlan(),
            oldMode: .strength, newMode: .cardio)
        let snapshot = Adapter.adaptedSnapshot(
            from: result,
            base: PrescriptionSnapshotPayload(
                sets: 3, repMin: 8, repMax: 12, usesDuration: false),
            equipment: "Treadmill", setupNotes: nil)

        XCTAssertEqual(snapshot.sets, 1)
        XCTAssertTrue(snapshot.usesDuration)
        XCTAssertNil(snapshot.repMin)
        XCTAssertEqual(snapshot.targetDistanceMeters, 5_000)
        XCTAssertNotNil(snapshot.cardioSegmentsData)
        XCTAssertNil(snapshot.effortModeRaw, "a cardio slot carries no effort")
        XCTAssertEqual(snapshot.equipment, "Treadmill")
    }

    // ==================================================
    // MARK: - 4. The slot keeps its alternatives
    // ==================================================

    /// The list is slot-scoped, so applying one alternative must leave every
    /// alternative — including the applied one — intact for the next switch.
    /// (`ActiveWorkoutView.applySwitchOutcome` carries them across; this is the
    /// value-level half of that guarantee.)
    func testApplyingAnAlternativeDoesNotDisturbTheAlternativesList() throws {
        let list = [
            alternative(
                "Machine", exerciseID: machineID, order: 0,
                prescription: try richPayload()),
            alternative("Treadmill", exerciseID: treadmillID, order: 1),
        ]
        var current = currentStrengthPlan()
        current.alternatives = list

        let result = outcome(applying: try richPayload(), current: current)
        var applied = result.sessionPlan
        applied.alternatives = current.alternatives

        XCTAssertEqual(applied.alternatives, list)
        XCTAssertEqual(
            applied.alternatives[1].prescription,
            list[1].prescription,
            "applying one alternative does not touch another")
    }

    // ==================================================
    // MARK: - 5. The destructive gate is shared
    // ==================================================

    /// The confirmation is a function of **logged sets alone** — its inputs do
    /// not mention which plan the switch will apply. That is the whole reason a
    /// prepared alternative inherits it for free by routing through the same
    /// `requestPendingSwap` entry point instead of applying directly.
    func testTheDeletionGateDoesNotDependOnWhichPlanIsApplied() {
        let slot = UUID()
        let impact = exerciseSwitchDeletionImpact(
            slotID: slot, isSuperset: false, slotOrder: [slot],
            setCounts: [slot: 3], loggedBySlot: [slot: [0]])

        XCTAssertTrue(impact.requiresConfirmation)
        XCTAssertEqual(impact.totalLoggedSets, 1)
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.message(for: impact),
            "Switching exercises will remove 1 logged set for this exercise.",
            "the same copy the Keep/Reset paths already show")
    }

    /// Nothing logged ⇒ no confirmation ⇒ the alternative applies on one tap,
    /// which is goal 3 of the feature.
    func testAnAlternativeAppliesImmediatelyWhenNothingIsLogged() {
        let slot = UUID()
        let impact = exerciseSwitchDeletionImpact(
            slotID: slot, isSuperset: false, slotOrder: [slot],
            setCounts: [slot: 3], loggedBySlot: [slot: []])

        XCTAssertFalse(impact.requiresConfirmation)
        XCTAssertNil(ExerciseSwitchConfirmationCopy.message(for: impact))
    }

    /// The superset cascade still counts a partner's sets, so switching a
    /// superset member to a prepared alternative warns about the whole block.
    func testTheSupersetCascadeStillCountsWhenApplyingAnAlternative() {
        let first = UUID()
        let second = UUID()
        let impact = exerciseSwitchDeletionImpact(
            slotID: first, isSuperset: true, slotOrder: [first, second],
            setCounts: [first: 3, second: 3],
            loggedBySlot: [first: [0], second: [0]])

        XCTAssertTrue(impact.requiresConfirmation)
        XCTAssertTrue(impact.includesPartnerSets)
        XCTAssertEqual(impact.totalLoggedSets, 2)
    }

    /// A cardio bout is one aggregate logged set, and it gates the switch like
    /// any other.
    func testACardioLoggedSetGatesTheSwitch() {
        let slot = UUID()
        let impact = exerciseSwitchDeletionImpact(
            slotID: slot, isSuperset: false, slotOrder: [slot],
            setCounts: [slot: 1], loggedBySlot: [slot: [0]])

        XCTAssertTrue(impact.requiresConfirmation)
        XCTAssertEqual(impact.totalLoggedSets, 1)
    }

    // ==================================================
    // MARK: - 6. Save & Exit / Resume
    // ==================================================

    /// What `persistSessionPlans` writes after an alternative is applied must
    /// come back whole: the applied prescription **and** the slot's list, so a
    /// resumed session can switch again.
    func testAnAppliedAlternativeSurvivesTheSessionPlanRoundTrip() throws {
        let list = [
            alternative(
                "Machine", exerciseID: machineID, order: 0,
                prescription: try richPayload()),
            alternative("Treadmill", exerciseID: treadmillID, order: 1),
        ]
        var current = currentStrengthPlan()
        current.alternatives = list

        // Apply, carrying the list across exactly as `applySwitchOutcome` does.
        var applied = outcome(
            applying: try richPayload(), current: current
        ).sessionPlan
        applied.alternatives = current.alternatives

        let slot = UUID()
        let data = try JSONEncoder().encode([slot.uuidString: applied])
        let restored = try XCTUnwrap(
            try JSONDecoder().decode(
                [String: SessionPlan].self, from: data)[slot.uuidString])

        XCTAssertEqual(restored.sets, 4)
        XCTAssertEqual(restored.repMin, 10)
        XCTAssertEqual(restored.restSecondsBetweenSets, 75)
        XCTAssertEqual(restored.rir, 3)
        XCTAssertEqual(restored.slotNotes, "seat height 4")
        XCTAssertEqual(restored.alternatives, list)
    }

    /// A cardio alternative's plan survives the same round trip, so the
    /// checklist is still there after a resume.
    func testAnAppliedCardioAlternativeSurvivesTheRoundTrip() throws {
        let authored = try cardioPlan()
        var payload = AlternativePrescriptionPayload(sets: 1)
        payload.usesDuration = true
        payload.targetDistanceMeters = 5_000
        payload.cardioSegments = authored

        let applied = outcome(
            applying: payload, current: currentStrengthPlan(),
            oldMode: .strength, newMode: .cardio
        ).sessionPlan

        let slot = UUID()
        let restored = try XCTUnwrap(
            try JSONDecoder().decode(
                [String: SessionPlan].self,
                from: try JSONEncoder().encode([slot.uuidString: applied])
            )[slot.uuidString])

        XCTAssertEqual(restored.targetDistanceMeters, 5_000)
        XCTAssertEqual(restored.structuredCardioPlan, authored)
    }

    // ==================================================
    // MARK: - 7. Keep / Reset are unchanged
    // ==================================================

    /// The existing choices must produce byte-identical outcomes — the whole
    /// adapter suite is the real proof, this is the local sanity check.
    func testKeepAndResetOutcomesCarryNoAlternative() {
        let keep = Adapter.outcome(
            choice: .keepCurrentPlan, current: currentStrengthPlan(),
            oldMode: .strength, newMode: .strength,
            resetSource: .appDefaults(for: .strength))
        let reset = Adapter.outcome(
            choice: .resetPlan, current: currentStrengthPlan(),
            oldMode: .strength, newMode: .strength,
            resetSource: .appDefaults(for: .strength))

        XCTAssertNil(keep.appliedAlternative)
        XCTAssertNil(keep.replacementWarmupSteps)
        XCTAssertNil(keep.replacementTechniques)
        XCTAssertTrue(keep.keepWarmupSteps)
        XCTAssertEqual(keep.sessionPlan.sets, 3)

        XCTAssertNil(reset.appliedAlternative)
        XCTAssertNil(reset.replacementWarmupSteps)
        XCTAssertFalse(reset.keepWarmupSteps)
    }

    /// A reset source with no effort target still preserves the pre-switch one
    /// — the `replacesEffortTarget` flag must not have changed that.
    func testResetWithoutAnEffortTargetStillPreservesTheCurrentOne() {
        var source = Adapter.ResetSource(sets: 3, repMin: 8, repMax: 12)
        source.rir = nil
        source.rpe = nil

        let result = Adapter.outcome(
            choice: .resetPlan, current: currentStrengthPlan(),
            oldMode: .strength, newMode: .strength, resetSource: source)

        XCTAssertEqual(result.sessionPlan.rir, 2, "inherited, as before F1")
        XCTAssertFalse(result.clearsEffortProgression)
    }
}
