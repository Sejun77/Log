import SwiftData
import XCTest

@testable import Log

/// Structured Cardio Slice 12E — routine transfer for the segment plan.
///
/// Structure is programming, and programming is what routine transfer carries
/// (`STRUCTURED_CARDIO_DESIGN.md` §6). The field is additive with a nil default
/// and **does not consume a `schemaVersion`**, for a specific reason:
/// `validateSupportedSchemaVersion` *rejects* a document whose version exceeds
/// the reader's, so bumping would make every older build refuse a routine
/// wholesale rather than import it minus its segments.
///
/// The three properties this file exists to pin:
///
///  1. **Old documents still import.** Literal v1 JSON that never had the key.
///  2. **New documents round-trip losslessly** — every segment field, the
///     segment `id`, and `repeatCount` (which no editor writes yet, and which
///     therefore has no other way of being proven to transfer).
///  3. **A malformed plan costs the plan, not the routine.** The wrapper
///     absorbs a wrong-shaped value so the recipient does not lose everything
///     over one bad key.
@MainActor
final class StructuredCardioTransferTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func segment(
        _ kind: CardioSegmentKind,
        id: UUID = UUID(),
        duration: Int? = nil,
        distance: Double? = nil,
        incline: Double? = nil,
        resistance: Double? = nil,
        zone: HRZone? = nil,
        note: String? = nil
    ) throws -> CardioSegment {
        try CardioSegment(
            id: id, kind: kind, durationSeconds: duration,
            distanceMeters: distance, inclinePercent: incline,
            resistanceLevel: resistance, hrZone: zone, note: note)
    }

    /// Every optional field populated at once, so one round trip proves them
    /// all rather than nine tests proving them one at a time.
    private func fullySpecifiedPlan(
        segmentID: UUID = UUID(),
        repeatCount: Int = 1
    ) throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(
                segments: [
                    segment(
                        .work, id: segmentID, duration: 1_200,
                        distance: 5_000, incline: -3, resistance: 8,
                        zone: .z3, note: "Hill repeat")
                ],
                repeatCount: repeatCount)
        ])
    }

    private func flatPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                segment(.warmUp, duration: 300),
                segment(.work, duration: 1_200),
                segment(.coolDown, duration: 300),
            ])
        ])
    }

    private func prescriptionDTO(
        plan: CardioSegmentPlan? = nil
    ) -> RoutineTransferSlotPrescriptionDTO {
        RoutineTransferSlotPrescriptionDTO(
            sets: 1, repMin: nil, repMax: nil, restSecondsBetweenSets: nil,
            restSecondsAfterExercise: nil, rir: nil, rpe: nil, tempo: nil,
            durationMinSeconds: nil, durationMaxSeconds: 1_800,
            usesDuration: true,
            cardioSegments: plan.map(
                RoutineTransferCardioSegmentsDTO.init(plan:)),
            techniquePlans: [], warmupScheme: nil)
    }

    private func doc(
        _ prescription: RoutineTransferSlotPrescriptionDTO
    ) -> RoutineTransferDocument {
        RoutineTransferDocument(
            schemaVersion: 1,
            routine: RoutineTransferRoutineDTO(
                name: "Cardio Day", notes: nil,
                blocks: [
                    RoutineTransferBlockDTO(
                        order: 0, isSuperset: false, restAfterSeconds: nil,
                        supersetRoundRestSeconds: nil,
                        slots: [
                            RoutineTransferSlotDTO(
                                order: 0, exerciseName: "Treadmill Run",
                                exerciseBodyPart: "Cardio",
                                exerciseEquipmentType: nil,
                                exerciseIsTimeBased: true, templateNotes: nil,
                                setTemplates: [], prescription: prescription)
                        ])
                ]))
    }

    private func importedPrescription(
        _ document: RoutineTransferDocument
    ) throws -> SlotPrescription {
        let routines = (try? context.fetch(FetchDescriptor<Routine>())) ?? []
        let exercises = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        _ = try RoutineTransfer.import(
            document, among: routines, exercises: exercises, in: context)
        let imported = try XCTUnwrap(
            (try context.fetch(FetchDescriptor<Routine>()))
                .first { $0.name.hasPrefix("Cardio Day") })
        return try XCTUnwrap(
            imported.blocks.first?.exercises.first?.prescription)
    }

    /// A routine in the store, ready to export.
    private func storedRoutine(
        plan: CardioSegmentPlan?
    ) throws -> Routine {
        let exercise = Exercise(name: "Treadmill Run", bodyPart: "Cardio")
        exercise.isTimeBased = true
        exercise.isCardio = true
        context.insert(exercise)

        let prescription = SlotPrescription()
        prescription.sets = 1
        prescription.usesDuration = true
        prescription.durationMaxSeconds = 1_800
        prescription.setStructuredCardioPlan(plan)
        context.insert(prescription)

        let slot = RoutineExercise(
            exercise: exercise, order: 0, setTemplates: [])
        slot.prescription = prescription
        context.insert(slot)

        let block = RoutineBlock(isSuperset: false, order: 0, exercises: [slot])
        context.insert(block)

        let routine = Routine(name: "Cardio Day", blocks: [block])
        context.insert(routine)
        try context.save()
        return routine
    }

    // ==================================================
    // MARK: - 1. Compatibility with older documents
    // ==================================================

    /// Literal v1 JSON with no `cardioSegments` key — the shape every export
    /// written before this slice has on disk.
    func testLegacyDocumentWithoutSegmentKeyDecodes() throws {
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
                    "exerciseName": "Treadmill Run",
                    "setTemplates": [],
                    "prescription": {
                      "sets": 1,
                      "usesDuration": true,
                      "durationMaxSeconds": 1800,
                      "techniquePlans": []
                    }
                  }]
                }]
              }
            }
            """
        let document = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: Data(json.utf8))

        XCTAssertNil(
            document.routine.blocks.first?.slots.first?.prescription?
                .cardioSegments)
    }

    func testLegacyDocumentImportsWithNoStructuredPlan() throws {
        let prescription = try importedPrescription(doc(prescriptionDTO()))

        XCTAssertNil(prescription.cardioSegmentsData)
        XCTAssertNil(prescription.structuredCardioPlan)
        XCTAssertFalse(prescription.hasStructuredCardioPlan)
    }

    /// The version guard is untouched — this change did not consume a version,
    /// so an older build still accepts documents written by this one.
    func testSchemaVersionIsUnchanged() {
        XCTAssertEqual(RoutineTransferDocument.currentSchemaVersion, 1)
    }

    /// A routine without segments must export byte-identically to before: the
    /// synthesized encoder omits a nil optional, so the key does not appear.
    func testAnUnstructuredRoutineDoesNotEmitTheKey() throws {
        let document = RoutineTransfer.export(try storedRoutine(plan: nil))
        let json = try XCTUnwrap(
            String(data: try JSONEncoder().encode(document), encoding: .utf8))

        XCTAssertFalse(
            json.contains("cardioSegments"),
            "an unstructured routine's document is unchanged by this slice")
    }

    // ==================================================
    // MARK: - 2. Export
    // ==================================================

    func testExportIncludesTheStructuredPlan() throws {
        let routine = try storedRoutine(plan: try flatPlan())

        let document = RoutineTransfer.export(routine)
        let exported = try XCTUnwrap(
            document.routine.blocks.first?.slots.first?.prescription?
                .cardioSegments?.plan)

        XCTAssertEqual(exported.expandedCount, 3)
        XCTAssertEqual(
            exported.expandedSegments().map(\.segment.kind),
            [.warmUp, .work, .coolDown])
    }

    /// Export goes through the decoding accessor, so a column this build cannot
    /// parse exports as no plan rather than shipping corruption to someone
    /// else's device. (This differs from `RoutineDuplicator`, which copies raw
    /// — duplication stays inside one store.)
    func testACorruptStoredColumnExportsAsNoPlan() throws {
        let routine = try storedRoutine(plan: try flatPlan())
        routine.blocks.first?.exercises.first?.prescription?
            .cardioSegmentsData = Data("<<garbage>>".utf8)

        let document = RoutineTransfer.export(routine)

        XCTAssertNil(
            document.routine.blocks.first?.slots.first?.prescription?
                .cardioSegments)
    }

    // ==================================================
    // MARK: - 3. Round trip
    // ==================================================

    /// Every field at once, through encode → decode → import → read back.
    func testRoundTripPreservesEverySegmentField() throws {
        let segmentID = UUID()
        let original = doc(
            prescriptionDTO(
                plan: try fullySpecifiedPlan(segmentID: segmentID)))

        let decoded = try JSONDecoder().decode(
            RoutineTransferDocument.self,
            from: try JSONEncoder().encode(original))
        let prescription = try importedPrescription(decoded)
        let plan = try XCTUnwrap(prescription.structuredCardioPlan)
        let group = try XCTUnwrap(plan.groups.first)
        let segment = try XCTUnwrap(group.segments.first)

        XCTAssertEqual(segment.kind, .work)
        XCTAssertEqual(segment.id, segmentID, "segment id survives")
        XCTAssertEqual(group.repeatCount, 1)
        XCTAssertEqual(segment.durationSeconds, 1_200)
        XCTAssertEqual(segment.distanceMeters, 5_000)
        XCTAssertEqual(segment.inclinePercent, -3, "decline keeps its sign")
        XCTAssertEqual(segment.resistanceLevel, 8)
        XCTAssertEqual(segment.hrZone, .z3)
        XCTAssertEqual(segment.note, "Hill repeat")
    }

    /// `repeatCount` has been in the payload since 12B and no editor writes one
    /// — this is the only place it is proven to transfer, which is exactly the
    /// point of shipping the field early.
    func testRoundTripPreservesRepeatCount() throws {
        let original = doc(
            prescriptionDTO(plan: try fullySpecifiedPlan(repeatCount: 5)))

        let decoded = try JSONDecoder().decode(
            RoutineTransferDocument.self,
            from: try JSONEncoder().encode(original))
        let plan = try XCTUnwrap(
            try importedPrescription(decoded).structuredCardioPlan)

        XCTAssertEqual(plan.groups.first?.repeatCount, 5)
        XCTAssertEqual(plan.expandedCount, 5)
    }

    func testRoundTripPreservesSegmentOrderAcrossAMultiSegmentPlan() throws {
        let original = doc(prescriptionDTO(plan: try flatPlan()))

        let decoded = try JSONDecoder().decode(
            RoutineTransferDocument.self,
            from: try JSONEncoder().encode(original))
        let plan = try XCTUnwrap(
            try importedPrescription(decoded).structuredCardioPlan)

        XCTAssertEqual(
            plan.expandedSegments().map(\.segment.kind),
            [.warmUp, .work, .coolDown])
    }

    /// A full store → export → import → store cycle, which is what the user
    /// actually does.
    func testExportImportCycleReproducesThePlan() throws {
        let source = try storedRoutine(plan: try flatPlan())
        let sourcePlan = try XCTUnwrap(
            source.blocks.first?.exercises.first?.prescription?
                .structuredCardioPlan)

        let document = RoutineTransfer.export(source)
        let reread = try JSONDecoder().decode(
            RoutineTransferDocument.self,
            from: try JSONEncoder().encode(document))
        let routines = try context.fetch(FetchDescriptor<Routine>())
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        _ = try RoutineTransfer.import(
            reread, among: routines, exercises: exercises, in: context)

        let imported = try XCTUnwrap(
            (try context.fetch(FetchDescriptor<Routine>()))
                .first { $0.id != source.id })
        XCTAssertEqual(
            imported.blocks.first?.exercises.first?.prescription?
                .structuredCardioPlan,
            sourcePlan,
            "including every segment id — the plans are equal, not merely alike")
    }

    /// The document is human-readable JSON that people inspect and hand-edit,
    /// so the plan must be nested structure, not an opaque base64 column.
    func testTheSegmentPlanIsEncodedAsReadableJSON() throws {
        let document = RoutineTransfer.export(
            try storedRoutine(plan: try flatPlan()))
        let json = try XCTUnwrap(
            String(data: try JSONEncoder().encode(document), encoding: .utf8))

        XCTAssertTrue(json.contains("\"cardioSegments\""))
        XCTAssertTrue(json.contains("\"groups\""))
        XCTAssertTrue(json.contains("\"warmUp\""))
        XCTAssertTrue(json.contains("\"repeatCount\""))
    }

    // ==================================================
    // MARK: - 4. Malformed payloads fail safely
    // ==================================================

    /// A `cardioSegments` value of the wrong JSON shape entirely. Without the
    /// wrapper this would fail the whole document's decode and the recipient
    /// would lose the routine over one bad key.
    func testAWrongShapedSegmentValueImportsAsNoPlan() throws {
        let json = """
            {
              "schemaVersion": 1,
              "routine": {
                "name": "Cardio Day",
                "blocks": [{
                  "order": 0,
                  "isSuperset": false,
                  "slots": [{
                    "order": 0,
                    "exerciseName": "Treadmill Run",
                    "setTemplates": [],
                    "prescription": {
                      "sets": 1,
                      "usesDuration": true,
                      "durationMaxSeconds": 1800,
                      "cardioSegments": "this is not a plan",
                      "techniquePlans": []
                    }
                  }]
                }]
              }
            }
            """
        let document = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: Data(json.utf8))

        XCTAssertNil(
            document.routine.blocks.first?.slots.first?.prescription?
                .cardioSegments?.plan,
            "unreadable means no plan…")
        let prescription = try importedPrescription(document)
        XCTAssertNil(prescription.structuredCardioPlan)
        XCTAssertEqual(
            prescription.sets, 1, "…and the rest of the slot still arrives")
        XCTAssertEqual(prescription.durationMaxSeconds, 1_800)
    }

    /// A structurally valid plan whose contents are junk: the Slice 12B
    /// decoder repairs it (unknown kind → `.work`, over-range repeat clamped),
    /// so the import is sane rather than rejected.
    func testAnOutOfRangePayloadIsRepairedOnImport() throws {
        let json = """
            {
              "schemaVersion": 1,
              "routine": {
                "name": "Cardio Day",
                "blocks": [{
                  "order": 0,
                  "isSuperset": false,
                  "slots": [{
                    "order": 0,
                    "exerciseName": "Treadmill Run",
                    "setTemplates": [],
                    "prescription": {
                      "sets": 1,
                      "usesDuration": true,
                      "cardioSegments": {
                        "version": 1,
                        "groups": [{
                          "repeatCount": 999,
                          "segments": [
                            { "kind": "sprint", "durationSeconds": 60 }
                          ]
                        }]
                      },
                      "techniquePlans": []
                    }
                  }]
                }]
              }
            }
            """
        let document = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: Data(json.utf8))
        let plan = try XCTUnwrap(
            try importedPrescription(document).structuredCardioPlan)

        XCTAssertEqual(plan.groups.first?.repeatCount, 20, "clamped, not refused")
        XCTAssertEqual(
            plan.groups.first?.segments.first?.kind, .work,
            "an unknown kind degrades to work")
    }

    /// A plan whose every segment normalizes away lands as "no structure" —
    /// the one representation, not an empty payload.
    func testAPlanThatNormalizesAwayImportsAsNoStructure() throws {
        let json = """
            {
              "schemaVersion": 1,
              "routine": {
                "name": "Cardio Day",
                "blocks": [{
                  "order": 0,
                  "isSuperset": false,
                  "slots": [{
                    "order": 0,
                    "exerciseName": "Treadmill Run",
                    "setTemplates": [],
                    "prescription": {
                      "sets": 1,
                      "usesDuration": true,
                      "cardioSegments": {
                        "version": 1,
                        "groups": [{
                          "repeatCount": 1,
                          "segments": [{ "kind": "work" }]
                        }]
                      },
                      "techniquePlans": []
                    }
                  }]
                }]
              }
            }
            """
        let document = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: Data(json.utf8))
        let prescription = try importedPrescription(document)

        XCTAssertNil(prescription.cardioSegmentsData)
        XCTAssertNil(prescription.structuredCardioPlan)
    }

    /// `null` is not an error either.
    func testAnExplicitNullSegmentValueImportsAsNoPlan() throws {
        let json = """
            {
              "schemaVersion": 1,
              "routine": {
                "name": "Cardio Day",
                "blocks": [{
                  "order": 0, "isSuperset": false,
                  "slots": [{
                    "order": 0,
                    "exerciseName": "Treadmill Run",
                    "setTemplates": [],
                    "prescription": {
                      "sets": 1, "usesDuration": true,
                      "cardioSegments": null,
                      "techniquePlans": []
                    }
                  }]
                }]
              }
            }
            """
        let document = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: Data(json.utf8))

        XCTAssertNil(try importedPrescription(document).structuredCardioPlan)
    }

    // ==================================================
    // MARK: - 5. Transfer carries authoring data only
    // ==================================================

    /// Checklist ticks are session-scoped draft state. There is no field for
    /// them in the transfer format and no code path from the store to it — the
    /// document is built from the routine, which has never seen a tick.
    func testTransferCarriesNoChecklistTickState() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let plan = try flatPlan()
        let store = CardioSegmentCheckStore(
            workoutID: UUID(), defaults: defaults)
        let tickedIDs = plan.expandedSegments().map(\.id)
        store.save(slotID: UUID(), checked: Set(tickedIDs))

        let document = RoutineTransfer.export(try storedRoutine(plan: plan))
        let json = try XCTUnwrap(
            String(data: try JSONEncoder().encode(document), encoding: .utf8))

        XCTAssertFalse(json.lowercased().contains("checked"))
        XCTAssertFalse(json.lowercased().contains("tick"))
        for id in tickedIDs {
            XCTAssertFalse(
                json.contains(id),
                "a resolved tick id must never appear in a transfer document")
        }
    }
}
