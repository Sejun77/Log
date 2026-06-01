import SwiftData
import XCTest

@testable import Log

/// Tests for the read-only model→DTO export (`RoutineTransfer.export`, Slice B).
/// Uses `SwiftDataTestHarness` because the source is a live `Routine` graph; the
/// service itself only reads it. Pins: per-level `order` sorting, exercise-hint
/// export, nil-exercise safety, verbatim raw fields, schema-version validity,
/// absence of identity keys in the JSON, and that the source is never mutated.
@MainActor
final class RoutineTransferExportTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    @discardableResult
    private func makeExercise(
        _ name: String, bodyPart: String? = nil, equipment: String? = nil,
        timeBased: Bool = false
    ) -> Exercise {
        let e = Exercise(
            name: name, bodyPart: bodyPart, equipmentType: equipment,
            isCustom: true)
        e.isTimeBased = timeBased
        context.insert(e)
        return e
    }

    private func makeRoutine(_ name: String, notes: String? = nil) -> Routine {
        let r = Routine(name: name, notes: notes, blocks: [])
        let v = RoutineVariant(name: "Default", order: 0)
        context.insert(v)
        r.variants.append(v)
        context.insert(r)
        return r
    }

    @discardableResult
    private func addBlock(
        to r: Routine, order: Int, isSuperset: Bool = false,
        restAfter: Int? = nil, roundRest: Int? = nil
    ) -> RoutineBlock {
        let b = RoutineBlock(
            isSuperset: isSuperset, order: order, restAfterSeconds: restAfter,
            exercises: [])
        b.supersetRoundRestSeconds = roundRest
        context.insert(b)
        r.blocks.append(b)
        return b
    }

    /// Append a slot. Pass `exercise: nil` for a deleted/unlinked slot (a
    /// transient placeholder is used for the required init, then detached —
    /// never inserted, exactly as `RoutineDuplicator.copySlot` does).
    @discardableResult
    private func addSlot(
        to b: RoutineBlock, exercise: Exercise?, order: Int
    ) -> RoutineExercise {
        let re: RoutineExercise
        if let exercise {
            re = RoutineExercise(exercise: exercise, order: order, setTemplates: [])
        } else {
            re = RoutineExercise(
                exercise: Exercise(name: ""), order: order, setTemplates: [])
            re.exercise = nil
        }
        context.insert(re)
        b.exercises.append(re)
        return re
    }

    /// Recursively collect every dictionary key in a decoded JSON value.
    private func allKeys(in json: Any) -> Set<String> {
        var keys: Set<String> = []
        if let dict = json as? [String: Any] {
            for (k, v) in dict {
                keys.insert(k)
                keys.formUnion(allKeys(in: v))
            }
        } else if let arr = json as? [Any] {
            for v in arr { keys.formUnion(allKeys(in: v)) }
        }
        return keys
    }

    // MARK: - 1. Minimal routine

    func testExportsMinimalRoutine() {
        let r = makeRoutine("Min")
        let doc = RoutineTransfer.export(r, exportedAt: nil, appVersion: "2.0")

        XCTAssertEqual(doc.schemaVersion, 1)
        XCTAssertNil(doc.exportedAt)
        XCTAssertEqual(doc.appVersion, "2.0")
        XCTAssertEqual(doc.routine.name, "Min")
        XCTAssertNil(doc.routine.notes)
        XCTAssertTrue(doc.routine.blocks.isEmpty)
    }

    // MARK: - 2. Fully populated round-trips

    /// Build a routine with two blocks, multi-slot superset, set templates,
    /// prescription (techniques + warmup) — every level intentionally inserted
    /// out of `order` to exercise the sort.
    private func makeFullRoutine() -> Routine {
        let r = makeRoutine("Push A", notes: "heavy")
        let bench = makeExercise(
            "Bench", bodyPart: "Chest", equipment: "Barbell")
        let plank = makeExercise("Plank", bodyPart: "Core", timeBased: true)
        let fly = makeExercise("Fly", bodyPart: "Chest", equipment: "Cable")

        // Normal block (inserted at order 1, should sort *after* the superset).
        let normal = addBlock(to: r, order: 1, restAfter: 60)
        let slot = addSlot(to: normal, exercise: bench, order: 0)
        slot.templateNotes = "pause"
        // Set templates out of order.
        let t1 = SetTemplate(
            kind: .working, targetReps: 8, targetWeight: 80, restSecondsAfter: 90)
        t1.order = 1
        let t0 = SetTemplate(
            kind: .warmup, targetReps: 5, targetWeight: 40, restSecondsAfter: 30)
        t0.order = 0
        context.insert(t1)
        context.insert(t0)
        slot.setTemplates = [t1, t0]
        // Prescription with techniques + warmup, both out of order.
        let presc = SlotPrescription(
            sets: 4, repMin: 8, repMax: 12, restSecondsBetweenSets: 90,
            restSecondsAfterExercise: 120)
        presc.rir = 2; presc.rpe = 8.5; presc.tempo = "3-1-1"
        context.insert(presc)
        let tech1 = TechniquePlan(order: 1, type: .dropset, dropPercent: 20, dropCount: 2)
        tech1.appliesToSetIndicesRaw = "0,2"
        tech1.dropsetEffortRaw = "fixedReps"; tech1.dropsetEffortReps = 8
        let tech0 = TechniquePlan(order: 0, type: .restPause)
        context.insert(tech1); context.insert(tech0)
        presc.techniquePlans = [tech1, tech0]
        let scheme = WarmupScheme(name: "Ramp")
        context.insert(scheme)
        let w1 = WarmupStep(order: 1, kind: .fixedReps, reps: 3, weight: 50)
        let w0 = WarmupStep(order: 0, kind: .percentage, percentOfWorking: 0.5)
        context.insert(w1); context.insert(w0)
        scheme.steps = [w1, w0]
        presc.warmupScheme = scheme
        slot.prescription = presc

        // Superset block (inserted at order 0, should sort *first*) with two
        // slots inserted out of order.
        let ss = addBlock(to: r, order: 0, isSuperset: true, roundRest: 120)
        addSlot(to: ss, exercise: plank, order: 1)
        addSlot(to: ss, exercise: fly, order: 0)
        try? context.save()
        return r
    }

    func testFullRoutineEncodeDecodeRoundTrips() throws {
        let doc = RoutineTransfer.export(makeFullRoutine())
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: data)
        XCTAssertEqual(decoded, doc)
    }

    // MARK: - 3. Blocks sorted by order

    func testBlocksSortedByOrder() {
        let doc = RoutineTransfer.export(makeFullRoutine())
        XCTAssertEqual(doc.routine.blocks.map(\.order), [0, 1])
        // Superset (inserted second, order 0) comes first.
        XCTAssertEqual(doc.routine.blocks.first?.isSuperset, true)
        XCTAssertEqual(doc.routine.blocks.first?.supersetRoundRestSeconds, 120)
    }

    // MARK: - 4. Slots sorted by order

    func testSlotsSortedByOrder() {
        let doc = RoutineTransfer.export(makeFullRoutine())
        let superset = doc.routine.blocks.first { $0.isSuperset }
        XCTAssertEqual(superset?.slots.map(\.order), [0, 1])
        XCTAssertEqual(superset?.slots.first?.exerciseName, "Fly")
        XCTAssertEqual(superset?.slots.last?.exerciseName, "Plank")
    }

    // MARK: - 5. SetTemplates sorted by order

    func testSetTemplatesSortedByOrder() {
        let doc = RoutineTransfer.export(makeFullRoutine())
        let slot = doc.routine.blocks
            .first { !$0.isSuperset }?.slots.first
        XCTAssertEqual(slot?.setTemplates.map(\.order), [0, 1])
        XCTAssertEqual(slot?.setTemplates.first?.kindRaw, "warmup")
        XCTAssertEqual(slot?.setTemplates.last?.kindRaw, "working")
    }

    // MARK: - 6. TechniquePlans sorted by order

    func testTechniquePlansSortedByOrder() {
        let doc = RoutineTransfer.export(makeFullRoutine())
        let plans = doc.routine.blocks
            .first { !$0.isSuperset }?.slots.first?.prescription?.techniquePlans
        XCTAssertEqual(plans?.map(\.order), [0, 1])
        XCTAssertEqual(plans?.last?.typeRaw, "dropset")
    }

    // MARK: - 7. WarmupSteps sorted by order

    func testWarmupStepsSortedByOrder() {
        let doc = RoutineTransfer.export(makeFullRoutine())
        let steps = doc.routine.blocks
            .first { !$0.isSuperset }?.slots.first?.prescription?
            .warmupScheme?.steps
        XCTAssertEqual(steps?.map(\.order), [0, 1])
        XCTAssertEqual(steps?.first?.kindRaw, "percentage")
        XCTAssertEqual(steps?.last?.weight, 50)
    }

    // MARK: - 8. Exercise hints exported from linked Exercise

    func testExerciseHintsExported() {
        let r = makeRoutine("R")
        let plank = makeExercise("Plank", bodyPart: "Core", timeBased: true)
        let b = addBlock(to: r, order: 0)
        addSlot(to: b, exercise: plank, order: 0)

        let slot = RoutineTransfer.export(r).routine.blocks.first?.slots.first
        XCTAssertEqual(slot?.exerciseName, "Plank")
        XCTAssertEqual(slot?.exerciseBodyPart, "Core")
        XCTAssertNil(slot?.exerciseEquipmentType)
        XCTAssertEqual(slot?.exerciseIsTimeBased, true)
    }

    // MARK: - 9. Nil-exercise slot exports safely

    func testNilExerciseSlotExportsSafely() {
        let r = makeRoutine("R")
        let b = addBlock(to: r, order: 0)
        addSlot(to: b, exercise: nil, order: 0)

        let slot = RoutineTransfer.export(r).routine.blocks.first?.slots.first
        XCTAssertEqual(slot?.exerciseName, "")
        XCTAssertNil(slot?.exerciseBodyPart)
        XCTAssertNil(slot?.exerciseEquipmentType)
        XCTAssertNil(slot?.exerciseIsTimeBased)
    }

    // MARK: - 10. Raw fields preserved exactly, incl. unknown values

    func testRawFieldsPreservedIncludingUnknown() {
        let r = makeRoutine("R")
        let ex = makeExercise("X")
        let b = addBlock(to: r, order: 0)
        let slot = addSlot(to: b, exercise: ex, order: 0)
        let tpl = SetTemplate(kind: .working, targetReps: 1)
        tpl.kindRaw = "myFutureKind"  // synthetic unknown
        context.insert(tpl)
        slot.setTemplates = [tpl]
        let presc = SlotPrescription(sets: 1)
        context.insert(presc)
        let tech = TechniquePlan(order: 0, type: .dropset)
        tech.typeRaw = "quantumSet"           // synthetic unknown
        tech.appliesToRaw = "everyThirdMoonday"
        tech.dropsetEffortRaw = "telepathic"
        context.insert(tech)
        presc.techniquePlans = [tech]
        slot.prescription = presc

        let dto = RoutineTransfer.export(r).routine.blocks.first?.slots.first
        XCTAssertEqual(dto?.setTemplates.first?.kindRaw, "myFutureKind")
        let t = dto?.prescription?.techniquePlans.first
        XCTAssertEqual(t?.typeRaw, "quantumSet")
        XCTAssertEqual(t?.appliesToRaw, "everyThirdMoonday")
        XCTAssertEqual(t?.dropsetEffortRaw, "telepathic")
    }

    // MARK: - 11. Exported document validates supported schema version

    func testExportedDocumentValidatesSchemaVersion() {
        let doc = RoutineTransfer.export(makeFullRoutine())
        XCTAssertEqual(doc.schemaVersion, RoutineTransferDocument.currentSchemaVersion)
        XCTAssertNoThrow(try doc.validateSupportedSchemaVersion())
    }

    // MARK: - 12 + 14. No forbidden identity keys; no RoutineVariant

    func testExportedJSONHasNoForbiddenIdentityKeys() throws {
        let data = try JSONEncoder().encode(RoutineTransfer.export(makeFullRoutine()))
        let keys = allKeys(in: try JSONSerialization.jsonObject(with: data))

        let forbidden: Set<String> = [
            "id", "persistentIdentifier", "slotID", "routineID",
            "routineSlotID", "routineVariantID", "variants", "variant",
            "workout", "workouts", "history",
        ]
        let hits = keys.intersection(forbidden)
        XCTAssertTrue(hits.isEmpty, "Forbidden keys present: \(hits)")
        // Positive sanity.
        XCTAssertTrue(keys.contains("exerciseName"))
        XCTAssertTrue(keys.contains("supersetRoundRestSeconds"))
    }

    // MARK: - 13. Source model not mutated

    func testSourceModelNotMutated() throws {
        let r = makeFullRoutine()
        let blockOrdersBefore = r.blocks.map(\.order).sorted()
        let slotOrdersBefore = r.blocks
            .flatMap { $0.exercises.map(\.order) }.sorted()
        let blockCountBefore = r.blocks.count
        let exerciseCountBefore = try context.fetch(
            FetchDescriptor<Exercise>()).count

        _ = RoutineTransfer.export(r)

        XCTAssertEqual(r.blocks.map(\.order).sorted(), blockOrdersBefore)
        XCTAssertEqual(
            r.blocks.flatMap { $0.exercises.map(\.order) }.sorted(),
            slotOrdersBefore)
        XCTAssertEqual(r.blocks.count, blockCountBefore)
        // No stub exercises created by a read-only export.
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Exercise>()).count,
            exerciseCountBefore)
        // The Default variant still exists on the source (just not exported).
        XCTAssertEqual(r.variants.count, 1)
    }

    // MARK: - Export filename slug (Slice E, pure)

    func testExportFilenameSlug() {
        XCTAssertEqual(RoutineTransfer.exportFilename(for: "Upper A"), "routine-upper-a")
        XCTAssertEqual(
            RoutineTransfer.exportFilename(for: "Push A (imported)"),
            "routine-push-a-imported")
        // Collapses runs, trims edge separators.
        XCTAssertEqual(
            RoutineTransfer.exportFilename(for: "  Legs / Pull!! "),
            "routine-legs-pull")
        // Symbol-only / empty → bare fallback (no trailing dash).
        XCTAssertEqual(RoutineTransfer.exportFilename(for: ""), "routine")
        XCTAssertEqual(RoutineTransfer.exportFilename(for: "***"), "routine")
        // Digits preserved.
        XCTAssertEqual(RoutineTransfer.exportFilename(for: "Day 1"), "routine-day-1")
    }
}
