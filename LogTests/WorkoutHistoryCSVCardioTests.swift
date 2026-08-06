import XCTest

@testable import Log

/// Cardio Phase 1, Slice 9 — the cardio columns appended to
/// `workout_history.csv`.
///
/// The export stays pure and read-only: `Workout` / `WorkoutItem` / `SetLog`
/// are constructed directly (no `ModelContext`) and only stored properties are
/// read. Exported text is parsed back through `CSVCodec` so cell assertions are
/// escaping-robust.
///
/// The distance contract these tests pin down: `distanceMeters` is canonical —
/// it is what was stored and the only column safe to aggregate — while
/// `distanceUnitRaw` is compatibility metadata recording the unit the user
/// typed in. It does not control display anywhere; display follows Settings.
final class WorkoutHistoryCSVCardioTests: XCTestCase {

    // Column indices of the appended cardio block.
    private let distanceMeters = 14
    private let distanceUnitRaw = 15
    private let avgHeartRate = 16
    private let hrZone = 17
    private let calories = 18
    private let inclinePercent = 19
    private let resistanceLevel = 20

    private var cardioColumns: ClosedRange<Int> { 14...20 }

    // MARK: - Fixtures

    private func log(
        duration: Int? = 1_800, reps: Int = 0, weight: Double? = nil,
        cardio: CardioMetrics = CardioMetrics()
    ) -> SetLog {
        let log = SetLog(
            indexInExercise: 0, kind: .working, reps: reps, weight: weight,
            timestamp: Date(timeIntervalSince1970: 0), durationSeconds: duration)
        log.applyCardioMetrics(cardio)
        return log
    }

    private func row(_ logs: [SetLog], name: String = "Treadmill Run")
        -> [String]
    {
        let item = WorkoutItem(exercise: Exercise(name: name), setLogs: logs)
        let workout = Workout(
            date: Date(timeIntervalSince1970: 0), items: [item])
        let grid = CSVCodec.parse(
            WorkoutHistoryCSV.export(workouts: [workout]))
        guard grid.count > 1 else {
            XCTFail("expected at least one data row")
            return []
        }
        return grid[1]
    }

    private func row(cardio: CardioMetrics) -> [String] {
        row([log(cardio: cardio)])
    }

    // MARK: - 8. Header

    func testHeaderAppendsTheSevenCardioColumns() {
        XCTAssertEqual(
            Array(WorkoutHistoryCSV.header.suffix(7)),
            ["distanceMeters", "distanceUnitRaw", "avgHeartRate", "hrZone",
             "calories", "inclinePercent", "resistanceLevel"])
        XCTAssertEqual(WorkoutHistoryCSV.header.count, 21)
    }

    func testEveryExportedRowHasTheFullColumnCount() {
        let grid = CSVCodec.parse(
            WorkoutHistoryCSV.export(workouts: [
                Workout(
                    date: Date(timeIntervalSince1970: 0),
                    items: [
                        WorkoutItem(
                            exercise: Exercise(name: "Bench"),
                            setLogs: [log(duration: nil, reps: 8, weight: 100)]),
                        WorkoutItem(
                            exercise: Exercise(name: "Treadmill Run"),
                            setLogs: [
                                log(cardio: CardioMetrics(
                                    distanceMeters: 5_000,
                                    distanceUnit: .kilometers))
                            ]),
                    ])
            ]))
        XCTAssertTrue(
            grid.allSatisfy { $0.count == WorkoutHistoryCSV.header.count })
    }

    // MARK: - 9. Strength rows export blank cardio cells

    func testStrengthRowLeavesEveryCardioColumnBlank() {
        let strength = row([log(duration: nil, reps: 8, weight: 100)], name: "Bench")
        for column in cardioColumns {
            XCTAssertEqual(
                strength[column], "",
                "column \(WorkoutHistoryCSV.header[column]) must be blank")
        }
        XCTAssertEqual(strength[8], "8", "reps still export")
        XCTAssertEqual(strength[9], "100", "weight still exports")
    }

    func testTimedHoldWithNoMetricsLeavesEveryCardioColumnBlank() {
        let hold = row([log(duration: 60)], name: "Plank")
        XCTAssertEqual(hold[10], "60", "the duration still exports")
        for column in cardioColumns {
            XCTAssertEqual(hold[column], "")
        }
    }

    /// A cardio bout logged with nothing but a duration is a complete, valid
    /// set — it must not start emitting zeros.
    func testDurationOnlyCardioBoutLeavesEveryCardioColumnBlank() {
        let bout = row([log(duration: 1_800)])
        for column in cardioColumns {
            XCTAssertEqual(bout[column], "")
        }
    }

    // MARK: - 10–15. Populated cardio values

    func testDistanceExportsCanonicalMeters() {
        let cells = row(
            cardio: CardioMetrics(distanceMeters: 5_000, distanceUnit: .kilometers))
        XCTAssertEqual(cells[distanceMeters], "5000")
    }

    /// The stored value is meters regardless of the entry unit: 3.1 mi is
    /// exported as its metric equivalent, not as "3.1".
    func testDistanceEnteredInMilesStillExportsMeters() throws {
        let cells = row(
            cardio: CardioMetrics(
                distanceMeters: 3.1 * 1_609.344, distanceUnit: .miles))
        XCTAssertEqual(cells[distanceUnitRaw], "mi")
        let meters = try XCTUnwrap(Double(cells[distanceMeters]))
        XCTAssertEqual(meters, 4_988.9664, accuracy: 0.001)
    }

    func testFractionalDistanceKeepsItsDecimals() {
        let cells = row(
            cardio: CardioMetrics(distanceMeters: 5_432.5, distanceUnit: .kilometers))
        XCTAssertEqual(cells[distanceMeters], "5432.5")
    }

