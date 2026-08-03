import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 3 — schema canary for the additive `SetLog` cardio
/// columns and the `cardioMetrics` / `applyCardioMetrics` accessors.
///
/// The columns are additive with nil defaults, so the properties that matter
/// are: they start nil, they survive a store round-trip, and reading them back
/// through `cardioMetrics` sanitizes anything a hand-edited or imported row
/// might contain. Rendering is covered by `CardioHistorySummaryTests`.
@MainActor
final class SetLogCardioMetricsTests: SwiftDataTestHarness {

    private func makeLog(
        reps: Int = 0, weight: Double? = nil, durationSeconds: Int? = nil
    ) -> SetLog {
        let log = SetLog(
            indexInExercise: 0, reps: reps, weight: weight,
            durationSeconds: durationSeconds)
        context.insert(log)
        return log
    }

    // MARK: - 1. Defaults

    func testCardioFieldsDefaultToNil() {
        let log = makeLog(reps: 8, weight: 60)

        XCTAssertNil(log.distanceMeters)
        XCTAssertNil(log.distanceUnitRaw)
        XCTAssertNil(log.avgHeartRate)
        XCTAssertNil(log.calories)
        XCTAssertNil(log.inclinePercent)
        XCTAssertNil(log.resistanceLevel)
        XCTAssertNil(log.hrZoneRaw)
    }

    /// The constructor is deliberately unchanged by Slice 3, so every existing
    /// call site — active workout, resume, prefill, tests — keeps producing
    /// metric-free sets with no edits.
    func testStrengthSetHasNoCardioMetrics() {
        let log = makeLog(reps: 8, weight: 60)

        XCTAssertTrue(log.cardioMetrics.isEmpty)
        XCTAssertFalse(log.hasCardioMetrics)
    }

    func testTimedHoldSetHasNoCardioMetrics() {
        let log = makeLog(durationSeconds: 60)

        XCTAssertTrue(log.cardioMetrics.isEmpty)
        XCTAssertFalse(log.hasCardioMetrics)
    }

