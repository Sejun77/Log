import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 3 + Slice 4 patch — the History set-row rendering.
///
/// The single most important assertion in this file is
/// `testDurationOnlyRowRendersExactlyAsBefore`: History has always rendered a
/// duration as the literal `"\(seconds)s"`, and every timed hold plus every
/// beta cardio log recorded before Slice 3 is a duration-only row. If that
/// string ever changes, thousands of existing History rows change with it.
///
/// The Slice 4 patch moved metrics off the row's trailing edge — where eight
/// segments wrapped into an unreadable block — onto **grouped secondary
/// lines**. The duration stays the primary trailing value, so a duration-only
/// row is still one line and still byte-identical.
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

    private func primary(_ log: SetLog) -> String? {
        CardioHistorySummary.primaryText(for: log)
    }

    private func lines(
        _ log: SetLog, fallbackUnit: DistanceUnit? = nil
    ) -> [String] {
        CardioHistorySummary.secondaryLines(
            for: log, fallbackUnit: fallbackUnit ?? km)
    }

    // MARK: - 1. Backward compatibility

    /// The compatibility guarantee, asserted against the literal string rather
    /// than against a helper, so a change to the helper cannot silently satisfy
    /// it. A duration-only row is one line with no metric lines under it.
    func testDurationOnlyRowRendersExactlyAsBefore() {
        for seconds in [1, 30, 45, 60, 90, 1_800, 2_700] {
            let log = makeLog(durationSeconds: seconds)
            XCTAssertEqual(primary(log), "\(seconds)s")
            XCTAssertTrue(lines(log).isEmpty)
        }
    }

    /// A timed hold (Plank) is a duration-only row and must be untouched.
    func testTimedHoldRowIsUnchanged() {
        let log = makeLog(durationSeconds: 60)

        XCTAssertEqual(primary(log), "60s")
        XCTAssertTrue(lines(log).isEmpty)
        XCTAssertFalse(log.hasCardioMetrics)
    }

    /// Strength sets have no primary duration, so `HistoryView` falls through
    /// to its existing weight/reps rendering, and add no metric lines.
    func testStrengthRowYieldsNoDurationAndNoLines() {
        for log in [
            makeLog(reps: 8, weight: 60),
            makeLog(reps: 12, weight: nil),
            makeLog(reps: 0, weight: nil),
        ] {
            XCTAssertNil(primary(log))
            XCTAssertTrue(lines(log).isEmpty)
        }
    }

    /// History has always gated on `dur > 0`; a zero or negative duration with
    /// no metrics stays a strength row.
    func testNonPositiveDurationWithoutMetricsYieldsNothing() {
        for log in [
            makeLog(reps: 8, weight: 60, durationSeconds: 0),
            makeLog(reps: 8, weight: 60, durationSeconds: -5),
        ] {
            XCTAssertNil(primary(log))
            XCTAssertTrue(lines(log).isEmpty)
        }
    }

    // MARK: - 2. Grouped secondary lines

    /// The Slice 4 patch's core layout assertion: three coherent groups, in
    /// order — what was covered, how the machine was set, how the body
    /// responded — instead of one eight-segment line.
    func testFullyPopulatedRowGroupsMetricsIntoThreeLines() {
        let log = makeLog(
            durationSeconds: 2_700,
            metrics: CardioMetrics(
                distanceMeters: 6_200, distanceUnit: km, avgHeartRate: 142,
                calories: 410, inclinePercent: 3, resistanceLevel: 8,
                hrZone: .z3))

        XCTAssertEqual(primary(log), "2700s")
        XCTAssertEqual(
            lines(log),
            [
                "6.2 km · 7:15 /km",
                "3% incline · level 8",
                "142 bpm · Z3 · 410 kcal",
            ])
    }

    /// The example from the patch brief, verbatim.
    func testBriefExampleRendersAsSpecified() {
        let log = makeLog(
            durationSeconds: 60,
            metrics: CardioMetrics(
                distanceMeters: 12_000, distanceUnit: km, avgHeartRate: 60,
                calories: 300, inclinePercent: 2, resistanceLevel: 10,
                hrZone: .z2))

        XCTAssertEqual(primary(log), "60s")
        XCTAssertEqual(
            lines(log),
            [
                "12 km · 0:05 /km",
                "2% incline · level 10",
                "60 bpm · Z2 · 300 kcal",
            ])
    }

    /// A group with nothing in it does not produce an empty line.
    func testEmptyGroupsAreOmittedEntirely() {
        let log = makeLog(
            durationSeconds: 1_800,
            metrics: CardioMetrics(distanceMeters: 5_000, distanceUnit: km))

        XCTAssertEqual(lines(log), ["5 km · 6:00 /km"])
    }

    func testMachineGroupAloneRendersAsOneLine() {
        let log = makeLog(
            durationSeconds: 1_800,
            metrics: CardioMetrics(inclinePercent: -3, resistanceLevel: 8))

        XCTAssertEqual(lines(log), ["-3% incline · level 8"])
    }

    func testResponseGroupAloneRendersAsOneLine() {
        let log = makeLog(
            durationSeconds: 1_800,
            metrics: CardioMetrics(avgHeartRate: 142, calories: 410, hrZone: .z3))

        XCTAssertEqual(lines(log), ["142 bpm · Z3 · 410 kcal"])
    }

    /// Distance renders in the unit the set was recorded in, and the pace is
    /// derived in that same unit — a mile row never shows a km pace.
    func testMilesRowRendersInMiles() {
        // 3 mi = 4828.032 m; 1500 s / 3 mi = 500 s/mi → 8:20 /mi
        let log = makeLog(
            durationSeconds: 1_500,
            metrics: CardioMetrics(distanceMeters: 4_828.032, distanceUnit: .miles))

        XCTAssertEqual(lines(log), ["3 mi · 8:20 /mi"])
    }

    /// The recorded unit wins over the current preference, so History reads
    /// back the way the user typed it.
    func testRecordedUnitWinsOverFallbackUnit() {
        let log = makeLog(
            durationSeconds: 1_500,
            metrics: CardioMetrics(distanceMeters: 4_828.032, distanceUnit: .miles))

        XCTAssertEqual(lines(log, fallbackUnit: .kilometers), ["3 mi · 8:20 /mi"])
    }

    // MARK: - 3. Distance without a usable duration

    /// Show the distance, omit the pace. `CardioDerived` refuses to divide by a
    /// missing or non-positive duration, so no sentinel or NaN can reach the
    /// string.
    func testDistanceWithoutDurationRendersDistanceButNoPace() {
        let log = makeLog(
            metrics: CardioMetrics(distanceMeters: 5_000, distanceUnit: km))

        XCTAssertNil(primary(log))
        XCTAssertEqual(lines(log), ["5 km"])
    }

    func testDistanceWithZeroDurationRendersDistanceButNoPace() {
        let log = makeLog(
            durationSeconds: 0,
            metrics: CardioMetrics(distanceMeters: 5_000, distanceUnit: km))

        XCTAssertNil(primary(log))
        XCTAssertEqual(lines(log), ["5 km"])
    }

    // MARK: - 4. Individual metrics

    func testHeartRateRendersBpm() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(avgHeartRate: 138))
        XCTAssertEqual(primary(log), "1200s")
        XCTAssertEqual(lines(log), ["138 bpm"])
    }

    func testCaloriesRenderKcal() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(calories: 250))
        XCTAssertEqual(lines(log), ["250 kcal"])
    }

    func testInclineRendersPercent() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(inclinePercent: 4.5))
        XCTAssertEqual(lines(log), ["4.5% incline"])
    }

    /// Treadmill decline keeps its sign rather than being dropped or shown as
    /// a positive grade.
    func testNegativeInclineRendersAsDecline() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(inclinePercent: -3))
        XCTAssertEqual(lines(log), ["-3% incline"])
    }

    /// Flat is a recorded setting, distinct from "not recorded".
    func testZeroInclineRenders() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(inclinePercent: 0))
        XCTAssertEqual(lines(log), ["0% incline"])
    }

    func testResistanceRendersLevel() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(resistanceLevel: 8))
        XCTAssertEqual(lines(log), ["level 8"])
    }

    func testFractionalResistanceKeepsItsDecimal() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(resistanceLevel: 7.5))
        XCTAssertEqual(lines(log), ["level 7.5"])
    }

    func testHeartRateZoneRendersShortLabel() {
        let log = makeLog(
            durationSeconds: 1_200, metrics: CardioMetrics(hrZone: .z4))
        XCTAssertEqual(lines(log), ["Z4"])
    }

    // MARK: - 5. Omission, never placeholders

    /// Every absent value disappears entirely — no dash, no "—", no empty
    /// segment, and no doubled separator.
    func testAbsentValuesAreOmittedWithoutPlaceholders() throws {
        let log = makeLog(
            durationSeconds: 1_800,
            metrics: CardioMetrics(distanceMeters: 5_000, distanceUnit: km))
        let rendered = try XCTUnwrap(lines(log).first)

        XCTAssertEqual(lines(log).count, 1)
        XCTAssertEqual(rendered, "5 km · 6:00 /km")
        for absent in ["—", "--", "  ", "bpm", "kcal", "incline", "level", "Z"] {
            XCTAssertFalse(
                rendered.contains(absent),
                "Unrecorded metric leaked into the summary as \(absent)")
        }
        XCTAssertFalse(rendered.hasPrefix("·"))
        XCTAssertFalse(rendered.hasSuffix("·"))
    }

    // MARK: - 6. Invalid stored values

    /// An unparseable unit falls back to the supplied unit instead of dropping
    /// the distance — the distance itself is canonical meters, so the number
    /// stays correct either way.
    func testInvalidDistanceUnitRawFallsBackWithoutCrashing() {
        let log = makeLog(durationSeconds: 1_800)
        log.distanceMeters = 5_000
        log.distanceUnitRaw = "kilometres"

        XCTAssertEqual(lines(log, fallbackUnit: .kilometers), ["5 km · 6:00 /km"])
        XCTAssertEqual(lines(log, fallbackUnit: .miles), ["3.11 mi · 9:39 /mi"])
    }

    func testMissingDistanceUnitRawFallsBackWithoutCrashing() {
        let log = makeLog(durationSeconds: 1_800)
        log.distanceMeters = 5_000
        log.distanceUnitRaw = nil

        XCTAssertEqual(lines(log, fallbackUnit: .kilometers), ["5 km · 6:00 /km"])
    }

    func testInvalidHRZoneRawIsOmittedWithoutCrashing() {
        let log = makeLog(durationSeconds: 1_800)
        log.hrZoneRaw = "z9"

        XCTAssertEqual(primary(log), "1800s")
        XCTAssertTrue(lines(log).isEmpty)
    }

    func testGarbageHRZoneRawIsOmittedWithoutCrashing() {
        let log = makeLog(durationSeconds: 1_800)
        log.hrZoneRaw = "🏃‍♂️ zone three"

        XCTAssertEqual(primary(log), "1800s")
        XCTAssertTrue(lines(log).isEmpty)
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

        XCTAssertEqual(primary(log), "1800s")
        XCTAssertTrue(lines(log).isEmpty)
    }

    /// Nothing but invalid metrics and no duration is not a cardio row at all.
    func testInvalidMetricsWithoutDurationYieldNothing() {
        let log = makeLog(reps: 8, weight: 60)
        log.distanceMeters = -100
        log.hrZoneRaw = "nope"

        XCTAssertNil(primary(log))
        XCTAssertTrue(lines(log).isEmpty)
    }

    // MARK: - 7. Collapsed active-workout summary

    /// The Slice 4 patch cap: never more than three segments, however much was
    /// recorded. The label ellipsized before this.
    func testCollapsedSummaryShowsAtMostThreeSegments() {
        let everything = CardioMetrics(
            distanceMeters: 6_200, distanceUnit: km, avgHeartRate: 142,
            calories: 410, inclinePercent: 3, resistanceLevel: 8, hrZone: .z3)

        let segments = CardioHistorySummary.collapsedSegments(
            everything, fallbackUnit: km)

        XCTAssertEqual(segments.count, CardioHistorySummary.collapsedSegmentLimit)
        XCTAssertEqual(segments.count, 3)
    }

    /// Priority is distance → heart rate → calories.
    func testCollapsedSummaryPrioritizesDistanceHeartRateCalories() {
        let everything = CardioMetrics(
            distanceMeters: 6_200, distanceUnit: km, avgHeartRate: 142,
            calories: 410, inclinePercent: 3, resistanceLevel: 8, hrZone: .z3)

        XCTAssertEqual(
            CardioHistorySummary.collapsedSummary(everything, fallbackUnit: km),
            "6.2 km · 142 bpm · 410 kcal")
    }

    /// The lower-priority metrics are excluded when the three preferred ones
    /// are all present — not merely truncated off the end of a longer string.
    func testCollapsedSummaryExcludesLowerPriorityMetrics() throws {
        let everything = CardioMetrics(
            distanceMeters: 6_200, distanceUnit: km, avgHeartRate: 142,
            calories: 410, inclinePercent: 3, resistanceLevel: 8, hrZone: .z3)
        let summary = try XCTUnwrap(
            CardioHistorySummary.collapsedSummary(everything, fallbackUnit: km))

        for excluded in ["incline", "level", "Z3", "/km", "km/h"] {
            XCTAssertFalse(
                summary.contains(excluded),
                "\(excluded) must not appear in the collapsed summary")
        }
    }

    /// Lower-priority metrics fill only the slots the preferred three leave
    /// empty.
    func testCollapsedSummaryFallsBackWhenPreferredMetricsAreAbsent() {
        let machineOnly = CardioMetrics(
            inclinePercent: -3, resistanceLevel: 8, hrZone: .z3)

        XCTAssertEqual(
            CardioHistorySummary.collapsedSummary(machineOnly, fallbackUnit: km),
            "-3% incline · level 8 · Z3")
    }

    func testCollapsedSummaryMixesPreferredAndFallback() {
        let partial = CardioMetrics(
            distanceMeters: 5_000, distanceUnit: km, inclinePercent: 2,
            resistanceLevel: 8, hrZone: .z3)

        // distance claims slot 1; incline and resistance fill 2 and 3.
        XCTAssertEqual(
            CardioHistorySummary.collapsedSummary(partial, fallbackUnit: km),
            "5 km · 2% incline · level 8")
    }

    /// Pace and speed are never in the collapsed summary — pace has its own
    /// preview row in the expanded section, and duration is the primary field.
    func testCollapsedSummaryNeverIncludesPaceOrSpeed() throws {
        let distanceOnly = CardioMetrics(distanceMeters: 6_200, distanceUnit: km)
        let summary = try XCTUnwrap(
            CardioHistorySummary.collapsedSummary(distanceOnly, fallbackUnit: km))

        XCTAssertEqual(summary, "6.2 km")
    }

    func testCollapsedSummaryIsNilWhenNothingRecorded() {
        XCTAssertNil(
            CardioHistorySummary.collapsedSummary(CardioMetrics(), fallbackUnit: km))
    }
}
