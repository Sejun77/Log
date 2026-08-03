import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 3 — the History set-row summary.
///
/// The single most important assertion in this file is
/// `testDurationOnlyRowRendersExactlyAsBefore`: History has always rendered a
/// duration as the literal `"\(seconds)s"`, and every timed hold plus every
/// beta cardio log recorded before this slice is a duration-only row. If that
/// string ever changes, thousands of existing History rows change with it.
///
/// The rest pin the additive behavior: present metrics appear, absent metrics
/// are omitted with no placeholder, invalid stored values are ignored rather
/// than crashing, and strength rows are never claimed by this path at all.
@MainActor
final class CardioHistorySummaryTests: SwiftDataTestHarness {

    /// Fixed fallback so no assertion depends on the tester's locale or on the
    /// `AppSettings.distanceUnit` preference. The fallback-specific tests pass
    /// their own unit explicitly.
    private let km = DistanceUnit.kilometers

    @discardableResult
    private func makeLog(
        reps: Int = 0,
        weight: Double? = nil,
        durationSeconds: Int? = nil,
        metrics: CardioMetrics? = nil
    ) -> SetLog {
        let log = SetLog(
            indexInExercise: 0, reps: reps, weight: weight,
            durationSeconds: durationSeconds)
        context.insert(log)
        if let metrics { log.applyCardioMetrics(metrics) }
        return log
    }

    private func text(
        _ log: SetLog, fallbackUnit: DistanceUnit? = nil
    ) -> String? {
        CardioHistorySummary.text(for: log, fallbackUnit: fallbackUnit ?? km)
    }

    // MARK: - 1. Backward compatibility

    /// The compatibility guarantee, asserted against the literal string rather
    /// than against a helper, so a change to the helper cannot silently satisfy
    /// it.
    func testDurationOnlyRowRendersExactlyAsBefore() {
        for seconds in [1, 30, 45, 60, 90, 1_800, 2_700] {
            let log = makeLog(durationSeconds: seconds)
            XCTAssertEqual(text(log), "\(seconds)s")
        }
    }

    /// A timed hold (Plank) is a duration-only row and must be untouched.
    func testTimedHoldRowIsUnchanged() {
        let log = makeLog(durationSeconds: 60)
        XCTAssertEqual(text(log), "60s")
        XCTAssertFalse(log.hasCardioMetrics)
    }

    /// Strength sets return nil, so `HistoryView` falls through to its existing
    /// weight/reps rendering, which Slice 3 does not touch.
    func testStrengthRowYieldsNoSummary() {
        XCTAssertNil(text(makeLog(reps: 8, weight: 60)))
        XCTAssertNil(text(makeLog(reps: 12, weight: nil)))
        XCTAssertNil(text(makeLog(reps: 0, weight: nil)))
    }

    /// History has always gated on `dur > 0`; a zero or negative duration with
    /// no metrics stays a strength row.
    func testNonPositiveDurationWithoutMetricsYieldsNoSummary() {
        XCTAssertNil(text(makeLog(reps: 8, weight: 60, durationSeconds: 0)))
        XCTAssertNil(text(makeLog(reps: 8, weight: 60, durationSeconds: -5)))
    }

    // MARK: - 2. Distance and derived pace

    func testDistanceAndDurationRenderDistanceAndPace() {
        // 6.2 km in 2700 s → 2700/6.2 = 435.48 s/km → 7:15 /km
        let log = makeLog(
            durationSeconds: 2_700,
            metrics: CardioMetrics(distanceMeters: 6_200, distanceUnit: km))

        XCTAssertEqual(text(log), "2700s · 6.2 km · 7:15 /km")
    }

