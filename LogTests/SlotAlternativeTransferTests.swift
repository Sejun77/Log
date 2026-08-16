import SwiftData
import XCTest

@testable import Log

/// Alternative Exercises Phase H2 — routine transfer carries prepared
/// alternatives.
///
/// Transfer is the one hop where an alternative's two identity fields cannot
/// travel as they are stored, and both rules are pinned here:
///
///  1. **`SlotAlternative.id` is not in the wire format at all**, so an import
///     necessarily mints a fresh one (§12.2). An imported routine must not
///     share authored alternative identity with the sender's copy — the same
///     rule duplication follows for the same reason.
///  2. **`exerciseID` travels as a name plus resolution hints**, because a
///     `UUID` from the sender's store means nothing on the recipient's device.
///     Import resolves it through the document's single exercise-resolution
///     rule: link an existing library row, or stub-create one — exactly what a
///     *slot's* exercise reference already does.
///
/// Everything else round-trips verbatim, down to the Cardio Plan's segment ids,
/// which the primary slot's plan already preserves on this path (§12.2, and
/// `StructuredCardioTransferTests.testRoundTripPreservesEverySegmentField`).
///
/// The compatibility half matters as much: the field is additive with a nil
/// default and **does not consume a `schemaVersion`**, because
/// `validateSupportedSchemaVersion` *rejects* a document newer than the reader
/// — bumping would make older builds refuse a whole routine rather than import
/// it minus its alternatives.
@MainActor
final class SlotAlternativeTransferTests: SwiftDataTestHarness {

    // ==================================================
    // MARK: - Fixtures
    // ==================================================