    func testDistanceUnitRawExportsTheEntryUnit() {
        for unit in DistanceUnit.allCases {
            let cells = row(
                cardio: CardioMetrics(distanceMeters: 5_000, distanceUnit: unit))
            XCTAssertEqual(cells[distanceUnitRaw], unit.rawValue)
        }
    }

    /// A unit with no distance carries no information, so `CardioMetrics` drops
    /// it — the export can never claim "mi" with nothing measured in miles.
    func testDistanceUnitIsBlankWhenThereIsNoDistance() {
        let cells = row(cardio: CardioMetrics(distanceUnit: .miles))
        XCTAssertEqual(cells[distanceMeters], "")
        XCTAssertEqual(cells[distanceUnitRaw], "")
    }

    func testAvgHeartRateExports() {
        XCTAssertEqual(
            row(cardio: CardioMetrics(avgHeartRate: 148))[avgHeartRate], "148")
    }

    func testHRZoneExportsItsRawValue() {
        for zone in HRZone.allCases {
            XCTAssertEqual(
                row(cardio: CardioMetrics(hrZone: zone))[hrZone], zone.rawValue)
        }
    }

    func testCaloriesExport() {
        XCTAssertEqual(row(cardio: CardioMetrics(calories: 412))[calories], "412")
    }

    func testInclineExports() {
        XCTAssertEqual(
            row(cardio: CardioMetrics(inclinePercent: 6))[inclinePercent], "6")
        XCTAssertEqual(
            row(cardio: CardioMetrics(inclinePercent: 1.5))[inclinePercent], "1.5")
    }

    /// Decline is a real treadmill setting, and the export has to keep its sign
    /// rather than blanking it or dropping to an absolute value.
    func testNegativeDeclineInclineExportsWithItsSign() {
        XCTAssertEqual(
            row(cardio: CardioMetrics(inclinePercent: -3))[inclinePercent], "-3")
        XCTAssertEqual(
            row(cardio: CardioMetrics(inclinePercent: -1.5))[inclinePercent],
            "-1.5")
    }

    /// Zero incline is a recorded value ("flat"), not an absent one — unlike
    /// every other cardio metric, 0 must survive to the file.
    func testZeroInclineExportsAsZeroRatherThanBlank() {
        XCTAssertEqual(
            row(cardio: CardioMetrics(inclinePercent: 0))[inclinePercent], "0")
    }

    func testResistanceLevelExports() {
        XCTAssertEqual(
            row(cardio: CardioMetrics(resistanceLevel: 12))[resistanceLevel], "12")
        XCTAssertEqual(
            row(cardio: CardioMetrics(resistanceLevel: 7.5))[resistanceLevel],
            "7.5")
    }

    func testAFullyPopulatedCardioRowExportsEveryColumn() {
        let cells = row(
            cardio: CardioMetrics(
                distanceMeters: 5_000, distanceUnit: .kilometers,
                avgHeartRate: 148, calories: 412, inclinePercent: -1.5,
                resistanceLevel: 8, hrZone: .z3))

        XCTAssertEqual(
            Array(cells[cardioColumns]),
            ["5000", "km", "148", "z3", "412", "-1.5", "8"])
    }

    // MARK: - 16. Missing values stay blank, never 0

    func testEachMetricIsIndependentlyBlankWhenAbsent() {
        // Only a heart rate: every other cardio cell must stay empty.
        let cells = row(cardio: CardioMetrics(avgHeartRate: 148))
        XCTAssertEqual(cells[avgHeartRate], "148")
        for column in cardioColumns where column != avgHeartRate {
            XCTAssertEqual(
                cells[column], "",
                "\(WorkoutHistoryCSV.header[column]) must be blank, not 0")
        }
    }

    func testNoCardioCellIsEverAZeroPlaceholder() {
        let bout = row([log(duration: 1_800)])
        for column in cardioColumns {
            XCTAssertNotEqual(bout[column], "0")
        }
    }

    // MARK: - Corrupt stored values never reach the file

    /// The exporter reads through `SetLog.cardioMetrics`, so a value that could
    /// only have come from a hand-edited store is normalized away rather than
    /// written out.
    func testOutOfRangeStoredValuesExportBlank() {
        let log = self.log()
        // Bypass `applyCardioMetrics` to simulate a corrupt row.
        log.distanceMeters = -500
        log.avgHeartRate = 900
        log.hrZoneRaw = "z9"
        log.calories = -10
        log.inclinePercent = 500
        log.resistanceLevel = -3
        log.distanceUnitRaw = "kilometres"

        let cells = row([log])
        for column in cardioColumns {
            XCTAssertEqual(
                cells[column], "",
                "\(WorkoutHistoryCSV.header[column]) must not export a corrupt value")
        }
    }

    // MARK: - Pre-cardio columns are undisturbed

    func testAppendingCardioColumnsDidNotShiftTheOriginalOnes() {
        let item = WorkoutItem(
            exercise: Exercise(name: "Bench"),
            setLogs: [log(duration: nil, reps: 5, weight: 82.5)])
        let workout = Workout(
            date: Date(timeIntervalSince1970: 0), routineName: "Push A",
            items: [item], notes: "felt strong")
        let cells = CSVCodec.parse(
            WorkoutHistoryCSV.export(workouts: [workout]))[1]

        XCTAssertEqual(cells[0], "1970-01-01T00:00:00Z")
        XCTAssertEqual(cells[2], "Push A")
        XCTAssertEqual(cells[3], "Bench")
        XCTAssertEqual(cells[8], "5")
        XCTAssertEqual(cells[9], "82.5")
        XCTAssertEqual(cells[13], "felt strong")
    }
}