    func testFullyPopulatedRowRendersEverySegmentInOrder() {
        let log = makeLog(
            durationSeconds: 2_700,
            metrics: CardioMetrics(
                distanceMeters: 6_200, distanceUnit: km, avgHeartRate: 142,
                calories: 410, inclinePercent: 3, resistanceLevel: 8,
                hrZone: .z3))

        XCTAssertEqual(
            text(log),
            "2700s · 6.2 km · 7:15 /km · 3% incline · level 8 · 142 bpm · Z3 · 410 kcal"
        )
    }

    /// Distance renders in the unit the set was recorded in, and the pace is
    /// derived in that same unit — a mile row never shows a km pace.
    func testMilesRowRendersInMiles() {
        // 3 mi = 4828.032 m; 1500 s / 3 mi = 500 s/mi → 8:20 /mi
        let log = makeLog(
            durationSeconds: 1_500,
            metrics: CardioMetrics(distanceMeters: 4_828.032, distanceUnit: .miles))

        XCTAssertEqual(text(log), "1500s · 3 mi · 8:20 /mi")
    }

    /// The recorded unit wins over the current preference, so History reads
    /// back the way the user typed it.
    func testRecordedUnitWinsOverFallbackUnit() {
        let log = makeLog(
            durationSeconds: 1_500,
            metrics: CardioMetrics(distanceMeters: 4_828.032, distanceUnit: .miles))

        XCTAssertEqual(
            text(log, fallbackUnit: .kilometers), "1500s · 3 mi · 8:20 /mi")
    }

    // MARK: - 3. Distance without a usable duration

    /// Requirement: show the distance, omit the pace. `CardioDerived` refuses
    /// to divide by a missing or non-positive duration, so no sentinel or NaN
    /// can reach the string.
    func testDistanceWithoutDurationRendersDistanceButNoPace() {
        let log = makeLog(
            metrics: CardioMetrics(distanceMeters: 5_000, distanceUnit: km))

        XCTAssertEqual(text(log), "5 km")
    }

    func testDistanceWithZeroDurationRendersDistanceButNoPace() {
        let log = makeLog(
            durationSeconds: 0,
            metrics: CardioMetrics(distanceMeters: 5_000, distanceUnit: km))

        XCTAssertEqual(text(log), "5 km")
    }

    // MARK: - 4. Individual metrics

