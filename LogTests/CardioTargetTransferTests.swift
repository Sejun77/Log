import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 5 — routine transfer round-trip for the target
/// distance.
///
/// The two new keys are additive with nil defaults, so this is deliberately a
/// **no `schemaVersion` bump** change: nothing about a document exported by an
/// earlier build became invalid, and this file's first job is to prove it by
/// decoding literal v1 JSON that never had the keys.
@MainActor
final class CardioTargetTransferTests: SwiftDataTestHarness {

    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles

    // MARK: - Fixtures

    private func prescriptionDTO(
        targetMeters: Double? = nil, targetUnitRaw: String? = nil
    ) -> RoutineTransferSlotPrescriptionDTO {
        RoutineTransferSlotPrescriptionDTO(
            sets: 1, repMin: nil, repMax: nil, restSecondsBetweenSets: nil,
            restSecondsAfterExercise: nil, rir: nil, rpe: nil, tempo: nil,
            durationMinSeconds: nil, durationMaxSeconds: 1_800,
            usesDuration: true,
            targetDistanceMeters: targetMeters,
            targetDistanceUnitRaw: targetUnitRaw,
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

    // MARK: - 37. Old documents still decode

    /// Literal v1 JSON with no target-distance keys — the shape every export
    /// written before this slice has on disk.
    func testLegacyDocumentWithoutTargetKeysDecodes() throws {
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

        let prescription = try XCTUnwrap(
            document.routine.blocks.first?.slots.first?.prescription)
        XCTAssertNil(prescription.targetDistanceMeters)
        XCTAssertNil(prescription.targetDistanceUnitRaw)
    }

    func testLegacyDocumentImportsWithNoTarget() throws {
        let prescription = try importedPrescription(doc(prescriptionDTO()))

        XCTAssertNil(prescription.targetDistanceMeters)
        XCTAssertNil(prescription.targetDistanceUnitRaw)
        XCTAssertNil(prescription.targetDistance(fallbackUnit: km))
    }

    /// The version guard is untouched — this change did not consume a version.
    func testSchemaVersionIsUnchanged() {
        XCTAssertEqual(RoutineTransferDocument.currentSchemaVersion, 1)
    }

    // MARK: - 38. Round-trip

    func testDocumentEncodesAndDecodesTheTarget() throws {
        let original = doc(
            prescriptionDTO(targetMeters: 5_000, targetUnitRaw: "km"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            RoutineTransferDocument.self, from: data)

        XCTAssertEqual(decoded, original)
        let prescription = try XCTUnwrap(
            decoded.routine.blocks.first?.slots.first?.prescription)
        XCTAssertEqual(prescription.targetDistanceMeters, 5_000)
        XCTAssertEqual(prescription.targetDistanceUnitRaw, "km")
    }

    func testExportCarriesTheTargetOffTheModel() throws {
        let ex = Exercise(name: "Treadmill Run")
        context.insert(ex)
        ex.setTimeBased(true)
        ex.setCardio(true)

        let p = SlotPrescription(usesDuration: true)
        p.sets = 1
        p.applyTargetDistance(CardioTargetDistance(text: "3.1", unit: mi))
        context.insert(p)

        let re = RoutineExercise(exercise: ex, order: 0, setTemplates: [])
        context.insert(re)
        re.prescription = p
        let block = RoutineBlock(
            isSuperset: false, order: 0, restAfterSeconds: nil, exercises: [re])
        context.insert(block)
        let routine = Routine(name: "Cardio Day", blocks: [block])
        context.insert(routine)
        try context.save()

        let exported = RoutineTransfer.export(routine)
        let dto = try XCTUnwrap(
            exported.routine.blocks.first?.slots.first?.prescription)

        XCTAssertEqual(
            try XCTUnwrap(dto.targetDistanceMeters), 3.1 * 1_609.344,
            accuracy: 0.001)
        XCTAssertEqual(dto.targetDistanceUnitRaw, "mi")
    }

    func testImportMaterializesTheTarget() throws {
        let prescription = try importedPrescription(
            doc(prescriptionDTO(targetMeters: 5_000, targetUnitRaw: "km")))

        let target = try XCTUnwrap(prescription.targetDistance(fallbackUnit: mi))
        XCTAssertEqual(target.unit, km)
        XCTAssertEqual(target.displayText, "5 km")
    }

    // MARK: - Imported documents are outside data

    /// An import is not trusted: a hand-edited or corrupt distance lands as
    /// "no target" rather than reaching a formatter.
    func testImportRejectsAnInvalidDistance() throws {
        for meters in [-500.0, 0, CardioLimits.maxDistanceMeters + 1] {
            let prescription = try importedPrescription(
                doc(prescriptionDTO(targetMeters: meters, targetUnitRaw: "km")))
            XCTAssertNil(
                prescription.targetDistanceMeters, "\(meters) should be rejected")
            XCTAssertNil(prescription.targetDistanceUnitRaw)
        }
    }

    /// An unusable unit is dropped, but the distance it belonged to survives —
    /// the value is canonical meters, so it is still correct.
    func testImportKeepsTheDistanceWhenTheUnitIsUnparseable() throws {
        let prescription = try importedPrescription(
            doc(
                prescriptionDTO(
                    targetMeters: 5_000, targetUnitRaw: "kilometres")))

        XCTAssertEqual(
            try XCTUnwrap(prescription.targetDistanceMeters), 5_000,
            accuracy: 0.001)
        XCTAssertNil(prescription.targetDistanceUnitRaw)
        XCTAssertEqual(
            prescription.targetDistance(fallbackUnit: km)?.displayText, "5 km",
            "the fallback unit renders it rather than dropping it")
    }

    /// A unit with no distance must not survive on its own.
    func testImportDropsAUnitWithoutADistance() throws {
        let prescription = try importedPrescription(
            doc(prescriptionDTO(targetMeters: nil, targetUnitRaw: "mi")))

        XCTAssertNil(prescription.targetDistanceMeters)
        XCTAssertNil(prescription.targetDistanceUnitRaw)
    }
}
