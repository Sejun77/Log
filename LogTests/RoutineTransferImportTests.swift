import SwiftData
import XCTest

@testable import Log

/// Tests for the DTO→model import (`RoutineTransfer.import`, Slice C) on
/// `SwiftDataTestHarness`. Pins: fresh identities, unique naming, trailing
/// order, name-based exercise resolution + additive stub creation (deduped),
/// empty-name skip, full materialization with raw-string preservation, the
/// schema-version guard (inserts nothing), and additive data-safety (existing
/// rows + history untouched).
@MainActor
final class RoutineTransferImportTests: SwiftDataTestHarness {

    // MARK: - Context fixtures

    @discardableResult
    private func makeExercise(
        _ name: String, bodyPart: String? = nil, order: Int = 0
    ) -> Exercise {
        let e = Exercise(name: name, bodyPart: bodyPart, isCustom: true)
        e.order = order
        context.insert(e)
        return e
    }

    @discardableResult
    private func makeRoutine(_ name: String, order: Int = 0) -> Routine {
        let r = Routine(name: name, blocks: [])
        r.order = order
        context.insert(r)
        return r
    }

    private func allRoutines() -> [Routine] {
        (try? context.fetch(FetchDescriptor<Routine>())) ?? []
    }
    private func allExercises() -> [Exercise] {
        (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
    }

    // MARK: - DTO builders

    private func slot(
        _ name: String, order: Int = 0, bodyPart: String? = nil,
        equipment: String? = nil, timeBased: Bool? = nil,
        templateNotes: String? = nil,
        templates: [RoutineTransferSetTemplateDTO] = [],
        prescription: RoutineTransferSlotPrescriptionDTO? = nil
    ) -> RoutineTransferSlotDTO {
        RoutineTransferSlotDTO(
            order: order, exerciseName: name, exerciseBodyPart: bodyPart,
            exerciseEquipmentType: equipment, exerciseIsTimeBased: timeBased,
            templateNotes: templateNotes, setTemplates: templates,
            prescription: prescription)
    }

    private func block(
        order: Int, isSuperset: Bool = false, restAfter: Int? = nil,
        roundRest: Int? = nil, slots: [RoutineTransferSlotDTO]
    ) -> RoutineTransferBlockDTO {
        RoutineTransferBlockDTO(
            order: order, isSuperset: isSuperset, restAfterSeconds: restAfter,
            supersetRoundRestSeconds: roundRest, slots: slots)
    }

    private func doc(
        _ name: String, notes: String? = nil, schemaVersion: Int = 1,
        blocks: [RoutineTransferBlockDTO]
    ) -> RoutineTransferDocument {
        RoutineTransferDocument(
            schemaVersion: schemaVersion,
            routine: RoutineTransferRoutineDTO(
                name: name, notes: notes, blocks: blocks))
    }

    @discardableResult
    private func runImport(_ d: RoutineTransferDocument) throws
        -> RoutineTransfer.ImportReport
    {
        try RoutineTransfer.import(
            d, among: allRoutines(), exercises: allExercises(), in: context)
    }

    // MARK: - 1. Minimal

    func testImportsMinimalRoutine() throws {
        let report = try runImport(
            doc("Upper", blocks: [block(order: 0, slots: [slot("Bench")])]))

        XCTAssertEqual(report.importedRoutineName, "Upper")
        XCTAssertEqual(report.blockCount, 1)
        XCTAssertEqual(report.slotCount, 1)
        let r = allRoutines().first { $0.name == "Upper" }
        XCTAssertEqual(r?.blocks.count, 1)
        XCTAssertEqual(r?.blocks.first?.exercises.first?.exercise?.name, "Bench")
    }

    // MARK: - 2 + 11–15. Fully populated graph materializes

    private func fullDoc() -> RoutineTransferDocument {
        let warmup = RoutineTransferWarmupSchemeDTO(
            name: "Ramp",
            steps: [
                RoutineTransferWarmupStepDTO(
                    order: 1, kindRaw: "fixedReps", reps: 3, percentOfWorking: nil,
                    restSecondsAfter: 40, note: nil, weight: 50),
                RoutineTransferWarmupStepDTO(
                    order: 0, kindRaw: "percentage", reps: nil,
                    percentOfWorking: 0.5, restSecondsAfter: 30, note: "easy",
                    weight: nil),
            ])
        let tech = RoutineTransferTechniquePlanDTO(
            order: 0, typeRaw: "quantumSet", repMin: 6, repMax: 10, reps: nil,
            durationSeconds: nil, restSeconds: 15, rounds: 2, dropPercent: 20,
            dropCount: 2, partialRangeNote: "half", note: "burn",
            appliesToRaw: "everyThirdMoonday", appliesToSetNumber: nil,
            appliesToSetIndicesRaw: "0,2", dropsetEffortRaw: "telepathic",
            dropsetEffortReps: 8)
        let presc = RoutineTransferSlotPrescriptionDTO(
            sets: 4, repMin: 8, repMax: 12, restSecondsBetweenSets: 90,
            restSecondsAfterExercise: 120, rir: 2, rpe: 8.5, tempo: "3-1-1",
            durationMinSeconds: nil, durationMaxSeconds: nil, usesDuration: false,
            techniquePlans: [tech], warmupScheme: warmup)
        let templates = [
            RoutineTransferSetTemplateDTO(
                order: 1, kindRaw: "working", targetReps: 8, targetWeight: 80,
                restSecondsAfter: 90, durationSeconds: nil),
            RoutineTransferSetTemplateDTO(
                order: 0, kindRaw: "myFutureKind", targetReps: 5,
                targetWeight: 40, restSecondsAfter: 30, durationSeconds: nil),
        ]
        let normal = block(
            order: 1, restAfter: 60,
            slots: [
                slot("Bench", order: 0, bodyPart: "Chest", equipment: "Barbell",
                    timeBased: false, templateNotes: "pause",
                    templates: templates, prescription: presc)
            ])
        let superset = block(
            order: 0, isSuperset: true, roundRest: 120,
            slots: [slot("Fly", order: 1), slot("Plank", order: 0, timeBased: true)])
        return doc("Push A", notes: "heavy", blocks: [normal, superset])
    }

    func testImportsFullGraph() throws {
        try runImport(fullDoc())
        let r = allRoutines().first { $0.name == "Push A" }
        XCTAssertEqual(r?.notes, "heavy")
        // Blocks renumbered contiguous; superset (DTO order 0) first.
        let blocks = r!.blocks.sorted { $0.order < $1.order }
        XCTAssertEqual(blocks.map(\.order), [0, 1])
        XCTAssertEqual(blocks[0].isSuperset, true)
        XCTAssertEqual(blocks[0].supersetRoundRestSeconds, 120)      // 15
        XCTAssertEqual(blocks[1].restAfterSeconds, 60)

        let slot = blocks[1].exercises.first
        XCTAssertEqual(slot?.templateNotes, "pause")
        // 11. setTemplates materialized + sorted + raw preserved.
        let tpls = slot!.setTemplates.sorted { $0.order < $1.order }
        XCTAssertEqual(tpls.map(\.kindRaw), ["myFutureKind", "working"])  // 13
        XCTAssertEqual(tpls.last?.targetWeight, 80)
        // 12. prescription materialized.
        XCTAssertEqual(slot?.prescription?.sets, 4)
        XCTAssertEqual(slot?.prescription?.tempo, "3-1-1")
        // 13. technique raw strings preserved verbatim.
        let t = slot?.prescription?.techniquePlans.first
        XCTAssertEqual(t?.typeRaw, "quantumSet")
        XCTAssertEqual(t?.appliesToRaw, "everyThirdMoonday")
        XCTAssertEqual(t?.appliesToSetIndicesRaw, "0,2")
        XCTAssertEqual(t?.dropsetEffortRaw, "telepathic")
        // 14. warmup materialized + sorted.
        let steps = slot?.prescription?.warmupScheme?.steps.sorted { $0.order < $1.order }
        XCTAssertEqual(steps?.map(\.kindRaw), ["percentage", "fixedReps"])
        XCTAssertEqual(steps?.last?.weight, 50)
    }

    // MARK: - 3. Fresh identities

    func testCreatesFreshIdentities() throws {
        let d = doc("R", blocks: [
            block(order: 0, slots: [slot("A")]),
            block(order: 1, slots: [slot("B")]),
        ])
        try runImport(d)
        let r1 = allRoutines().first { $0.name == "R" }!
        let blockIDs = r1.blocks.map(\.slotID)
        XCTAssertEqual(Set(blockIDs).count, 2, "block slotIDs unique")
        let slotIDs = r1.blocks.flatMap { $0.exercises.map(\.slotID) }
        XCTAssertEqual(Set(slotIDs).count, 2, "slot slotIDs unique")

        // A second import of the same document gets distinct identities.
        try runImport(d)
        let routines = allRoutines().filter { $0.name.hasPrefix("R") }
        XCTAssertEqual(routines.count, 2)
        XCTAssertNotEqual(routines[0].id, routines[1].id)
        XCTAssertTrue(
            Set(routines[0].blocks.map(\.slotID))
                .isDisjoint(with: Set(routines[1].blocks.map(\.slotID))))
    }

    // MARK: - 4. One fresh Default variant

    func testCreatesOneDefaultVariant() throws {
        try runImport(doc("R", blocks: [block(order: 0, slots: [slot("A")])]))
        let r = allRoutines().first { $0.name == "R" }
        XCTAssertEqual(r?.variants.count, 1)
        XCTAssertEqual(r?.variants.first?.name, "Default")
    }

    // MARK: - 5. Name collision → unique name

    func testNameCollisionGetsUniqueName() throws {
        makeRoutine("Push A", order: 0)
        let report = try runImport(
            doc("Push A", blocks: [block(order: 0, slots: [slot("A")])]))
        XCTAssertEqual(report.sourceRoutineName, "Push A")
        XCTAssertEqual(report.importedRoutineName, "Push A (imported)")
        XCTAssertEqual(allRoutines().filter { $0.name == "Push A" }.count, 1)

        // A second collision increments.
        let report2 = try runImport(
            doc("push a", blocks: [block(order: 0, slots: [slot("A")])]))
        XCTAssertEqual(report2.importedRoutineName, "push a (imported 2)")
    }

    // MARK: - 6. Trailing order

    func testRoutineOrderAppendedAfterMax() throws {
        makeRoutine("X", order: 5)
        makeRoutine("Y", order: 9)
        try runImport(doc("Z", blocks: [block(order: 0, slots: [slot("A")])]))
        XCTAssertEqual(allRoutines().first { $0.name == "Z" }?.order, 10)
    }

    // MARK: - 7 + 16. Existing exercise matched by name, not mutated

    func testExistingExerciseMatchedCaseInsensitivelyAndNotMutated() throws {
        let bench = makeExercise("Bench", bodyPart: "Chest", order: 0)
        let benchID = bench.id
        let report = try runImport(
            doc("R", blocks: [
                block(order: 0, slots: [slot("  bench  ", bodyPart: "WRONG")])
            ]))

        XCTAssertEqual(report.matchedExerciseNames, ["Bench"])
        XCTAssertTrue(report.createdExerciseNames.isEmpty)
        // Linked to the existing row, which is unchanged.
        let linked = allRoutines().first { $0.name == "R" }?
            .blocks.first?.exercises.first?.exercise
        XCTAssertEqual(linked?.id, benchID)
        XCTAssertEqual(bench.bodyPart, "Chest")          // not overwritten
        XCTAssertEqual(allExercises().count, 1)          // no stub created
    }

    // MARK: - 8. Missing exercise auto-created as custom with hints

    func testMissingExerciseAutoCreated() throws {
        makeExercise("Existing", order: 3)
        let report = try runImport(
            doc("R", blocks: [
                block(order: 0, slots: [
                    slot("Hack Squat", bodyPart: "Legs",
                        equipment: "Machine", timeBased: false)
                ])
            ]))

        XCTAssertEqual(report.createdExerciseNames, ["Hack Squat"])
        let created = allExercises().first { $0.name == "Hack Squat" }
        XCTAssertNotNil(created)
        XCTAssertEqual(created?.isCustom, true)
        XCTAssertEqual(created?.bodyPart, "Legs")
        XCTAssertEqual(created?.equipmentType, "Machine")
        XCTAssertEqual(created?.isTimeBased, false)
        XCTAssertEqual(created?.order, 4)                // appended after max(3)
    }

    // MARK: - 9. Missing exercise deduped within one import

    func testMissingExerciseDedupedWithinBatch() throws {
        let report = try runImport(
            doc("R", blocks: [
                block(order: 0, slots: [slot("NewEx", order: 0)]),
                block(order: 1, slots: [slot("newex", order: 0)]),
            ]))
        XCTAssertEqual(report.createdExerciseNames, ["NewEx"])
        XCTAssertEqual(allExercises().filter {
            $0.name.lowercased() == "newex"
        }.count, 1)
        // Both slots link to the same created instance.
        let r = allRoutines().first { $0.name == "R" }!
        let linked = r.blocks.compactMap { $0.exercises.first?.exercise?.id }
        XCTAssertEqual(Set(linked).count, 1)
    }

    // MARK: - 10. Empty exerciseName slot skipped; emptied block dropped

    func testEmptyExerciseNameSlotSkipped() throws {
        let report = try runImport(
            doc("R", blocks: [
                block(order: 0, slots: [
                    slot("", order: 0), slot("Bench", order: 1),
                ]),
                block(order: 1, slots: [slot("   ", order: 0)]),  // all empty
            ]))
        XCTAssertEqual(report.skippedSlotCount, 2)
        XCTAssertEqual(report.blockCount, 1)             // second block dropped
        XCTAssertEqual(report.slotCount, 1)
        let r = allRoutines().first { $0.name == "R" }!
        XCTAssertEqual(r.blocks.count, 1)
        XCTAssertEqual(r.blocks.first?.exercises.count, 1)
        XCTAssertEqual(r.blocks.first?.exercises.first?.exercise?.name, "Bench")
    }

    // MARK: - 17. No history created

    func testNoHistoryCreated() throws {
        try runImport(fullDoc())
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutItem>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SetLog>()).count, 0)
    }

    // MARK: - 18. Unsupported future schemaVersion throws, inserts nothing

    func testUnsupportedSchemaVersionThrowsAndInsertsNothing() {
        makeRoutine("Existing", order: 0)
        makeExercise("Bench", order: 0)
        let routinesBefore = allRoutines().count
        let exercisesBefore = allExercises().count
        let future = RoutineTransferDocument.currentSchemaVersion + 1

        XCTAssertThrowsError(
            try runImport(
                doc("R", schemaVersion: future,
                    blocks: [block(order: 0, slots: [slot("New")])]))
        ) { err in
            XCTAssertEqual(
                err as? RoutineTransferError,
                .unsupportedSchemaVersion(
                    found: future,
                    supported: RoutineTransferDocument.currentSchemaVersion))
        }
        XCTAssertEqual(allRoutines().count, routinesBefore)
        XCTAssertEqual(allExercises().count, exercisesBefore)
    }

    // MARK: - 19. Empty routine (no blocks) is safe

    func testEmptyRoutineImportsSafely() throws {
        let report = try runImport(doc("Empty", blocks: []))
        XCTAssertEqual(report.blockCount, 0)
        XCTAssertEqual(report.slotCount, 0)
        let r = allRoutines().first { $0.name == "Empty" }
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.blocks.count, 0)
        XCTAssertEqual(r?.variants.count, 1)
    }

    // MARK: - 20. Save + refetch persists

    func testImportPersistsAfterRefetch() throws {
        try runImport(fullDoc())
        // Fresh fetch (post-save) sees the whole graph.
        let fetched = try context.fetch(
            FetchDescriptor<Routine>(
                predicate: #Predicate { $0.name == "Push A" }))
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.blocks.count, 2)
        let slotCount = fetched.first?.blocks.reduce(0) { $0 + $1.exercises.count }
        XCTAssertEqual(slotCount, 3)
    }
}