    func testHeartRateRendersBpm() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(avgHeartRate: 138))
        XCTAssertEqual(text(log), "1200s · 138 bpm")
    }

    func testCaloriesRenderKcal() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(calories: 250))
        XCTAssertEqual(text(log), "1200s · 250 kcal")
    }

    func testInclineRendersPercent() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(inclinePercent: 4.5))
        XCTAssertEqual(text(log), "1200s · 4.5% incline")
    }

    /// Treadmill decline keeps its sign rather than being dropped or shown as
    /// a positive grade.
    func testNegativeInclineRendersAsDecline() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(inclinePercent: -3))
        XCTAssertEqual(text(log), "1200s · -3% incline")
    }

    /// Flat is a recorded setting, distinct from "not recorded".
    func testZeroInclineRenders() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(inclinePercent: 0))
        XCTAssertEqual(text(log), "1200s · 0% incline")
    }

    func testResistanceRendersLevel() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(resistanceLevel: 8))
        XCTAssertEqual(text(log), "1200s · level 8")
    }

    func testFractionalResistanceKeepsItsDecimal() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(resistanceLevel: 7.5))
        XCTAssertEqual(text(log), "1200s · level 7.5")
    }

    func testHeartRateZoneRendersShortLabel() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(hrZone: .z4))
        XCTAssertEqual(text(log), "1200s · Z4")
    }

    // MARK: - 5. Omission, never placeholders

    /// Every absent value disappears entirely — no dash, no "—", no empty
    /// segment, and no doubled separator.
    func testAbsentValuesAreOmittedWithoutPlaceholders() throws {
        let log = makeLog(
            durationSeconds: 1_800,
            metrics: CardioMetrics(distanceMeters: 5_000, distanceUnit: km))
        let rendered = try XCTUnwrap(text(log))

        XCTAssertEqual(rendered, "1800s · 5 km · 6:00 /km")
        for absent in ["—", "--", "  ", "bpm", "kcal", "incline", "level", "Z"] {
            XCTAssertFalse(
                rendered.contains(absent),
                "Unrecorded metric leaked into the summary as \(absent)")
        }
        XCTAssertFalse(rendered.hasPrefix("·"))
        XCTAssertFalse(rendered.hasSuffix("·"))
    }

    func testSegmentCountMatchesRecordedMetrics() {
        let log = makeLog(
            durationSeconds: 1_800,
            metrics: CardioMetrics(
                distanceMeters: 5_000, distanceUnit: km, avgHeartRate: 150))

        // duration, distance, pace, bpm
        XCTAssertEqual(
            CardioHistorySummary.segments(for: log, fallbackUnit: km).count, 4)
    }

    // MARK: - 6. Invalid stored values

    /// An unparseable unit falls back to the supplied unit instead of dropping
    /// the distance — the distance itself is canonical meters, so the number
    /// stays correct either way.
    func testInvalidDistanceUnitRawFallsBackWithoutCrashing() {
        let log = makeLog(durationSeconds: 1_800)
        log.distanceMeters = 5_000
        log.distanceUnitRaw = "kilometres"

        XCTAssertEqual(text(log, fallbackUnit: .kilometers), "1800s · 5 km · 6:00 /km")
        XCTAssertEqual(
            text(log, fallbackUnit: .miles), "1800s · 3.11 mi · 9:39 /mi")
    }

    func testMissingDistanceUnitRawFallsBackWithoutCrashing() {
        let log = makeLog(durationSeconds: 1_800)
        log.distanceMeters = 5_000
        log.distanceUnitRaw = nil

        XCTAssertEqual(text(log, fallbackUnit: .kilometers), "1800s · 5 km · 6:00 /km")
    }

    func testInvalidHRZoneRawIsOmittedWithoutCrashing() {
        let log = makeLog(durationSeconds: 1_800)
        log.hrZoneRaw = "z9"

        XCTAssertEqual(text(log), "1800s")
    }

    func testGarbageHRZoneRawIsOmittedWithoutCrashing() {
        let log = makeLog(durationSeconds: 1_800)
        log.hrZoneRaw = "🏃‍♂️ zone three"

        XCTAssertEqual(text(log), "1800s")
    }

    /// A row full of impossible values degrades to the duration-only rendering
    /// rather than crashing or printing NaN.
    func testFullyInvalidRowDegradesToDurationOnly() {
        let log = makeLog(durationSeconds: 1_800)
        log.distanceMeters = .nan
        log.distanceUnitRaw = ""
        log.avgHeartRate = -40
        log.calories = 10_000_000
        log.inclinePercent = .infinity
        log.resistanceLevel = -3
        log.hrZoneRaw = "zzz"

        XCTAssertEqual(text(log), "1800s")
    }

    /// Nothing but invalid metrics and no duration is not a cardio row at all.
    func testInvalidMetricsWithoutDurationYieldNoSummary() {
        let log = makeLog(reps: 8, weight: 60)
        log.distanceMeters = -100
        log.hrZoneRaw = "nope"

        XCTAssertNil(text(log))
    }

    // MARK: - 7. Localization keys

    /// The two words the summary introduces must exist in Korean, so a Korean
    /// tester never sees an English word inside an otherwise numeric row.
    func testSummaryWordsAreKoreanLocalized() throws {
        let bundle = Bundle(for: Exercise.self)
        let path = try XCTUnwrap(bundle.path(forResource: "ko", ofType: "lproj"))
        let ko = try XCTUnwrap(Bundle(path: path))

        for key in ["incline", "level"] {
            let value = ko.localizedString(forKey: key, value: key, table: nil)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "History cardio summary word has no Korean translation: \(key)")
        }
    }
}