    /// A pre-Slice-3 row has none of these columns; lightweight migration fills
    /// the nil defaults. Round-tripping asserts the default that survives the
    /// store, not just the in-memory init value.
    func testCardioFieldsDefaultToNilThroughStore() throws {
        let log = makeLog(durationSeconds: 1800)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SetLog>())
        XCTAssertEqual(fetched.count, 1)
        let stored = try XCTUnwrap(fetched.first)
        XCTAssertNil(stored.distanceMeters)
        XCTAssertNil(stored.distanceUnitRaw)
        XCTAssertNil(stored.avgHeartRate)
        XCTAssertNil(stored.calories)
        XCTAssertNil(stored.inclinePercent)
        XCTAssertNil(stored.resistanceLevel)
        XCTAssertNil(stored.hrZoneRaw)
        XCTAssertTrue(stored.cardioMetrics.isEmpty)
    }

    // MARK: - 2. Store and read back every field

    func testAllCardioFieldsRoundTripThroughStore() throws {
        let log = makeLog(durationSeconds: 2_700)
        log.applyCardioMetrics(
            CardioMetrics(
                distanceMeters: 6_200,
                distanceUnit: .kilometers,
                avgHeartRate: 142,
                calories: 410,
                inclinePercent: 3,
                resistanceLevel: 8,
                hrZone: .z3
            ))
        try context.save()

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SetLog>()).first)
        XCTAssertEqual(stored.distanceMeters, 6_200)
        XCTAssertEqual(stored.distanceUnitRaw, "km")
        XCTAssertEqual(stored.avgHeartRate, 142)
        XCTAssertEqual(stored.calories, 410)
        XCTAssertEqual(stored.inclinePercent, 3)
        XCTAssertEqual(stored.resistanceLevel, 8)
        XCTAssertEqual(stored.hrZoneRaw, "z3")

        let metrics = stored.cardioMetrics
        XCTAssertEqual(metrics.distanceMeters, 6_200)
        XCTAssertEqual(metrics.distanceUnit, .kilometers)
        XCTAssertEqual(metrics.avgHeartRate, 142)
        XCTAssertEqual(metrics.calories, 410)
        XCTAssertEqual(metrics.inclinePercent, 3)
        XCTAssertEqual(metrics.resistanceLevel, 8)
        XCTAssertEqual(metrics.hrZone, .z3)
        XCTAssertTrue(stored.hasCardioMetrics)
    }

    // MARK: - 3. distanceUnitRaw round-trip

    func testDistanceUnitRawRoundTripsForBothUnits() throws {
        for unit in DistanceUnit.allCases {
            let log = makeLog(durationSeconds: 600)
            log.applyCardioMetrics(
                CardioMetrics(distanceMeters: 5_000, distanceUnit: unit))
            try context.save()

            XCTAssertEqual(log.distanceUnitRaw, unit.rawValue)
            XCTAssertEqual(log.cardioMetrics.distanceUnit, unit)
        }
    }

    /// Distance is stored canonically in meters regardless of entry unit, so a
    /// mile-entered distance is not silently reinterpreted when read back.
    func testDistanceIsStoredCanonicallyInMeters() throws {
        let meters = try XCTUnwrap(DistanceUnit.miles.meters(from: 3))
        let log = makeLog(durationSeconds: 1_500)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: meters, distanceUnit: .miles))

        XCTAssertEqual(log.distanceMeters ?? 0, 4_828.032, accuracy: 0.001)
        XCTAssertEqual(
            log.cardioMetrics.distanceValue(in: .miles) ?? 0, 3, accuracy: 0.0001)
    }

    /// A unit with no distance carries no information; `CardioMetrics` drops it,
    /// so the two columns can never disagree about whether a distance exists.
    func testDistanceUnitIsDroppedWithoutADistance() {
        let log = makeLog(durationSeconds: 600)
        log.applyCardioMetrics(CardioMetrics(distanceUnit: .kilometers))

        XCTAssertNil(log.distanceMeters)
        XCTAssertNil(log.distanceUnitRaw)
    }

    // MARK: - 4. hrZoneRaw round-trip

    func testHRZoneRawRoundTripsForEveryZone() throws {
        for zone in HRZone.allCases {
            let log = makeLog(durationSeconds: 600)
            log.applyCardioMetrics(CardioMetrics(hrZone: zone))
            try context.save()

            XCTAssertEqual(log.hrZoneRaw, zone.rawValue)
            XCTAssertEqual(log.cardioMetrics.hrZone, zone)
        }
    }

    // MARK: - Sanitizing on read

    /// Columns written directly (a hand-edited store, or a future importer bug)
    /// are sanitized by `cardioMetrics` rather than reaching the UI.
    func testInvalidStoredValuesAreSanitizedOnRead() {
        let log = makeLog(durationSeconds: 600)
        log.distanceMeters = -5_000
        log.distanceUnitRaw = "kilometres"
        log.avgHeartRate = 900
        log.calories = -20
        log.inclinePercent = 500
        log.resistanceLevel = .nan
        log.hrZoneRaw = "z9"

        let metrics = log.cardioMetrics
        XCTAssertNil(metrics.distanceMeters)
        XCTAssertNil(metrics.distanceUnit)
        XCTAssertNil(metrics.avgHeartRate)
        XCTAssertNil(metrics.calories)
        XCTAssertNil(metrics.inclinePercent)
        XCTAssertNil(metrics.resistanceLevel)
        XCTAssertNil(metrics.hrZone)
        XCTAssertTrue(metrics.isEmpty)
    }

    /// Writing through `applyCardioMetrics` rejects invalid values *before*
    /// they are persisted, so the store never accumulates rows that only look
    /// clean at read time.
    func testApplyRejectsInvalidValuesAtTheWriteSite() {
        let log = makeLog(durationSeconds: 600)
        log.applyCardioMetrics(
            CardioMetrics(
                distanceMeters: -1, avgHeartRate: 900, calories: 0,
                inclinePercent: 500, resistanceLevel: 1_000))

        XCTAssertNil(log.distanceMeters)
        XCTAssertNil(log.avgHeartRate)
        XCTAssertNil(log.calories)
        XCTAssertNil(log.inclinePercent)
        XCTAssertNil(log.resistanceLevel)
    }

    func testApplyingEmptyMetricsClearsEveryColumn() {
        let log = makeLog(durationSeconds: 600)
        log.applyCardioMetrics(
            CardioMetrics(
                distanceMeters: 5_000, distanceUnit: .kilometers,
                avgHeartRate: 150, calories: 300, inclinePercent: 2,
                resistanceLevel: 5, hrZone: .z4))
        XCTAssertTrue(log.hasCardioMetrics)

        log.applyCardioMetrics(CardioMetrics())

        XCTAssertNil(log.distanceMeters)
        XCTAssertNil(log.distanceUnitRaw)
        XCTAssertNil(log.avgHeartRate)
        XCTAssertNil(log.calories)
        XCTAssertNil(log.inclinePercent)
        XCTAssertNil(log.resistanceLevel)
        XCTAssertNil(log.hrZoneRaw)
        XCTAssertFalse(log.hasCardioMetrics)
    }

    /// Zero incline is a real, recorded setting ("flat"), unlike a zero
    /// distance or calorie count which means "not recorded".
    func testZeroInclineIsPreservedAsARecordedValue() {
        let log = makeLog(durationSeconds: 600)
        log.applyCardioMetrics(CardioMetrics(inclinePercent: 0))

        XCTAssertEqual(log.inclinePercent, 0)
        XCTAssertTrue(log.hasCardioMetrics)
    }

    func testNegativeInclineIsPreservedAsDecline() {
        let log = makeLog(durationSeconds: 600)
        log.applyCardioMetrics(CardioMetrics(inclinePercent: -3))

        XCTAssertEqual(log.inclinePercent, -3)
        XCTAssertEqual(log.cardioMetrics.inclinePercent, -3)
    }

    // MARK: - Analytics isolation

    /// Cardio sets carry no weight and no reps, so they contribute nothing to
    /// e1RM or volume. Slice 3 adds columns only — it must not open a path for
    /// a cardio bout to appear in a strength chart.
    func testCardioSetsContributeNothingToStrengthAnalytics() {
        let ex = Exercise(name: "Treadmill Run", isCustom: false)
        ex.setTimeBased(true)
        ex.setCardio(true)
        context.insert(ex)

        let workout = Workout(date: .now, items: [])
        workout.completedAt = Date().addingTimeInterval(3_600)
        context.insert(workout)

        let log = makeLog(durationSeconds: 2_700)
        log.applyCardioMetrics(
            CardioMetrics(
                distanceMeters: 6_200, distanceUnit: .kilometers,
                avgHeartRate: 142, calories: 410))

        let item = WorkoutItem(exercise: ex, setLogs: [log])
        context.insert(item)
        workout.items.append(item)

        // No exercise qualifies for a strength series at all.
        XCTAssertTrue(
            WorkoutHistoryAnalytics.availableExercises(in: [workout]).isEmpty,
            "A cardio-only workout must offer no strength analytics subject")

        XCTAssertNil(StrengthAnalytics.e1RM(weight: log.weight ?? 0, reps: log.reps))
        XCTAssertEqual(
            StrengthAnalytics.sessionVolume([(weight: log.weight ?? 0, reps: log.reps)]),
            0)
    }
}
