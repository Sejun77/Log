import SwiftData
import XCTest

@testable import Log

/// Cardio Slice 11 — History cardio charts.
///
/// Two things are under test and they are deliberately separate:
///
///  1. **`CardioProgressAnalytics`** — the aggregation. Sums, the weighted pace
///     rule, and the nil-means-absent rule that keeps a blank field out of a
///     series instead of plotting it as zero.
///  2. **`availableProgressMetrics`** — the separation. A cardio exercise is
///     never offered e1RM, a strength exercise is never offered pace, and the
///     existing strength/bodyweight/timed-hold lists are untouched.
///
/// Unit conversion is asserted at the boundary the app actually uses: meters in
/// the store, `DistanceUnit` at display time. Nothing here writes
/// `AppSettings` — the chart takes its unit as a parameter precisely so this is
/// testable without mutating global defaults.
@MainActor
final class CardioProgressChartTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    /// One performed set. `distanceMeters` / `durationSeconds` are the two
    /// fields the charts are built from; both are independently optional,
    /// because that is exactly the state real beta rows are in.
    @discardableResult
    private func cardioSet(
        distanceMeters: Double? = nil,
        durationSeconds: Int? = nil,
        calories: Int? = nil,
        avgHeartRate: Int? = nil,
        kind: SetKind = .working
    ) -> SetLog {
        let log = SetLog(
            indexInExercise: 0, kind: kind, reps: 0, weight: nil,
            durationSeconds: durationSeconds)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(
                distanceMeters: distanceMeters,
                distanceUnit: .kilometers,
                avgHeartRate: avgHeartRate,
                calories: calories))
        return log
    }

    /// A strength set: reps and weight, no cardio fields at all.
    private func strengthSet(reps: Int, weight: Double) -> SetLog {
        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: reps, weight: weight,
            durationSeconds: nil)
        context.insert(log)
        return log
    }

    private func totals(_ logs: [SetLog])
        -> CardioProgressAnalytics.SessionTotals
    {
        CardioProgressAnalytics.totals(for: logs)
    }

    // MARK: - 1. Sums

    func testDistanceSumsAcrossSetsInOneSession() throws {
        let t = totals([
            cardioSet(distanceMeters: 5_000, durationSeconds: 1_500),
            cardioSet(distanceMeters: 3_000, durationSeconds: 900),
        ])
        XCTAssertEqual(t.distanceMeters, 8_000)
        XCTAssertEqual(
            try XCTUnwrap(t.distanceValue(in: .kilometers)), 8, accuracy: 0.0001)
    }

    func testDurationSumsAcrossSetsInOneSession() {
        let t = totals([
            cardioSet(durationSeconds: 1_500),
            cardioSet(durationSeconds: 900),
        ])
        XCTAssertEqual(t.durationSeconds, 2_400)
        XCTAssertEqual(t.durationValue, 2_400)
    }

    /// Warm-up sets count. The distance chart has to agree with the History row
    /// the user is looking at, and that row shows every set.
    func testWarmupSetsContributeToCardioTotals() {
        let t = totals([
            cardioSet(distanceMeters: 1_000, durationSeconds: 400, kind: .warmup),
            cardioSet(distanceMeters: 5_000, durationSeconds: 1_500),
        ])
        XCTAssertEqual(t.distanceMeters, 6_000)
        XCTAssertEqual(t.durationSeconds, 1_900)
    }

    // MARK: - 2. Weighted pace

    /// The reason pace is not an average of paces. Here a 1 km jog at 6:00/km
    /// and a 9 km run at 4:00/km average to 5:00/km if you average the *rates*,
    /// but the athlete actually ran 10 km in 42:00 — 4:12/km.
    func testPaceIsWeightedByDistanceNotAveragedAcrossSets() throws {
        let t = totals([
            cardioSet(distanceMeters: 1_000, durationSeconds: 360),
            cardioSet(distanceMeters: 9_000, durationSeconds: 2_160),
        ])

        let pace = try XCTUnwrap(t.paceSecondsPerUnit(in: .kilometers))
        XCTAssertEqual(pace, 252, accuracy: 0.0001, "2520 s ÷ 10 km = 4:12/km")
        XCTAssertNotEqual(
            pace, 300,
            "an arithmetic mean of the per-set paces would give 5:00/km")
        XCTAssertEqual(CardioDerived.formatPace(secondsPerUnit: pace), "4:12")
    }

    func testPaceUsesTotalsInMiles() throws {
        // 1609.344 m in 480 s → 8:00/mi exactly.
        let t = totals([cardioSet(distanceMeters: 1_609.344, durationSeconds: 480)])
        let pace = try XCTUnwrap(t.paceSecondsPerUnit(in: .miles))
        XCTAssertEqual(pace, 480, accuracy: 0.0001)
        XCTAssertEqual(CardioDerived.formatPace(secondsPerUnit: pace), "8:00")
    }

    func testSpeedUsesTotals() throws {
        let t = totals([cardioSet(distanceMeters: 10_000, durationSeconds: 3_600)])
        XCTAssertEqual(
            try XCTUnwrap(t.speedUnitsPerHour(in: .kilometers)), 10,
            accuracy: 0.0001)
    }

    // MARK: - 3. Missing data is absent, never zero

    func testDurationOnlySessionHasDurationButNoDistanceOrPace() {
        let t = totals([cardioSet(durationSeconds: 1_800)])
        XCTAssertEqual(t.durationValue, 1_800)
        XCTAssertNil(t.distanceValue(in: .kilometers))
        XCTAssertNil(t.paceSecondsPerUnit(in: .kilometers))
    }

    func testDistanceOnlySessionHasDistanceButNoPace() {
        let t = totals([cardioSet(distanceMeters: 5_000)])
        XCTAssertEqual(t.distanceValue(in: .kilometers), 5)
        XCTAssertNil(t.durationValue)
        XCTAssertNil(
            t.paceSecondsPerUnit(in: .kilometers),
            "a pace with no duration would be invented")
    }

    func testSetsWithoutDistanceDoNotContributeToDistanceOrPace() throws {
        let t = totals([
            cardioSet(distanceMeters: 5_000, durationSeconds: 1_500),
            cardioSet(durationSeconds: 600),  // untimed walk, no distance
        ])
        XCTAssertEqual(t.distanceMeters, 5_000)
        XCTAssertEqual(t.durationSeconds, 2_100)
        // The duration still counts toward pace — it is time spent on the
        // exercise, and the totals are what the user did.
        XCTAssertEqual(
            try XCTUnwrap(t.paceSecondsPerUnit(in: .kilometers)), 420,
            accuracy: 0.0001)
    }

    /// Zero and negative values are rejected by `CardioMetrics` on the way in,
    /// so they can neither crash nor produce a pace.
    func testZeroAndNegativeValuesProduceNoSeries() {
        let t = totals([
            cardioSet(distanceMeters: 0, durationSeconds: 0),
            cardioSet(distanceMeters: -5_000, durationSeconds: -60),
        ])
        XCTAssertEqual(t.distanceMeters, 0)
        XCTAssertEqual(t.durationSeconds, 0)
        XCTAssertNil(t.distanceValue(in: .kilometers))
        XCTAssertNil(t.durationValue)
        XCTAssertNil(t.paceSecondsPerUnit(in: .kilometers))
    }

    func testEmptySessionIsAllNil() {
        let t = totals([])
        XCTAssertNil(t.distanceValue(in: .kilometers))
        XCTAssertNil(t.durationValue)
        XCTAssertNil(t.paceSecondsPerUnit(in: .kilometers))
        XCTAssertNil(t.caloriesValue)
        XCTAssertNil(t.avgHeartRateValue)
    }

    // MARK: - 4. Calories and heart rate

    func testCaloriesSumAcrossSets() {
        let t = totals([
            cardioSet(durationSeconds: 900, calories: 120),
            cardioSet(durationSeconds: 900, calories: 200),
        ])
        XCTAssertEqual(t.caloriesValue, 320)
    }

    func testCaloriesAreNilWhenNoneRecorded() {
        let t = totals([cardioSet(distanceMeters: 5_000, durationSeconds: 1_500)])
        XCTAssertNil(
            t.caloriesValue, "an unrecorded field must not chart as zero")
    }

    /// Duration-weighted: 30 min at 150 bpm and 10 min at 110 bpm is 140 bpm,
    /// not the unweighted 130.
    func testHeartRateIsDurationWeighted() throws {
        let t = totals([
            cardioSet(durationSeconds: 1_800, avgHeartRate: 150),
            cardioSet(durationSeconds: 600, avgHeartRate: 110),
        ])
        XCTAssertEqual(
            try XCTUnwrap(t.avgHeartRateValue), 140, accuracy: 0.0001)
    }

    /// With no durations to weight by, a plain mean is the only honest answer.
    func testHeartRateFallsBackToPlainMeanWithoutDurations() throws {
        let t = totals([
            cardioSet(avgHeartRate: 150),
            cardioSet(avgHeartRate: 110),
        ])
        XCTAssertEqual(
            try XCTUnwrap(t.avgHeartRateValue), 130, accuracy: 0.0001)
    }

    func testHeartRateIgnoresSetsWithoutAReading() throws {
        let t = totals([
            cardioSet(durationSeconds: 1_800, avgHeartRate: 150),
            cardioSet(durationSeconds: 1_800),  // no HR recorded
        ])
        XCTAssertEqual(
            try XCTUnwrap(t.avgHeartRateValue), 150, accuracy: 0.0001,
            "a missing reading must not be averaged in as zero")
    }

    func testHeartRateIsNilWhenNoneRecorded() {
        XCTAssertNil(totals([cardioSet(durationSeconds: 1_800)]).avgHeartRateValue)
    }

    /// Out-of-range readings are rejected by `CardioMetrics`, so they never
    /// reach the average.
    func testImplausibleHeartRateIsExcluded() {
        let t = totals([
            cardioSet(durationSeconds: 600, avgHeartRate: 900),
            cardioSet(durationSeconds: 600, avgHeartRate: 140),
        ])
        XCTAssertEqual(t.avgHeartRateValue, 140)
    }

    // MARK: - 5. Unit conversion at display time

    func testDistanceReadsInTheSettingsUnitWithoutChangingStorage() throws {
        let t = totals([cardioSet(distanceMeters: 5_000, durationSeconds: 1_500)])

        XCTAssertEqual(
            try XCTUnwrap(t.distanceValue(in: .kilometers)), 5, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(t.distanceValue(in: .miles)), 3.106856,
            accuracy: 0.00001)
        XCTAssertEqual(
            t.distanceMeters, 5_000,
            "the stored quantity is meters and does not move with the "
                + "display unit")
    }

    func testPaceReadsInTheSettingsUnit() throws {
        // 5 km in 25:00 → 5:00/km, which is 8:03/mi.
        let t = totals([cardioSet(distanceMeters: 5_000, durationSeconds: 1_500)])

        XCTAssertEqual(
            CardioDerived.formatPace(
                secondsPerUnit: try XCTUnwrap(t.paceSecondsPerUnit(in: .kilometers))),
            "5:00")
        XCTAssertEqual(
            CardioDerived.formatPace(
                secondsPerUnit: try XCTUnwrap(t.paceSecondsPerUnit(in: .miles))),
            "8:03")
    }

    /// The labels the chart puts on the axis follow the same preference.
    func testChartLabelsFollowTheDistanceUnit() {
        XCTAssertEqual(
            ProgressMetric.cardioDistance.yAxisLabel(distanceUnit: .kilometers),
            "Distance (km)")
        XCTAssertEqual(
            ProgressMetric.cardioDistance.yAxisLabel(distanceUnit: .miles),
            "Distance (mi)")
        XCTAssertEqual(
            ProgressMetric.cardioPace.yAxisLabel(distanceUnit: .kilometers),
            "Pace (min/km)")
        XCTAssertEqual(
            ProgressMetric.cardioPace.yAxisLabel(distanceUnit: .miles),
            "Pace (min/mi)")
    }

    /// Strength labels must not have moved.
    func testStrengthChartLabelsAreUnchanged() {
        let unit = Units.weightIsKg ? "kg" : "lb"
        XCTAssertEqual(
            ProgressMetric.e1rm.yAxisLabel(distanceUnit: .kilometers),
            "e1RM (\(unit))")
        XCTAssertEqual(
            ProgressMetric.totalReps.yAxisLabel(distanceUnit: .miles),
            "Total reps")
        XCTAssertEqual(
            ProgressMetric.totalDuration.yAxisLabel(distanceUnit: .miles),
            "Total duration (s)")
    }

    // MARK: - 6. Strength / cardio separation

    func testCardioExerciseOffersCardioMetricsAndNoStrengthMetrics() {
        let metrics = availableProgressMetrics(
            isTimeBased: true, isBodyweightEquipment: false,
            includesBodyweight: false, hasUserBodyweight: true, isCardio: true)

        XCTAssertEqual(
            metrics,
            [
                .cardioDistance, .totalDuration, .cardioPace, .cardioCalories,
                .cardioHeartRate,
            ])
        XCTAssertFalse(metrics.contains(.e1rm))
        XCTAssertFalse(metrics.contains(.volume))
        XCTAssertFalse(metrics.contains(.bestWeight))
        XCTAssertFalse(metrics.contains(.totalReps))
    }

    func testStrengthExerciseOffersNoCardioMetrics() {
        let metrics = availableProgressMetrics(
            isTimeBased: false, isBodyweightEquipment: false,
            includesBodyweight: false, hasUserBodyweight: false)

        XCTAssertEqual(metrics, [.e1rm, .volume, .bestWeight, .totalReps])
        XCTAssertTrue(metrics.allSatisfy { !$0.isCardioOnly })
    }

    /// A timed hold is time-based but not cardio: duration only, exactly as
    /// before this slice.
    func testTimedHoldStaysDurationOnly() {
        XCTAssertEqual(
            availableProgressMetrics(
                isTimeBased: true, isBodyweightEquipment: true,
                includesBodyweight: false, hasUserBodyweight: false),
            [.totalDuration])
    }

    /// Defensive: the impossible `isCardio && !isTimeBased` row degrades to the
    /// non-cardio rules rather than offering pace for a set with no duration.
    func testCardioFlagWithoutTimeBasedDoesNotOfferCardioMetrics() {
        let metrics = availableProgressMetrics(
            isTimeBased: false, isBodyweightEquipment: false,
            includesBodyweight: false, hasUserBodyweight: false, isCardio: true)
        XCTAssertTrue(metrics.allSatisfy { !$0.isCardioOnly })
    }

    /// Strength sets carry no cardio fields, so they contribute nothing to a
    /// cardio series even when they sit in the same list.
    func testStrengthSetsContributeNothingToCardioTotals() {
        let t = totals([
            strengthSet(reps: 8, weight: 100),
            strengthSet(reps: 5, weight: 120),
        ])
        XCTAssertEqual(t.distanceMeters, 0)
        XCTAssertEqual(t.durationSeconds, 0)
        XCTAssertNil(t.caloriesValue)
        XCTAssertNil(t.avgHeartRateValue)
        XCTAssertNil(t.paceSecondsPerUnit(in: .kilometers))
    }

    /// The other direction: a cardio bout has no weight and no reps, so the
    /// strength aggregation reports nothing for it. This is what keeps a
    /// treadmill run out of e1RM and volume charts.
    func testCardioSetsContributeNothingToStrengthMetrics() {
        let logs = [
            cardioSet(distanceMeters: 5_000, durationSeconds: 1_500),
            cardioSet(distanceMeters: 3_000, durationSeconds: 900),
        ]
        let sets = logs.map { (weight: $0.weight ?? 0, reps: $0.reps) }

        XCTAssertNil(StrengthAnalytics.bestE1RM(sets: sets))
        XCTAssertEqual(StrengthAnalytics.sessionVolume(sets), 0)
    }

    /// The other analytics surface. `WorkoutHistoryAnalytics` gates on
    /// `weight > 0 && reps > 0`, so a cardio bout falls out of the strength and
    /// volume series on its own — the design doc calls this "existing
    /// protection to preserve", and preserved-by-accident is not preserved.
    func testCardioWorkoutsAreInvisibleToStrengthAnalytics() throws {
        let exercise = Exercise(name: "Treadmill Run", bodyPart: "Cardio")
        exercise.setTimeBased(true)
        exercise.setCardio(true)
        context.insert(exercise)

        let item = WorkoutItem(exercise: exercise, setLogs: [])
        context.insert(item)
        item.setLogs.append(
            cardioSet(distanceMeters: 10_000, durationSeconds: 3_000, calories: 600))

        let workout = Workout(date: .now, items: [item])
        workout.completedAt = .now
        context.insert(workout)
        try context.save()

        XCTAssertTrue(
            WorkoutHistoryAnalytics.availableExercises(in: [workout]).isEmpty,
            "a cardio-only exercise has no strength series to offer")

        let ref = WorkoutHistoryAnalytics.ExerciseRef(
            key: .id(exercise.id), displayName: exercise.name)
        XCTAssertTrue(
            WorkoutHistoryAnalytics.strengthSeries(for: ref, in: [workout]).isEmpty)
        XCTAssertTrue(
            WorkoutHistoryAnalytics.volumeSeries(for: ref, in: [workout]).isEmpty)
    }

    // MARK: - 7. Chart presentation rules

    /// Lower pace is a better session, so the PR rosette follows the minimum
    /// for pace and the maximum for everything else.
    func testOnlyPaceTreatsLowerAsBetter() {
        XCTAssertTrue(ProgressMetric.cardioPace.lowerIsBetter)
        for metric in ProgressMetric.allCases where metric != .cardioPace {
            XCTAssertFalse(
                metric.lowerIsBetter,
                "\(metric.rawValue) should peak upward")
        }
    }

    func testEachCardioMetricHasItsOwnEmptyState() {
        let cardio: [ProgressMetric] = [
            .cardioDistance, .cardioPace, .cardioCalories, .cardioHeartRate,
        ]
        let generic = ProgressMetric.e1rm.emptyStateText
        for metric in cardio {
            XCTAssertNotEqual(
                metric.emptyStateText, generic,
                "\(metric.rawValue) should explain which field is missing")
        }
    }

    // MARK: - 8. Session grouping through WorkoutItems

    func testTotalsAggregateEveryMatchingItemInASession() throws {
        let exercise = Exercise(name: "Treadmill Run", bodyPart: "Cardio")
        exercise.setTimeBased(true)
        exercise.setCardio(true)
        context.insert(exercise)
        let first = WorkoutItem(exercise: exercise, setLogs: [])
        let second = WorkoutItem(exercise: exercise, setLogs: [])
        context.insert(first)
        context.insert(second)
        first.setLogs.append(cardioSet(distanceMeters: 5_000, durationSeconds: 1_500))
        second.setLogs.append(cardioSet(distanceMeters: 2_000, durationSeconds: 600))

        let t = CardioProgressAnalytics.totals(forItems: [first, second])

        XCTAssertEqual(t.distanceMeters, 7_000)
        XCTAssertEqual(t.durationSeconds, 2_100)
        XCTAssertEqual(
            try XCTUnwrap(t.distanceValue(in: .kilometers)), 7, accuracy: 0.0001)
    }
}
