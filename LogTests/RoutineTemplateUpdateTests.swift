import SwiftData
import XCTest

@testable import Log

/// Saving a replacement as a **reversible promotion/demotion** (`RoutineTemplateUpdate`)
/// and the complete-plan bundle it is built on (`SlotPlanBundle`).
///
/// Every workout here runs through the real pieces the app uses: the plan is
/// frozen by `StartWorkoutFromRoutineView.makePlan`, a switch goes through
/// `ExerciseSwitchPlanAdapter` + `sessionPlanAfterSwitch` +
/// `applySwitchSnapshots` (exactly what `ActiveWorkoutView.performPendingSwap`
/// calls), and finishing calls `RoutineTemplateUpdate.apply`.
///
/// **What "exact" means here.** The round-trip guarantee covers
/// exercise-specific *plan* data — every field of the bundle, checked at the
/// model level by `SlotDump`. It deliberately does **not** cover an
/// alternative's relationship metadata: the promoted alternative's "why/when"
/// note is dropped (the relationship it described no longer exists) and
/// alternative ids are reissued. Tests assert the note is dropped and never
/// assert an id survives.
@MainActor
final class RoutineTemplateUpdateTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func exercise(
        _ name: String, timeBased: Bool = false, cardio: Bool = false
    ) -> Exercise {
        let e = Exercise(name: name)
        e.isTimeBased = timeBased
        e.isCardio = cardio
        context.insert(e)
        return e
    }

    private func segments(_ warmUp: Int, _ work: Int) throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                CardioSegment(kind: .warmUp, durationSeconds: warmUp),
                CardioSegment(kind: .work, durationSeconds: work),
            ])
        ])
    }

    /// A's plan, deliberately loaded with every kind of field the bundle
    /// carries — including the legacy ones the in-app editor never writes
    /// (technique rep range / duration, per-set overrides, a named scheme).
    private func loadAPlan(onto re: RoutineExercise) {
        let p = SlotPrescription(
            sets: 4, repMin: 5, repMax: 8,
            restSecondsBetweenSets: 180, restSecondsAfterExercise: 240,
            rir: 2, rpe: 8, tempo: "3-1-1-0",
            effortModeRaw: EffortMode.progression.rawValue,
            rirStart: 3, rirEnd: 1, rpeStart: 7, rpeEnd: 9)
        context.insert(p)
        p.setCustomEffortTargets([3, 2, 1.5, 0], metric: .rir)

        let scheme = WarmupScheme(name: "Heavy ramp")
        context.insert(scheme)
        let s0 = WarmupStep(
            order: 0, kind: .percentage, reps: 8, percentOfWorking: 40,
            restSecondsAfter: 60, note: "bar")
        let s1 = WarmupStep(
            order: 1, kind: .fixedReps, reps: 3, restSecondsAfter: 90,
            weight: 80)
        context.insert(s0)
        context.insert(s1)
        scheme.steps = [s0, s1]
        p.warmupScheme = scheme

        let drop = TechniquePlan(
            order: 0, type: .dropset, repMin: 6, repMax: 10,
            durationSeconds: 30, restSeconds: 10, dropPercent: 20,
            dropCount: 2, note: "last set",
            appliesToRaw: "lastWorkingSet", dropsetEffortRaw: "amrap")
        let pause = TechniquePlan(
            order: 1, type: .restPause, reps: 4, restSeconds: 15, rounds: 3,
            appliesToRaw: "allWorkingSets", appliesToSetIndicesRaw: "0,2")
        context.insert(drop)
        context.insert(pause)
        p.techniquePlans = [drop, pause]

        re.prescription = p
        re.templateNotes = "A: belt on top sets"

        let t0 = SetTemplate(
            kind: .working, targetReps: 5, targetWeight: 100,
            restSecondsAfter: 180)
        t0.order = 0
        let t1 = SetTemplate(
            kind: .working, targetReps: 5, targetWeight: 102.5,
            restSecondsAfter: 200)
        t1.order = 1
        context.insert(t0)
        context.insert(t1)
        re.setTemplates = [t0, t1]
    }

    /// B's prepared plan — every value different from A's.
    private func bPayload() -> AlternativePrescriptionPayload {
        AlternativePrescriptionPayload(
            sets: 3, repMin: 10, repMax: 12,
            restSecondsBetweenSets: 75, restSecondsAfterExercise: 90,
            rir: 1, rpe: 9, tempo: "2-0-1-0",
            effortModeRaw: EffortMode.single.rawValue,
            customRIRTargets: [2, 1.5, 1],
            customRPETargets: [8, 8.5, 9],
            warmupSteps: [
                WarmupStepSnapshot(
                    order: 0, kind: .fixedReps, reps: 12, percentOfWorking: nil,
                    note: "light", restSecondsAfter: 45, weight: 20)
            ],
            techniques: [
                TechniquePlanSnapshot(
                    order: 0, type: .partialReps, dropPercent: nil,
                    dropCount: nil, rounds: nil, restSeconds: nil,
                    partialRangeNote: "bottom half", partialRangeRaw: nil,
                    note: nil, reps: 6, appliesToRaw: "lastWorkingSet",
                    appliesToSetNumber: nil, appliesToSetIndicesRaw: nil,
                    dropsetEffortRaw: nil, dropsetEffortReps: nil,
                    repMin: 12, repMax: 15, durationSeconds: nil)
            ],
            slotNotes: "B: seat 4",
            warmupSchemeName: "Machine ramp",
            setTemplates: [
                SetTemplatePayload(
                    order: 0, kindRaw: SetKind.working.rawValue,
                    targetReps: 12, targetWeight: 55, restSecondsAfter: 75)
            ])
    }

    private struct Fixture {
        var routine: Routine
        var slot: RoutineExercise
        var a: Exercise
        var b: Exercise
        var bAlternativeID: UUID
    }

    /// Primary A (rich plan), alternatives [X, B (prepared, rich), Y].
    private func fixture(bEnabled: Bool = true) -> Fixture {
        let a = exercise("Barbell Bench Press")
        let b = exercise("Machine Chest Press")
        let x = exercise("Dumbbell Bench Press")
        let y = exercise("Push-Up")

        let re = RoutineExercise(exercise: a, order: 0, setTemplates: [])
        context.insert(re)
        loadAPlan(onto: re)

        let bAlt = SlotAlternative(
            order: 1, isEnabled: bEnabled, exerciseID: b.id,
            exerciseName: b.name, note: "when the rack is busy",
            prescription: bPayload())
        re.prescription?.setSlotAlternatives([
            SlotAlternative(
                order: 0, exerciseID: x.id, exerciseName: x.name,
                prescription: AlternativePrescriptionPayload(sets: 2)),
            bAlt,
            SlotAlternative(
                order: 2, isEnabled: false, exerciseID: y.id,
                exerciseName: y.name,
                prescription: AlternativePrescriptionPayload(sets: 5)),
        ])

        let block = RoutineBlock(order: 0, exercises: [re])
        context.insert(block)
        let r = Routine(name: "Upper A", blocks: [block])
        context.insert(r)
        try? context.save()
        return Fixture(
            routine: r, slot: re, a: a, b: b, bAlternativeID: bAlt.id)
    }

    // MARK: - Workout simulation (the app's real switch path)

    private struct Session {
        var planEx: PlanExercise
        var plan: SessionPlan
    }

    private func start(_ r: Routine, slot index: Int = 0) throws -> Session {
        let plan = StartWorkoutFromRoutineView.makePlan(from: r)
        let ex = try XCTUnwrap(
            plan.blocks.flatMap(\.exercises)[safe: index])
        return Session(planEx: ex, plan: SlotPlanBundle.sessionBaseline(of: ex).with(
            alternatives: ex.alternativesSnapshot))
    }

    /// `performPendingSwap` → `applySwitchOutcome` → `swapExercise`, minus the
    /// UI state: the same adapter call, the same session-plan step, the same
    /// snapshot rewrite.
    private func switchSlot(
        _ s: inout Session, from old: Exercise, to new: Exercise,
        via choice: PendingSwapPlan
    ) {
        let outcome = ExerciseSwitchPlanAdapter.outcome(
            choice: choice.adapterChoice,
            current: s.plan,
            oldMode: old.trackingMode,
            newMode: new.trackingMode,
            resetSource: .appDefaults(for: new.trackingMode))
        s.plan = sessionPlanAfterSwitch(
            adapted: outcome.sessionPlan, previous: s.plan,
            appliedAlternativeID: choice.appliedAlternativeID)
        applySwitchSnapshots(
            to: &s.planEx, outcome: outcome,
            equipment: new.equipmentType, setupNotes: new.setupDefaults,
            usesDuration: new.isTimeBased)
        s.planEx.currentExerciseID = new.id
        s.planEx.name = new.name
        s.planEx.isTimeBased = new.isTimeBased
    }

    private func preparedChoice(
        _ s: Session, for exercise: Exercise
    ) throws -> PendingSwapPlan {
        let alt = try XCTUnwrap(
            s.plan.alternatives.first { $0.exerciseID == exercise.id })
        return .useAlternative(alt)
    }

    /// Finish with the Save Routine Changes rows for this slot selected:
    /// `applySwaps` selects its replacement row, `applyPlanEdits` its
    /// plan-changes row.
    private func finish(
        _ s: Session, applySwaps: Bool, applyPlanEdits: Bool = false,
        hasPlanEdits: Bool = false
    ) throws {
        let request = RoutineTemplateUpdate.SlotRequest(
            planExercise: s.planEx, sessionPlan: s.plan,
            hasPlanEdits: hasPlanEdits)
        let selected = RoutineTemplateUpdate.pendingChanges(for: [request])
            .filter { $0.kind == .replacement ? applySwaps : applyPlanEdits }
        try RoutineTemplateUpdate.apply(
            [request], selected: Set(selected), in: context)
    }

    // MARK: - Model-level plan dump (independent of the bundle conversions)

    /// Every stored exercise-specific plan field of a slot, read straight off
    /// the models. Comparing dumps checks the conversions without trusting them.
    private struct SlotDump: Equatable {
        var scalars: String
        var customRIR: String?
        var customRPE: String?
        var cardio: CardioSegmentPlan?
        var schemeName: String?
        var steps: [String]
        var techniques: [String]
        var templates: [String]
        var notes: String?
    }

    private func dump(_ re: RoutineExercise) -> SlotDump {
        let p = re.prescription
        let scalars = [
            "\(String(describing: p?.sets))", "\(String(describing: p?.repMin))",
            "\(String(describing: p?.repMax))",
            "\(String(describing: p?.restSecondsBetweenSets))",
            "\(String(describing: p?.restSecondsAfterExercise))",
            "\(String(describing: p?.rir))", "\(String(describing: p?.rpe))",
            "\(String(describing: p?.tempo))",
            "\(String(describing: p?.effortModeRaw))",
            "\(String(describing: p?.rirStart))", "\(String(describing: p?.rirEnd))",
            "\(String(describing: p?.rpeStart))", "\(String(describing: p?.rpeEnd))",
            "\(String(describing: p?.durationMinSeconds))",
            "\(String(describing: p?.durationMaxSeconds))",
            "\(String(describing: p?.usesDuration))",
            "\(String(describing: p?.targetDistanceMeters))",
            "\(String(describing: p?.targetDistanceUnitRaw))",
        ].joined(separator: "|")
        return SlotDump(
            scalars: scalars,
            customRIR: p?.customRIRTargetsRaw,
            customRPE: p?.customRPETargetsRaw,
            cardio: p?.structuredCardioPlan,
            schemeName: p?.warmupScheme?.name,
            steps: (p?.warmupScheme?.steps ?? []).sorted { $0.order < $1.order }
                .map {
                    "\($0.order)|\($0.kindRaw)|\(String(describing: $0.reps))|\(String(describing: $0.percentOfWorking))|\(String(describing: $0.restSecondsAfter))|\(String(describing: $0.note))|\(String(describing: $0.weight))"
                },
            techniques: (p?.techniquePlans ?? []).sorted { $0.order < $1.order }
                .map {
                    [
                        "\($0.order)", $0.typeRaw,
                        "\(String(describing: $0.repMin))",
                        "\(String(describing: $0.repMax))",
                        "\(String(describing: $0.reps))",
                        "\(String(describing: $0.durationSeconds))",
                        "\(String(describing: $0.restSeconds))",
                        "\(String(describing: $0.rounds))",
                        "\(String(describing: $0.dropPercent))",
                        "\(String(describing: $0.dropCount))",
                        "\(String(describing: $0.partialRangeNote))",
                        "\(String(describing: $0.partialRangeRaw))",
                        "\(String(describing: $0.note))", $0.appliesToRaw,
                        "\(String(describing: $0.appliesToSetNumber))",
                        $0.appliesToSetIndicesRaw,
                        "\(String(describing: $0.dropsetEffortRaw))",
                        "\(String(describing: $0.dropsetEffortReps))",
                    ].joined(separator: "|")
                },
            templates: re.setTemplates.sorted { $0.order < $1.order }.map {
                "\($0.order)|\($0.kindRaw)|\($0.targetReps)|\(String(describing: $0.targetWeight))|\(String(describing: $0.restSecondsAfter))|\(String(describing: $0.durationSeconds))"
            },
            notes: re.templateNotes)
    }

    // ==================================================
    // MARK: - Prepared alternative: true A/B swap
    // ==================================================

    func testPreparedSwapPromotesBWithItsPreparedPlanAndDemotesAWithItsWholePlan() throws {
        let f = fixture()
        let aBefore = SlotPlanBundle.capture(from: f.slot)
        let bPrepared = try XCTUnwrap(
            f.slot.prescription?.slotAlternatives[1].prescription)

        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        XCTAssertEqual(s.plan.appliedAlternativeID, f.bAlternativeID)
        try finish(s, applySwaps: true)

        // Primary is B with B's prepared plan — none of A's.
        XCTAssertEqual(f.slot.exercise?.id, f.b.id)
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), bPrepared)
        XCTAssertEqual(f.slot.prescription?.sets, 3)
        XCTAssertEqual(f.slot.prescription?.warmupScheme?.name, "Machine ramp")
        XCTAssertEqual(f.slot.setTemplates.map(\.targetWeight), [55])
        XCTAssertEqual(f.slot.prescription?.techniquePlans.first?.repMin, 12)
        XCTAssertEqual(f.slot.templateNotes, "B: seat 4")

        // A sits at B's exact former position with A's complete plan.
        let alts = try XCTUnwrap(f.slot.prescription?.slotAlternatives)
        XCTAssertEqual(alts.map(\.exerciseName),
                       ["Dumbbell Bench Press", "Barbell Bench Press", "Push-Up"])
        XCTAssertEqual(alts[1].exerciseID, f.a.id)
        XCTAssertEqual(alts[1].prescription, aBefore)
        XCTAssertTrue(alts[1].isEnabled)
        // B's "why/when" note described B relative to A; it is not moved to A.
        XCTAssertNil(alts[1].note)
        // No "same as primary" B row remains.
        XCTAssertFalse(alts.contains { $0.exerciseID == f.b.id })
        // Siblings untouched (enabled state included).
        XCTAssertEqual(alts[0].prescription.sets, 2)
        XCTAssertFalse(alts[2].isEnabled)
    }

    func testDemotedAInheritsBsDisabledState() throws {
        // The workout only offers enabled alternatives, so this exercises the
        // pure promotion directly: A takes B's enabled flag, whatever it is.
        let aID = UUID(), bID = UUID(), xID = UUID()
        let bAlt = SlotAlternative(
            order: 1, isEnabled: false, exerciseID: bID, exerciseName: "B",
            note: "why", prescription: AlternativePrescriptionPayload(sets: 3))
        let result = RoutineTemplateUpdate.promotion(
            demotedExerciseID: aID, demotedExerciseName: "A",
            demotedPlan: AlternativePrescriptionPayload(sets: 4),
            promotedExerciseID: bID, appliedAlternativeID: bAlt.id,
            routineAlternatives: [
                SlotAlternative(order: 0, exerciseID: xID, exerciseName: "X"),
                bAlt,
            ],
            frozenAlternatives: [bAlt],
            switchTimePlan: AlternativePrescriptionPayload(sets: 99),
            planEdits: nil)

        XCTAssertEqual(result.primaryPlan.sets, 3, "prepared payload, not switch-time")
        XCTAssertEqual(result.alternatives.map(\.exerciseID), [xID, aID])
        XCTAssertFalse(result.alternatives[1].isEnabled)
        XCTAssertNil(result.alternatives[1].note)
    }

    // ==================================================
    // MARK: - Round trip
    // ==================================================

    func testAToBToARestoresBothPlansExactly() throws {
        let f = fixture()
        let aDump = dump(f.slot)
        let aBundle = SlotPlanBundle.capture(from: f.slot)
        let bPrepared = try XCTUnwrap(
            f.slot.prescription?.slotAlternatives[1].prescription)

        // Workout 1: A → B (prepared), Update Routine.
        var s1 = try start(f.routine)
        switchSlot(&s1, from: f.a, to: f.b, via: try preparedChoice(s1, for: f.b))
        try finish(s1, applySwaps: true)
        let bDump = dump(f.slot)

        // Workout 2: B → A (A is now prepared), Update Routine.
        var s2 = try start(f.routine)
        switchSlot(&s2, from: f.b, to: f.a, via: try preparedChoice(s2, for: f.a))
        try finish(s2, applySwaps: true)

        XCTAssertEqual(f.slot.exercise?.id, f.a.id)
        XCTAssertEqual(dump(f.slot), aDump, "A's stored plan restored field-for-field")
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), aBundle)

        let alts = try XCTUnwrap(f.slot.prescription?.slotAlternatives)
        XCTAssertEqual(alts.map(\.exerciseID).count, 3)
        XCTAssertEqual(alts[1].exerciseID, f.b.id, "B back in its own position")
        XCTAssertEqual(alts[1].prescription, bPrepared, "B's plan still recoverable")
        // Relationship metadata is not part of the guarantee: B's old note is
        // gone and its id was reissued — deliberately not asserted equal.
        XCTAssertNil(alts[1].note)

        // Once more, to prove the swap is stable rather than drifting.
        var s3 = try start(f.routine)
        switchSlot(&s3, from: f.a, to: f.b, via: try preparedChoice(s3, for: f.b))
        try finish(s3, applySwaps: true)
        XCTAssertEqual(dump(f.slot), bDump)

        var s4 = try start(f.routine)
        switchSlot(&s4, from: f.b, to: f.a, via: try preparedChoice(s4, for: f.a))
        try finish(s4, applySwaps: true)
        XCTAssertEqual(dump(f.slot), aDump)
    }

    func testPlanFidelityCoversEveryLegacyField() throws {
        let f = fixture()
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        try finish(s, applySwaps: true)

        let demoted = try XCTUnwrap(
            f.slot.prescription?.slotAlternatives.first { $0.exerciseID == f.a.id })
        let plan = demoted.prescription
        XCTAssertEqual(plan.warmupSchemeName, "Heavy ramp")
        XCTAssertEqual(plan.warmupSteps.map(\.weight), [nil, 80])
        XCTAssertEqual(plan.techniques.first?.repMin, 6)
        XCTAssertEqual(plan.techniques.first?.repMax, 10)
        XCTAssertEqual(plan.techniques.first?.durationSeconds, 30)
        XCTAssertEqual(plan.techniques.last?.appliesToSetIndicesRaw, "0,2")
        XCTAssertEqual(plan.setTemplates?.map(\.targetWeight), [100, 102.5])
        XCTAssertEqual(plan.setTemplates?.map(\.restSecondsAfter), [180, 200])
        XCTAssertEqual(plan.effortModeRaw, EffortMode.progression.rawValue)
        XCTAssertEqual(plan.rirStart, 3)
        XCTAssertEqual(plan.rpeEnd, 9)
        XCTAssertEqual(plan.customRIRTargets, [3, 2, 1.5, 0])
        XCTAssertEqual(plan.tempo, "3-1-1-0")
        XCTAssertEqual(plan.slotNotes, "A: belt on top sets")
    }

    // ==================================================
    // MARK: - Replacement + plan changes (formerly Apply All)
    // ==================================================

    func testApplyAllOverlaysOnlyTheEditsOntoBsCompletePlan() throws {
        let f = fixture()
        let aBundle = SlotPlanBundle.capture(from: f.slot)
        let bPrepared = try XCTUnwrap(
            f.slot.prescription?.slotAlternatives[1].prescription)

        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        // Edit Plan during the workout.
        s.plan.sets = 5
        s.plan.rir = 0
        s.plan.slotNotes = "B: seat 5"
        try finish(s, applySwaps: true, applyPlanEdits: true, hasPlanEdits: true)

        var expected = bPrepared
        expected.sets = 5
        expected.rir = 0
        expected.slotNotes = "B: seat 5"
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), expected)
        // B's own non-editable plan, not A's — no mixture.
        XCTAssertEqual(f.slot.prescription?.effortModeRaw, EffortMode.single.rawValue)
        XCTAssertEqual(f.slot.prescription?.warmupScheme?.name, "Machine ramp")
        XCTAssertEqual(f.slot.setTemplates.map(\.targetWeight), [55])
        XCTAssertEqual(f.slot.prescription?.rpe, 9, "untouched field keeps B's value")

        let demoted = try XCTUnwrap(
            f.slot.prescription?.slotAlternatives.first { $0.exerciseID == f.a.id })
        XCTAssertEqual(demoted.prescription, aBundle, "A unchanged by B's edits")
    }

    func testUpdateRoutineWithoutApplyAllIgnoresMidWorkoutEdits() throws {
        let f = fixture()
        let bPrepared = try XCTUnwrap(
            f.slot.prescription?.slotAlternatives[1].prescription)
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        s.plan.sets = 7
        try finish(s, applySwaps: true, applyPlanEdits: false, hasPlanEdits: true)

        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), bPrepared)
    }

    /// B's plan changes without its replacement: the edits were made to B's
    /// plan and go to B's alternative — never onto A's primary plan.
    func testPlanEditsOnASwitchedSlotDoNotMixIntoTheUnswappedPrimary() throws {
        let f = fixture()
        let before = dump(f.slot)
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        s.plan.sets = 7
        try finish(s, applySwaps: false, applyPlanEdits: true, hasPlanEdits: true)

        XCTAssertEqual(f.slot.exercise?.id, f.a.id)
        XCTAssertEqual(dump(f.slot), before)
        XCTAssertEqual(
            f.slot.prescription?.slotAlternatives[1].prescription.sets, 7)
    }

    func testApplyPlanEditsOnAnUnswitchedSlotChangesOnlyTheEditedFields() throws {
        let f = fixture()
        let before = SlotPlanBundle.capture(from: f.slot)
        let altsBefore = f.slot.prescription?.alternativesData
        var s = try start(f.routine)
        s.plan.sets = 6
        s.plan.tempo = "4-0-1-0"
        try finish(s, applySwaps: false, applyPlanEdits: true, hasPlanEdits: true)

        var expected = before
        expected.sets = 6
        expected.tempo = "4-0-1-0"
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), expected)
        XCTAssertEqual(f.slot.prescription?.alternativesData, altsBefore)
        XCTAssertEqual(f.slot.exercise?.id, f.a.id)
    }

    // ==================================================
    // MARK: - Generic switch
    // ==================================================

    func testGenericKeepPromotesTheKeptPlanAndAppendsAEnabled() throws {
        let f = fixture()
        let aBundle = SlotPlanBundle.capture(from: f.slot)
        let c = exercise("Incline Bench Press")
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: c, via: .keepCurrentPlan)
        XCTAssertNil(s.plan.appliedAlternativeID)
        let switchTime = SlotPlanBundle.switchTimePlan(of: s.planEx)
        try finish(s, applySwaps: true)

        XCTAssertEqual(f.slot.exercise?.id, c.id)
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), switchTime)
        // Keep = A's prescription values carried onto C, no per-set overrides.
        XCTAssertEqual(f.slot.prescription?.sets, 4)
        XCTAssertEqual(f.slot.prescription?.repMax, 8)
        XCTAssertTrue(f.slot.setTemplates.isEmpty)

        let alts = try XCTUnwrap(f.slot.prescription?.slotAlternatives)
        XCTAssertEqual(alts.count, 4, "A appended")
        XCTAssertEqual(alts.last?.exerciseID, f.a.id)
        XCTAssertEqual(alts.last?.isEnabled, true)
        XCTAssertEqual(alts.last?.prescription, aBundle)
        XCTAssertEqual(alts[1].exerciseID, f.b.id, "existing rows untouched")
    }

    func testGenericResetPromotesTheResetPlan() throws {
        let f = fixture()
        let aBundle = SlotPlanBundle.capture(from: f.slot)
        let c = exercise("Incline Bench Press")
        var s = try start(f.routine)
        let expectedReset = ExerciseSwitchPlanAdapter.outcome(
            choice: .resetPlan, current: s.plan, oldMode: .strength,
            newMode: .strength, resetSource: .appDefaults(for: .strength)
        ).sessionPlan
        switchSlot(&s, from: f.a, to: c, via: .resetPlan)
        try finish(s, applySwaps: true)

        XCTAssertEqual(f.slot.exercise?.id, c.id)
        XCTAssertEqual(f.slot.prescription?.sets, expectedReset.sets)
        XCTAssertEqual(f.slot.prescription?.repMin, expectedReset.repMin)
        XCTAssertEqual(f.slot.prescription?.repMax, expectedReset.repMax)
        XCTAssertNil(f.slot.prescription?.warmupScheme, "reset clears warm-ups")
        XCTAssertEqual(f.slot.prescription?.techniquePlans.count, 0)
        XCTAssertNil(f.slot.templateNotes)
        XCTAssertEqual(
            f.slot.prescription?.slotAlternatives.last?.prescription, aBundle)
    }

    /// Picking a prepared alternative's exercise through the generic picker is
    /// a **generic** switch: B gets the plan the Keep choice produced, never
    /// its prepared payload — and B's prepared row does not survive as a
    /// "Same as this exercise" alternative of itself.
    func testGenericKeepOfAPreparedExerciseUsesTheKeptPlanAndRemovesBsRow() throws {
        let f = fixture()
        let aBundle = SlotPlanBundle.capture(from: f.slot)
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: .keepCurrentPlan)
        XCTAssertNil(s.plan.appliedAlternativeID, "generic picker records no provenance")
        let keptPlan = SlotPlanBundle.switchTimePlan(of: s.planEx)
        try finish(s, applySwaps: true)

        XCTAssertEqual(f.slot.exercise?.id, f.b.id)
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), keptPlan)
        XCTAssertEqual(f.slot.prescription?.sets, 4, "kept plan, not prepared 3")
        XCTAssertNotEqual(f.slot.prescription?.warmupScheme?.name, "Machine ramp")
        assertGenericDemotion(f, aBundle: aBundle)
    }

    func testGenericResetOfAPreparedExerciseUsesTheResetPlanAndRemovesBsRow() throws {
        let f = fixture()
        let aBundle = SlotPlanBundle.capture(from: f.slot)
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: .resetPlan)
        XCTAssertNil(s.plan.appliedAlternativeID)
        let resetPlan = SlotPlanBundle.switchTimePlan(of: s.planEx)
        try finish(s, applySwaps: true)

        XCTAssertEqual(f.slot.exercise?.id, f.b.id)
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), resetPlan)
        // The default set count can coincide with B's prepared 3, so compare
        // the whole plan: the prepared payload has a tempo, notes, a warm-up
        // and an override the reset plan does not.
        XCTAssertNotEqual(SlotPlanBundle.capture(from: f.slot), bPayload().normalized(),
                          "not the prepared payload")
        XCTAssertNil(f.slot.templateNotes)
        XCTAssertNil(f.slot.prescription?.warmupScheme, "reset carries no warm-up")
        XCTAssertTrue(f.slot.setTemplates.isEmpty)
        assertGenericDemotion(f, aBundle: aBundle)
    }

    /// After a generic promotion of B: no row for B, A appended and enabled
    /// with its complete plan, the other rows untouched.
    private func assertGenericDemotion(
        _ f: Fixture, aBundle: AlternativePrescriptionPayload,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let alts = f.slot.prescription?.slotAlternatives ?? []
        XCTAssertFalse(alts.contains { $0.exerciseID == f.b.id },
                       "the primary is never its own alternative", file: file, line: line)
        XCTAssertEqual(alts.map(\.exerciseName),
                       ["Dumbbell Bench Press", "Push-Up", "Barbell Bench Press"],
                       file: file, line: line)
        XCTAssertEqual(alts.last?.exerciseID, f.a.id, file: file, line: line)
        XCTAssertEqual(alts.last?.isEnabled, true, file: file, line: line)
        XCTAssertNil(alts.last?.note, file: file, line: line)
        XCTAssertEqual(alts.last?.prescription, aBundle, file: file, line: line)
        XCTAssertFalse(alts[1].isEnabled, "Push-Up keeps its disabled state",
                       file: file, line: line)
    }

    // ==================================================
    // MARK: - Provenance
    // ==================================================

    func testOnlyThePreparedActionRecordsProvenance() {
        let alt = SlotAlternative(exerciseID: UUID(), exerciseName: "B")
        XCTAssertEqual(PendingSwapPlan.useAlternative(alt).appliedAlternativeID, alt.id)
        XCTAssertNil(PendingSwapPlan.keepCurrentPlan.appliedAlternativeID)
        XCTAssertNil(PendingSwapPlan.resetPlan.appliedAlternativeID)
    }

    func testPreparedThenGenericSwitchClearsProvenance() throws {
        let f = fixture()
        let c = exercise("Incline Bench Press")
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        XCTAssertNotNil(s.plan.appliedAlternativeID)
        switchSlot(&s, from: f.b, to: c, via: .keepCurrentPlan)
        XCTAssertNil(s.plan.appliedAlternativeID)
        XCTAssertEqual(s.plan.alternatives.count, 3, "frozen list still carried")

        try finish(s, applySwaps: true)
        // C was not promoted with B's prepared plan.
        XCTAssertEqual(f.slot.exercise?.id, c.id)
        XCTAssertNotEqual(f.slot.prescription?.warmupScheme?.name, "Machine ramp")
        XCTAssertTrue(
            f.slot.prescription?.slotAlternatives.contains { $0.exerciseID == f.b.id }
                ?? false)
    }

    /// Save & Exit writes `sessionPlans` to `AppState.sessionPlansJSON`; a cold
    /// resume decodes them. Provenance must ride along and still drive the
    /// prepared promotion.
    func testProvenanceSurvivesSaveAndExitAndColdResume() throws {
        let f = fixture()
        let bPrepared = try XCTUnwrap(
            f.slot.prescription?.slotAlternatives[1].prescription)
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))

        let key = s.planEx.routineSlotID.uuidString
        let json = try JSONEncoder().encode([key: s.plan])
        let restored = try JSONDecoder().decode([String: SessionPlan].self, from: json)
        s.plan = try XCTUnwrap(restored[key])
        XCTAssertEqual(s.plan.appliedAlternativeID, f.bAlternativeID)

        try finish(s, applySwaps: true)
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), bPrepared)
    }

    // ==================================================
    // MARK: - Backward compatibility
    // ==================================================

    func testOldPayloadWithoutNewKeysDecodes() throws {
        let json = #"""
            {"version":1,"alternatives":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF",
             "order":0,"isEnabled":true,"exerciseID":"7F9619FF-8B86-D011-B42D-00CF4FC964FF",
             "exerciseName":"B","prescription":{"sets":3,"usesDuration":false,
             "warmupSteps":[{"order":0,"kind":"percentage","reps":5}],
             "techniques":[{"order":0,"type":"dropset","dropPercent":20}]}}]}
            """#
        let alts = SlotAlternatives.decode(from: Data(json.utf8))
        let plan = try XCTUnwrap(alts.first?.prescription)
        XCTAssertEqual(plan.sets, 3)
        XCTAssertNil(plan.warmupSchemeName)
        XCTAssertNil(plan.setTemplates)
        XCTAssertEqual(plan.warmupSteps.count, 1)
        XCTAssertEqual(plan.techniques.first?.dropPercent, 20)
        XCTAssertNil(plan.techniques.first?.repMin)
    }

    func testOldTechniqueSnapshotWithoutNewKeysDecodes() throws {
        let json = #"[{"order":0,"type":"restPause","rounds":3,"restSeconds":15}]"#
        let decoded = try JSONDecoder().decode(
            [TechniquePlanSnapshot].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.rounds, 3)
        XCTAssertNil(decoded.first?.repMin)
        XCTAssertNil(decoded.first?.repMax)
        XCTAssertNil(decoded.first?.durationSeconds)
    }

    func testOldSessionPlanWithoutProvenanceDecodes() throws {
        let json = #"{"sets":3,"usesDuration":false}"#
        let plan = try JSONDecoder().decode(SessionPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.sets, 3)
        XCTAssertNil(plan.appliedAlternativeID)
    }

    func testNewPayloadFieldsRoundTripThroughTheCodec() throws {
        let alt = SlotAlternative(
            exerciseID: UUID(), exerciseName: "A", prescription: bPayload())
        let decoded = SlotAlternatives.decode(from: SlotAlternatives.encode([alt]))
        XCTAssertEqual(decoded.first?.prescription, bPayload().normalized())
        XCTAssertEqual(decoded.first?.prescription.setTemplates?.first?.targetWeight, 55)
        XCTAssertEqual(decoded.first?.prescription.warmupSchemeName, "Machine ramp")
        XCTAssertEqual(decoded.first?.prescription.techniques.first?.repMin, 12)
    }

    func testAPayloadWithoutNewFieldsEncodesWithoutTheirKeys() throws {
        let alt = SlotAlternative(
            exerciseID: UUID(), exerciseName: "A",
            prescription: AlternativePrescriptionPayload(sets: 3))
        let data = try XCTUnwrap(SlotAlternatives.encode([alt]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("setTemplates"))
        XCTAssertFalse(text.contains("warmupSchemeName"))
    }

    // ==================================================
    // MARK: - Shared object safety
    // ==================================================

    func testASharedWarmupSchemeOnAnotherSlotIsUntouched() throws {
        let f = fixture()
        let shared = try XCTUnwrap(f.slot.prescription?.warmupScheme)
        // A second slot that (legally, per `.nullify`) shares A's scheme.
        let other = exercise("Overhead Press")
        let re2 = RoutineExercise(exercise: other, order: 1, setTemplates: [])
        let p2 = SlotPrescription(sets: 3)
        context.insert(re2)
        context.insert(p2)
        p2.warmupScheme = shared
        re2.prescription = p2
        f.routine.blocks.first?.exercises.append(re2)
        try context.save()
        let stepsBefore = shared.steps.map(\.order).sorted()

        var s = try start(f.routine, slot: 0)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        try finish(s, applySwaps: true)

        XCTAssertNotNil(p2.warmupScheme, "other slot keeps its warm-up")
        XCTAssertEqual(p2.warmupScheme?.persistentModelID, shared.persistentModelID)
        XCTAssertEqual(p2.warmupScheme?.name, "Heavy ramp")
        XCTAssertEqual(p2.warmupScheme?.steps.map(\.order).sorted(), stepsBefore)
        XCTAssertNotEqual(
            f.slot.prescription?.warmupScheme?.persistentModelID,
            shared.persistentModelID,
            "the promoted slot gets its own scheme, never the shared one")
    }

    func testReplacedChildrenAreDeletedNotOrphaned() throws {
        let f = fixture()
        let techniquesBefore = try context.fetchCount(FetchDescriptor<TechniquePlan>())
        let templatesBefore = try context.fetchCount(FetchDescriptor<SetTemplate>())
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        try finish(s, applySwaps: true)

        // A had 2 techniques / 2 overrides; B's plan has 1 / 1. A's now live
        // only inside the alternative payload (a value), so the rows are gone.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TechniquePlan>()),
                       techniquesBefore - 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SetTemplate>()),
                       templatesBefore - 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WarmupScheme>()), 1)
    }

    // ==================================================
    // MARK: - Plain finish
    // ==================================================

    func testPlainFinishLeavesTheRoutineUntouched() throws {
        let f = fixture()
        let before = dump(f.slot)
        let altsBefore = f.slot.prescription?.alternativesData
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        s.plan.sets = 9
        try finish(s, applySwaps: false, applyPlanEdits: false, hasPlanEdits: true)

        XCTAssertEqual(f.slot.exercise?.id, f.a.id)
        XCTAssertEqual(dump(f.slot), before)
        XCTAssertEqual(f.slot.prescription?.alternativesData, altsBefore)
    }

    // ==================================================
    // MARK: - Regressions
    // ==================================================

    func testDuplicationAndTransferCarryTheDemotedPlanLosslessly() throws {
        let f = fixture()
        let aBundle = SlotPlanBundle.capture(from: f.slot)
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        try finish(s, applySwaps: true)

        // Duplication.
        let copy = RoutineDuplicator.duplicate(
            f.routine, among: [f.routine], in: context)
        let copiedSlot = try XCTUnwrap(copy.blocks.first?.exercises.first)
        XCTAssertEqual(
            copiedSlot.prescription?.slotAlternatives
                .first { $0.exerciseID == f.a.id }?.prescription,
            aBundle)

        // Transfer: export → JSON → import.
        let library = try context.fetch(FetchDescriptor<Exercise>())
        let document = RoutineTransfer.export(f.routine, exercises: library)
        let data = try RoutineTransfer.makeJSONEncoder().encode(document)
        let decoded = try RoutineTransfer.makeJSONDecoder().decode(
            RoutineTransferDocument.self, from: data)
        let routinesBefore = try context.fetch(FetchDescriptor<Routine>())
        _ = try RoutineTransfer.import(
            decoded, among: routinesBefore, exercises: library, in: context)
        let imported = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Routine>()).first {
                r in !routinesBefore.contains { $0.persistentModelID == r.persistentModelID }
            })
        let importedSlot = try XCTUnwrap(imported.blocks.first?.exercises.first)
        XCTAssertEqual(
            importedSlot.prescription?.slotAlternatives
                .first { $0.exerciseID == f.a.id }?.prescription,
            aBundle)
    }

    func testDeletingTheDemotedExercisePrunesOnlyItsAlternative() throws {
        let f = fixture()
        let workout = Workout(date: .now, items: [WorkoutItem(exercise: f.a, setLogs: [])])
        context.insert(workout)
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        try finish(s, applySwaps: true)

        ExerciseDeletionService.delete(f.a, in: context)

        XCTAssertEqual(f.slot.exercise?.id, f.b.id, "the slot (now B) survives")
        XCTAssertFalse(
            f.slot.prescription?.slotAlternatives.contains { $0.exerciseID == f.a.id }
                ?? true)
        XCTAssertEqual(workout.items.count, 1, "history is not deleted")
    }

    func testCardioPreparedSwapSwapsSegmentPlansAndDistance() throws {
        let tread = exercise("Treadmill", timeBased: true, cardio: true)
        let bike = exercise("Bike", timeBased: true, cardio: true)
        let re = RoutineExercise(exercise: tread, order: 0, setTemplates: [])
        context.insert(re)
        let p = SlotPrescription(
            sets: 1, durationMinSeconds: 1_800, durationMaxSeconds: 1_800,
            usesDuration: true, targetDistanceMeters: 5_000,
            targetDistanceUnitRaw: DistanceUnit.kilometers.rawValue)
        context.insert(p)
        p.setStructuredCardioPlan(try segments(300, 1_500))
        re.prescription = p
        let bikePlan = AlternativePrescriptionPayload(
            sets: 1, durationMinSeconds: 2_400, durationMaxSeconds: 2_400,
            usesDuration: true, targetDistanceMeters: 15_000,
            targetDistanceUnitRaw: DistanceUnit.kilometers.rawValue,
            cardioSegments: try segments(600, 1_800))
        p.setSlotAlternatives([
            SlotAlternative(exerciseID: bike.id, exerciseName: "Bike",
                            prescription: bikePlan)
        ])
        let block = RoutineBlock(order: 0, exercises: [re])
        context.insert(block)
        let r = Routine(name: "Cardio", blocks: [block])
        context.insert(r)
        try context.save()
        let treadDump = dump(re)
        let treadBundle = SlotPlanBundle.capture(from: re)

        var s = try start(r)
        switchSlot(&s, from: tread, to: bike, via: try preparedChoice(s, for: bike))
        try finish(s, applySwaps: true)

        XCTAssertEqual(re.exercise?.id, bike.id)
        XCTAssertEqual(re.prescription?.structuredCardioPlan, bikePlan.cardioSegments)
        XCTAssertEqual(re.prescription?.targetDistanceMeters, 15_000)
        XCTAssertEqual(
            re.prescription?.slotAlternatives.first?.prescription, treadBundle)

        var s2 = try start(r)
        switchSlot(&s2, from: bike, to: tread, via: try preparedChoice(s2, for: tread))
        try finish(s2, applySwaps: true)
        XCTAssertEqual(dump(re), treadDump)
    }

    /// History is the performed workout; Update Routine writes only routine
    /// objects.
    func testHistorySnapshotIsNotRewritten() throws {
        let f = fixture()
        let item = WorkoutItem(exercise: f.a, setLogs: [])
        item.templateNotesSnapshot = "performed note"
        item.techniquePlansSnapshotData = Data("[]".utf8)
        let workout = Workout(date: .now, items: [item])
        context.insert(workout)
        try context.save()

        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        try finish(s, applySwaps: true)

        XCTAssertEqual(item.exercise?.id, f.a.id)
        XCTAssertEqual(item.templateNotesSnapshot, "performed note")
        XCTAssertEqual(item.techniquePlansSnapshotData, Data("[]".utf8))
    }

    // ==================================================
    // MARK: - Cold resume (real persistence + rebuild path)
    // ==================================================

    /// What a switch writes and Save & Exit persists, through the app's own
    /// writers: `swapExercise`'s fresh `WorkoutItem` frozen by
    /// `WorkoutItemSnapshotWriter`, and `persistSessionPlans`'s JSON in
    /// `AppState.sessionPlansJSON`.
    private func saveAndExit(
        _ s: Session, switchedTo new: Exercise, routine r: Routine
    ) throws -> Workout {
        let item = WorkoutItem(exercise: new, setLogs: [])
        context.insert(item)
        WorkoutItemSnapshotWriter.populate(
            item, from: s.planEx, liveSwappedExercise: new, in: context)
        let workout = Workout(date: .now, routineID: r.id, items: [item])
        context.insert(workout)

        let appState = BootstrapRoot.fetchOrCreateAppState(in: context)
        let stringKeyed = [s.planEx.routineSlotID.uuidString: s.plan]
        appState.sessionPlansJSON = String(
            decoding: try JSONEncoder().encode(stringKeyed), as: UTF8.self)
        try context.save()
        return workout
    }

    /// Cold resume as `ActiveWorkoutView` performs it: rebuild the plan from
    /// the store (`WorkoutResumeService.rebuildPlan`), initialize the session
    /// plan from the rebuilt snapshot (`initializeSessionPlans`), then overlay
    /// the persisted plan (`restoreSessionPlansFromAppState`).
    private func coldResume(_ workout: Workout) throws -> Session {
        let rebuilt = try XCTUnwrap(
            WorkoutResumeService.rebuildPlan(for: workout, in: context))
        let planEx = try XCTUnwrap(rebuilt.blocks.first?.exercises.first)
        var plan = SlotPlanBundle.sessionBaseline(of: planEx)
            .with(alternatives: planEx.alternativesSnapshot)

        let appState = BootstrapRoot.fetchOrCreateAppState(in: context)
        let json = try XCTUnwrap(appState.sessionPlansJSON)
        let restored = try JSONDecoder().decode(
            [String: SessionPlan].self, from: Data(json.utf8))
        if let persisted = restored[planEx.routineSlotID.uuidString] {
            plan = persisted
        }
        return Session(planEx: planEx, plan: plan)
    }

    func testColdResumeKeepsPreparedProvenanceAndSwapsCorrectly() throws {
        let f = fixture()
        let aBundle = SlotPlanBundle.capture(from: f.slot)
        let bPrepared = try XCTUnwrap(
            f.slot.prescription?.slotAlternatives[1].prescription)

        var live = try start(f.routine)
        switchSlot(&live, from: f.a, to: f.b, via: try preparedChoice(live, for: f.b))
        XCTAssertEqual(live.plan.appliedAlternativeID, f.bAlternativeID)
        let workout = try saveAndExit(live, switchedTo: f.b, routine: f.routine)

        let resumed = try coldResume(workout)
        XCTAssertEqual(resumed.planEx.currentExerciseID, f.b.id)
        XCTAssertEqual(resumed.planEx.originalExerciseID, f.a.id)
        XCTAssertEqual(resumed.plan.appliedAlternativeID, f.bAlternativeID,
                       "provenance survives the cold resume")
        XCTAssertFalse(sessionPlanHasEdits(resumed.plan, for: resumed.planEx),
                       "a resumed switch is not a pending plan edit")

        try finish(resumed, applySwaps: true)

        XCTAssertEqual(f.slot.exercise?.id, f.b.id)
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), bPrepared)
        let alts = try XCTUnwrap(f.slot.prescription?.slotAlternatives)
        XCTAssertEqual(alts[1].exerciseID, f.a.id, "A at B's former position")
        XCTAssertEqual(alts[1].prescription, aBundle)
        XCTAssertFalse(alts.contains { $0.exerciseID == f.b.id })
    }

    func testColdResumeRecoversTheGenericSwitchTimePlanAndPromotesIt() throws {
        let f = fixture()
        let aBundle = SlotPlanBundle.capture(from: f.slot)
        let c = exercise("Incline Bench Press")

        var live = try start(f.routine)
        switchSlot(&live, from: f.a, to: c, via: .keepCurrentPlan)
        XCTAssertNil(live.plan.appliedAlternativeID)
        let liveSwitchTimePlan = SlotPlanBundle.switchTimePlan(of: live.planEx)
        // The kept plan is rich — effort progression, custom targets, A's
        // warm-ups and techniques (with the extended technique fields) — so
        // recovering it exactly is a real check of the resume path.
        XCTAssertEqual(liveSwitchTimePlan.effortModeRaw, EffortMode.progression.rawValue)
        XCTAssertEqual(liveSwitchTimePlan.warmupSteps.count, 2)
        XCTAssertEqual(liveSwitchTimePlan.techniques.first?.repMin, 6)
        let workout = try saveAndExit(live, switchedTo: c, routine: f.routine)

        let resumed = try coldResume(workout)
        XCTAssertEqual(resumed.planEx.currentExerciseID, c.id)
        XCTAssertNil(resumed.plan.appliedAlternativeID)
        XCTAssertEqual(SlotPlanBundle.switchTimePlan(of: resumed.planEx),
                       liveSwitchTimePlan,
                       "switch-time plan recovered exactly from the WorkoutItem")

        try finish(resumed, applySwaps: true)

        XCTAssertEqual(f.slot.exercise?.id, c.id)
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), liveSwitchTimePlan)
        let alts = try XCTUnwrap(f.slot.prescription?.slotAlternatives)
        XCTAssertEqual(alts.last?.exerciseID, f.a.id)
        XCTAssertEqual(alts.last?.isEnabled, true)
        XCTAssertEqual(alts.last?.prescription, aBundle)
    }

    // ==================================================
    // MARK: - Save Routine Changes sheet (cases A–F)
    // ==================================================

    /// Two slots: slot 0 is the fixture's A (switchable to prepared B), slot 1
    /// an unswitched Overhead Press (3 sets).
    private func twoSlotFixture() throws -> (Fixture, RoutineExercise) {
        let f = fixture()
        let ohp = exercise("Overhead Press")
        let re2 = RoutineExercise(exercise: ohp, order: 1, setTemplates: [])
        let p2 = SlotPrescription(sets: 3, repMin: 6, repMax: 8)
        context.insert(re2)
        context.insert(p2)
        re2.prescription = p2
        f.routine.blocks.first?.exercises.append(re2)
        try context.save()
        return (f, re2)
    }

    private struct SheetCase {
        var f: Fixture
        var re2: RoutineExercise
        var requests: [RoutineTemplateUpdate.SlotRequest]
        var rows: [RoutineChangeRow]
        var before0: SlotDump
        var before1: SlotDump
        var alts0Before: [SlotAlternative]
    }

    /// One case on a fresh store: optionally switch slot 0 A → prepared B,
    /// apply the case's session edits (B: 6 sets; Overhead Press: 5 sets), and
    /// build the sheet's rows exactly as the view does
    /// (`routineTemplateRequests` → `routineChangeRows`, original names looked
    /// up from the store).
    private func sheetCase(
        switchToB: Bool, editB: Bool, editOther: Bool
    ) throws -> SheetCase {
        let (f, re2) = try twoSlotFixture()
        let before0 = dump(f.slot)
        let before1 = dump(re2)
        let alts0Before = f.slot.prescription?.slotAlternatives ?? []
        var s0 = try start(f.routine, slot: 0)
        var s1 = try start(f.routine, slot: 1)
        if switchToB {
            switchSlot(&s0, from: f.a, to: f.b, via: try preparedChoice(s0, for: f.b))
        }
        if editB { s0.plan.sets = 6 }
        if editOther { s1.plan.sets = 5 }

        let exercises = [s0.planEx, s1.planEx]
        let requests = routineTemplateRequests(
            exercises: exercises,
            sessionPlans: [
                s0.planEx.routineSlotID: s0.plan, s1.planEx.routineSlotID: s1.plan,
            ])
        let rows = routineChangeRows(
            requests: requests, exercises: exercises,
            originalName: { id in
                try? self.context.fetch(
                    FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
                ).first?.name
            })
        return SheetCase(
            f: f, re2: re2, requests: requests, rows: rows,
            before0: before0, before1: before1, alts0Before: alts0Before)
    }

    /// What saving a selection wrote to the two slots.
    private struct Writes: Equatable {
        var slot0Exercise: String
        var slot0Sets: Int?
        /// Sets of B's alternative row, while B is still an alternative.
        var bAlternativeSets: Int?
        var slot1Sets: Int?
        /// Every stored plan field of the slot is exactly as before.
        var slot0Untouched: Bool
        var slot1Untouched: Bool
    }

    private func save(
        _ c: SheetCase, _ selected: Set<RoutineTemplateUpdate.PendingChange>
    ) throws -> Writes {
        try RoutineTemplateUpdate.apply(c.requests, selected: selected, in: context)
        return Writes(
            slot0Exercise: c.f.slot.exercise?.name ?? "",
            slot0Sets: c.f.slot.prescription?.sets,
            bAlternativeSets: c.f.slot.prescription?.slotAlternatives
                .first { $0.exerciseID == c.f.b.id }?.prescription.sets,
            slot1Sets: c.re2.prescription?.sets,
            slot0Untouched: dump(c.f.slot) == c.before0,
            slot1Untouched: dump(c.re2) == c.before1)
    }

    /// Saves the sheet as first presented: every row selected.
    private func saveAsPresented(_ c: SheetCase) throws -> Writes {
        let selection = RoutineChangeSelection(rows: c.rows)
        let request = try XCTUnwrap(selection.saveRequest)
        return try save(c, request.selectedChanges)
    }

    private let bench = "Barbell Bench Press"
    private let machine = "Machine Chest Press"
    private let replacementTitle = "Barbell Bench Press → Machine Chest Press"
    private let bPlanTitle = "Machine Chest Press plan changes"
    private let otherPlanTitle = "Overhead Press plan changes"

    /// B's prepared plan (3 sets) is still B's row; nothing written.
    private var nothingWritten: Writes {
        Writes(slot0Exercise: bench, slot0Sets: 4, bAlternativeSets: 3,
               slot1Sets: 3, slot0Untouched: true, slot1Untouched: true)
    }

    func testSheetCaseA_NothingChangedNeedsNoSheet() throws {
        let c = try sheetCase(switchToB: false, editB: false, editOther: false)
        XCTAssertEqual(c.rows, [], "no rows → the plain Finish confirmation")
        // The ordinary finish writes nothing.
        XCTAssertEqual(
            try save(c, FinishRequest.finishOnly.selectedChanges), nothingWritten)
    }

    func testSheetCaseB_OneUnswitchedPlanEdit() throws {
        let c = try sheetCase(switchToB: false, editB: false, editOther: true)
        XCTAssertEqual(c.rows.map(\.title), [otherPlanTitle])
        XCTAssertEqual(c.rows.map(\.label), [.planChanges(exercise: "Overhead Press")])
        var expected = nothingWritten
        expected.slot1Sets = 5
        expected.slot1Untouched = false
        XCTAssertEqual(try saveAsPresented(c), expected)
    }

    func testSheetCaseC_ReplacementOnly() throws {
        let c = try sheetCase(switchToB: true, editB: false, editOther: false)
        XCTAssertEqual(c.rows.map(\.title), [replacementTitle])
        XCTAssertEqual(c.rows.map(\.label), [.replacement(from: bench, to: machine)])
        XCTAssertEqual(
            try saveAsPresented(c),
            Writes(slot0Exercise: machine, slot0Sets: 3, bAlternativeSets: nil,
                   slot1Sets: 3, slot0Untouched: false, slot1Untouched: true))
    }

    func testSheetCaseD_ReplacementAndSwitchedPlanEdit() throws {
        let c = try sheetCase(switchToB: true, editB: true, editOther: false)
        XCTAssertEqual(c.rows.map(\.title), [replacementTitle, bPlanTitle])
        XCTAssertEqual(
            try saveAsPresented(c),
            Writes(slot0Exercise: machine, slot0Sets: 6, bAlternativeSets: nil,
                   slot1Sets: 3, slot0Untouched: false, slot1Untouched: true))
    }

    func testSheetCaseE_ReplacementAndUnrelatedEdit() throws {
        let c = try sheetCase(switchToB: true, editB: false, editOther: true)
        XCTAssertEqual(c.rows.map(\.title), [replacementTitle, otherPlanTitle])
        XCTAssertEqual(
            try saveAsPresented(c),
            Writes(slot0Exercise: machine, slot0Sets: 3, bAlternativeSets: nil,
                   slot1Sets: 5, slot0Untouched: false, slot1Untouched: false))
    }

    func testSheetCaseF_AllThreeInWorkoutOrder() throws {
        let c = try sheetCase(switchToB: true, editB: true, editOther: true)
        XCTAssertEqual(c.rows.map(\.title), [replacementTitle, bPlanTitle, otherPlanTitle])
        XCTAssertEqual(c.rows.map(\.change.kind), [.replacement, .planChanges, .planChanges])
        XCTAssertEqual(
            c.rows.map(\.change.routineExerciseID),
            [c.f.slot.persistentModelID, c.f.slot.persistentModelID,
             c.re2.persistentModelID])
    }

    /// Every row starts selected, and each toggles on its own — no row ever
    /// selects or deselects another.
    func testRowsStartSelectedAndToggleIndependently() throws {
        let c = try sheetCase(switchToB: true, editB: true, editOther: true)
        let fresh = RoutineChangeSelection(rows: c.rows)
        XCTAssertEqual(fresh.selected, Set(c.rows.map(\.id)), "all selected")
        XCTAssertTrue(fresh.canSave)

        for row in c.rows {
            var selection = fresh
            selection.toggle(row.id)
            XCTAssertFalse(selection.isSelected(row.id), row.title)
            for other in c.rows where other.id != row.id {
                XCTAssertTrue(selection.isSelected(other.id),
                              "\(row.title) changed \(other.title)")
            }
            selection.toggle(row.id)
            XCTAssertEqual(selection, fresh)
        }
    }

    /// Zero selected disables Save Selected Changes — it is not silently
    /// another action.
    func testZeroSelectedCannotSave() throws {
        let c = try sheetCase(switchToB: true, editB: true, editOther: true)
        var selection = RoutineChangeSelection(rows: c.rows)
        for row in c.rows { selection.toggle(row.id) }
        XCTAssertTrue(selection.selected.isEmpty)
        XCTAssertFalse(selection.canSave)
        XCTAssertNil(selection.saveRequest)

        selection.toggle(c.rows[2].id)
        XCTAssertEqual(selection.saveRequest, .saveSelected([c.rows[2].id]))
    }

    /// A new presentation regenerates the rows and selects them all again,
    /// whatever an earlier (cancelled) presentation had unchecked.
    func testEachPresentationStartsFullySelected() throws {
        let c = try sheetCase(switchToB: true, editB: true, editOther: true)
        var cancelled = RoutineChangeSelection(rows: c.rows)
        cancelled.toggle(c.rows[0].id)
        let first = RoutineChangesPresentation(rows: c.rows)
        let second = RoutineChangesPresentation(rows: c.rows)
        XCTAssertNotEqual(first.id, second.id, "a fresh sheet each time")
        XCTAssertEqual(
            RoutineChangeSelection(rows: second.rows).selected,
            Set(c.rows.map(\.id)))
    }

    /// Every one of the eight selections of case F writes exactly its rows.
    func testEverySelectionOfCaseFWritesExactlyItsRows() throws {
        for mask in 0..<8 {
            let replace = mask & 1 != 0
            let bPlan = mask & 2 != 0
            let otherPlan = mask & 4 != 0
            let c = try sheetCase(switchToB: true, editB: true, editOther: true)
            var selected = Set<RoutineTemplateUpdate.PendingChange>()
            if replace { selected.insert(c.rows[0].id) }
            if bPlan { selected.insert(c.rows[1].id) }
            if otherPlan { selected.insert(c.rows[2].id) }

            var expected = nothingWritten
            if replace {
                expected.slot0Exercise = machine
                expected.slot0Sets = bPlan ? 6 : 3
                expected.bAlternativeSets = nil
                expected.slot0Untouched = false
            } else if bPlan {
                // Plan only: A stays, B's row takes the edited plan.
                expected.bAlternativeSets = 6
            }
            if otherPlan {
                expected.slot1Sets = 5
                expected.slot1Untouched = false
            }
            XCTAssertEqual(try save(c, selected), expected, "selection \(mask)")
        }
    }

    /// Everything selected is the old Apply all: B's complete prepared plan
    /// with B's edits, A demoted whole into B's position, the other slot's
    /// edits — and nothing else.
    func testSelectingAllIsTheCompleteSave() throws {
        let c = try sheetCase(switchToB: true, editB: true, editOther: true)
        let aBundle = SlotPlanBundle.capture(from: c.f.slot)
        let otherBundle = SlotPlanBundle.capture(from: c.re2)
        _ = try saveAsPresented(c)

        var bExpected = c.alts0Before[1].prescription
        bExpected.sets = 6
        XCTAssertEqual(SlotPlanBundle.capture(from: c.f.slot), bExpected.normalized())
        let alts = c.f.slot.prescription?.slotAlternatives ?? []
        XCTAssertEqual(alts.map(\.exerciseName),
                       ["Dumbbell Bench Press", bench, "Push-Up"])
        XCTAssertEqual(alts[1].prescription, aBundle)
        var otherExpected = otherBundle
        otherExpected.sets = 5
        XCTAssertEqual(SlotPlanBundle.capture(from: c.re2), otherExpected.normalized())
    }

    /// Finish This Workout Only writes no routine change, whatever is pending.
    func testFinishThisWorkoutOnlyWritesNothing() throws {
        let c = try sheetCase(switchToB: true, editB: true, editOther: true)
        XCTAssertEqual(FinishRequest.finishOnly.selectedChanges, [])
        XCTAssertEqual(
            try save(c, FinishRequest.finishOnly.selectedChanges), nothingWritten)
        XCTAssertEqual(c.f.slot.prescription?.slotAlternatives, c.alts0Before)
    }

    /// A switch alone — prepared, Keep or Reset — is never counted as a plan
    /// edit, so case C (one replacement row) holds for every switch kind.
    func testASwitchAloneIsNeverAPlanEdit() throws {
        let f = fixture()
        for choice in [PendingSwapPlan.keepCurrentPlan, .resetPlan] {
            var s = try start(f.routine)
            switchSlot(&s, from: f.a, to: f.b, via: choice)
            XCTAssertFalse(sessionPlanHasEdits(s.plan, for: s.planEx), "\(choice)")
        }
        var s = try start(f.routine)
        switchSlot(&s, from: f.a, to: f.b, via: try preparedChoice(s, for: f.b))
        XCTAssertFalse(sessionPlanHasEdits(s.plan, for: s.planEx))
    }

    // ==================================================
    // MARK: - Alternative editor keeps the new fields
    // ==================================================

    /// The alternative editor's draft round trip must not strip a demoted
    /// primary's overrides or scheme name — editing A after demotion would
    /// otherwise silently lose them.
    func testAlternativeDraftRoundTripsTheNewFields() throws {
        let payload = bPayload().normalized()
        let draft = try AlternativeDraftStore(
            exerciseName: "B", trackingMode: .strength, equipmentType: nil,
            includesBodyweightInLoad: false, payload: payload)
        XCTAssertEqual(draft.payload(), payload)
    }

    // ==================================================
    // MARK: - Independent selection (replacement × plan changes)
    // ==================================================
    //
    // A switched slot offers "A → B" and "B plan changes" as two independent
    // rows. Each scenario below runs all four combinations.

    private enum SwitchKind {
        /// B chosen through the prepared-alternative action.
        case prepared
        /// An exercise that is not an alternative, chosen generically (Keep).
        case genericNew
        /// B — already a (disabled) alternative — chosen generically (Keep).
        case genericExisting
    }

    private struct SelectionRun {
        var f: Fixture
        var switched: Exercise
        var aBundle: AlternativePrescriptionPayload
        var aDump: SlotDump
        var altsBefore: [SlotAlternative]
        /// B's base plan: prepared payload or generic switch-time plan.
        var basePlan: AlternativePrescriptionPayload
        /// `basePlan` with this test's edits.
        var editedPlan: AlternativePrescriptionPayload
    }

    /// Switch A → B by `kind`, edit B's plan (6 sets, 14 reps max, a note),
    /// then save exactly the selected rows through
    /// `RoutineTemplateUpdate.apply(_:selected:in:)`.
    private func runSelection(
        _ kind: SwitchKind, replacement: Bool, plan: Bool
    ) throws -> SelectionRun {
        let f = fixture(bEnabled: kind != .genericExisting)
        let aBundle = SlotPlanBundle.capture(from: f.slot)
        let aDump = dump(f.slot)
        let altsBefore = f.slot.prescription?.slotAlternatives ?? []
        let switched = kind == .genericNew ? exercise("Incline Bench Press") : f.b

        var s = try start(f.routine)
        let choice: PendingSwapPlan =
            kind == .prepared ? try preparedChoice(s, for: f.b) : .keepCurrentPlan
        switchSlot(&s, from: f.a, to: switched, via: choice)
        let basePlan =
            kind == .prepared
            ? altsBefore[1].prescription : SlotPlanBundle.switchTimePlan(of: s.planEx)
        s.plan.sets = 6
        s.plan.repMax = 14
        s.plan.slotNotes = "B: edited"
        var edited = basePlan
        edited.sets = 6
        edited.repMax = 14
        edited.slotNotes = "B: edited"

        let request = RoutineTemplateUpdate.SlotRequest(
            planExercise: s.planEx, sessionPlan: s.plan,
            hasPlanEdits: sessionPlanHasEdits(s.plan, for: s.planEx))
        let rows = RoutineTemplateUpdate.pendingChanges(for: [request])
        XCTAssertEqual(rows.map(\.kind), [.replacement, .planChanges])
        let selected = rows.filter {
            $0.kind == .replacement ? replacement : plan
        }
        try RoutineTemplateUpdate.apply(
            [request], selected: Set(selected), in: context)

        return SelectionRun(
            f: f, switched: switched, aBundle: aBundle, aDump: aDump,
            altsBefore: altsBefore, basePlan: basePlan,
            editedPlan: edited.normalized())
    }

    /// Holds in every combination: no duplicate rows for any exercise, the
    /// primary is never its own alternative, and A's plan survives — as the
    /// untouched primary or as an alternative.
    private func assertSelectionInvariants(
        _ r: SelectionRun, file: StaticString = #filePath, line: UInt = #line
    ) {
        let alts = r.f.slot.prescription?.slotAlternatives ?? []
        XCTAssertEqual(Set(alts.map(\.exerciseID)).count, alts.count,
                       "no duplicate alternatives", file: file, line: line)
        XCTAssertFalse(alts.contains { $0.exerciseID == r.f.slot.exercise?.id },
                       "primary is not its own alternative", file: file, line: line)
        if r.f.slot.exercise?.id == r.f.a.id {
            XCTAssertEqual(dump(r.f.slot), r.aDump, "A untouched", file: file, line: line)
        } else {
            XCTAssertEqual(alts.first { $0.exerciseID == r.f.a.id }?.prescription,
                           r.aBundle, "A demoted whole", file: file, line: line)
        }
    }

    private func assertRoutineUnchanged(
        _ r: SelectionRun, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(r.f.slot.exercise?.id, r.f.a.id, file: file, line: line)
        XCTAssertEqual(dump(r.f.slot), r.aDump, file: file, line: line)
        XCTAssertEqual(r.f.slot.prescription?.slotAlternatives, r.altsBefore,
                       file: file, line: line)
    }

    /// Plan only, B already listed: A stays primary and B's row keeps its
    /// id, position, enabled state and note — only its plan changes.
    private func assertPlanSavedInPlace(
        _ r: SelectionRun, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(r.f.slot.exercise?.id, r.f.a.id, file: file, line: line)
        let alts = r.f.slot.prescription?.slotAlternatives ?? []
        XCTAssertEqual(alts.count, r.altsBefore.count, file: file, line: line)
        var expected = r.altsBefore
        expected[1].prescription = r.editedPlan
        XCTAssertEqual(alts, expected, file: file, line: line)
        XCTAssertEqual(alts[1].id, r.altsBefore[1].id, file: file, line: line)
        XCTAssertEqual(alts[1].order, 1, file: file, line: line)
        XCTAssertEqual(alts[1].isEnabled, r.altsBefore[1].isEnabled, file: file, line: line)
        XCTAssertEqual(alts[1].note, "when the rack is busy", file: file, line: line)
    }

    /// Replacement selected: B is primary with `plan`, B's row (if any) is
    /// gone, A is an alternative.
    private func assertPromoted(
        _ r: SelectionRun, with plan: AlternativePrescriptionPayload,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(r.f.slot.exercise?.id, r.switched.id, file: file, line: line)
        XCTAssertEqual(SlotPlanBundle.capture(from: r.f.slot), plan.normalized(),
                       file: file, line: line)
        let alts = r.f.slot.prescription?.slotAlternatives ?? []
        XCTAssertEqual(alts.filter { $0.exerciseID == r.f.a.id }.count, 1,
                       file: file, line: line)
    }

    // Prepared B

    func testPreparedSelectionNeither() throws {
        let r = try runSelection(.prepared, replacement: false, plan: false)
        assertRoutineUnchanged(r)
        assertSelectionInvariants(r)
    }

    func testPreparedSelectionPlanOnlyUpdatesBsRowInPlace() throws {
        let r = try runSelection(.prepared, replacement: false, plan: true)
        assertPlanSavedInPlace(r)
        XCTAssertEqual(r.f.slot.prescription?.slotAlternatives[1].prescription.warmupSchemeName,
                       "Machine ramp", "B's own unedited plan carried")
        XCTAssertEqual(r.f.slot.prescription?.slotAlternatives[1].prescription.setTemplates?.count, 1)
        assertSelectionInvariants(r)
    }

    func testPreparedSelectionReplacementOnlyUsesThePreparedPlan() throws {
        let r = try runSelection(.prepared, replacement: true, plan: false)
        assertPromoted(r, with: r.basePlan)
        let alts = r.f.slot.prescription?.slotAlternatives ?? []
        XCTAssertEqual(alts[1].exerciseID, r.f.a.id, "A takes B's position")
        assertSelectionInvariants(r)
    }

    func testPreparedSelectionBothUsesTheEditedPlan() throws {
        let r = try runSelection(.prepared, replacement: true, plan: true)
        assertPromoted(r, with: r.editedPlan)
        XCTAssertEqual(r.f.slot.prescription?.slotAlternatives[1].exerciseID, r.f.a.id)
        assertSelectionInvariants(r)
    }

    // Generic, B not an alternative

    func testGenericNewSelectionNeither() throws {
        let r = try runSelection(.genericNew, replacement: false, plan: false)
        assertRoutineUnchanged(r)
        assertSelectionInvariants(r)
    }

    func testGenericNewSelectionPlanOnlyCreatesOneEnabledAlternative() throws {
        let r = try runSelection(.genericNew, replacement: false, plan: true)
        XCTAssertEqual(r.f.slot.exercise?.id, r.f.a.id, "A remains primary")
        XCTAssertEqual(dump(r.f.slot), r.aDump)
        let alts = r.f.slot.prescription?.slotAlternatives ?? []
        XCTAssertEqual(Array(alts.prefix(3)), r.altsBefore, "existing rows untouched")
        let created = alts.filter { $0.exerciseID == r.switched.id }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(alts.last?.exerciseID, r.switched.id, "appended")
        XCTAssertEqual(created.first?.order, 3)
        XCTAssertEqual(created.first?.isEnabled, true)
        XCTAssertNil(created.first?.note)
        XCTAssertEqual(created.first?.exerciseName, "Incline Bench Press")
        XCTAssertEqual(created.first?.prescription, r.editedPlan, "complete edited plan")
        assertSelectionInvariants(r)
    }

    func testGenericNewSelectionReplacementOnlyUsesTheSwitchTimePlan() throws {
        let r = try runSelection(.genericNew, replacement: true, plan: false)
        assertPromoted(r, with: r.basePlan)
        let alts = r.f.slot.prescription?.slotAlternatives ?? []
        XCTAssertEqual(alts.count, 4)
        XCTAssertEqual(alts.last?.exerciseID, r.f.a.id)
        XCTAssertEqual(alts.last?.isEnabled, true)
        assertSelectionInvariants(r)
    }

    func testGenericNewSelectionBothUsesTheEditedPlan() throws {
        let r = try runSelection(.genericNew, replacement: true, plan: true)
        assertPromoted(r, with: r.editedPlan)
        XCTAssertEqual(r.f.slot.prescription?.slotAlternatives.last?.exerciseID, r.f.a.id)
        assertSelectionInvariants(r)
    }

    // Generic, B already an alternative (disabled, to prove state is kept)

    func testGenericExistingSelectionNeither() throws {
        let r = try runSelection(.genericExisting, replacement: false, plan: false)
        assertRoutineUnchanged(r)
        assertSelectionInvariants(r)
    }

    func testGenericExistingSelectionPlanOnlyUpdatesBsRowInPlace() throws {
        let r = try runSelection(.genericExisting, replacement: false, plan: true)
        assertPlanSavedInPlace(r)
        XCTAssertEqual(r.f.slot.prescription?.slotAlternatives[1].isEnabled, false)
        XCTAssertNotEqual(r.f.slot.prescription?.slotAlternatives[1].prescription,
                          r.altsBefore[1].prescription.normalized())
        XCTAssertEqual(r.f.slot.prescription?.slotAlternatives[1].prescription.sets, 6)
        assertSelectionInvariants(r)
    }

    func testGenericExistingSelectionReplacementOnlyUsesTheKeptPlanAndRemovesBsRow() throws {
        let r = try runSelection(.genericExisting, replacement: true, plan: false)
        assertPromoted(r, with: r.basePlan)
        XCTAssertNotEqual(SlotPlanBundle.capture(from: r.f.slot),
                          r.altsBefore[1].prescription.normalized(), "not the old payload")
        assertGenericDemotion(r.f, aBundle: r.aBundle)
        assertSelectionInvariants(r)
    }

    func testGenericExistingSelectionBothUsesTheEditedPlanAndRemovesBsRow() throws {
        let r = try runSelection(.genericExisting, replacement: true, plan: true)
        assertPromoted(r, with: r.editedPlan)
        assertGenericDemotion(r.f, aBundle: r.aBundle)
        assertSelectionInvariants(r)
    }

    // Rows

    func testPendingChangesListEachRowIndependently() throws {
        let (f, _) = try twoSlotFixture()
        var s0 = try start(f.routine, slot: 0)
        var s1 = try start(f.routine, slot: 1)
        func requests() -> [RoutineTemplateUpdate.SlotRequest] {
            [s0, s1].map {
                RoutineTemplateUpdate.SlotRequest(
                    planExercise: $0.planEx, sessionPlan: $0.plan,
                    hasPlanEdits: sessionPlanHasEdits($0.plan, for: $0.planEx))
            }
        }
        XCTAssertEqual(RoutineTemplateUpdate.pendingChanges(for: requests()), [])

        switchSlot(&s0, from: f.a, to: f.b, via: try preparedChoice(s0, for: f.b))
        XCTAssertEqual(RoutineTemplateUpdate.pendingChanges(for: requests()).map(\.kind),
                       [.replacement], "a switch alone is not a plan change")

        s0.plan.sets = 6
        s1.plan.sets = 5
        let rows = RoutineTemplateUpdate.pendingChanges(for: requests())
        XCTAssertEqual(rows.map(\.kind), [.replacement, .planChanges, .planChanges])
        XCTAssertEqual(rows.map(\.routineExerciseID),
                       [s0.planEx.routineExerciseID, s0.planEx.routineExerciseID,
                        s1.planEx.routineExerciseID])
    }

    /// Bench → B (replacement only) plus the other slot's plan: exactly those
    /// two rows are written — B's edits are not.
    func testSelectionAppliesExactlyTheSelectedRowsAcrossSlots() throws {
        let (f, re2) = try twoSlotFixture()
        let bPrepared = try XCTUnwrap(f.slot.prescription?.slotAlternatives[1].prescription)
        var s0 = try start(f.routine, slot: 0)
        var s1 = try start(f.routine, slot: 1)
        switchSlot(&s0, from: f.a, to: f.b, via: try preparedChoice(s0, for: f.b))
        s0.plan.sets = 6
        s1.plan.sets = 5
        let requests = [s0, s1].map {
            RoutineTemplateUpdate.SlotRequest(
                planExercise: $0.planEx, sessionPlan: $0.plan,
                hasPlanEdits: sessionPlanHasEdits($0.plan, for: $0.planEx))
        }
        let rows = RoutineTemplateUpdate.pendingChanges(for: requests)
        try RoutineTemplateUpdate.apply(
            requests, selected: [rows[0], rows[2]], in: context)

        XCTAssertEqual(f.slot.exercise?.id, f.b.id)
        XCTAssertEqual(SlotPlanBundle.capture(from: f.slot), bPrepared)
        XCTAssertEqual(re2.prescription?.sets, 5)
    }

}

private extension SessionPlan {
    /// What `ActiveWorkoutView.initializeSessionPlans` adds on top of the
    /// snapshot-built plan.
    func with(alternatives: [SlotAlternative]) -> SessionPlan {
        var copy = self
        copy.alternatives = alternatives
        return copy
    }
}
