import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 5 — the target-distance value type and its storage.
///
/// The invariant this file exists to protect: a **target** is not a **result**.
/// `SlotPrescription.targetDistanceMeters` and `SetLog.distanceMeters` are
/// different fields on different models, and logging a set must never write
/// back to the routine that prescribed it.
@MainActor
final class CardioTargetDistanceTests: SwiftDataTestHarness {

    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles

    private func makePrescription() -> SlotPrescription {
        let p = SlotPrescription()
        context.insert(p)
        return p
    }

    // MARK: - 1–5. Defaults and migration safety

    func testSlotPrescriptionTargetDistanceDefaultsToNil() {
        let p = makePrescription()
        XCTAssertNil(p.targetDistanceMeters)
        XCTAssertNil(p.targetDistanceUnitRaw)
        XCTAssertNil(p.targetDistance(displayUnit: km))
    }

    func testPlannedSnapshotTargetDistanceDefaultsToNil() {
        let snapshot = PlannedPrescriptionSnapshot()
        context.insert(snapshot)
        XCTAssertNil(snapshot.targetDistanceMeters)
        XCTAssertNil(snapshot.targetDistanceUnitRaw)
        XCTAssertNil(snapshot.targetDistance(displayUnit: km))
    }

    func testSessionPlanTargetDistanceDefaultsToNil() {
        let plan = SessionPlan()
        XCTAssertNil(plan.targetDistanceMeters)
        XCTAssertNil(plan.targetDistanceUnitRaw)
        XCTAssertNil(plan.targetDistance(displayUnit: km))
    }

    func testSnapshotPayloadTargetDistanceDefaultsToNil() {
        XCTAssertNil(PrescriptionSnapshotPayload.empty.targetDistanceMeters)
        XCTAssertNil(PrescriptionSnapshotPayload.empty.targetDistanceUnitRaw)
    }

    /// The existing full-argument initializer must still produce a
    /// target-free prescription, so every fixture and builder that predates
    /// this slice is unaffected.
    func testExistingInitializersLeaveTheTargetNil() {
        let p = SlotPrescription(
            sets: 3, repMin: 8, repMax: 12, restSecondsBetweenSets: 90,
            durationMinSeconds: nil, durationMaxSeconds: nil,
            usesDuration: false)
        context.insert(p)
        XCTAssertNil(p.targetDistanceMeters)
        XCTAssertNil(p.targetDistanceUnitRaw)
    }

    /// A prescription written before this slice reads as "no target", not as a
    /// zero-distance target.
    func testLegacyPrescriptionReadsAsNoTarget() throws {
        let p = makePrescription()
        p.sets = 1
        p.usesDuration = true
        p.durationMaxSeconds = 1_800
        try context.save()

        XCTAssertNil(p.targetDistance(displayUnit: km))
    }

    // MARK: - 6–7. Canonical storage

