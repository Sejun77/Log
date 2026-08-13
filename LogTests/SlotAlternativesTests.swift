import XCTest

@testable import Log

/// Alternative Exercises Phase B — the pure value types and payload codec.
///
/// Nothing here touches SwiftData: `SlotAlternatives.swift` is value types
/// only, so these are plain `XCTestCase` tests with literal fixtures, matching
/// `StructuredCardioPlanTests`. No `ModelContainer`, no `ModelContext`, no
/// harness.
///
/// The rules the suite pins are the ones `docs/ALTERNATIVE_EXERCISES_DESIGN.md`
/// §5.3 / §8.7 state:
///
///   * everything the user authored round-trips, including a disabled
///     alternative and an alternative that carries warm-ups, techniques and a
///     Cardio Plan,
///   * nil / empty / corrupt all read as `[]` — one representation of "none",
///   * one malformed alternative costs itself and not its siblings,
///   * an unknown future `version` decodes what it can rather than throwing.
final class SlotAlternativesTests: XCTestCase {

    // MARK: - Fixtures

    private let benchID = UUID()
    private let machineID = UUID()
    private let treadmillID = UUID()

    private func warmupStep(order: Int, reps: Int) -> WarmupStepSnapshot {
        WarmupStepSnapshot(
            order: order, kind: .percentage, reps: reps,
            percentOfWorking: 50, note: "bar only", restSecondsAfter: 60)
    }

    private func technique(order: Int) -> TechniquePlanSnapshot {
        TechniquePlanSnapshot(
            order: order, type: .dropset, dropPercent: 20, dropCount: 2,
            rounds: nil, restSeconds: 15, partialRangeNote: nil, note: nil,
            reps: nil)
    }

