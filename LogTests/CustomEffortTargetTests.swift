import SwiftData
import XCTest

@testable import Log

/// End-to-end coverage for **custom per-set effort targets** (`EffortMode`
/// `.custom`), following the same three hops the prepared-alternatives suite
/// pins, plus the two persistence paths that leave the device:
///
///     SlotPrescription.customRIRTargetsRaw    (authoring truth)
///              ↓  frozen by makePlan / rebuildPlan
///     PrescriptionSnapshotPayload             (the workout plan)
///              ↓  toModel() at WorkoutItem creation
///     PlannedPrescriptionSnapshot             (durable, survives resume)
///
///     RoutineDuplicator.duplicate             (copy inside this store)
///     RoutineTransfer.export / .import        (crosses to another device)
///
/// The invariant running through all of it: a target the user typed for a
/// specific set is reproduced **exactly** — half steps included — wherever it
/// is later displayed, and a routine authored before this feature existed keeps
/// behaving exactly as it did.
@MainActor
final class CustomEffortTargetTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func exercise(_ name: String = "Barbell Bench Press") -> Exercise {
        let e = Exercise(name: name)
        context.insert(e)
        return e
    }

    /// A one-slot routine whose prescription uses custom per-set RIR targets.
    @discardableResult
    private func routine(
        customRIR: [Double] = [2, 1.5, 1, 0],
        sets: Int = 4,
        name: String = "Upper A"
    ) -> (Routine, SlotPrescription) {
        let ex = exercise()
        let p = SlotPrescription(sets: sets, repMin: 6, repMax: 10)
        context.insert(p)
        p.effortModeRaw = EffortMode.custom.rawValue
        p.setCustomEffortTargets(customRIR, metric: .rir)

        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        re.prescription = p
        context.insert(re)

        let block = RoutineBlock(order: 0, exercises: [re])
        context.insert(block)

        let r = Routine(name: name, blocks: [block])
        context.insert(r)
        return (r, p)
    }

    private func planExercise(for r: Routine) throws -> PlanExercise {
        let plan = StartWorkoutFromRoutineView.makePlan(from: r)
        return try XCTUnwrap(plan.blocks.first?.exercises.first)
    }

    private func labels(
        _ snapshot: PrescriptionSnapshotPayload?, sets: Int,
        autoreg: AutoregMode = .rir
    ) -> [String?] {
        WorkoutEffortTargetResolver.perRowLabels(
            setKinds: Array(repeating: .working, count: sets),
            fields: WorkoutEffortTargetResolver.effectiveFields(
                snapshot: snapshot.map {
                    WorkoutEffortTargetResolver.Fields(payload: $0)
                },
                sessionRIR: nil, sessionRPE: nil),
            autoregMode: autoreg)
    }

    // ==================================================
    // MARK: - 1. Storage
    // ==================================================

    func testCustomTargetsPersistExactlyOnTheSlot() throws {
        let (_, p) = routine(customRIR: [2, 1.5, 1, 0])
        try context.save()

        let fetched = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SlotPrescription>()).first)
        XCTAssertEqual(fetched.effortMode, .custom)
        XCTAssertEqual(fetched.customRIRTargets, [2, 1.5, 1, 0])
        XCTAssertEqual(fetched.customRPETargets, [8, 8.5, 9, 10])
        XCTAssertEqual(p.customRIRTargetsRaw, "2,1.5,1,0")
    }

    func testCustomRPETargetsPersistExactly() throws {
        let (_, p) = routine()
        p.setCustomEffortTargets([8, 8.5, 9.5, 10], metric: .rpe)
        try context.save()

        let fetched = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SlotPrescription>()).first)
        XCTAssertEqual(fetched.customRPETargets, [8, 8.5, 9.5, 10])
        XCTAssertEqual(fetched.customRIRTargets, [2, 1.5, 0.5, 0])
    }

    /// A slot authored before this feature carries nil columns and behaves
    /// exactly as it did — including the new automatic progression.
    func testExistingRoutinesOpenUnchanged() {
        let p = SlotPrescription(
            sets: 4, rir: 2, effortModeRaw: EffortMode.progression.rawValue,
            rirStart: 2, rirEnd: 0)
        context.insert(p)

        XCTAssertNil(p.customRIRTargetsRaw)
        XCTAssertNil(p.customRPETargetsRaw)
        XCTAssertEqual(p.effortMode, .progression)
        XCTAssertEqual(
            WorkoutEffortTargetResolver.perSetValues(
                fields: .init(prescription: p), autoregMode: .rir,
                workingSetCount: 4),
            [2, 2, 1, 0])
    }

    func testLegacySingleTargetStillWorks() {
        let p = SlotPrescription(sets: 3, rir: 2)
        context.insert(p)
        XCTAssertEqual(p.effortMode, .single)
        XCTAssertEqual(
            WorkoutEffortTargetResolver.perSetValues(
                fields: .init(prescription: p), autoregMode: .rir,
                workingSetCount: 3),
            [2, 2, 2])
    }

    // ==================================================
    // MARK: - 1b. The editor walkthrough, end to end
    // ==================================================

    /// The manual verification checklist, executed against the **production**
    /// editor path: `SlotPrescription.applyEffortMode` is exactly what the mode
    /// picker calls, and `resizeCustomEffortTargets` exactly what the sets
    /// stepper triggers. Only the taps are simulated.
    func testEditorWalkthroughFromProgressionToCustomAndBack() throws {
        let ex = exercise()
        let p = SlotPrescription(sets: 4, repMin: 6, repMax: 10)
        context.insert(p)
        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        re.prescription = p
        context.insert(re)

        func targets(_ sets: Int, _ autoreg: AutoregMode = .rir) -> [Double] {
            WorkoutEffortTargetResolver.perSetValues(
                fields: .init(prescription: p), autoregMode: autoreg,
                workingSetCount: sets)
        }

        // 2–3. RIR progression 2 → 0 over 4 sets shows 2, 2, 1, 0.
        p.applyEffortMode(.progression, metric: .rir, defaultValue: 2)
        p.rirStart = 2
        p.rpeStart = 8
        p.rirEnd = 0
        p.rpeEnd = 10
        XCTAssertEqual(targets(4), [2, 2, 1, 0])

        // 4–5. Five sets shows 2, 2, 1, 1, 0.
        p.sets = 5
        p.resizeCustomEffortTargets(to: 5, metric: .rir)
        XCTAssertEqual(targets(5), [2, 2, 1, 1, 0])

        // 6–7. RPE progression 8 → 10 over 4 sets shows 8, 8, 9, 10.
        p.sets = 4
        XCTAssertEqual(targets(4, .rpe), [8, 8, 9, 10])

        // 8. Switching to Custom Per Set seeds from the generated progression.
        p.applyEffortMode(.custom, metric: .rir, defaultValue: 2)
        XCTAssertEqual(p.effortMode, .custom)
        XCTAssertEqual(p.customRIRTargets, [2, 2, 1, 0])

        // 9. Entering 2, 1.5, 1, 0 stores them exactly.
        p.setCustomEffortTargets([2, 1.5, 1, 0], metric: .rir)
        XCTAssertEqual(targets(4), [2, 1.5, 1, 0])

        // 10. They survive leaving and reopening the routine (a real save +
        // fetch, not an in-memory reference).
        try context.save()
        let reopened = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SlotPrescription>()).first)
        XCTAssertEqual(reopened.customRIRTargets, [2, 1.5, 1, 0])

        // 5 (custom half): growing the set count repeats the last target and
        // leaves the earlier ones untouched; shrinking truncates.
        reopened.sets = 6
        reopened.resizeCustomEffortTargets(to: 6, metric: .rir)
        XCTAssertEqual(reopened.customRIRTargets, [2, 1.5, 1, 0, 0, 0])
        reopened.sets = 3
        reopened.resizeCustomEffortTargets(to: 3, metric: .rir)
        XCTAssertEqual(reopened.customRIRTargets, [2, 1.5, 1])

        // Back to Progression: the first and last custom targets become the
        // endpoints.
        reopened.applyEffortMode(.progression, metric: .rir, defaultValue: 2)
        XCTAssertEqual(reopened.rirStart, 2)
        XCTAssertEqual(reopened.rirEnd, 1)
        XCTAssertEqual(reopened.rpeStart, 8, "the opposite metric stays mirrored")
        XCTAssertEqual(reopened.rpeEnd, 9)

        // And back to Custom: the authored list is kept, not regenerated.
        reopened.applyEffortMode(.custom, metric: .rir, defaultValue: 2)
        XCTAssertEqual(reopened.customRIRTargets, [2, 1.5, 1])
    }

    /// Same Target → Custom seeds every set with the one value.
    func testSameTargetToCustomSeedsTheRepeatedValueOnTheSlot() {
        let p = SlotPrescription(sets: 3, rir: 1.5, rpe: 8.5)
        context.insert(p)
        p.applyEffortMode(.custom, metric: .rir, defaultValue: 2)
        XCTAssertEqual(p.customRIRTargets, [1.5, 1.5, 1.5])
    }

    /// A one-set slot gets one editable target.
    func testOneSetCustomOnTheSlot() {
        let p = SlotPrescription(sets: 1, rir: 2)
        context.insert(p)
        p.applyEffortMode(.custom, metric: .rir, defaultValue: 2)
        XCTAssertEqual(p.customRIRTargets, [2])
    }

    /// Tapping through the picker must not invent an opposite-metric value on
    /// a legacy slot that only ever stored one.
    func testModeSwitchDoesNotInventAPairedValue() {
        let p = SlotPrescription(sets: 3, rir: 2)
        context.insert(p)
        XCTAssertNil(p.rpe)

        p.applyEffortMode(.none, metric: .rir, defaultValue: 2)
        XCTAssertNil(p.rpe, "nothing changed, so nothing was written")
        XCTAssertEqual(p.rir, 2)
    }

    // ==================================================
    // MARK: - 2. Session freeze / active workout
    // ==================================================

    func testStartingAWorkoutFreezesCustomTargets() throws {
        let (r, _) = routine(customRIR: [2, 1.5, 1, 0])
        let snapshot = try XCTUnwrap(
            try planExercise(for: r).prescriptionSnapshot)

        XCTAssertEqual(snapshot.effortModeRaw, EffortMode.custom.rawValue)
        XCTAssertEqual(snapshot.customRIRTargetsRaw, "2,1.5,1,0")
        XCTAssertEqual(snapshot.customRPETargetsRaw, "8,8.5,9,10")
    }

    func testActiveWorkoutRowsShowThePerSetTargets() throws {
        let (r, _) = routine(customRIR: [2, 1.5, 1, 0])
        let snapshot = try planExercise(for: r).prescriptionSnapshot

        XCTAssertEqual(
            labels(snapshot, sets: 4),
            ["RIR 2", "RIR 1.5", "RIR 1", "RIR 0"])
        // The same slot viewed with the app set to RPE, through the shared
        // `10 - x` fallback.
        XCTAssertEqual(
            labels(snapshot, sets: 4, autoreg: .rpe),
            ["RPE 8", "RPE 8.5", "RPE 9", "RPE 10"])
    }

    /// Warm-up rows never get an effort label; the working ordinals still index
    /// the custom list.
    func testWarmupRowsGetNoTargetAndWorkingOrdinalsStayAligned() throws {
        let (r, _) = routine(customRIR: [2, 1, 0])
        let snapshot = try XCTUnwrap(
            try planExercise(for: r).prescriptionSnapshot)

        let rowLabels = WorkoutEffortTargetResolver.perRowLabels(
            setKinds: [.warmup, .working, .working, .working],
            fields: .init(payload: snapshot), autoregMode: .rir)
        XCTAssertEqual(rowLabels, [nil, "RIR 2", "RIR 1", "RIR 0"])
    }

    /// Save & Exit freezes the snapshot onto the `WorkoutItem`; Resume reads it
    /// back. The round trip must not touch a single target.
    func testSaveAndExitResumePreservesCustomTargets() throws {
        let (r, _) = routine(customRIR: [2, 1.5, 1, 0])
        let planEx = try planExercise(for: r)
        let frozen = try XCTUnwrap(planEx.prescriptionSnapshot)

        // Save & Exit — the payload becomes a durable snapshot row.
        let model = frozen.toModel()
        context.insert(model)
        try context.save()

        // Resume — the snapshot row becomes a payload again.
        let restored = PrescriptionSnapshotPayload(from: model)
        XCTAssertEqual(restored.customRIRTargetsRaw, "2,1.5,1,0")
        XCTAssertEqual(restored.customRPETargetsRaw, "8,8.5,9,10")
        XCTAssertEqual(
            labels(restored, sets: 4),
            ["RIR 2", "RIR 1.5", "RIR 1", "RIR 0"])
    }

    /// A cold resume rebuilds from the routine and must produce the same
    /// frozen targets `makePlan` did.
    func testResumeRebuildCarriesCustomTargets() throws {
        let (r, _) = routine(customRIR: [2, 1.5, 1, 0])
        let workout = Workout(date: .now, routineID: r.id, items: [])
        context.insert(workout)
        try context.save()

        let rebuilt = try XCTUnwrap(
            WorkoutResumeService.rebuildPlan(for: workout, in: context))
        let snapshot = try XCTUnwrap(
            rebuilt.blocks.first?.exercises.first?.prescriptionSnapshot)

        XCTAssertEqual(snapshot.customRIRTargetsRaw, "2,1.5,1,0")
    }

    /// Frozen means frozen: editing the routine mid-workout cannot rewrite what
    /// the running session shows.
    func testEditingTheRoutineDoesNotChangeTheFrozenTargets() throws {
        let (r, p) = routine(customRIR: [2, 1.5, 1, 0])
        let snapshot = try XCTUnwrap(
            try planExercise(for: r).prescriptionSnapshot)

        p.setCustomEffortTargets([0, 0, 0, 0], metric: .rir)

        XCTAssertEqual(snapshot.customRIRTargetsRaw, "2,1.5,1,0")
    }

    /// A slot whose frozen list is shorter than the session's set count still
    /// labels every row, repeating the last authored target.
    func testFrozenListFitsAGrownSetCount() throws {
        let (r, _) = routine(customRIR: [2, 1, 0], sets: 3)
        let snapshot = try planExercise(for: r).prescriptionSnapshot

        XCTAssertEqual(
            labels(snapshot, sets: 5),
            ["RIR 2", "RIR 1", "RIR 0", "RIR 0", "RIR 0"])
    }

    // ==================================================
    // MARK: - 3. Summaries
    // ==================================================

    func testBlockSummaryStatesTheCustomTargets() throws {
        let (r, _) = routine(customRIR: [2, 1.5, 1, 0])
        let block = try XCTUnwrap(r.blocks.first)

        XCTAssertTrue(
            BlockPrescriptionSummary(block: block, effortMetric: .rir)
                .subtitle.contains("RIR 2/1.5/1/0"),
            BlockPrescriptionSummary(block: block, effortMetric: .rir).subtitle)
    }

    func testBlockSummaryOmitsEffortWhenAutoregIsOff() throws {
        let (r, _) = routine()
        let block = try XCTUnwrap(r.blocks.first)

        XCTAssertFalse(
            BlockPrescriptionSummary(block: block, effortMetric: nil)
                .subtitle.contains("RIR"))
    }

    // ==================================================
    // MARK: - 4. Duplication
    // ==================================================

    func testDuplicationPreservesCustomTargets() throws {
        let (src, _) = routine(customRIR: [2, 1.5, 1, 0])
        try context.save()

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let copied = try XCTUnwrap(
            copy.blocks.first?.exercises.first?.prescription)

        XCTAssertEqual(copied.effortMode, .custom)
        XCTAssertEqual(copied.customRIRTargets, [2, 1.5, 1, 0])
        XCTAssertEqual(copied.customRPETargets, [8, 8.5, 9, 10])
    }

    /// The copy is independent: editing it cannot reach back into the original.
    func testDuplicatedTargetsAreIndependent() throws {
        let (src, srcPrescription) = routine(customRIR: [2, 1.5, 1, 0])
        try context.save()

        let copy = RoutineDuplicator.duplicate(src, among: [src], in: context)
        let copied = try XCTUnwrap(
            copy.blocks.first?.exercises.first?.prescription)
        copied.setCustomEffortTargets([0, 0, 0, 0], metric: .rir)

        XCTAssertEqual(srcPrescription.customRIRTargets, [2, 1.5, 1, 0])
    }

    // ==================================================
    // MARK: - 5. Transfer
    // ==================================================

    private func importedPrescription(
        _ document: RoutineTransferDocument, named: String
    ) throws -> SlotPrescription {
        let routines = (try? context.fetch(FetchDescriptor<Routine>())) ?? []
        let exercises = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        _ = try RoutineTransfer.import(
            document, among: routines, exercises: exercises, in: context)
        let imported = try XCTUnwrap(
            (try context.fetch(FetchDescriptor<Routine>()))
                .last { $0.name.hasPrefix(named) })
        return try XCTUnwrap(
            imported.blocks.first?.exercises.first?.prescription)
    }

    func testExportCarriesCustomTargets() throws {
        let (r, _) = routine(customRIR: [2, 1.5, 1, 0])
        let dto = try XCTUnwrap(
            RoutineTransfer.export(r).routine.blocks.first?.slots.first?
                .prescription)

        XCTAssertEqual(dto.effortModeRaw, EffortMode.custom.rawValue)
        XCTAssertEqual(dto.customRIRTargets, [2, 1.5, 1, 0])
        XCTAssertEqual(dto.customRPETargets, [8, 8.5, 9, 10])
    }

    func testExportOmitsTheKeysForASlotWithoutCustomTargets() throws {
        let ex = exercise("Squat")
        let p = SlotPrescription(sets: 3, rir: 2)
        context.insert(p)
        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        re.prescription = p
        context.insert(re)
        let block = RoutineBlock(order: 0, exercises: [re])
        context.insert(block)
        let r = Routine(name: "Legs", blocks: [block])
        context.insert(r)

        let json = try XCTUnwrap(
            String(
                data: try JSONEncoder().encode(RoutineTransfer.export(r)),
                encoding: .utf8))
        XCTAssertFalse(json.contains("customRIRTargets"))
        XCTAssertFalse(json.contains("customRPETargets"))
    }

    func testExportImportRoundTripPreservesCustomTargets() throws {
        let (r, _) = routine(customRIR: [2, 1.5, 1, 0], name: "Shared Day")
        let data = try JSONEncoder().encode(RoutineTransfer.export(r))
        let document = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: data)

        let imported = try importedPrescription(document, named: "Shared Day")
        XCTAssertEqual(imported.effortMode, .custom)
        XCTAssertEqual(imported.customRIRTargets, [2, 1.5, 1, 0])
        XCTAssertEqual(imported.customRPETargets, [8, 8.5, 9, 10])
    }

    /// A document written before this feature has no custom keys at all and
    /// must import exactly as it always did.
    func testOlderDocumentWithoutCustomTargetKeysImportsSafely() throws {
        let json = """
            {
              "schemaVersion": 1,
              "routine": {
                "name": "Legacy",
                "blocks": [{
                  "order": 0,
                  "isSuperset": false,
                  "slots": [{
                    "order": 0,
                    "exerciseName": "Barbell Row",
                    "setTemplates": [],
                    "prescription": {
                      "sets": 4,
                      "repMin": 6,
                      "repMax": 10,
                      "usesDuration": false,
                      "effortModeRaw": "progression",
                      "rirStart": 2,
                      "rirEnd": 0,
                      "techniquePlans": []
                    }
                  }]
                }]
              }
            }
            """
        let document = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: Data(json.utf8))

        let imported = try importedPrescription(document, named: "Legacy")
        XCTAssertNil(imported.customRIRTargetsRaw)
        XCTAssertNil(imported.customRPETargetsRaw)
        XCTAssertEqual(imported.effortMode, .progression)
        XCTAssertEqual(
            WorkoutEffortTargetResolver.perSetValues(
                fields: .init(prescription: imported), autoregMode: .rir,
                workingSetCount: 4),
            [2, 2, 1, 0],
            "an old progression routine adopts the new human-friendly ramp")
    }

    /// A hand-edited document with an impossible target is refused whole rather
    /// than reaching a formatter — the slot degrades to the values it still
    /// carries.
    func testHandEditedCustomTargetsAreRejectedOnImport() throws {
        let json = """
            {
              "schemaVersion": 1,
              "routine": {
                "name": "Tampered",
                "blocks": [{
                  "order": 0,
                  "isSuperset": false,
                  "slots": [{
                    "order": 0,
                    "exerciseName": "Barbell Row",
                    "setTemplates": [],
                    "prescription": {
                      "sets": 3,
                      "usesDuration": false,
                      "effortModeRaw": "custom",
                      "rir": 2,
                      "customRIRTargets": [2, 999, 0],
                      "techniquePlans": []
                    }
                  }]
                }]
              }
            }
            """
        let document = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: Data(json.utf8))

        let imported = try importedPrescription(document, named: "Tampered")
        XCTAssertNil(imported.customRIRTargetsRaw)
        XCTAssertEqual(
            WorkoutEffortTargetResolver.perSetValues(
                fields: .init(prescription: imported), autoregMode: .rir,
                workingSetCount: 3),
            [2, 2, 2],
            "degrades to the single value it still stores, never to nothing")
    }
}