    func testKilometerTargetStoresMetersAndUnit() throws {
        let p = makePrescription()
        p.applyTargetDistance(CardioTargetDistance(text: "5", unit: km))

        XCTAssertEqual(try XCTUnwrap(p.targetDistanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(
            p.targetDistanceUnitRaw, "km",
            "the entry unit is still written for compatibility")

        let target = try XCTUnwrap(p.targetDistance(displayUnit: mi))
        XCTAssertEqual(
            target.unit, mi,
            "display follows the requested unit, not the stored raw")
        XCTAssertEqual(target.displayText, "3.11 mi")
    }

    func testMileTargetStoresMetersAndUnit() throws {
        let p = makePrescription()
        p.applyTargetDistance(CardioTargetDistance(text: "3.1", unit: mi))

        XCTAssertEqual(
            try XCTUnwrap(p.targetDistanceMeters), 3.1 * 1_609.344,
            accuracy: 0.001)
        XCTAssertEqual(p.targetDistanceUnitRaw, "mi")

        let target = try XCTUnwrap(p.targetDistance(displayUnit: km))
        XCTAssertEqual(target.unit, km)
        XCTAssertEqual(target.displayText, "4.99 km")
    }

    /// The stored unit is a display choice, not a second source of truth: the
    /// same target read in the other unit is the same distance.
    func testStorageIsCanonicalRegardlessOfEntryUnit() throws {
        let metric = makePrescription()
        metric.applyTargetDistance(CardioTargetDistance(text: "1.609344", unit: km))
        let imperial = makePrescription()
        imperial.applyTargetDistance(CardioTargetDistance(text: "1", unit: mi))

        XCTAssertEqual(
            try XCTUnwrap(metric.targetDistanceMeters),
            try XCTUnwrap(imperial.targetDistanceMeters),
            accuracy: 0.01)
    }

    // MARK: - 8–9. Empty and invalid input

    func testEmptyTargetStoresNil() {
        let p = makePrescription()
        p.applyTargetDistance(CardioTargetDistance(text: "5", unit: km))
        p.applyTargetDistance(CardioTargetDistance(text: "", unit: km))

        XCTAssertNil(p.targetDistanceMeters)
        XCTAssertNil(
            p.targetDistanceUnitRaw,
            "clearing the distance must clear the unit with it")
    }

    func testInvalidTargetTextNormalizesToNil() {
        for text in ["", " ", "abc", "-5", "0", "0.0", ".", "1e999"] {
            XCTAssertNil(
                CardioTargetDistance(text: text, unit: km),
                "\"\(text)\" should be no target")
        }
    }

    func testOutOfRangeTargetNormalizesToNil() {
        // `CardioLimits.maxDistanceMeters` is 1 000 000 m — 1000 km.
        XCTAssertNil(CardioTargetDistance(text: "1001", unit: km))
        XCTAssertNotNil(CardioTargetDistance(text: "1000", unit: km))
    }

    func testNonFiniteAndNegativeStoredMetersReadAsNoTarget() {
        for meters in [
            -1, 0, Double.nan, .infinity, -.infinity,
            CardioLimits.maxDistanceMeters + 1,
        ] {
            XCTAssertNil(
                CardioTargetDistance(meters: meters, displayUnit: km),
                "\(meters) should be no target")
        }
    }

    /// A hand-edited row that somehow holds an invalid distance must not reach
    /// a formatter — it reads as nil rather than crashing or rendering junk.
    func testCorruptStoredDistanceDegradesToNoTarget() throws {
        let p = makePrescription()
        p.targetDistanceMeters = -500
        p.targetDistanceUnitRaw = "km"
        try context.save()

        XCTAssertNil(p.targetDistance(displayUnit: km))
    }

    // MARK: - 10. The stored raw unit is not a display override

    /// The Settings-only policy in its bluntest form: whatever
    /// `targetDistanceUnitRaw` holds — a real unit, a junk string, or nothing —
    /// the target renders in the unit the caller asked for, and the meters are
    /// untouched.
    func testStoredRawUnitNeverOverridesTheDisplayUnit() throws {
        for raw in ["km", "mi", "kilometres", "", nil] as [String?] {
            let p = makePrescription()
            p.targetDistanceMeters = 5_000
            p.targetDistanceUnitRaw = raw

            let metric = try XCTUnwrap(p.targetDistance(displayUnit: km))
            XCTAssertEqual(metric.unit, km, "raw \(raw ?? "nil")")
            XCTAssertEqual(metric.displayText, "5 km", "raw \(raw ?? "nil")")

            let imperial = try XCTUnwrap(p.targetDistance(displayUnit: mi))
            XCTAssertEqual(imperial.unit, mi, "raw \(raw ?? "nil")")
            XCTAssertEqual(imperial.displayText, "3.11 mi", "raw \(raw ?? "nil")")

            XCTAssertEqual(
                p.targetDistanceMeters, 5_000,
                "reading in either unit must not move the stored meters")
        }
    }

    /// A unit with no distance carries no information and must never resurrect
    /// a target on its own.
    func testUnitWithoutDistanceIsNotATarget() {
        let p = makePrescription()
        p.targetDistanceMeters = nil
        p.targetDistanceUnitRaw = "mi"

        XCTAssertNil(CardioTargetDistance(meters: nil, displayUnit: km))
        XCTAssertNil(p.targetDistance(displayUnit: km))
    }

    // MARK: - Formatting

    func testDisplayTextTrimsTrailingZerosLikeEveryOtherDistance() {
        let cases: [(String, DistanceUnit, String)] = [
            ("5", .kilometers, "5 km"),
            ("5.0", .kilometers, "5 km"),
            ("6.2", .kilometers, "6.2 km"),
            ("6.25", .kilometers, "6.25 km"),
            ("0.5", .miles, "0.5 mi"),
        ]
        for (text, unit, expected) in cases {
            XCTAssertEqual(
                CardioTargetDistance(text: text, unit: unit)?.displayText,
                expected)
        }
    }

    /// The entry field seeds from `valueText`, so it must round-trip: what the
    /// user typed comes back unchanged.
    func testValueTextRoundTripsThroughStorage() throws {
        for text in ["5", "6.2", "6.25", "0.5", "42"] {
            let p = makePrescription()
            p.applyTargetDistance(CardioTargetDistance(text: text, unit: km))
            let target = try XCTUnwrap(p.targetDistance(displayUnit: km))
            XCTAssertEqual(target.valueText, text)
        }
    }

    // MARK: - Target is not a result

    /// The core separation. Setting a target writes only the prescription;
    /// logging a distance writes only the set log.
    func testTargetAndPerformedDistanceAreIndependent() throws {
        let p = makePrescription()
        p.applyTargetDistance(CardioTargetDistance(text: "5", unit: km))

        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_800)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: 4_200, distanceUnit: km))
        try context.save()

        XCTAssertEqual(try XCTUnwrap(p.targetDistanceMeters), 5_000, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(log.distanceMeters), 4_200, accuracy: 0.001,
            "a shortfall against the target must stay visible")
    }

    /// `SetLog` has no target field and `SlotPrescription` has no performed
    /// field — the separation is structural, not conventional.
    func testLoggingCardioMetricsDoesNotTouchThePrescription() throws {
        let p = makePrescription()
        p.applyTargetDistance(CardioTargetDistance(text: "5", unit: km))
        let before = p.targetDistanceMeters

        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 600)
        context.insert(log)
        log.applyCardioMetrics(CardioMetrics(distanceMeters: 9_999))
        try context.save()

        XCTAssertEqual(p.targetDistanceMeters, before)
    }
}