    private func cardioPlan(segmentID: UUID = UUID()) throws -> CardioSegmentPlan
    {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(
                segments: [
                    CardioSegment(
                        id: segmentID, kind: .warmUp, durationSeconds: 300),
                    CardioSegment(kind: .work, durationSeconds: 1_200),
                ],
                repeatCount: 3)
        ])
    }

    /// An alternative carrying every field the payload can hold.
    private func richAlternative(
        exerciseID: UUID,
        name: String = "Machine Chest Press",
        order: Int = 0,
        enabled: Bool = true,
        segmentID: UUID = UUID()
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
                rir: 2, rpe: 8, tempo: "3-0-1-0",
                effortModeRaw: EffortMode.progression.rawValue,
                rirStart: 3, rirEnd: 1,
                rpeStart: 7, rpeEnd: 9,
                durationMinSeconds: 30, durationMaxSeconds: 45,
                usesDuration: true,
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
                        partialRangeNote: nil, note: "to failure", reps: nil)
                ],
                cardioSegments: try cardioPlan(segmentID: segmentID),
                slotNotes: "seat height 4"))
    }

    private func simpleAlternative(
        exerciseID: UUID, name: String, order: Int, enabled: Bool = true
    ) -> SlotAlternative {
        SlotAlternative(
            order: order, isEnabled: enabled, exerciseID: exerciseID,
            exerciseName: name,
            prescription: AlternativePrescriptionPayload(
                sets: 3, repMin: 8, repMax: 12))
    }

    @discardableResult
    private func exercise(
        _ name: String,
        bodyPart: String? = nil,
        equipment: String? = nil,
        timeBased: Bool = false
    ) -> Exercise {
        let e = Exercise(name: name, bodyPart: bodyPart)
        e.equipmentType = equipment
        e.isTimeBased = timeBased
        context.insert(e)
        return e
    }

    /// A one-block, one-slot routine in the store whose slot prescription
    /// carries `alternatives`.
    @discardableResult
    private func storedRoutine(
        _ name: String = "Upper A",
        alternatives: [SlotAlternative]
    ) throws -> Routine {
        let primary = exercise("Barbell Bench Press", bodyPart: "Chest")

        let p = SlotPrescription(sets: 4, repMin: 6, repMax: 10)
        context.insert(p)
        p.setSlotAlternatives(alternatives)

        let slot = RoutineExercise(exercise: primary, order: 0, setTemplates: [])
        slot.prescription = p
        context.insert(slot)

        let block = RoutineBlock(order: 0, exercises: [slot])
        context.insert(block)

        let routine = Routine(name: name, blocks: [block])
        let variant = RoutineVariant(name: "Default", order: 0)
        context.insert(variant)
        routine.variants.append(variant)
        context.insert(routine)
        try context.save()
        return routine
    }

    private func library() -> [Exercise] {
        (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
    }

    /// Export the way the app does — with the exercise library, so alternative
    /// references resolve to a live name + hints.
    private func exported(_ routine: Routine) -> RoutineTransferDocument {
        RoutineTransfer.export(routine, exercises: library())
    }

    /// Through the real JSON coders and back, which is what a shared file is.
    private func roundTripped(
        _ document: RoutineTransferDocument
    ) throws -> RoutineTransferDocument {
        try RoutineTransfer.makeJSONDecoder().decode(
            RoutineTransferDocument.self,
            from: try RoutineTransfer.makeJSONEncoder().encode(document))
    }

    private func json(_ document: RoutineTransferDocument) throws -> String {
        try XCTUnwrap(
            String(
                data: try RoutineTransfer.makeJSONEncoder().encode(document),
                encoding: .utf8))
    }

    /// The exported alternatives of the document's first slot.
    private func exportedAlternatives(
        _ document: RoutineTransferDocument
    ) -> [RoutineTransferAlternativeDTO] {
        document.routine.blocks.first?.slots.first?.prescription?
            .alternatives?.alternatives ?? []
    }

    @discardableResult
    private func importRoutine(
        _ document: RoutineTransferDocument
    ) throws -> Routine {
        let routines = (try? context.fetch(FetchDescriptor<Routine>())) ?? []
        let existingIDs = Set(routines.map(\.id))
        _ = try RoutineTransfer.import(
            document, among: routines, exercises: library(), in: context)
        return try XCTUnwrap(
            (try context.fetch(FetchDescriptor<Routine>()))
                .first { !existingIDs.contains($0.id) },
            "the imported routine")
    }

    private func importedPrescription(
        _ document: RoutineTransferDocument
    ) throws -> SlotPrescription {
        try XCTUnwrap(
            try importRoutine(document).blocks.first?.exercises.first?
                .prescription,
            "the imported slot's prescription")
    }

    /// Store → export → JSON → import → read back: the whole user journey.
    private func cycled(
        _ routine: Routine
    ) throws -> [SlotAlternative] {
        try importedPrescription(try roundTripped(exported(routine)))
            .slotAlternatives
    }

    /// A hand-written document whose one slot prescription carries `body` as
    /// its raw `alternatives` value — for the malformed cases, which cannot be
    /// built out of the DTOs by construction.
    private func literalDocument(
        alternativesJSON: String
    ) throws -> RoutineTransferDocument {
        let json = """
            {
              "schemaVersion": 1,
              "routine": {
                "name": "Upper A",
                "blocks": [{
                  "order": 0,
                  "isSuperset": false,
                  "slots": [{
                    "order": 0,
                    "exerciseName": "Barbell Bench Press",
                    "setTemplates": [],
                    "prescription": {
                      "sets": 4,
                      "repMin": 6,
                      "repMax": 10,
                      "usesDuration": false,
                      "techniquePlans": [],
                      "alternatives": \(alternativesJSON)
                    }
                  }]
                }]
              }
            }
            """
        return try RoutineTransfer.makeJSONDecoder().decode(
            RoutineTransferDocument.self, from: Data(json.utf8))
    }

    // ==================================================
    // MARK: - 1. Export
    // ==================================================

    /// A routine that never used the feature must export byte-identically to
    /// before this slice: the synthesized encoder omits a nil optional, so the
    /// key does not appear at all.
    func testARoutineWithNoAlternativesDoesNotEmitTheKey() throws {
        let document = exported(try storedRoutine(alternatives: []))

        XCTAssertNil(
            document.routine.blocks.first?.slots.first?.prescription?
                .alternatives)
        XCTAssertFalse(try json(document).contains("alternatives"))
    }

    func testExportingOneAlternativePreservesEveryField() throws {
        let machine = exercise(
            "Machine Chest Press", bodyPart: "Chest", equipment: "Machine")
        let segmentID = UUID()
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id, segmentID: segmentID)
        ])

        let dto = try XCTUnwrap(exportedAlternatives(exported(routine)).first)

        XCTAssertEqual(dto.order, 0)
        XCTAssertTrue(dto.isEnabled)
        XCTAssertEqual(dto.exerciseName, "Machine Chest Press")
        XCTAssertEqual(dto.exerciseBodyPart, "Chest")
        XCTAssertEqual(dto.exerciseEquipmentType, "Machine")
        XCTAssertEqual(dto.exerciseIsTimeBased, false)
        XCTAssertEqual(dto.note, "when the rack is busy")

        let p = dto.prescription
        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
        XCTAssertEqual(p.restSecondsBetweenSets, 90)
        XCTAssertEqual(p.restSecondsAfterExercise, 120)
        XCTAssertEqual(p.rir, 2)
        XCTAssertEqual(p.rpe, 8)
        XCTAssertEqual(p.tempo, "3-0-1-0")
        XCTAssertEqual(p.effortModeRaw, EffortMode.progression.rawValue)
        XCTAssertEqual(p.rirStart, 3)
        XCTAssertEqual(p.rirEnd, 1)
        XCTAssertEqual(p.rpeStart, 7)
        XCTAssertEqual(p.rpeEnd, 9)
        XCTAssertEqual(p.durationMinSeconds, 30)
        XCTAssertEqual(p.durationMaxSeconds, 45)
        XCTAssertTrue(p.usesDuration)
    }

    func testExportingMultipleAlternativesPreservesOrder() throws {
        let machine = exercise("Machine Chest Press")
        let dumbbell = exercise("Dumbbell Bench Press")
        let pushUp = exercise("Push-Up")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id, order: 0),
            simpleAlternative(
                exerciseID: dumbbell.id, name: "Dumbbell Bench Press", order: 1),
            simpleAlternative(exerciseID: pushUp.id, name: "Push-Up", order: 2),
        ])

        let dtos = exportedAlternatives(exported(routine))

        XCTAssertEqual(dtos.map(\.order), [0, 1, 2])
        XCTAssertEqual(
            dtos.map(\.exerciseName),
            ["Machine Chest Press", "Dumbbell Bench Press", "Push-Up"])
    }

    /// Disabled means "prepared, not offered" — it is still prepared work and
    /// must transfer, with the flag intact.
    func testADisabledAlternativeIsExportedAsDisabled() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id, enabled: false)
        ])

        XCTAssertEqual(
            exportedAlternatives(exported(routine)).first?.isEnabled, false)
    }

    func testTheUsageNoteIsExported() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        XCTAssertEqual(
            exportedAlternatives(exported(routine)).first?.note,
            "when the rack is busy")
    }

    func testWarmupSnapshotsAreExported() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        let steps = try XCTUnwrap(
            exportedAlternatives(exported(routine)).first?.prescription
                .warmupSteps)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.kind, .percentage)
        XCTAssertEqual(steps.first?.reps, 10)
        XCTAssertEqual(steps.first?.percentOfWorking, 50)
        XCTAssertEqual(steps.first?.note, "bar only")
        XCTAssertEqual(steps.first?.restSecondsAfter, 60)
    }

    func testTechniqueSnapshotsAreExported() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        let techniques = try XCTUnwrap(
            exportedAlternatives(exported(routine)).first?.prescription
                .techniques)
        XCTAssertEqual(techniques.count, 1)
        XCTAssertEqual(techniques.first?.type, .dropset)
        XCTAssertEqual(techniques.first?.dropPercent, 20)
        XCTAssertEqual(techniques.first?.dropCount, 2)
        XCTAssertEqual(techniques.first?.restSeconds, 15)
        XCTAssertEqual(techniques.first?.note, "to failure")
    }

    func testTheStructuredCardioPlanIsExportedAsReadableStructure() throws {
        let machine = exercise("Machine Chest Press")
        let segmentID = UUID()
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id, segmentID: segmentID)
        ])

        let document = exported(routine)
        let plan = try XCTUnwrap(
            exportedAlternatives(document).first?.prescription.cardioSegments)
        XCTAssertEqual(plan.groups.first?.repeatCount, 3)
        XCTAssertEqual(
            plan.groups.first?.segments.map(\.kind), [.warmUp, .work])
        XCTAssertEqual(plan.groups.first?.segments.first?.id, segmentID)

        // Nested structure, not an opaque blob: the document is JSON people
        // inspect and hand-edit.
        let text = try json(document)
        XCTAssertTrue(text.contains("\"cardioSegments\""))
        XCTAssertTrue(text.contains("\"repeatCount\""))
        XCTAssertTrue(text.contains("\"warmUp\""))
    }

    func testTheTargetDistanceIsExported() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        let p = try XCTUnwrap(
            exportedAlternatives(exported(routine)).first?.prescription)
        XCTAssertEqual(p.targetDistanceMeters, 5_000)
        XCTAssertEqual(p.targetDistanceUnitRaw, DistanceUnit.kilometers.rawValue)
    }

    func testTheAlternativesSlotNotesAreExported() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        XCTAssertEqual(
            exportedAlternatives(exported(routine)).first?.prescription
                .slotNotes,
            "seat height 4")
    }

    /// The reference travels as a name — never as the sender's `UUID`, which
    /// would be meaningless on the recipient's device.
    func testTheExportedReferenceIsANameNotTheSendersID() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        let text = try json(exported(routine))
        XCTAssertTrue(text.contains("\"exerciseName\" : \"Machine Chest Press\""))
        XCTAssertFalse(text.contains("exerciseID"))
        XCTAssertFalse(
            text.contains(machine.id.uuidString),
            "no sender-side exercise id may appear in a transfer document")
    }

    /// The `id` identifies prepared work inside one store; the format carries
    /// content only, and its absence is what makes fresh ids structural.
    func testTheAlternativeIDIsNeverExported() throws {
        let machine = exercise("Machine Chest Press")
        let authored = try richAlternative(exerciseID: machine.id)
        let routine = try storedRoutine(alternatives: [authored])
        let stored = try XCTUnwrap(
            routine.blocks.first?.exercises.first?.prescription?
                .slotAlternatives.first)

        XCTAssertFalse(try json(exported(routine)).contains(stored.id.uuidString))
    }

    /// A stored column this build cannot parse exports as **no alternatives**
    /// rather than shipping corruption onward — the same rule the structured
    /// cardio column follows, and the deliberate difference from
    /// `RoutineDuplicator`, which stays inside one store.
    func testACorruptStoredColumnExportsAsNoAlternatives() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])
        routine.blocks.first?.exercises.first?.prescription?.alternativesData =
            Data("<<garbage>>".utf8)

        XCTAssertNil(
            exported(routine).routine.blocks.first?.slots.first?.prescription?
                .alternatives)
    }

    /// An alternative whose exercise was deleted still transfers: the name
    /// frozen on it at authoring time is a usable reference, and dropping
    /// prepared work would be the worse failure.
    func testAnUnresolvableAlternativeFallsBackToItsFrozenName() throws {
        let routine = try storedRoutine(alternatives: [
            simpleAlternative(
                exerciseID: UUID(), name: "Machine Chest Press", order: 0)
        ])

        let dto = try XCTUnwrap(exportedAlternatives(exported(routine)).first)
        XCTAssertEqual(dto.exerciseName, "Machine Chest Press")
        XCTAssertNil(dto.exerciseBodyPart, "no hints without a resolved row")
    }

    // ==================================================
    // MARK: - 2. Older documents stay compatible
    // ==================================================

    /// Literal v1 JSON with no `alternatives` key — the shape every export
    /// written before this slice has on disk.
    func testALegacyDocumentWithoutTheKeyDecodes() throws {
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
                    "exerciseName": "Barbell Bench Press",
                    "setTemplates": [],
                    "prescription": {
                      "sets": 4,
                      "usesDuration": false,
                      "techniquePlans": []
                    }
                  }]
                }]
              }
            }
            """
        let document = try RoutineTransfer.makeJSONDecoder().decode(
            RoutineTransferDocument.self, from: Data(json.utf8))

        XCTAssertNil(
            document.routine.blocks.first?.slots.first?.prescription?
                .alternatives)
    }

    func testALegacyDocumentImportsWithNoAlternatives() throws {
        let prescription = try importedPrescription(
            try literalDocument(alternativesJSON: "null"))

        XCTAssertNil(prescription.alternativesData)
        XCTAssertEqual(prescription.slotAlternatives, [])
        XCTAssertFalse(prescription.hasSlotAlternatives)
        XCTAssertEqual(prescription.sets, 4, "the rest of the slot still arrives")
    }

    /// This change did not consume a version, so an older build still accepts
    /// documents written by this one — it imports them minus the alternatives
    /// rather than refusing the routine.
    func testSchemaVersionIsUnchanged() {
        XCTAssertEqual(RoutineTransferDocument.currentSchemaVersion, 1)
    }

    // ==================================================
    // MARK: - 3. Import round trip
    // ==================================================

    func testImportingOneAlternativeSucceeds() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        let imported = try cycled(routine)

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.exerciseName, "Machine Chest Press")
    }

    func testImportingMultipleAlternativesPreservesOrder() throws {
        let machine = exercise("Machine Chest Press")
        let dumbbell = exercise("Dumbbell Bench Press")
        let pushUp = exercise("Push-Up")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id, order: 0),
            simpleAlternative(
                exerciseID: dumbbell.id, name: "Dumbbell Bench Press", order: 1),
            simpleAlternative(exerciseID: pushUp.id, name: "Push-Up", order: 2),
        ])

        let imported = try cycled(routine)

        XCTAssertEqual(imported.count, 3)
        XCTAssertEqual(imported.map(\.order), [0, 1, 2])
        XCTAssertEqual(
            imported.map(\.exerciseName),
            ["Machine Chest Press", "Dumbbell Bench Press", "Push-Up"])
    }

    /// The rule the format enforces structurally: no id crosses the wire, so
    /// every imported alternative is new prepared work as far as identity goes.
    func testImportedAlternativesReceiveFreshIDs() throws {
        let machine = exercise("Machine Chest Press")
        let dumbbell = exercise("Dumbbell Bench Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id, order: 0),
            simpleAlternative(
                exerciseID: dumbbell.id, name: "Dumbbell Bench Press", order: 1),
        ])
        let sourceIDs = Set(
            try XCTUnwrap(
                routine.blocks.first?.exercises.first?.prescription?
                    .slotAlternatives
            ).map(\.id))

        let importedIDs = try cycled(routine).map(\.id)

        XCTAssertEqual(importedIDs.count, 2)
        XCTAssertEqual(Set(importedIDs).count, 2, "and unique among themselves")
        for id in importedIDs {
            XCTAssertFalse(
                sourceIDs.contains(id),
                "an imported alternative never reuses the sender's id")
        }
    }

    /// The document's mapping rule for *every* exercise reference: resolve by
    /// name. Importing next to the library the routine was authored against
    /// links to the very same rows.
    func testAnImportedAlternativeLinksToTheMatchingLibraryExercise() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        let imported = try XCTUnwrap(try cycled(routine).first)

        XCTAssertEqual(imported.exerciseID, machine.id)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Exercise>())
                .filter { $0.name == "Machine Chest Press" }.count,
            1,
            "and no second copy of the exercise is created")
    }

    /// The other half of the same rule: a name with no match stub-creates a
    /// custom exercise, carrying the hints the export took from the sender's
    /// row — so a cardio alternative arrives time-based rather than as a blank
    /// strength row.
    func testAnUnmatchedAlternativeExerciseIsStubCreatedWithItsHints() throws {
        let treadmill = exercise(
            "Treadmill Run", bodyPart: "Cardio", equipment: "Machine",
            timeBased: true)
        let routine = try storedRoutine(alternatives: [
            try richAlternative(
                exerciseID: treadmill.id, name: "Treadmill Run")
        ])
        let document = try roundTripped(exported(routine))

        // Delete the exercise before importing: the recipient's library has
        // never seen it.
        context.delete(treadmill)
        try context.save()

        let imported = try XCTUnwrap(
            try importedPrescription(document).slotAlternatives.first)
        let created = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Exercise>())
                .first { $0.name == "Treadmill Run" })

        XCTAssertEqual(imported.exerciseID, created.id)
        XCTAssertEqual(created.bodyPart, "Cardio")
        XCTAssertEqual(created.equipmentType, "Machine")
        XCTAssertTrue(created.isTimeBased)
        XCTAssertTrue(created.isCustom)
    }

    /// An alternative that names the slot's own exercise links to that one row
    /// rather than a second copy of it — one resolution rule, one dedupe.
    func testAlternativeAndSlotReferencesShareOneCreatedExercise() throws {
        let document = try literalDocument(
            alternativesJSON: """
                [{
                  "order": 0,
                  "isEnabled": true,
                  "exerciseName": "barbell bench press",
                  "prescription": { "sets": 3, "usesDuration": false }
                }]
                """)

        let routine = try importRoutine(document)
        let slot = try XCTUnwrap(routine.blocks.first?.exercises.first)
        let alternative = try XCTUnwrap(
            slot.prescription?.slotAlternatives.first)

        XCTAssertEqual(alternative.exerciseID, slot.exercise?.id)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Exercise>()).count, 1,
            "the case-insensitive name resolves to the one row")
    }

    func testImportedAlternativesPreserveExerciseName() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        XCTAssertEqual(
            try cycled(routine).first?.exerciseName, "Machine Chest Press")
    }

    func testImportedAlternativesPreserveTheEnabledFlag() throws {
        let machine = exercise("Machine Chest Press")
        let dumbbell = exercise("Dumbbell Bench Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id, order: 0, enabled: false),
            simpleAlternative(
                exerciseID: dumbbell.id, name: "Dumbbell Bench Press", order: 1,
                enabled: true),
        ])

        XCTAssertEqual(try cycled(routine).map(\.isEnabled), [false, true])
    }

    func testImportedAlternativesPreserveTheUsageNote() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        XCTAssertEqual(try cycled(routine).first?.note, "when the rack is busy")
    }

    func testImportedAlternativesPreserveEveryPrescriptionField() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        let p = try XCTUnwrap(try cycled(routine).first?.prescription)

        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
        XCTAssertEqual(p.restSecondsBetweenSets, 90)
        XCTAssertEqual(p.restSecondsAfterExercise, 120)
        XCTAssertEqual(p.rir, 2)
        XCTAssertEqual(p.rpe, 8)
        XCTAssertEqual(p.tempo, "3-0-1-0")
        XCTAssertEqual(p.effortModeRaw, EffortMode.progression.rawValue)
        XCTAssertEqual(p.rirStart, 3)
        XCTAssertEqual(p.rirEnd, 1)
        XCTAssertEqual(p.rpeStart, 7)
        XCTAssertEqual(p.rpeEnd, 9)
        XCTAssertEqual(p.durationMinSeconds, 30)
        XCTAssertEqual(p.durationMaxSeconds, 45)
        XCTAssertTrue(p.usesDuration)
    }

    func testImportedAlternativesPreserveWarmupSnapshots() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        let steps = try XCTUnwrap(
            try cycled(routine).first?.prescription.warmupSteps)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.kind, .percentage)
        XCTAssertEqual(steps.first?.reps, 10)
        XCTAssertEqual(steps.first?.percentOfWorking, 50)
        XCTAssertEqual(steps.first?.note, "bar only")
        XCTAssertEqual(steps.first?.restSecondsAfter, 60)
    }

    func testImportedAlternativesPreserveTechniqueSnapshots() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        let techniques = try XCTUnwrap(
            try cycled(routine).first?.prescription.techniques)
        XCTAssertEqual(techniques.count, 1)
        XCTAssertEqual(techniques.first?.type, .dropset)
        XCTAssertEqual(techniques.first?.dropPercent, 20)
        XCTAssertEqual(techniques.first?.dropCount, 2)
        XCTAssertEqual(techniques.first?.restSeconds, 15)
        XCTAssertEqual(techniques.first?.note, "to failure")
    }

    /// Including the segment ids and the repeat count — the plans are equal,
    /// not merely alike. Segment identity follows what the *primary* slot's
    /// plan already does on this path: preserved, not reissued.
    func testImportedAlternativesPreserveTheStructuredCardioPlan() throws {
        let machine = exercise("Machine Chest Press")
        let segmentID = UUID()
        let source = try richAlternative(
            exerciseID: machine.id, segmentID: segmentID)
        let routine = try storedRoutine(alternatives: [source])

        let plan = try XCTUnwrap(
            try cycled(routine).first?.prescription.cardioSegments)

        XCTAssertEqual(plan, source.prescription.cardioSegments)
        XCTAssertEqual(plan.groups.first?.repeatCount, 3)
        XCTAssertEqual(plan.groups.first?.segments.first?.id, segmentID)
        XCTAssertEqual(plan.groups.first?.segments.first?.durationSeconds, 300)
    }

    func testImportedAlternativesPreserveTheTargetDistance() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        let p = try XCTUnwrap(try cycled(routine).first?.prescription)
        XCTAssertEqual(p.targetDistanceMeters, 5_000)
        XCTAssertEqual(p.targetDistanceUnitRaw, DistanceUnit.kilometers.rawValue)
    }

    /// A hand-edited impossible distance lands as "no target" rather than
    /// reaching a formatter — the same "re-normalized rather than trusted" rule
    /// the primary prescription's distance follows on this path.
    func testAnImpossibleImportedDistanceIsDroppedWithItsUnit() throws {
        let document = try literalDocument(
            alternativesJSON: """
                [{
                  "order": 0,
                  "exerciseName": "Machine Chest Press",
                  "prescription": {
                    "sets": 3,
                    "usesDuration": false,
                    "targetDistanceMeters": -5,
                    "targetDistanceUnitRaw": "kilometers"
                  }
                }]
                """)

        let imported = try XCTUnwrap(
            try importedPrescription(document).slotAlternatives.first)

        XCTAssertNil(imported.prescription.targetDistanceMeters)
        XCTAssertNil(imported.prescription.targetDistanceUnitRaw)
        XCTAssertEqual(imported.prescription.sets, 3, "the rest survives")
    }

    func testImportedAlternativesPreserveTheirSlotNotes() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])

        XCTAssertEqual(
            try cycled(routine).first?.prescription.slotNotes, "seat height 4")
    }

    /// The whole point of the slice, stated once: what the recipient reads back
    /// through the normal accessor is what the sender authored, id and exercise
    /// reference aside.
    func testImportedAlternativesAreVisibleThroughSlotAlternatives() throws {
        let machine = exercise("Machine Chest Press")
        let source = try richAlternative(exerciseID: machine.id)
        let routine = try storedRoutine(alternatives: [source])

        let imported = try XCTUnwrap(try cycled(routine).first)

        XCTAssertEqual(imported.order, source.order)
        XCTAssertEqual(imported.isEnabled, source.isEnabled)
        XCTAssertEqual(imported.exerciseName, source.exerciseName)
        XCTAssertEqual(imported.note, source.note)
        XCTAssertEqual(imported.prescription, source.prescription)
        XCTAssertEqual(imported.exerciseID, source.exerciseID, "same library row")
        XCTAssertNotEqual(imported.id, source.id, "but new prepared-work identity")
    }

    /// The import preview promises what the import does — an alternative that
    /// will create a library row must be counted, or the promise is an
    /// undercount.
    func testThePreviewCountsAnAlternativesNewExercise() throws {
        let document = try literalDocument(
            alternativesJSON: """
                [{
                  "order": 0,
                  "exerciseName": "Machine Chest Press",
                  "prescription": { "sets": 3, "usesDuration": false }
                }]
                """)

        let preview = RoutineTransfer.preview(
            document, existingExerciseNames: ["Barbell Bench Press"])

        XCTAssertEqual(preview.matchedExerciseNames, ["Barbell Bench Press"])
        XCTAssertEqual(preview.createdExerciseNames, ["Machine Chest Press"])

        let report = try RoutineTransfer.import(
            document,
            among: (try? context.fetch(FetchDescriptor<Routine>())) ?? [],
            exercises: [exercise("Barbell Bench Press")], in: context)
        XCTAssertEqual(report.createdExerciseNames, preview.createdExerciseNames)
        XCTAssertEqual(report.matchedExerciseNames, preview.matchedExerciseNames)
    }

    // ==================================================
    // MARK: - 4. Malformed payloads fail safely
    // ==================================================

    /// An `alternatives` value of the wrong JSON shape entirely. Without the
    /// wrapper this would fail the whole document's decode and the recipient
    /// would lose the routine over one bad key.
    func testAWrongShapedAlternativesValueImportsAsNoAlternatives() throws {
        let document = try literalDocument(
            alternativesJSON: "\"this is not a list\"")

        XCTAssertEqual(
            document.routine.blocks.first?.slots.first?.prescription?
                .alternatives?.alternatives, [])

        let prescription = try importedPrescription(document)
        XCTAssertNil(prescription.alternativesData)
        XCTAssertEqual(prescription.sets, 4, "the rest of the slot still arrives")
        XCTAssertEqual(prescription.repMax, 10)
    }

    /// A malformed element costs itself and never its siblings: no name at all,
    /// a blank name, and an unreadable prescription are each dropped.
    func testAMalformedAlternativeIsDroppedAndItsSiblingsSurvive() throws {
        let document = try literalDocument(
            alternativesJSON: """
                [
                  { "order": 0, "prescription": { "sets": 3 } },
                  { "order": 1, "exerciseName": "   ",
                    "prescription": { "sets": 3 } },
                  { "order": 2, "exerciseName": "Machine Chest Press" },
                  { "order": 3, "exerciseName": "Push-Up",
                    "prescription": "not an object" },
                  { "order": 4, "exerciseName": "Dumbbell Bench Press",
                    "prescription": { "sets": 3, "repMin": 8, "repMax": 12 } }
                ]
                """)

        let imported = try importedPrescription(document).slotAlternatives

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.exerciseName, "Dumbbell Bench Press")
        XCTAssertEqual(imported.first?.order, 0, "and is re-densified to 0")
        XCTAssertEqual(imported.first?.prescription.sets, 3)
    }

    /// A hand-written element missing `order` / `isEnabled` is not malformed —
    /// it takes the defaults, exactly as the stored payload's decoder does.
    func testAnAlternativeMissingOptionalKeysTakesTheDefaults() throws {
        let document = try literalDocument(
            alternativesJSON: """
                [{
                  "exerciseName": "Machine Chest Press",
                  "prescription": { "sets": 3 }
                }]
                """)

        let imported = try XCTUnwrap(
            try importedPrescription(document).slotAlternatives.first)

        XCTAssertEqual(imported.order, 0)
        XCTAssertTrue(imported.isEnabled)
        XCTAssertNil(imported.note)
    }

    /// An empty list is "no alternatives", and no alternatives has exactly one
    /// stored representation — a nil column, not an empty payload.
    func testAnEmptyAlternativesArrayImportsAsANilColumn() throws {
        let prescription = try importedPrescription(
            try literalDocument(alternativesJSON: "[]"))

        XCTAssertNil(prescription.alternativesData)
        XCTAssertEqual(prescription.slotAlternatives, [])
    }

    /// A malformed *plan inside* an otherwise valid alternative costs the plan,
    /// not the alternative — the wrapper's philosophy, one level down.
    func testAWrongShapedCardioPlanCostsThePlanNotTheAlternative() throws {
        let document = try literalDocument(
            alternativesJSON: """
                [{
                  "order": 0,
                  "exerciseName": "Machine Chest Press",
                  "prescription": {
                    "sets": 3,
                    "usesDuration": false,
                    "cardioSegments": "not a plan"
                  }
                }]
                """)

        let imported = try XCTUnwrap(
            try importedPrescription(document).slotAlternatives.first)

        XCTAssertNil(imported.prescription.cardioSegments)
        XCTAssertEqual(imported.prescription.sets, 3)
    }

    // ==================================================
    // MARK: - 5. An imported routine behaves like an authored one
    // ==================================================

    /// Phase H1 on top of H2: the imported routine is an ordinary routine, so
    /// duplicating it deep-copies its alternatives with fresh ids and shared
    /// exercise references.
    func testAnImportedRoutineDuplicatesItsAlternativesCorrectly() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])
        let imported = try importRoutine(try roundTripped(exported(routine)))
        let importedAlternatives = try XCTUnwrap(
            imported.blocks.first?.exercises.first?.prescription?
                .slotAlternatives)

        let copy = RoutineDuplicator.duplicate(
            imported, among: try context.fetch(FetchDescriptor<Routine>()),
            in: context)
        let copied = try XCTUnwrap(
            copy.blocks.first?.exercises.first?.prescription?.slotAlternatives)

        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(
            copied.first?.prescription, importedAlternatives.first?.prescription)
        XCTAssertEqual(
            copied.first?.exerciseID, importedAlternatives.first?.exerciseID,
            "duplication shares definition-level exercises")
        XCTAssertNotEqual(
            copied.first?.id, importedAlternatives.first?.id,
            "but reissues the alternative id")
    }

    /// Phase E on top of H2: starting a workout from the imported routine
    /// freezes its alternatives into the plan, so the switch sheet offers them.
    func testAnImportedRoutineFreezesItsAlternativesIntoTheSessionPlan() throws {
        let machine = exercise("Machine Chest Press")
        let routine = try storedRoutine(alternatives: [
            try richAlternative(exerciseID: machine.id)
        ])
        let imported = try importRoutine(try roundTripped(exported(routine)))
        let importedAlternatives = try XCTUnwrap(
            imported.blocks.first?.exercises.first?.prescription?
                .slotAlternatives)

        let plan = StartWorkoutFromRoutineView.makePlan(from: imported)
        let planExercise = try XCTUnwrap(plan.blocks.first?.exercises.first)

        XCTAssertEqual(planExercise.alternativesSnapshot, importedAlternatives)

        let sessionPlan = SessionPlan(
            from: try XCTUnwrap(planExercise.prescriptionSnapshot),
            notes: planExercise.templateNotesSnapshot,
            alternatives: planExercise.alternativesSnapshot)
        XCTAssertEqual(sessionPlan.alternatives, importedAlternatives)
    }
}