    private func cardioPlan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(
                segments: [
                    CardioSegment(kind: .warmUp, durationSeconds: 300),
                    CardioSegment(kind: .work, durationSeconds: 1_200),
                ])
        ])
    }

    /// A fully-loaded alternative: every prescription field set, plus warm-ups,
    /// techniques and a Cardio Plan.
    private func richAlternative() throws -> SlotAlternative {
        SlotAlternative(
            order: 0,
            isEnabled: true,
            exerciseID: machineID,
            exerciseName: "Machine Chest Press",
            note: "when the rack is busy",
            prescription: AlternativePrescriptionPayload(
                sets: 3,
                repMin: 8,
                repMax: 12,
                restSecondsBetweenSets: 90,
                restSecondsAfterExercise: 120,
                rir: 2,
                rpe: 8,
                tempo: "3010",
                effortModeRaw: "rirRange",
                rirStart: 3,
                rirEnd: 1,
                rpeStart: 7,
                rpeEnd: 9,
                durationMinSeconds: 30,
                durationMaxSeconds: 45,
                usesDuration: false,
                targetDistanceMeters: 5_000,
                targetDistanceUnitRaw: "km",
                warmupSteps: [warmupStep(order: 0, reps: 10), warmupStep(order: 1, reps: 5)],
                techniques: [technique(order: 0)],
                cardioSegments: try cardioPlan(),
                slotNotes: "seat height 4"))
    }

    private func simpleAlternative(
        order: Int, name: String, enabled: Bool = true
    ) -> SlotAlternative {
        SlotAlternative(
            order: order,
            isEnabled: enabled,
            exerciseID: UUID(),
            exerciseName: name,
            prescription: AlternativePrescriptionPayload(sets: 3, repMin: 8, repMax: 12))
    }

    private func roundTrip(_ list: [SlotAlternative]) throws -> [SlotAlternative] {
        let data = try XCTUnwrap(SlotAlternatives.encode(list))
        return SlotAlternatives.decode(from: data)
    }

    /// Encodes a hand-built payload dictionary, for the tolerance tests that
    /// need to express something the type system cannot produce.
    private func encodeJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// The wire form of a valid alternative, as a mutable dictionary.
    private func alternativeJSON(
        id: UUID = UUID(), order: Int = 0, exerciseID: UUID
    ) -> [String: Any] {
        [
            "id": id.uuidString,
            "order": order,
            "isEnabled": true,
            "exerciseID": exerciseID.uuidString,
            "exerciseName": "Machine Chest Press",
            "prescription": ["sets": 3, "usesDuration": false],
        ]
    }

    // MARK: - 1. Round-trip: one alternative

    func testSingleAlternativeRoundTrips() throws {
        let original = try richAlternative()
        let decoded = try roundTrip([original])

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first, original)
    }

    // MARK: - 2. Round-trip: multiple alternatives

    func testMultipleAlternativesRoundTrip() throws {
        let list = [
            try richAlternative(),
            simpleAlternative(order: 1, name: "DB Bench Press"),
            simpleAlternative(order: 2, name: "Push-Up", enabled: false),
        ]

        XCTAssertEqual(try roundTrip(list), list)
    }

    // MARK: - 3. Ordering is stable

    func testOrderingIsStableAcrossRoundTrip() throws {
        // Authored out of order, and sparsely numbered.
        let list = [
            simpleAlternative(order: 30, name: "third"),
            simpleAlternative(order: 10, name: "first"),
            simpleAlternative(order: 20, name: "second"),
        ]

        let decoded = try roundTrip(list)

        XCTAssertEqual(decoded.map(\.exerciseName), ["first", "second", "third"])
        // `order` is positional metadata, so it is rewritten dense and 0-based.
        XCTAssertEqual(decoded.map(\.order), [0, 1, 2])
        // Re-encoding a normalized list changes nothing further.
        XCTAssertEqual(try roundTrip(decoded), decoded)
    }

    func testEqualOrdersKeepAuthoredSequence() {
        let list = [
            simpleAlternative(order: 0, name: "a"),
            simpleAlternative(order: 0, name: "b"),
            simpleAlternative(order: 0, name: "c"),
        ]

        XCTAssertEqual(
            SlotAlternatives.normalize(list).map(\.exerciseName),
            ["a", "b", "c"])
    }

    // MARK: - 4. Disabled alternative persists

    func testDisabledAlternativePersists() throws {
        let list = [
            simpleAlternative(order: 0, name: "kept on", enabled: true),
            simpleAlternative(order: 1, name: "switched off", enabled: false),
        ]

        let decoded = try roundTrip(list)

        XCTAssertEqual(decoded.map(\.isEnabled), [true, false])
        XCTAssertEqual(decoded[1].exerciseName, "switched off")
    }

    // MARK: - 5. Note persists

    func testNotePersists() throws {
        let decoded = try roundTrip([try richAlternative()])
        XCTAssertEqual(decoded.first?.note, "when the rack is busy")
    }

    func testBlankNoteNormalizesToNil() {
        var alternative = simpleAlternative(order: 0, name: "x")
        alternative.note = "   \n "

        XCTAssertNil(SlotAlternatives.normalize([alternative]).first?.note)
    }

    // MARK: - 6. Exercise id persists

    func testExerciseIDPersists() throws {
        let decoded = try roundTrip([try richAlternative()])
        XCTAssertEqual(decoded.first?.exerciseID, machineID)
    }

    // MARK: - 7. Exercise name persists

    func testExerciseNamePersists() throws {
        let decoded = try roundTrip([try richAlternative()])
        XCTAssertEqual(decoded.first?.exerciseName, "Machine Chest Press")
    }

    /// A blank name is legal — the reference may still resolve, and the
    /// resolved `Exercise` supplies the name. It must not drop the row.
    func testBlankExerciseNameIsKeptAndTrimmed() throws {
        var alternative = simpleAlternative(order: 0, name: "  ")
        alternative.exerciseName = "   "

        let decoded = try roundTrip([alternative])

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.exerciseName, "")
        XCTAssertEqual(decoded.first?.exerciseID, alternative.exerciseID)
    }

    func testExerciseNameIsTrimmed() {
        var alternative = simpleAlternative(order: 0, name: "x")
        alternative.exerciseName = "  Machine Chest Press  "

        XCTAssertEqual(
            SlotAlternatives.normalize([alternative]).first?.exerciseName,
            "Machine Chest Press")
    }

    // MARK: - 8. Prescription fields persist

    func testPrescriptionFieldsPersist() throws {
        let decoded = try XCTUnwrap(try roundTrip([try richAlternative()]).first)
        let p = decoded.prescription

        XCTAssertEqual(p.sets, 3)
        XCTAssertEqual(p.repMin, 8)
        XCTAssertEqual(p.repMax, 12)
        XCTAssertEqual(p.restSecondsBetweenSets, 90)
        XCTAssertEqual(p.restSecondsAfterExercise, 120)
        XCTAssertEqual(p.rir, 2)
        XCTAssertEqual(p.rpe, 8)
        XCTAssertEqual(p.tempo, "3010")
        XCTAssertEqual(p.effortModeRaw, "rirRange")
        XCTAssertEqual(p.rirStart, 3)
        XCTAssertEqual(p.rirEnd, 1)
        XCTAssertEqual(p.rpeStart, 7)
        XCTAssertEqual(p.rpeEnd, 9)
        XCTAssertEqual(p.durationMinSeconds, 30)
        XCTAssertEqual(p.durationMaxSeconds, 45)
        XCTAssertFalse(p.usesDuration)
        XCTAssertEqual(p.slotNotes, "seat height 4")
    }

    func testUsesDurationPersistsWhenTrue() throws {
        var alternative = simpleAlternative(order: 0, name: "Plank")
        alternative.prescription.usesDuration = true
        alternative.prescription.durationMinSeconds = 45
        alternative.prescription.durationMaxSeconds = 60

        let decoded = try XCTUnwrap(try roundTrip([alternative]).first)

        XCTAssertTrue(decoded.prescription.usesDuration)
        XCTAssertEqual(decoded.prescription.durationMinSeconds, 45)
        XCTAssertEqual(decoded.prescription.durationMaxSeconds, 60)
    }

    // MARK: - 9. Warm-up snapshots persist

    func testWarmupSnapshotsPersist() throws {
        let decoded = try XCTUnwrap(try roundTrip([try richAlternative()]).first)
        let steps = decoded.prescription.warmupSteps

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps.map(\.order), [0, 1])
        XCTAssertEqual(steps.map(\.reps), [10, 5])
        XCTAssertEqual(steps.first?.kind, .percentage)
        XCTAssertEqual(steps.first?.percentOfWorking, 50)
        XCTAssertEqual(steps.first?.note, "bar only")
        XCTAssertEqual(steps.first?.restSecondsAfter, 60)
    }

    // MARK: - 10. Technique snapshots persist

    func testTechniqueSnapshotsPersist() throws {
        let decoded = try XCTUnwrap(try roundTrip([try richAlternative()]).first)
        let techniques = decoded.prescription.techniques

        XCTAssertEqual(techniques.count, 1)
        XCTAssertEqual(techniques.first?.type, .dropset)
        XCTAssertEqual(techniques.first?.dropPercent, 20)
        XCTAssertEqual(techniques.first?.dropCount, 2)
        XCTAssertEqual(techniques.first?.restSeconds, 15)
    }

    // MARK: - 11. Structured cardio plan persists

    func testStructuredCardioPlanPersists() throws {
        // Compared against the *same* fixture instance, not a fresh one: every
        // segment carries a stable id, so two calls to `cardioPlan()` are
        // deliberately unequal.
        let original = try richAlternative()
        let authored = try XCTUnwrap(original.prescription.cardioSegments)
        let decoded = try XCTUnwrap(try roundTrip([original]).first)
        let plan = try XCTUnwrap(decoded.prescription.cardioSegments)

        XCTAssertEqual(plan, authored)
        XCTAssertEqual(plan.segmentCount, 2)
        XCTAssertEqual(plan.totalDurationSeconds, 1_500)
    }

    /// An empty plan and no plan are the same state — the rule
    /// `SlotPrescription.structuredCardioPlan` already uses.
    func testEmptyCardioPlanNormalizesToNil() throws {
        var alternative = simpleAlternative(order: 0, name: "Treadmill")
        alternative.exerciseID = treadmillID
        alternative.prescription.cardioSegments = .empty

        XCTAssertNil(
            SlotAlternatives.normalize([alternative]).first?.prescription
                .cardioSegments)
        XCTAssertNil(try roundTrip([alternative]).first?.prescription.cardioSegments)
    }

    // MARK: - 12. Target distance persists

    func testTargetDistancePersists() throws {
        let decoded = try XCTUnwrap(try roundTrip([try richAlternative()]).first)

        XCTAssertEqual(decoded.prescription.targetDistanceMeters, 5_000)
        XCTAssertEqual(decoded.prescription.targetDistanceUnitRaw, "km")
    }

    // MARK: - 13. Empty list

    func testEmptyListEncodesToNil() {
        XCTAssertNil(SlotAlternatives.encode([]))
    }

    func testNilAndEmptyDataDecodeToEmptyList() {
        XCTAssertEqual(SlotAlternatives.decode(from: nil), [])
        XCTAssertEqual(SlotAlternatives.decode(from: Data()), [])
    }

    /// An explicitly empty payload (a shape this build never writes, but an
    /// older or hand-edited column could hold) still reads as `[]`.
    func testEmptyPayloadDecodesToEmptyList() throws {
        let data = try encodeJSON(["version": 1, "alternatives": []])
        XCTAssertEqual(SlotAlternatives.decode(from: data), [])
    }

    // MARK: - 14. Corrupt data

    func testCorruptDataDecodesToEmptyList() {
        let garbage = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        XCTAssertEqual(SlotAlternatives.decode(from: garbage), [])
    }

    func testTruncatedJSONDecodesToEmptyList() throws {
        let full = try XCTUnwrap(SlotAlternatives.encode([try richAlternative()]))
        let truncated = full.prefix(full.count / 2)

        XCTAssertEqual(SlotAlternatives.decode(from: Data(truncated)), [])
    }

    func testNonObjectPayloadDecodesToEmptyList() throws {
        let data = try XCTUnwrap("[1, 2, 3]".data(using: .utf8))
        XCTAssertEqual(SlotAlternatives.decode(from: data), [])
    }

    // MARK: - 15. Malformed alternative inside a valid payload

    func testAlternativeWithoutExerciseReferenceIsDropped() throws {
        var broken = alternativeJSON(exerciseID: benchID)
        broken.removeValue(forKey: "exerciseID")

        let data = try encodeJSON([
            "version": 1,
            "alternatives": [
                broken,
                alternativeJSON(order: 1, exerciseID: machineID),
            ],
        ])

        let decoded = SlotAlternatives.decode(from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.exerciseID, machineID)
        // The survivor is re-indexed from 0 — order is dense after normalize.
        XCTAssertEqual(decoded.first?.order, 0)
    }

    func testAlternativeWithUnreadablePrescriptionIsDropped() throws {
        var broken = alternativeJSON(exerciseID: benchID)
        broken["prescription"] = "not an object"

        let data = try encodeJSON([
            "version": 1,
            "alternatives": [
                broken,
                alternativeJSON(order: 1, exerciseID: machineID),
            ],
        ])

        let decoded = SlotAlternatives.decode(from: data)

        XCTAssertEqual(decoded.map(\.exerciseID), [machineID])
    }

    /// A prescription that is present but empty is *not* malformed: the user
    /// may simply have authored nothing on it.
    func testAlternativeWithEmptyPrescriptionSurvives() throws {
        var sparse = alternativeJSON(exerciseID: benchID)
        sparse["prescription"] = [String: Any]()

        let data = try encodeJSON(["version": 1, "alternatives": [sparse]])
        let decoded = SlotAlternatives.decode(from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.prescription, AlternativePrescriptionPayload())
    }

    /// One bad warm-up step costs the step, not the alternative.
    func testMalformedWarmupStepIsDroppedWithoutFailingTheAlternative() throws {
        var alternative = alternativeJSON(exerciseID: machineID)
        alternative["prescription"] = [
            "usesDuration": false,
            "warmupSteps": [
                ["order": 0, "kind": "percentage", "reps": 10],
                ["order": "not an int", "kind": "percentage"],
            ],
        ]

        let data = try encodeJSON(["version": 1, "alternatives": [alternative]])
        let decoded = SlotAlternatives.decode(from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.prescription.warmupSteps.count, 1)
        XCTAssertEqual(decoded.first?.prescription.warmupSteps.first?.reps, 10)
    }

    // MARK: - 16. Unknown / future payload version

    func testFutureVersionDecodesWhatItCan() throws {
        let data = try encodeJSON([
            "version": 99,
            "alternatives": [alternativeJSON(exerciseID: machineID)],
        ])

        let decoded = SlotAlternatives.decode(from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.exerciseID, machineID)
    }

    func testMissingVersionDefaultsToCurrent() throws {
        let data = try encodeJSON([
            "alternatives": [alternativeJSON(exerciseID: machineID)]
        ])
        let payload = try JSONDecoder().decode(
            SlotAlternativesPayload.self, from: data)

        XCTAssertEqual(payload.version, SlotAlternativesPayload.currentVersion)
        XCTAssertEqual(payload.alternatives.count, 1)
    }

    /// Unknown keys — at the payload, the alternative and the prescription
    /// level — are ignored rather than failing the decode.
    func testUnknownFutureFieldsAreIgnored() throws {
        var alternative = alternativeJSON(exerciseID: machineID)
        alternative["futureAlternativeField"] = "🚀"
        alternative["prescription"] = [
            "sets": 4,
            "usesDuration": false,
            "futurePrescriptionField": ["nested": true],
        ]

        let data = try encodeJSON([
            "version": 2,
            "alternatives": [alternative],
            "futurePayloadField": 7,
        ])

        let decoded = SlotAlternatives.decode(from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.prescription.sets, 4)
    }

    /// Re-encoding a future payload writes **this build's** version: the value
    /// we hold is a v1 value, whatever it was read from.
    func testReEncodingWritesCurrentVersion() throws {
        let data = try encodeJSON([
            "version": 99,
            "alternatives": [alternativeJSON(exerciseID: machineID)],
        ])

        let reEncoded = try XCTUnwrap(
            SlotAlternatives.encode(SlotAlternatives.decode(from: data)))
        let payload = try JSONDecoder().decode(
            SlotAlternativesPayload.self, from: reEncoded)

        XCTAssertEqual(payload.version, SlotAlternativesPayload.currentVersion)
    }

    // MARK: - 17. Duplicate ids

    func testDuplicateIDsAreReissuedAndWorkIsKept() {
        let shared = UUID()
        let replacement = UUID()
        var first = simpleAlternative(order: 0, name: "first")
        var second = simpleAlternative(order: 1, name: "second")
        first.id = shared
        second.id = shared

        let normalized = SlotAlternatives.normalize(
            [first, second], idGenerator: { replacement })

        XCTAssertEqual(normalized.count, 2, "duplicates are repaired, not dropped")
        XCTAssertEqual(normalized.map(\.exerciseName), ["first", "second"])
        XCTAssertEqual(normalized[0].id, shared, "the first occurrence keeps the id")
        XCTAssertEqual(normalized[1].id, replacement)
        XCTAssertEqual(Set(normalized.map(\.id)).count, 2)
    }

    func testDuplicateIDsSurviveDecodeAsUniqueRows() throws {
        let shared = UUID()
        let data = try encodeJSON([
            "version": 1,
            "alternatives": [
                alternativeJSON(id: shared, order: 0, exerciseID: benchID),
                alternativeJSON(id: shared, order: 1, exerciseID: machineID),
            ],
        ])

        let decoded = SlotAlternatives.decode(from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(Set(decoded.map(\.id)).count, 2)
        XCTAssertEqual(decoded.map(\.exerciseID), [benchID, machineID])
    }

    // MARK: - Determinism

    func testEncodingIsDeterministic() throws {
        let list = [try richAlternative(), simpleAlternative(order: 1, name: "DB")]

        let first = try XCTUnwrap(SlotAlternatives.encode(list))
        let second = try XCTUnwrap(SlotAlternatives.encode(list))

        XCTAssertEqual(first, second)
    }

    func testNormalizeIsIdempotent() throws {
        let list = [
            try richAlternative(),
            simpleAlternative(order: 5, name: "DB Bench Press"),
        ]

        let once = SlotAlternatives.normalize(list)
        XCTAssertEqual(SlotAlternatives.normalize(once), once)
    }

    // MARK: - Payload shape

    /// Absent values are omitted rather than written as null, so the common
    /// alternative stays small in the column.
    func testEncodedPrescriptionOmitsAbsentValues() throws {
        let alternative = SlotAlternative(
            exerciseID: machineID,
            exerciseName: "Machine Chest Press",
            prescription: AlternativePrescriptionPayload(sets: 3))

        let data = try XCTUnwrap(SlotAlternatives.encode([alternative]))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let alternatives = try XCTUnwrap(json["alternatives"] as? [[String: Any]])
        let prescription = try XCTUnwrap(
            alternatives.first?["prescription"] as? [String: Any])

        XCTAssertEqual(Set(prescription.keys), ["sets", "usesDuration"])
        XCTAssertNil(alternatives.first?["note"])
    }
}
