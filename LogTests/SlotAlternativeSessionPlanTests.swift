import SwiftData
import XCTest

@testable import Log

/// Alternative Exercises Phase E — carrying a slot's prepared alternatives from
/// the routine into the session.
///
/// They travel three hops, and this file pins each one:
///
///     SlotPrescription.alternativesData      (authoring truth)
///              ↓  frozen by makePlan / rebuildPlan
///     PlanExercise.alternativesSnapshot      (the workout plan)
///              ↓  copied by initializeSessionPlans
///     SessionPlan.alternatives               (persisted in AppState JSON)
///
/// Two invariants run through all of it:
///
///  1. **Frozen, not referenced.** Once a workout starts, editing or deleting
///     the routine's alternatives cannot change what the session holds — the
///     converse of non-negotiable rule 4, and the same guarantee the
///     prescription snapshot already gives.
///  2. **No data is lost on the way.** Every field an alternative carries,
///     including warm-ups, techniques and a Cardio Plan, survives the freeze
///     and a Save & Exit → Resume round trip.
///
/// Nothing here asserts *behavior*: no switch sheet reads these yet (Phase F).
@MainActor
final class SlotAlternativeSessionPlanTests: SwiftDataTestHarness {

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

    private func cardioPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                CardioSegment(kind: .warmUp, durationSeconds: 300),
                CardioSegment(kind: .work, durationSeconds: 1_200),
            ])
        ])
    }

    /// A fully-loaded alternative: prescription fields, warm-ups, techniques,
    /// a Cardio Plan, a target distance, a usage note and a slot note.
    private func richAlternative(
        name: String = "Machine Chest Press",
        exerciseID: UUID = UUID(),
        order: Int = 0,
        enabled: Bool = true
    ) throws -> SlotAlternative {
        SlotAlternative(
            order: order,
            isEnabled: enabled,
            exerciseID: exerciseID,
            exerciseName: name,
            note: "when the rack is busy",
            prescription: AlternativePrescriptionPayload(
                sets: 3, repMin: 8, repMax: 12,
                restSecondsBetweenSets: 90, restSecondsAfterExercise: 120,
                rir: 2, tempo: "3-0-1-0",
                effortModeRaw: EffortMode.single.rawValue,
                targetDistanceMeters: 5_000,
                targetDistanceUnitRaw: DistanceUnit.kilometers.rawValue,
                warmupSteps: [
                    WarmupStepSnapshot(
                        order: 0, kind: .percentage, reps: 10,
                        percentOfWorking: 50, note: "bar only",
                        restSecondsAfter: 60)
                ],
                techniques: [
                    TechniquePlanSnapshot(
                        order: 0, type: .dropset, dropPercent: 20,
                        dropCount: 2, rounds: nil, restSeconds: 15,
                        partialRangeNote: nil, note: nil, reps: nil)
                ],
                cardioSegments: try cardioPlan(),
                slotNotes: "seat height 4"))
    }

    private func simpleAlternative(
        _ name: String, order: Int, enabled: Bool = true
    ) -> SlotAlternative {
        SlotAlternative(
            order: order, isEnabled: enabled, exerciseID: UUID(),
            exerciseName: name,
            prescription: AlternativePrescriptionPayload(
                sets: 3, repMin: 8, repMax: 12))
    }

    /// A one-slot routine whose prescription carries the given alternatives.
    @discardableResult
    private func routine(
        with alternatives: [SlotAlternative],
        slotNotes: String? = nil
    ) -> (Routine, SlotPrescription) {
        let ex = exercise("Barbell Bench Press")
        let p = SlotPrescription(sets: 4, repMin: 6, repMax: 10)
        context.insert(p)
        p.setSlotAlternatives(alternatives)

        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        re.templateNotes = slotNotes
        re.prescription = p
        context.insert(re)

        let block = RoutineBlock(order: 0, exercises: [re])
        context.insert(block)

        let r = Routine(name: "Upper A", blocks: [block])
        context.insert(r)
        return (r, p)
    }

    /// The frozen plan for a routine, built by the **real** start path.
    private func planExercise(for r: Routine) throws -> PlanExercise {
        let plan = StartWorkoutFromRoutineView.makePlan(from: r)
        return try XCTUnwrap(plan.blocks.first?.exercises.first)
    }

    /// What `ActiveWorkoutView.initializeSessionPlans` does for one slot.
    private func sessionPlan(for ex: PlanExercise) -> SessionPlan {
        guard let snap = ex.prescriptionSnapshot else {
            var p = SessionPlan()
            p.slotNotes = ex.templateNotesSnapshot
            p.alternatives = ex.alternativesSnapshot
            return p
        }
        return SessionPlan(
            from: snap, notes: ex.templateNotesSnapshot,
            alternatives: ex.alternativesSnapshot)
    }

    // ==================================================
    // MARK: - 1. Routine → SessionPlan
    // ==================================================

    func testSlotWithNoAlternativesFreezesAnEmptyList() throws {
        let (r, p) = routine(with: [])
        XCTAssertNil(p.alternativesData)

        let planEx = try planExercise(for: r)

        XCTAssertEqual(planEx.alternativesSnapshot, [])
        XCTAssertEqual(sessionPlan(for: planEx).alternatives, [])
        XCTAssertNil(
            sessionPlan(for: planEx).alternativesSnapshot,
            "no alternatives stores nil, so the plan encodes as it did before")
    }

    func testOneAlternativeIsCarriedIntoTheSessionPlan() throws {
        let authored = try richAlternative()
        let (r, _) = routine(with: [authored])

        let planEx = try planExercise(for: r)

        XCTAssertEqual(planEx.alternativesSnapshot, [authored])
        XCTAssertEqual(sessionPlan(for: planEx).alternatives, [authored])
    }

    func testEveryAlternativeIsCarried() throws {
        let list = [
            try richAlternative(order: 0),
            simpleAlternative("DB Bench Press", order: 1),
            simpleAlternative("Push-Up", order: 2, enabled: false),
        ]
        let (r, _) = routine(with: list)

        XCTAssertEqual(try planExercise(for: r).alternativesSnapshot, list)
    }

    func testOrderingIsNormalizedAndStable() throws {
        let (r, _) = routine(with: [
            simpleAlternative("third", order: 30),
            simpleAlternative("first", order: 10),
            simpleAlternative("second", order: 20),
        ])

        let frozen = try planExercise(for: r).alternativesSnapshot

        XCTAssertEqual(
            frozen.map(\.exerciseName), ["first", "second", "third"])
        XCTAssertEqual(frozen.map(\.order), [0, 1, 2])
    }

    /// Disabled alternatives ride along. Filtering them out of the switch sheet
    /// is Phase F's decision, and it cannot make it from data it never got.
    func testDisabledAlternativesArePreserved() throws {
        let (r, _) = routine(with: [
            simpleAlternative("on", order: 0),
            simpleAlternative("off", order: 1, enabled: false),
        ])

        XCTAssertEqual(
            try planExercise(for: r).alternativesSnapshot.map(\.isEnabled),
            [true, false])
    }

    func testEveryFieldOfAnAlternativeSurvivesTheFreeze() throws {
        let exerciseID = UUID()
        let authored = try richAlternative(exerciseID: exerciseID)
        let (r, _) = routine(with: [authored])

        let frozen = try XCTUnwrap(
            try planExercise(for: r).alternativesSnapshot.first)

        XCTAssertEqual(frozen.id, authored.id)
        XCTAssertEqual(frozen.order, 0)
        XCTAssertTrue(frozen.isEnabled)
        XCTAssertEqual(frozen.exerciseID, exerciseID)
        XCTAssertEqual(frozen.exerciseName, "Machine Chest Press")
        XCTAssertEqual(frozen.note, "when the rack is busy")

        let p = frozen.prescription
        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
        XCTAssertEqual(p.restSecondsBetweenSets, 90)
        XCTAssertEqual(p.restSecondsAfterExercise, 120)
        XCTAssertEqual(p.rir, 2)
        XCTAssertEqual(p.tempo, "3-0-1-0")
        XCTAssertEqual(p.effortModeRaw, EffortMode.single.rawValue)
        XCTAssertEqual(p.targetDistanceMeters, 5_000)
        XCTAssertEqual(p.targetDistanceUnitRaw, "km")
        XCTAssertEqual(p.slotNotes, "seat height 4")
        XCTAssertEqual(p.warmupSteps.count, 1)
        XCTAssertEqual(p.warmupSteps.first?.percentOfWorking, 50)
        XCTAssertEqual(p.techniques.count, 1)
        XCTAssertEqual(p.techniques.first?.type, .dropset)
        XCTAssertEqual(
            p.cardioSegments, authored.prescription.cardioSegments,
            "including the segment ids a checklist would tick")
        XCTAssertEqual(p.cardioSegments?.expandedCount, 2)
    }

    /// A corrupt column costs the alternatives, never the workout — the Phase C
    /// accessor's tolerance, inherited by the freeze.
    func testCorruptAlternativesDataFreezesAsEmpty() throws {
        let (r, p) = routine(with: [try richAlternative()])
        p.alternativesData = Data([0x00, 0x01, 0x02, 0xFF])

        let planEx = try planExercise(for: r)

        XCTAssertEqual(planEx.alternativesSnapshot, [])
        XCTAssertEqual(sessionPlan(for: planEx).alternatives, [])
    }

    /// The slot's own notes and the alternative's are different fields and must
    /// not be crossed.
    func testSlotNotesAndAlternativeNotesStaySeparate() throws {
        let (r, _) = routine(
            with: [try richAlternative()], slotNotes: "primary slot note")

        let planEx = try planExercise(for: r)
        let sp = sessionPlan(for: planEx)

        XCTAssertEqual(sp.slotNotes, "primary slot note")
        XCTAssertEqual(sp.alternatives.first?.prescription.slotNotes, "seat height 4")
        XCTAssertEqual(sp.alternatives.first?.note, "when the rack is busy")
    }

    // ==================================================
    // MARK: - 2. Frozen, not referenced
    // ==================================================

    func testEditingTheRoutineAfterStartDoesNotChangeTheSession() throws {
        let authored = try richAlternative()
        let (r, p) = routine(with: [authored])
        let planEx = try planExercise(for: r)
        let sp = sessionPlan(for: planEx)

        // The user edits the routine while the workout is in flight.
        SlotAlternativeAuthoring.update(id: authored.id, in: p) {
            $0.exerciseName = "Something Else"
            $0.isEnabled = false
            $0.prescription.sets = 99
        }
        SlotAlternativeAuthoring.append(
            exerciseID: UUID(), exerciseName: "Added later",
            prescription: AlternativePrescriptionPayload(), to: p)
        try context.save()

        XCTAssertEqual(planEx.alternativesSnapshot, [authored])
        XCTAssertEqual(sp.alternatives, [authored])
        XCTAssertEqual(
            p.slotAlternatives.count, 2, "the routine did change — only it")
    }

    func testDeletingRoutineAlternativesAfterStartDoesNotChangeTheSession() throws {
        let authored = try richAlternative()
        let (r, p) = routine(with: [authored])
        let planEx = try planExercise(for: r)
        let sp = sessionPlan(for: planEx)

        p.clearSlotAlternatives()
        try context.save()

        XCTAssertEqual(planEx.alternativesSnapshot, [authored])
        XCTAssertEqual(sp.alternatives, [authored])
        XCTAssertEqual(p.slotAlternatives, [])
    }

    /// Editing the slot's *own* prescription cannot reach an alternative's:
    /// they are separate payloads, and the session froze both.
    func testEditingThePrimaryPrescriptionDoesNotChangeAlternatives() throws {
        let authored = try richAlternative()
        let (r, p) = routine(with: [authored])
        let sp = sessionPlan(for: try planExercise(for: r))

        p.sets = 99
        p.repMin = 1
        p.repMax = 2
        p.targetDistanceMeters = 42_195
        p.setStructuredCardioPlan(try cardioPlan())
        try context.save()

        XCTAssertEqual(sp.alternatives.first?.prescription.sets, 3)
        XCTAssertEqual(sp.alternatives.first?.prescription.repMin, 8)
        XCTAssertEqual(
            sp.alternatives.first?.prescription.targetDistanceMeters, 5_000)
        XCTAssertEqual(
            sp.alternatives.first?.prescription.cardioSegments,
            authored.prescription.cardioSegments)
    }

    // ==================================================
    // MARK: - 3. Save & Exit / Resume
    // ==================================================

    /// `persistSessionPlans` encodes `[String: SessionPlan]` into
    /// `AppState.sessionPlansJSON`; `restoreSessionPlansFromAppState` decodes
    /// it. This is that round trip.
    func testSessionPlansRoundTripThroughTheAppStateJSON() throws {
        let authored = try richAlternative()
        let (r, _) = routine(with: [authored])
        let planEx = try planExercise(for: r)
        let slotID = planEx.routineSlotID
        let plans = [slotID.uuidString: sessionPlan(for: planEx)]

        let data = try JSONEncoder().encode(plans)
        let decoded = try JSONDecoder().decode(
            [String: SessionPlan].self, from: data)

        let restored = try XCTUnwrap(decoded[slotID.uuidString])
        XCTAssertEqual(restored.alternatives, [authored])
        XCTAssertEqual(
            restored.alternatives.first?.prescription.cardioSegments,
            authored.prescription.cardioSegments)
        XCTAssertEqual(
            restored.alternatives.first?.prescription.warmupSteps.count, 1)
        XCTAssertEqual(
            restored.alternatives.first?.prescription.techniques.count, 1)
    }

    /// The compatibility case that decides the shape of the field: a
    /// `SessionPlan` persisted by **any earlier build** has no alternatives key
    /// at all. It must decode — losing the whole session's plan edits to a
    /// missing key would be a far worse bug than having no alternatives.
    func testAnOlderSavedSessionPlanDecodesWithNoAlternatives() throws {
        let legacy = Data(
            """
            {"sets":3,"repMin":8,"repMax":12,"restSecondsBetweenSets":90,
             "usesDuration":false,"slotNotes":"cue"}
            """.utf8)

        let decoded = try JSONDecoder().decode(SessionPlan.self, from: legacy)

        XCTAssertEqual(decoded.alternatives, [])
        XCTAssertNil(decoded.alternativesSnapshot)
        XCTAssertEqual(decoded.sets, 3)
        XCTAssertEqual(decoded.slotNotes, "cue")
    }

    /// A plan with no alternatives must encode exactly as it did before the
    /// field existed, so nothing about the persisted format changes for the
    /// ~100% of slots that never use the feature.
    func testAPlanWithNoAlternativesEncodesWithoutTheKey() throws {
        let plan = sessionPlan(for: try planExercise(for: routine(with: []).0))

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(plan)) as? [String: Any])

        XCTAssertNil(json["alternativesSnapshot"])
    }

    /// Cold resume rebuilds the plan from the routine
    /// (`WorkoutResumeService`), which mirrors `makePlan` — so a resumed
    /// session that never persisted a plan still has its alternatives.
    func testResumeRebuildCarriesAlternatives() throws {
        let authored = try richAlternative()
        let (r, _) = routine(with: [authored])
        let workout = Workout(date: .now, routineID: r.id, items: [])
        context.insert(workout)
        try context.save()

        let rebuilt = try XCTUnwrap(
            WorkoutResumeService.rebuildPlan(for: workout, in: context))
        let planEx = try XCTUnwrap(rebuilt.blocks.first?.exercises.first)

        XCTAssertEqual(planEx.alternativesSnapshot, [authored])
    }

    /// The persisted `SessionPlan` — not the rebuilt plan — is what a resumed
    /// session ends up with, because `restoreSessionPlansFromAppState` overlays
    /// `initializeSessionPlans`. Reproduced here in order.
    func testPersistedSessionPlanWinsOverTheRebuiltRoutineOnResume() throws {
        let authored = try richAlternative()
        let (r, p) = routine(with: [authored])
        let workout = Workout(date: .now, routineID: r.id, items: [])
        context.insert(workout)

        // Save & Exit: the session's plans are written.
        let planEx = try planExercise(for: r)
        let slotID = planEx.routineSlotID
        let persisted = try JSONEncoder().encode(
            [slotID.uuidString: sessionPlan(for: planEx)])

        // The user then edits the routine before resuming.
        p.clearSlotAlternatives()
        try context.save()

        // Cold resume: rebuild, initialize, then overlay.
        let rebuilt = try XCTUnwrap(
            WorkoutResumeService.rebuildPlan(for: workout, in: context))
        var sessionPlans: [UUID: SessionPlan] = [:]
        for block in rebuilt.blocks {
            for ex in block.exercises {
                sessionPlans[ex.routineSlotID] = sessionPlan(for: ex)
            }
        }
        let restored = try JSONDecoder().decode(
            [String: SessionPlan].self, from: persisted)
        for (key, plan) in restored {
            if let id = UUID(uuidString: key) { sessionPlans[id] = plan }
        }

        XCTAssertEqual(
            sessionPlans[slotID]?.alternatives, [authored],
            "the session resumes with what it froze, not with the edited routine")
    }

    // ==================================================
    // MARK: - 4. No behavior change
    // ==================================================

    /// A routine with no alternatives must produce the same plan it produced
    /// before Phase E — the regression the whole feature is gated on.
    func testARoutineWithoutAlternativesBuildsTheSamePlan() throws {
        let (r, _) = routine(with: [])

        let planEx = try planExercise(for: r)

        XCTAssertEqual(planEx.alternativesSnapshot, [])
        XCTAssertEqual(planEx.name, "Barbell Bench Press")
        XCTAssertEqual(planEx.prescriptionSnapshot?.sets, 4)
        XCTAssertEqual(planEx.prescriptionSnapshot?.repMin, 6)
        XCTAssertEqual(planEx.prescriptionSnapshot?.repMax, 10)
        XCTAssertEqual(planEx.warmupStepsSnapshot.count, 0)
        XCTAssertEqual(planEx.techniquePlansSnapshot.count, 0)
    }

    /// Alternatives belong to the slot, not to the exercise in it, so the
    /// switch apply path carries them across the adapter's fresh plan. (What a
    /// switch *offers* is Phase F; this only pins that the data survives.)
    func testAlternativesSurviveTheSwitchApplyPath() throws {
        let authored = try richAlternative()
        let (r, _) = routine(with: [authored])
        let planEx = try planExercise(for: r)
        var sessionPlans: [UUID: SessionPlan] = [
            planEx.routineSlotID: sessionPlan(for: planEx)
        ]

        // Exactly what `applySwitchOutcome` does with the adapter's result.
        let outcome = ExerciseSwitchPlanAdapter.outcome(
            choice: .keepCurrentPlan,
            current: sessionPlans[planEx.routineSlotID],
            oldMode: .strength,
            newMode: .strength,
            resetSource: .appDefaults(for: .strength))
        var applied = outcome.sessionPlan
        applied.alternatives =
            sessionPlans[planEx.routineSlotID]?.alternatives ?? []
        sessionPlans[planEx.routineSlotID] = applied

        XCTAssertEqual(
            sessionPlans[planEx.routineSlotID]?.alternatives, [authored])
    }
}
