import XCTest

@testable import Log

/// Pure round-trip + format tests for the Routine Transfer v2 wire DTOs
/// (Slice A). No SwiftData / `ModelContext` — value-in / value-out, mirroring
/// `CSVCodecTests`. Pins: lossless encode→decode of the full nested graph,
/// verbatim raw-string survival (incl. unknown future cases), minimal/empty
/// representability, that the JSON carries **no** SwiftData identity keys, and
/// the schema-version guard.
final class RoutineTransferDTOTests: XCTestCase {

    // MARK: - Helpers

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A fully populated document exercising every DTO field.
    private func fullDocument() -> RoutineTransferDocument {
        let warmup = RoutineTransferWarmupSchemeDTO(
            name: "Ramp",
            steps: [
                RoutineTransferWarmupStepDTO(
                    order: 0, kindRaw: "percentage", reps: 5,
                    percentOfWorking: 0.5, restSecondsAfter: 30,
                    note: "easy", weight: nil),
                RoutineTransferWarmupStepDTO(
                    order: 1, kindRaw: "fixedWeight", reps: 3,
                    percentOfWorking: nil, restSecondsAfter: 45,
                    note: nil, weight: 40),
            ]
        )
        let technique = RoutineTransferTechniquePlanDTO(
            order: 0, typeRaw: "dropset", repMin: 6, repMax: 10, reps: nil,
            durationSeconds: nil, restSeconds: 15, rounds: 2, dropPercent: 20,
            dropCount: 2, partialRangeNote: "bottom half", note: "burn",
            appliesToRaw: "lastWorkingSet", appliesToSetNumber: nil,
            appliesToSetIndicesRaw: "0,2", dropsetEffortRaw: "fixedReps",
            dropsetEffortReps: 8)
        let prescription = RoutineTransferSlotPrescriptionDTO(
            sets: 4, repMin: 8, repMax: 12, restSecondsBetweenSets: 90,
            restSecondsAfterExercise: 120, rir: 2, rpe: 8.5, tempo: "3-1-1",
            durationMinSeconds: nil, durationMaxSeconds: nil, usesDuration: false,
            techniquePlans: [technique], warmupScheme: warmup)
        let slot = RoutineTransferSlotDTO(
            order: 0, exerciseName: "Bench Press", exerciseBodyPart: "Chest",
            exerciseEquipmentType: "Barbell", exerciseIsTimeBased: false,
            templateNotes: "pause on chest",
            setTemplates: [
                RoutineTransferSetTemplateDTO(
                    order: 0, kindRaw: "working", targetReps: 8,
                    targetWeight: 80, restSecondsAfter: 90, durationSeconds: nil)
            ],
            prescription: prescription)
        let block = RoutineTransferBlockDTO(
            order: 0, isSuperset: true, restAfterSeconds: 60,
            supersetRoundRestSeconds: 120, slots: [slot])
        let routine = RoutineTransferRoutineDTO(
            name: "Push A", notes: "heavy day", blocks: [block])
        return RoutineTransferDocument(
            schemaVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "2.0",
            routine: routine)
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

    // MARK: - 1 + 2. Full populated round-trip preserves the nested graph

    func testFullDocumentRoundTripsEqual() throws {
        let doc = fullDocument()
        let decoded = try roundTrip(doc)
        XCTAssertEqual(decoded, doc)
    }

    func testNestedGraphSurvivesRoundTrip() throws {
        let decoded = try roundTrip(fullDocument())
        let block = decoded.routine.blocks.first
        let slot = block?.slots.first
        let presc = slot?.prescription

        XCTAssertEqual(decoded.routine.blocks.count, 1)
        XCTAssertEqual(block?.slots.count, 1)
        XCTAssertEqual(slot?.setTemplates.count, 1)
        XCTAssertNotNil(presc)
        XCTAssertEqual(presc?.techniquePlans.count, 1)
        XCTAssertEqual(presc?.warmupScheme?.steps.count, 2)
        // Spot-check a deep leaf value survived.
        XCTAssertEqual(presc?.warmupScheme?.steps.last?.weight, 40)
        XCTAssertEqual(slot?.setTemplates.first?.targetWeight, 80)
    }

    // MARK: - 3. Raw enum strings survive verbatim (incl. unknown cases)

    func testRawStringsSurviveIncludingUnknownValues() throws {
        let technique = RoutineTransferTechniquePlanDTO(
            order: 0, typeRaw: "quantumSet", repMin: nil, repMax: nil,
            reps: nil, durationSeconds: nil, restSeconds: nil, rounds: nil,
            dropPercent: nil, dropCount: nil, partialRangeNote: nil, note: nil,
            appliesToRaw: "everyThirdMoonday", appliesToSetNumber: nil,
            appliesToSetIndicesRaw: nil, dropsetEffortRaw: "telepathic",
            dropsetEffortReps: nil)
        let presc = RoutineTransferSlotPrescriptionDTO(
            sets: 1, repMin: nil, repMax: nil, restSecondsBetweenSets: nil,
            restSecondsAfterExercise: nil, rir: nil, rpe: nil, tempo: nil,
            durationMinSeconds: nil, durationMaxSeconds: nil, usesDuration: false,
            techniquePlans: [technique], warmupScheme: nil)
        let slot = RoutineTransferSlotDTO(
            order: 0, exerciseName: "X", exerciseBodyPart: nil,
            exerciseEquipmentType: nil, exerciseIsTimeBased: nil,
            templateNotes: nil,
            setTemplates: [
                RoutineTransferSetTemplateDTO(
                    order: 0, kindRaw: "myFutureKind", targetReps: 1,
                    targetWeight: nil, restSecondsAfter: nil, durationSeconds: nil)
            ],
            prescription: presc)
        let doc = RoutineTransferDocument(
            routine: RoutineTransferRoutineDTO(
                name: "R", notes: nil,
                blocks: [
                    RoutineTransferBlockDTO(
                        order: 0, isSuperset: false, restAfterSeconds: nil,
                        supersetRoundRestSeconds: nil, slots: [slot])
                ]))

        let decoded = try roundTrip(doc)
        let dt = decoded.routine.blocks.first?.slots.first
        XCTAssertEqual(dt?.setTemplates.first?.kindRaw, "myFutureKind")
        XCTAssertEqual(dt?.prescription?.techniquePlans.first?.typeRaw, "quantumSet")
        XCTAssertEqual(
            dt?.prescription?.techniquePlans.first?.appliesToRaw,
            "everyThirdMoonday")
        XCTAssertEqual(
            dt?.prescription?.techniquePlans.first?.dropsetEffortRaw, "telepathic")
    }

    // MARK: - 4. Nil-heavy minimal routine

    func testNilHeavyMinimalRoutineRoundTrips() throws {
        let slot = RoutineTransferSlotDTO(
            order: 0, exerciseName: "Squat", exerciseBodyPart: nil,
            exerciseEquipmentType: nil, exerciseIsTimeBased: nil,
            templateNotes: nil, setTemplates: [], prescription: nil)
        let doc = RoutineTransferDocument(
            exportedAt: nil, appVersion: nil,
            routine: RoutineTransferRoutineDTO(
                name: "Min", notes: nil,
                blocks: [
                    RoutineTransferBlockDTO(
                        order: 0, isSuperset: false, restAfterSeconds: nil,
                        supersetRoundRestSeconds: nil, slots: [slot])
                ]))
        XCTAssertEqual(try roundTrip(doc), doc)
    }

    // MARK: - 5. Empty routine (no blocks) is representable

    func testEmptyRoutineRoundTrips() throws {
        let doc = RoutineTransferDocument(
            routine: RoutineTransferRoutineDTO(
                name: "Empty", notes: nil, blocks: []))
        let decoded = try roundTrip(doc)
        XCTAssertEqual(decoded, doc)
        XCTAssertTrue(decoded.routine.blocks.isEmpty)
    }

    // MARK: - 6. Superset block round-trips its round rest

    func testSupersetBlockRoundRestRoundTrips() throws {
        let block = RoutineTransferBlockDTO(
            order: 2, isSuperset: true, restAfterSeconds: 30,
            supersetRoundRestSeconds: 150, slots: [])
        let doc = RoutineTransferDocument(
            routine: RoutineTransferRoutineDTO(
                name: "SS", notes: nil, blocks: [block]))
        let decoded = try roundTrip(doc)
        let b = decoded.routine.blocks.first
        XCTAssertEqual(b?.isSuperset, true)
        XCTAssertEqual(b?.supersetRoundRestSeconds, 150)
        XCTAssertEqual(b?.restAfterSeconds, 30)
    }

    // MARK: - 7. JSON carries no SwiftData identity keys

    func testJSONHasNoForbiddenIdentityKeys() throws {
        let data = try JSONEncoder().encode(fullDocument())
        let json = try JSONSerialization.jsonObject(with: data)
        let keys = allKeys(in: json)

        // Exact-key checks (not naive "id" substring — "durationSeconds" etc.
        // legitimately contain those letters).
        let forbidden: Set<String> = [
            "id", "persistentIdentifier", "slotID", "workout", "history",
            "routineID", "routineSlotID", "routineVariantID",
        ]
        let hits = keys.intersection(forbidden)
        XCTAssertTrue(hits.isEmpty, "Forbidden identity keys present: \(hits)")

        // Sanity: the expected content keys *are* present.
        XCTAssertTrue(keys.contains("schemaVersion"))
        XCTAssertTrue(keys.contains("exerciseName"))
        XCTAssertTrue(keys.contains("supersetRoundRestSeconds"))
    }

    // MARK: - 8. Schema-version guard

    func testCurrentSchemaVersionIsSupported() throws {
        let doc = RoutineTransferDocument(
            schemaVersion: RoutineTransferDocument.currentSchemaVersion,
            routine: RoutineTransferRoutineDTO(name: "R", notes: nil, blocks: []))
        XCTAssertNoThrow(try doc.validateSupportedSchemaVersion())
    }

    func testUnsupportedFutureSchemaVersionIsRejected() {
        let future = RoutineTransferDocument.currentSchemaVersion + 1
        let doc = RoutineTransferDocument(
            schemaVersion: future,
            routine: RoutineTransferRoutineDTO(name: "R", notes: nil, blocks: []))
        XCTAssertThrowsError(try doc.validateSupportedSchemaVersion()) { err in
            XCTAssertEqual(
                err as? RoutineTransferError,
                .unsupportedSchemaVersion(
                    found: future,
                    supported: RoutineTransferDocument.currentSchemaVersion))
        }
    }

    func testCurrentSchemaVersionConstantIsOne() {
        XCTAssertEqual(RoutineTransferDocument.currentSchemaVersion, 1)
    }

    // MARK: - 9. Shared ISO-8601 JSON coders

    private func emptyRoutineJSON(exportedAt: String) -> Data {
        Data(
            """
            {"schemaVersion":1,"exportedAt":\(exportedAt),
             "routine":{"name":"R","blocks":[]}}
            """.utf8)
    }

    func testDecoderAcceptsISO8601ExportedAtString() throws {
        // A plain JSONDecoder would reject this string-form date.
        let data = emptyRoutineJSON(exportedAt: "\"2026-06-01T00:00:00Z\"")
        let doc = try RoutineTransfer.makeJSONDecoder()
            .decode(RoutineTransferDocument.self, from: data)
        XCTAssertEqual(doc.schemaVersion, 1)
        XCTAssertEqual(
            doc.exportedAt, Date(timeIntervalSince1970: 1_780_272_000))
        XCTAssertEqual(doc.routine.name, "R")
    }

    func testDecoderAcceptsNullExportedAt() throws {
        let data = emptyRoutineJSON(exportedAt: "null")
        let doc = try RoutineTransfer.makeJSONDecoder()
            .decode(RoutineTransferDocument.self, from: data)
        XCTAssertNil(doc.exportedAt)
    }

    func testEncoderWritesISO8601StringNotNumericTimestamp() throws {
        let doc = RoutineTransferDocument(
            exportedAt: Date(timeIntervalSince1970: 1_780_272_000),
            routine: RoutineTransferRoutineDTO(name: "R", notes: nil, blocks: []))
        let data = try RoutineTransfer.makeJSONEncoder().encode(doc)

        // The JSON value must be the ISO-8601 *string*, not a bare number.
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let exportedAt = obj?["exportedAt"]
        XCTAssertTrue(
            exportedAt is String, "exportedAt should encode as an ISO-8601 string")
        XCTAssertEqual(exportedAt as? String, "2026-06-01T00:00:00Z")
    }

    func testConfiguredCodersRoundTripWithDate() throws {
        let doc = RoutineTransferDocument(
            exportedAt: Date(timeIntervalSince1970: 1_780_272_000),
            appVersion: "2.0",
            routine: RoutineTransferRoutineDTO(name: "R", notes: "n", blocks: []))
        let data = try RoutineTransfer.makeJSONEncoder().encode(doc)
        let decoded = try RoutineTransfer.makeJSONDecoder()
            .decode(RoutineTransferDocument.self, from: data)
        XCTAssertEqual(decoded, doc)
    }

    func testUnsupportedSchemaVersionStillThrowsAfterISODecode() throws {
        let data = Data(
            """
            {"schemaVersion":999,"exportedAt":"2026-06-01T00:00:00Z",
             "routine":{"name":"R","blocks":[]}}
            """.utf8)
        let doc = try RoutineTransfer.makeJSONDecoder()
            .decode(RoutineTransferDocument.self, from: data)
        XCTAssertThrowsError(try doc.validateSupportedSchemaVersion()) { err in
            XCTAssertEqual(
                err as? RoutineTransferError,
                .unsupportedSchemaVersion(
                    found: 999,
                    supported: RoutineTransferDocument.currentSchemaVersion))
        }
    }

    func testConfiguredDecoderStillRejectsInvalidJSON() {
        let data = Data("{}".utf8)  // missing required keys
        XCTAssertThrowsError(
            try RoutineTransfer.makeJSONDecoder()
                .decode(RoutineTransferDocument.self, from: data)
        ) { err in
            XCTAssertTrue(err is DecodingError)
        }
    }
}
