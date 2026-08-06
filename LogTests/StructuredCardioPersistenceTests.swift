import SwiftData
import XCTest

@testable import Log

/// Structured Cardio Slice 12C — routine-level persistence.
///
/// The plan is stored as a JSON `Data?` column on `SlotPrescription` and read
/// back through `structuredCardioPlan`. What these tests pin is the pair of
/// rules that make an encoded column safe to put in a routine:
///
///  1. **No structure has exactly one representation.** nil payload, empty
///     plan, and unreadable payload all read as `nil`, so no view has to check
///     three states.
///  2. **A bad payload can never make a routine unopenable.** Decoding is
///     tolerant on the way out, so corruption costs the plan, not the slot.
@MainActor
final class StructuredCardioPersistenceTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func prescription() -> SlotPrescription {
        let p = SlotPrescription()
        context.insert(p)
        return p
    }

    private func segment(
        _ kind: CardioSegmentKind, duration: Int? = nil,
        distance: Double? = nil
    ) throws -> CardioSegment {
        try CardioSegment(
            kind: kind, durationSeconds: duration, distanceMeters: distance)
    }

    /// 5 min warm-up → 20 min work → 5 min cool-down.
    private func plan() throws -> CardioSegmentPlan {
        try CardioSegmentPlan(groups: [
            CardioSegmentGroup(segments: [
                segment(.warmUp, duration: 300),
                segment(.work, duration: 1_200),
                segment(.coolDown, duration: 300),
            ])
        ])
    }

    // MARK: - 1. Default state

    func testNewPrescriptionHasNoStructuredPlan() {
        let p = prescription()
        XCTAssertNil(p.cardioSegmentsData)
        XCTAssertNil(p.structuredCardioPlan)
        XCTAssertFalse(p.hasStructuredCardioPlan)
    }

    /// The additive column must not disturb anything a prescription already
    /// does — this is the "existing routines behave exactly as before" claim.
    func testStructuredPlanDoesNotDisturbOtherPrescriptionFields() throws {
        let p = prescription()
        p.sets = 1
        p.usesDuration = true
        p.durationMaxSeconds = 1_800
        p.targetDistanceMeters = 5_000
        p.targetDistanceUnitRaw = DistanceUnit.kilometers.rawValue

        p.setStructuredCardioPlan(try plan())
        try context.save()

        XCTAssertEqual(p.sets, 1)
        XCTAssertTrue(p.usesDuration)
        XCTAssertEqual(p.durationMaxSeconds, 1_800)
        XCTAssertEqual(p.targetDistanceMeters, 5_000)
        XCTAssertEqual(p.targetDistanceUnitRaw, "km")
    }

    // MARK: - 2. Round-trip

    func testSettingAPlanStoresEncodedData() throws {
        let p = prescription()
        p.setStructuredCardioPlan(try plan())

        XCTAssertNotNil(p.cardioSegmentsData)
        XCTAssertTrue(p.hasStructuredCardioPlan)
    }

    func testStoredPlanReadsBackIdentically() throws {
        let p = prescription()
        let original = try plan()
        p.setStructuredCardioPlan(original)
        try context.save()

        XCTAssertEqual(p.structuredCardioPlan, original)
    }

    func testStoredPlanSurvivesSaveAndRefetch() throws {
        let p = prescription()
        p.setStructuredCardioPlan(try plan())
        try context.save()

        let refetched = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SlotPrescription>()).first)
        let read = try XCTUnwrap(refetched.structuredCardioPlan)

        XCTAssertEqual(read.expandedSegments().map(\.segment.kind),
            [.warmUp, .work, .coolDown])
        XCTAssertEqual(read.totalDurationSeconds, 1_800)
    }

    /// Order is the plan; a cool-down that sorted itself before the work would
    /// be a different session.
    func testSegmentOrderIsPreserved() throws {
        let p = prescription()
        p.setStructuredCardioPlan(try plan())
        try context.save()

        XCTAssertEqual(
            p.structuredCardioPlan?.groups.first?.segments.map(\.kind),
            [.warmUp, .work, .coolDown])
    }

    func testSegmentTargetsArePreserved() throws {
        let p = prescription()
        let rich = try CardioSegment(
            kind: .work, durationSeconds: 1_200, distanceMeters: 5_000,
            inclinePercent: -3, resistanceLevel: 8, hrZone: .z3, note: "Tempo")
        p.setStructuredCardioPlan(
            try CardioSegmentPlan(groups: [
                CardioSegmentGroup(segments: [rich])
            ]))
        try context.save()

        let read = try XCTUnwrap(
            p.structuredCardioPlan?.groups.first?.segments.first)
        XCTAssertEqual(read, rich)
        XCTAssertEqual(read.inclinePercent, -3)
        XCTAssertEqual(read.hrZone, .z3)
        XCTAssertEqual(read.note, "Tempo")
    }

    // MARK: - 3. One representation of "no structure"

    func testClearingStoresNil() throws {
        let p = prescription()
        p.setStructuredCardioPlan(try plan())
        XCTAssertNotNil(p.cardioSegmentsData)

        p.clearStructuredCardioPlan()

        XCTAssertNil(p.cardioSegmentsData)
        XCTAssertNil(p.structuredCardioPlan)
    }

    func testSettingNilStoresNil() throws {
        let p = prescription()
        p.setStructuredCardioPlan(try plan())
        p.setStructuredCardioPlan(nil)
        XCTAssertNil(p.cardioSegmentsData)
    }

    /// Deleting the last segment must persist as "unstructured", not as an
    /// empty payload — otherwise the store accumulates two ways to say nothing.
    func testEmptyPlanStoresNilRatherThanAnEmptyPayload() throws {
        let p = prescription()
        p.setStructuredCardioPlan(try plan())

        p.setStructuredCardioPlan(.empty)

        XCTAssertNil(p.cardioSegmentsData)
        XCTAssertNil(p.structuredCardioPlan)
        XCTAssertFalse(p.hasStructuredCardioPlan)
    }

    // MARK: - 4. Corrupt payloads fail safely

    func testUnreadableDataReadsAsNoPlan() throws {
        let p = prescription()
        p.cardioSegmentsData = Data([0x00, 0x01, 0x02])

        XCTAssertNil(p.structuredCardioPlan)
        XCTAssertFalse(p.hasStructuredCardioPlan)
    }

    func testWrongShapeJSONReadsAsNoPlan() throws {
        let p = prescription()
        p.cardioSegmentsData = Data(#"{"unexpected":true}"#.utf8)

        XCTAssertNil(
            p.structuredCardioPlan,
            "a payload with no groups is no plan, not a crash")
    }

    /// A payload whose every segment is unusable normalizes to an empty plan,
    /// which reads as no plan at all.
    func testPayloadThatNormalizesToNothingReadsAsNoPlan() throws {
        let p = prescription()
        p.cardioSegmentsData = Data(
            #"{"version":1,"groups":[{"repeatCount":1,"segments":[{"kind":"work"}]}]}"#
                .utf8)

        XCTAssertNil(p.structuredCardioPlan)
    }

    /// A payload from a future build with unknown fields still reads.
    func testForwardCompatiblePayloadStillReads() throws {
        let p = prescription()
        p.cardioSegmentsData = Data(
            """
            {"version":99,"groups":[{"repeatCount":1,"cadence":90,"segments":[
              {"kind":"work","durationSeconds":600,"power":250}]}]}
            """.utf8)

        XCTAssertEqual(p.structuredCardioPlan?.expandedCount, 1)
    }

    // MARK: - 5. Editor visibility rule

    func testStructuredCardioIsOfferedForCardioOnly() {
        XCTAssertTrue(CardioRoutineRules.showsCardioSegments(.cardio))
        XCTAssertFalse(CardioRoutineRules.showsCardioSegments(.timedHold))
        XCTAssertFalse(CardioRoutineRules.showsCardioSegments(.strength))
    }

    /// Segments replace the warm-up scheme for cardio; the two must never be
    /// offered on the same slot.
    func testSegmentsAndWarmupSchemeAreMutuallyExclusive() {
        for mode in [TrackingMode.strength, .timedHold, .cardio] {
            XCTAssertNotEqual(
                CardioRoutineRules.showsCardioSegments(mode),
                CardioRoutineRules.showsWarmupScheme(mode),
                "\(mode) offers both or neither")
        }
    }

    /// The other cardio rules are untouched by this slice.
    func testExistingCardioRulesAreUnchanged() {
        XCTAssertEqual(CardioRoutineRules.defaultSets(.cardio), 1)
        XCTAssertFalse(CardioRoutineRules.showsTechniques(.cardio))
        XCTAssertFalse(CardioRoutineRules.showsTempo(.cardio))
        XCTAssertFalse(CardioRoutineRules.showsEffortControl(.cardio))
        XCTAssertTrue(CardioRoutineRules.showsTargetDistance(.cardio))
    }

    // MARK: - 6. Coexistence with the distance target

    /// Structured segments are additive: a slot can carry both a whole-bout
    /// distance target and a segment plan, and neither reads the other.
    func testTargetDistanceAndStructuredPlanCoexist() throws {
        let p = prescription()
        p.applyTargetDistance(
            CardioTargetDistance(meters: 5_000, displayUnit: .kilometers))
        p.setStructuredCardioPlan(try plan())
        try context.save()

        XCTAssertEqual(p.targetDistanceMeters, 5_000)
        XCTAssertEqual(p.structuredCardioPlan?.totalDurationSeconds, 1_800)

        // Clearing one leaves the other alone.
        p.clearStructuredCardioPlan()
        XCTAssertEqual(p.targetDistanceMeters, 5_000)
    }

    /// Distance is canonical meters in the payload; the unit is a display
    /// choice made by the caller, never stored in the segment.
    func testSegmentDistanceRendersInTheRequestedUnit() throws {
        let p = prescription()
        p.setStructuredCardioPlan(
            try CardioSegmentPlan(groups: [
                CardioSegmentGroup(segments: [
                    segment(.work, duration: 1_500, distance: 5_000)
                ])
            ]))
        try context.save()

        let read = try XCTUnwrap(p.structuredCardioPlan)
        XCTAssertEqual(
            read.summary(distanceUnit: .kilometers), "1 segment · 25m · 5 km")
        XCTAssertEqual(
            read.summary(distanceUnit: .miles), "1 segment · 25m · 3.11 mi")
        XCTAssertEqual(
            read.totalDistanceMeters, 5_000,
            "the stored quantity does not move with the display unit")
    }

    // MARK: - 7. The editor's plan shape

    /// The editor authors one group at `repeatCount == 1` — repeats exist in
    /// the model but have no UI until 12F. If that ever changes accidentally,
    /// this is the test that says so.
    func testEditorAuthoredPlansUseASingleUnrepeatedGroup() throws {
        let p = prescription()
        p.setStructuredCardioPlan(try plan())

        let read = try XCTUnwrap(p.structuredCardioPlan)
        XCTAssertEqual(read.groups.count, 1)
        XCTAssertEqual(read.groups.first?.repeatCount, 1)
        XCTAssertEqual(read.expandedCount, read.segmentCount)
    }

    /// A repeated plan still stores and reads correctly — the payload is ready
    /// for 12F even though nothing writes one yet.
    func testRepeatedPlansStoreAndReadCorrectly() throws {
        let p = prescription()
        p.setStructuredCardioPlan(
            try CardioSegmentPlan(groups: [
                CardioSegmentGroup(
                    segments: [
                        segment(.work, duration: 60),
                        segment(.recovery, duration: 120),
                    ],
                    repeatCount: 5)
            ]))
        try context.save()

        let read = try XCTUnwrap(p.structuredCardioPlan)
        XCTAssertEqual(read.expandedCount, 10)
        XCTAssertEqual(read.totalDurationSeconds, 900)
    }
}
