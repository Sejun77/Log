import SwiftData
import XCTest

@testable import Log

/// Alternative Exercises Phase C — routine-slot persistence.
///
/// Alternatives are stored as a JSON `Data?` column on `SlotPrescription` and
/// read back through `slotAlternatives`. What these tests pin is the pair of
/// rules that make an encoded column safe to put in a routine — the same two
/// `StructuredCardioPersistenceTests` pins for `cardioSegmentsData`:
///
///  1. **"No alternatives" has exactly one representation.** nil column, empty
///     data, empty list and unreadable payload all read as `[]`, so no view has
///     to check four states.
///  2. **A bad payload can never make a routine unopenable.** Decoding is
///     tolerant on the way out, so corruption costs the alternatives, not the
///     slot.
///
/// The codec itself is Phase B's and is tested exhaustively in
/// `SlotAlternativesTests`; what is new here is that a `@Model` carries it,
/// survives a save + refetch, and disturbs nothing else on the prescription.
@MainActor
final class SlotAlternativePersistenceTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private let machineID = UUID()
    private let dumbbellID = UUID()

    private func prescription() -> SlotPrescription {
        let p = SlotPrescription()
        context.insert(p)
        return p
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
    /// a Cardio Plan, a target distance, and both note fields.
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
                tempo: "3010",
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
        order: Int, name: String, enabled: Bool = true
    ) -> SlotAlternative {
        SlotAlternative(
            order: order,
            isEnabled: enabled,
            exerciseID: dumbbellID,
            exerciseName: name,
            prescription: AlternativePrescriptionPayload(
                sets: 3, repMin: 8, repMax: 12))
    }

    // MARK: - 1. Default state

    func testNewPrescriptionHasNoAlternatives() {
        let p = prescription()

        XCTAssertNil(p.alternativesData)
        XCTAssertEqual(p.slotAlternatives, [])
        XCTAssertFalse(p.hasSlotAlternatives)
    }

    /// The "existing routines behave exactly as before" claim: a prescription
    /// written before this column existed has nil there and reads as having no
    /// alternatives, with no migration step of any kind.
    func testPrescriptionWithNilColumnReadsAsNoAlternatives() throws {
        let p = prescription()
        p.sets = 4
        p.repMin = 6
        p.repMax = 10
        try context.save()

        let refetched = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SlotPrescription>()).first)

        XCTAssertNil(refetched.alternativesData)
        XCTAssertEqual(refetched.slotAlternatives, [])
        XCTAssertEqual(refetched.sets, 4)
    }

    // MARK: - 2. Corrupt payloads fail safely

    func testUnreadableDataReadsAsNoAlternatives() {
        let p = prescription()
        p.alternativesData = Data([0x00, 0x01, 0x02, 0xFF])

        XCTAssertEqual(p.slotAlternatives, [])
        XCTAssertFalse(p.hasSlotAlternatives)
    }

    func testEmptyDataReadsAsNoAlternatives() {
        let p = prescription()
        p.alternativesData = Data()

        XCTAssertEqual(p.slotAlternatives, [])
    }

    func testWrongShapeJSONReadsAsNoAlternatives() {
        let p = prescription()
        p.alternativesData = Data(#"{"unexpected":true}"#.utf8)

        XCTAssertEqual(
            p.slotAlternatives, [],
            "a payload with no alternatives is none, not a crash")
    }

    /// One malformed alternative costs itself, not the slot's other prepared
    /// work — §8.7. Written as raw JSON because the typed API cannot express
    /// an alternative with no exercise reference.
    func testMalformedAlternativeIsDroppedAndSiblingsSurvive() throws {
        let p = prescription()
        p.alternativesData = Data(
            """
            {"version":1,"alternatives":[
              {"id":"\(UUID().uuidString)","order":0,"isEnabled":true,
               "exerciseName":"No reference","prescription":{"usesDuration":false}},
              {"id":"\(UUID().uuidString)","order":1,"isEnabled":true,
               "exerciseID":"\(machineID.uuidString)",
               "exerciseName":"Machine Chest Press",
               "prescription":{"sets":3,"usesDuration":false}}
            ]}
            """.utf8)

        let read = p.slotAlternatives

        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.exerciseID, machineID)
        XCTAssertEqual(read.first?.order, 0, "the survivor is re-indexed dense")
    }

    /// A payload from a future build with unknown fields still reads.
    func testForwardCompatiblePayloadStillReads() {
        let p = prescription()
        p.alternativesData = Data(
            """
            {"version":99,"alternatives":[
              {"id":"\(UUID().uuidString)","order":0,"isEnabled":true,
               "exerciseID":"\(machineID.uuidString)",
               "exerciseName":"Machine Chest Press","futureField":"🚀",
               "prescription":{"sets":3,"usesDuration":false,"cadence":90}}
            ],"futurePayloadField":7}
            """.utf8)

        XCTAssertEqual(p.slotAlternatives.count, 1)
        XCTAssertEqual(p.slotAlternatives.first?.prescription.sets, 3)
    }

    // MARK: - 3. One representation of "none"

    func testSettingAnEmptyListClearsTheColumn() throws {
        let p = prescription()
        p.setSlotAlternatives([try richAlternative()])
        XCTAssertNotNil(p.alternativesData)

        p.setSlotAlternatives([])

        XCTAssertNil(
            p.alternativesData,
            "deleting the last alternative persists as nil, not as an empty payload")
        XCTAssertEqual(p.slotAlternatives, [])
        XCTAssertFalse(p.hasSlotAlternatives)
    }

    func testClearingStoresNil() throws {
        let p = prescription()
        p.setSlotAlternatives([try richAlternative()])

        p.clearSlotAlternatives()

        XCTAssertNil(p.alternativesData)
        XCTAssertEqual(p.slotAlternatives, [])
    }

    // MARK: - 4. Round-trip

    func testSettingOneAlternativeStoresEncodedData() throws {
        let p = prescription()
        p.setSlotAlternatives([try richAlternative()])

        XCTAssertNotNil(p.alternativesData)
        XCTAssertTrue(p.hasSlotAlternatives)
    }

    func testStoredAlternativeReadsBackIdentically() throws {
        let p = prescription()
        let original = try richAlternative()
        p.setSlotAlternatives([original])
        try context.save()

        XCTAssertEqual(p.slotAlternatives, [original])
    }

    func testMultipleAlternativesRoundTrip() throws {
        let p = prescription()
        let list = [
            try richAlternative(),
            simpleAlternative(order: 1, name: "DB Bench Press"),
            simpleAlternative(order: 2, name: "Push-Up"),
        ]
        p.setSlotAlternatives(list)
        try context.save()

        XCTAssertEqual(p.slotAlternatives, list)
    }

    func testDisabledAlternativePersists() throws {
        let p = prescription()
        p.setSlotAlternatives([
            simpleAlternative(order: 0, name: "on", enabled: true),
            simpleAlternative(order: 1, name: "off", enabled: false),
        ])
        try context.save()

        XCTAssertEqual(p.slotAlternatives.map(\.isEnabled), [true, false])
        XCTAssertTrue(
            p.hasSlotAlternatives,
            "a disabled alternative is still prepared work")
    }

    func testBothNoteFieldsPersist() throws {
        let p = prescription()
        p.setSlotAlternatives([try richAlternative()])
        try context.save()

        let read = try XCTUnwrap(p.slotAlternatives.first)
        XCTAssertEqual(read.note, "when the rack is busy")
        XCTAssertEqual(read.prescription.slotNotes, "seat height 4")
    }

    func testPrescriptionFieldsPersist() throws {
        let p = prescription()
        p.setSlotAlternatives([try richAlternative()])
        try context.save()

        let read = try XCTUnwrap(p.slotAlternatives.first).prescription
        XCTAssertEqual(read.sets, 3)
        XCTAssertEqual(read.repMin, 8)
        XCTAssertEqual(read.repMax, 12)
        XCTAssertEqual(read.restSecondsBetweenSets, 90)
        XCTAssertEqual(read.restSecondsAfterExercise, 120)
        XCTAssertEqual(read.rir, 2)
        XCTAssertEqual(read.tempo, "3010")
    }

    func testWarmupSnapshotsPersist() throws {
        let p = prescription()
        p.setSlotAlternatives([try richAlternative()])
        try context.save()

        let steps = try XCTUnwrap(p.slotAlternatives.first).prescription
            .warmupSteps
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.kind, .percentage)
        XCTAssertEqual(steps.first?.reps, 10)
        XCTAssertEqual(steps.first?.percentOfWorking, 50)
        XCTAssertEqual(steps.first?.note, "bar only")
    }

    func testTechniqueSnapshotsPersist() throws {
        let p = prescription()
        p.setSlotAlternatives([try richAlternative()])
        try context.save()

        let techniques = try XCTUnwrap(p.slotAlternatives.first).prescription
            .techniques
        XCTAssertEqual(techniques.count, 1)
        XCTAssertEqual(techniques.first?.type, .dropset)
        XCTAssertEqual(techniques.first?.dropPercent, 20)
        XCTAssertEqual(techniques.first?.dropCount, 2)
        XCTAssertEqual(techniques.first?.restSeconds, 15)
    }

    func testStructuredCardioPlanPersists() throws {
        let p = prescription()
        // Compared against the same fixture instance: segments carry stable
        // ids, so two calls to `cardioPlan()` are deliberately unequal.
        let original = try richAlternative()
        let authored = try XCTUnwrap(original.prescription.cardioSegments)
        p.setSlotAlternatives([original])
        try context.save()

        let read = try XCTUnwrap(
            p.slotAlternatives.first?.prescription.cardioSegments)
        XCTAssertEqual(read, authored)
        XCTAssertEqual(read.expandedSegments().map(\.segment.kind), [.warmUp, .work])
        XCTAssertEqual(read.totalDurationSeconds, 1_500)
    }

    func testTargetDistancePersists() throws {
        let p = prescription()
        p.setSlotAlternatives([try richAlternative()])
        try context.save()

        let read = try XCTUnwrap(p.slotAlternatives.first).prescription
        XCTAssertEqual(read.targetDistanceMeters, 5_000)
        XCTAssertEqual(read.targetDistanceUnitRaw, "km")
    }

    // MARK: - 5. Normalization happens on write

    func testOrderingNormalizesOnWrite() throws {
        let p = prescription()
        p.setSlotAlternatives([
            simpleAlternative(order: 30, name: "third"),
            simpleAlternative(order: 10, name: "first"),
            simpleAlternative(order: 20, name: "second"),
        ])
        try context.save()

        XCTAssertEqual(
            p.slotAlternatives.map(\.exerciseName),
            ["first", "second", "third"])
        XCTAssertEqual(p.slotAlternatives.map(\.order), [0, 1, 2])
    }

    func testDuplicateIDsAreRepairedOnWrite() throws {
        let p = prescription()
        let shared = UUID()
        var first = simpleAlternative(order: 0, name: "first")
        var second = simpleAlternative(order: 1, name: "second")
        first.id = shared
        second.id = shared

        p.setSlotAlternatives([first, second])
        try context.save()

        let read = p.slotAlternatives
        XCTAssertEqual(read.count, 2, "duplicates are repaired, not dropped")
        XCTAssertEqual(read.map(\.exerciseName), ["first", "second"])
        XCTAssertEqual(Set(read.map(\.id)).count, 2)
        XCTAssertEqual(read.first?.id, shared, "the first occurrence keeps its id")
    }

    /// The column holds the normalized form, so reading it back is a fixed
    /// point: no further rewriting happens on the next read or write.
    func testStoredPayloadIsAFixedPoint() throws {
        let p = prescription()
        p.setSlotAlternatives([
            simpleAlternative(order: 5, name: "b"),
            simpleAlternative(order: 1, name: "a"),
        ])
        let firstWrite = p.alternativesData

        p.setSlotAlternatives(p.slotAlternatives)

        XCTAssertEqual(p.alternativesData, firstWrite)
    }

    // MARK: - 6. SwiftData persistence

    func testAlternativesSurviveSaveAndRefetch() throws {
        let p = prescription()
        let original = try richAlternative()
        p.setSlotAlternatives([
            original, simpleAlternative(order: 1, name: "DB Bench Press"),
        ])
        try context.save()

        let refetched = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SlotPrescription>()).first)
        let read = refetched.slotAlternatives

        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.first, original)
        XCTAssertEqual(read.map(\.exerciseName),
            ["Machine Chest Press", "DB Bench Press"])
        XCTAssertEqual(
            read.first?.prescription.cardioSegments,
            original.prescription.cardioSegments)
    }

    /// Alternatives ride along with the slot they belong to, addressed through
    /// the routine graph rather than the prescription fetch above.
    func testAlternativesReadBackThroughTheRoutineSlot() throws {
        let exercise = Exercise(name: "Barbell Bench Press", bodyPart: "Chest")
        let slot = RoutineExercise(exercise: exercise, order: 0, setTemplates: [])
        let p = prescription()
        p.setSlotAlternatives([try richAlternative()])
        slot.prescription = p
        context.insert(exercise)
        context.insert(slot)
        try context.save()

        let refetched = try XCTUnwrap(
            try context.fetch(FetchDescriptor<RoutineExercise>()).first)

        XCTAssertEqual(
            refetched.prescription?.slotAlternatives.first?.exerciseName,
            "Machine Chest Press")
    }

    // MARK: - 7. The additive column disturbs nothing

    /// Mirrors `StructuredCardioPersistenceTests`' equivalent: writing
    /// alternatives must not touch a single existing prescription field.
    func testWritingAlternativesDoesNotDisturbOtherPrescriptionFields() throws {
        let p = prescription()
        p.sets = 4
        p.repMin = 6
        p.repMax = 10
        p.restSecondsBetweenSets = 120
        p.rir = 1
        p.tempo = "2010"
        p.usesDuration = false
        p.targetDistanceMeters = 5_000
        p.targetDistanceUnitRaw = DistanceUnit.kilometers.rawValue
        let cardio = try cardioPlan()
        p.setStructuredCardioPlan(cardio)

        p.setSlotAlternatives([try richAlternative()])
        try context.save()

        XCTAssertEqual(p.sets, 4)
        XCTAssertEqual(p.repMin, 6)
        XCTAssertEqual(p.repMax, 10)
        XCTAssertEqual(p.restSecondsBetweenSets, 120)
        XCTAssertEqual(p.rir, 1)
        XCTAssertEqual(p.tempo, "2010")
        XCTAssertFalse(p.usesDuration)
        XCTAssertEqual(p.targetDistanceMeters, 5_000)
        XCTAssertEqual(p.targetDistanceUnitRaw, "km")
        XCTAssertEqual(
            p.structuredCardioPlan, cardio,
            "the slot's own Cardio Plan is independent of an alternative's")
    }

    /// The converse: the slot's structured cardio column and the alternatives
    /// column are separate storage, so clearing one leaves the other.
    func testClearingAlternativesLeavesTheSlotsOwnCardioPlan() throws {
        let p = prescription()
        p.setStructuredCardioPlan(try cardioPlan())
        p.setSlotAlternatives([try richAlternative()])

        p.clearSlotAlternatives()
        try context.save()

        XCTAssertNil(p.alternativesData)
        XCTAssertNotNil(p.cardioSegmentsData)
        XCTAssertTrue(p.hasStructuredCardioPlan)
    }
}
