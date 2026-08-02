import XCTest

@testable import Log

/// Cardio Phase 1, Slice 1 — the pure value types underneath the cardio system
/// (`docs/CARDIO_SYSTEM_DESIGN.md`).
///
/// Nothing in the app reads these types yet. These tests exist so the storage
/// and derivation contracts are pinned *before* any UI, model field, or CSV
/// column depends on them:
///
///   - distance is canonical meters, converted only at the boundary
///   - pace and speed are derived, never stored, and never produce NaN/infinity
///   - every optional metric normalizes invalid input to nil rather than
///     clamping it into a plausible-looking value
final class CardioMetricsTests: XCTestCase {

    /// Distances round-trip through a division, so exact equality is the wrong
    /// assertion. 1e-6 m is a micrometre — far tighter than any real entry.
    private let tolerance = 1e-6

    // MARK: - 1. Distance conversion

    func testKilometersToMeters() {
        XCTAssertEqual(DistanceUnit.kilometers.meters(from: 1), 1_000)
        XCTAssertEqual(DistanceUnit.kilometers.meters(from: 5), 5_000)
        XCTAssertEqual(DistanceUnit.kilometers.meters(from: 0.4), 400)
        XCTAssertEqual(DistanceUnit.kilometers.meters(from: 0), 0)
    }

    /// The mile is defined as exactly 1609.344 m.
    func testMilesToMeters() throws {
        XCTAssertEqual(
            try XCTUnwrap(DistanceUnit.miles.meters(from: 1)), 1_609.344,
            accuracy: tolerance)
        XCTAssertEqual(
            try XCTUnwrap(DistanceUnit.miles.meters(from: 3)), 4_828.032,
            accuracy: tolerance)
    }

    func testMetersToKilometers() throws {
        XCTAssertEqual(
            try XCTUnwrap(DistanceUnit.kilometers.value(fromMeters: 5_000)), 5,
            accuracy: tolerance)
        XCTAssertEqual(
            try XCTUnwrap(DistanceUnit.kilometers.value(fromMeters: 400)), 0.4,
            accuracy: tolerance)
    }

    func testMetersToMiles() throws {
        XCTAssertEqual(
            try XCTUnwrap(DistanceUnit.miles.value(fromMeters: 1_609.344)), 1,
            accuracy: tolerance)
        XCTAssertEqual(
            try XCTUnwrap(DistanceUnit.miles.value(fromMeters: 8_046.72)), 5,
            accuracy: tolerance)
    }

    func testDistanceRoundTripsInBothUnits() throws {
        for unit in DistanceUnit.allCases {
            for entered in [0.25, 1, 3.1, 5, 10, 26.2, 100] {
                let meters = try XCTUnwrap(unit.meters(from: entered))
                let back = try XCTUnwrap(unit.value(fromMeters: meters))
                XCTAssertEqual(
                    back, entered, accuracy: tolerance,
                    "\(entered) \(unit.symbol) should round-trip through meters")
            }
        }
    }

    func testConversionRejectsNegativeAndNonFiniteInput() {
        for unit in DistanceUnit.allCases {
            XCTAssertNil(unit.meters(from: -1))
            XCTAssertNil(unit.meters(from: .nan))
            XCTAssertNil(unit.meters(from: .infinity))
            XCTAssertNil(unit.value(fromMeters: -1))
            XCTAssertNil(unit.value(fromMeters: .nan))
            XCTAssertNil(unit.value(fromMeters: .infinity))
        }
    }

    // MARK: - 2. DistanceUnit raw values

    func testDistanceUnitRawValuesAreTheDisplaySymbols() {
        XCTAssertEqual(DistanceUnit.kilometers.rawValue, "km")
        XCTAssertEqual(DistanceUnit.miles.rawValue, "mi")
        XCTAssertEqual(DistanceUnit.kilometers.symbol, "km")
        XCTAssertEqual(DistanceUnit.miles.symbol, "mi")
    }

    func testDistanceUnitParsingIsTolerant() {
        XCTAssertEqual(DistanceUnit.from(raw: "km"), .kilometers)
        XCTAssertEqual(DistanceUnit.from(raw: " KM "), .kilometers)
        XCTAssertEqual(DistanceUnit.from(raw: "Mi"), .miles)
        XCTAssertNil(DistanceUnit.from(raw: nil))
        XCTAssertNil(DistanceUnit.from(raw: ""))
        XCTAssertNil(
            DistanceUnit.from(raw: "meters"),
            "unknown units must resolve to nil, never to a silent default")
    }

    // MARK: - 3. HRZone

    func testHRZoneRawValuesRoundTrip() {
        for zone in HRZone.allCases {
            XCTAssertEqual(HRZone(rawValue: zone.rawValue), zone)
            XCTAssertEqual(HRZone.from(raw: zone.rawValue), zone)
        }
        XCTAssertEqual(HRZone.allCases.map(\.rawValue), ["z1", "z2", "z3", "z4", "z5"])
    }

    func testHRZoneOrderingAndLabels() {
        XCTAssertEqual(HRZone.allCases.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(HRZone.allCases.map(\.shortLabel), ["Z1", "Z2", "Z3", "Z4", "Z5"])
        XCTAssertTrue(HRZone.z1 < HRZone.z2)
        XCTAssertTrue(HRZone.z5 > HRZone.z3)
        XCTAssertEqual(HRZone.allCases.sorted(), HRZone.allCases)
    }

    func testHRZoneParsingIsTolerant() {
        XCTAssertEqual(HRZone.from(raw: " Z4 "), .z4)
        XCTAssertNil(HRZone.from(raw: nil))
        XCTAssertNil(HRZone.from(raw: "z6"))
        XCTAssertNil(HRZone.from(raw: "zone 2"))
    }

    // MARK: - 4. Field normalization

    func testDistanceNormalization() {
        XCTAssertEqual(CardioMetrics.normalizedDistanceMeters(5_000), 5_000)
        XCTAssertEqual(
            CardioMetrics.normalizedDistanceMeters(CardioLimits.maxDistanceMeters),
            CardioLimits.maxDistanceMeters)

        XCTAssertNil(CardioMetrics.normalizedDistanceMeters(nil))
        XCTAssertNil(CardioMetrics.normalizedDistanceMeters(0))
        XCTAssertNil(CardioMetrics.normalizedDistanceMeters(-1))
        XCTAssertNil(CardioMetrics.normalizedDistanceMeters(.nan))
        XCTAssertNil(CardioMetrics.normalizedDistanceMeters(.infinity))
        XCTAssertNil(
            CardioMetrics.normalizedDistanceMeters(
                CardioLimits.maxDistanceMeters + 1),
            "out-of-range distance is rejected, not clamped")
    }

    func testHeartRateNormalization() {
        XCTAssertEqual(CardioMetrics.normalizedHeartRate(142), 142)
        XCTAssertEqual(
            CardioMetrics.normalizedHeartRate(CardioLimits.minHeartRate),
            CardioLimits.minHeartRate)
        XCTAssertEqual(
            CardioMetrics.normalizedHeartRate(CardioLimits.maxHeartRate),
            CardioLimits.maxHeartRate)

        XCTAssertNil(CardioMetrics.normalizedHeartRate(nil))
        XCTAssertNil(CardioMetrics.normalizedHeartRate(0))
        XCTAssertNil(CardioMetrics.normalizedHeartRate(-60))
        XCTAssertNil(CardioMetrics.normalizedHeartRate(19))
        XCTAssertNil(
            CardioMetrics.normalizedHeartRate(1_500),
            "an implausible bpm is rejected rather than clamped into a "
                + "fabricated-but-believable vital sign")
    }

    func testCaloriesNormalization() {
        XCTAssertEqual(CardioMetrics.normalizedCalories(410), 410)
        XCTAssertNil(CardioMetrics.normalizedCalories(nil))
        XCTAssertNil(CardioMetrics.normalizedCalories(0))
        XCTAssertNil(CardioMetrics.normalizedCalories(-10))
        XCTAssertNil(CardioMetrics.normalizedCalories(CardioLimits.maxCalories + 1))
    }

    /// Incline is the one metric where 0 is kept: a set explicitly recorded as
    /// flat is different from a set with no incline recorded. It is also the
    /// only **signed** metric — see the decline tests below.
    func testInclineNormalizationKeepsZeroAndPositiveGrades() {
        XCTAssertEqual(CardioMetrics.normalizedInclinePercent(0), 0)
        XCTAssertEqual(CardioMetrics.normalizedInclinePercent(3.5), 3.5)
        XCTAssertEqual(
            CardioMetrics.normalizedInclinePercent(CardioLimits.maxInclinePercent),
            CardioLimits.maxInclinePercent)

        XCTAssertNil(CardioMetrics.normalizedInclinePercent(nil))
        XCTAssertNil(CardioMetrics.normalizedInclinePercent(.nan))
        XCTAssertNil(CardioMetrics.normalizedInclinePercent(.infinity))
        XCTAssertNil(CardioMetrics.normalizedInclinePercent(-.infinity))
    }

    /// Decline is a real treadmill setting, so a negative grade is valid input
    /// rather than something to reject.
    func testInclineNormalizationAcceptsDecline() {
        XCTAssertEqual(CardioMetrics.normalizedInclinePercent(-3), -3)
        XCTAssertEqual(CardioMetrics.normalizedInclinePercent(-0.5), -0.5)
        XCTAssertEqual(CardioMetrics.normalizedInclinePercent(-6), -6)
        XCTAssertEqual(
            CardioMetrics.normalizedInclinePercent(CardioLimits.minInclinePercent),
            CardioLimits.minInclinePercent,
            "the lower bound itself is inclusive")
    }

    func testInclineRejectsValuesOutsideTheSignedRange() {
        XCTAssertNil(
            CardioMetrics.normalizedInclinePercent(
                CardioLimits.minInclinePercent - 0.1))
        XCTAssertNil(CardioMetrics.normalizedInclinePercent(-31))
        XCTAssertNil(CardioMetrics.normalizedInclinePercent(-1_000))
        XCTAssertNil(
            CardioMetrics.normalizedInclinePercent(
                CardioLimits.maxInclinePercent + 0.1))
        XCTAssertNil(CardioMetrics.normalizedInclinePercent(101))
        XCTAssertNil(CardioMetrics.normalizedInclinePercent(1_000))
    }

    func testInclineRangeBounds() {
        XCTAssertEqual(CardioLimits.minInclinePercent, -30)
        XCTAssertEqual(CardioLimits.maxInclinePercent, 100)
    }

    /// A decline value has to survive construction, not just the normalizer —
    /// the initializer is the only way the field is ever populated.
    func testDeclineSurvivesMetricsConstruction() {
        let m = CardioMetrics(inclinePercent: -3)
        XCTAssertEqual(m.inclinePercent, -3)
        XCTAssertFalse(
            m.isEmpty, "a recorded decline counts as recorded metrics")

        XCTAssertNil(CardioMetrics(inclinePercent: -31).inclinePercent)
    }

    func testDeclineParsesFromFreeText() {
        XCTAssertEqual(CardioMetrics.parseInclinePercent("-3"), -3)
        XCTAssertEqual(CardioMetrics.parseInclinePercent(" -0.5 "), -0.5)
        XCTAssertEqual(CardioMetrics.parseInclinePercent("-30"), -30)
        XCTAssertNil(CardioMetrics.parseInclinePercent("-31"))
        XCTAssertNil(CardioMetrics.parseInclinePercent("-"))
    }

    func testResistanceNormalization() {
        XCTAssertEqual(CardioMetrics.normalizedResistanceLevel(8), 8)
        XCTAssertEqual(CardioMetrics.normalizedResistanceLevel(8.5), 8.5)

        XCTAssertNil(CardioMetrics.normalizedResistanceLevel(nil))
        XCTAssertNil(CardioMetrics.normalizedResistanceLevel(0))
        XCTAssertNil(CardioMetrics.normalizedResistanceLevel(-3))
        XCTAssertNil(CardioMetrics.normalizedResistanceLevel(.nan))
        XCTAssertNil(
            CardioMetrics.normalizedResistanceLevel(
                CardioLimits.maxResistanceLevel + 1))
    }

    // MARK: - 5. CardioMetrics construction

    func testInitializerNormalizesEveryField() {
        let m = CardioMetrics(
            distanceMeters: -5,
            distanceUnit: .kilometers,
            avgHeartRate: 1_000,
            calories: -1,
            inclinePercent: .nan,
            resistanceLevel: .infinity,
            hrZone: .z3
        )

        XCTAssertNil(m.distanceMeters)
        XCTAssertNil(m.avgHeartRate)
        XCTAssertNil(m.calories)
        XCTAssertNil(m.inclinePercent)
        XCTAssertNil(m.resistanceLevel)
        XCTAssertEqual(m.hrZone, .z3)
    }

    /// A unit with no distance carries no information and would let the two
    /// fields disagree about whether a distance was recorded.
    func testDistanceUnitIsDroppedWithoutADistance() {
        let m = CardioMetrics(distanceMeters: nil, distanceUnit: .miles)
        XCTAssertNil(m.distanceUnit)

        let withDistance = CardioMetrics(
            distanceMeters: 5_000, distanceUnit: .miles)
        XCTAssertEqual(withDistance.distanceUnit, .miles)
    }

    func testIsEmptyReflectsWhetherAnythingWasRecorded() {
        XCTAssertTrue(CardioMetrics().isEmpty)
        XCTAssertTrue(
            CardioMetrics(distanceMeters: -1).isEmpty,
            "rejected input leaves the metrics empty")
        XCTAssertFalse(CardioMetrics(distanceMeters: 5_000).isEmpty)
        XCTAssertFalse(CardioMetrics(inclinePercent: 0).isEmpty)
        XCTAssertFalse(CardioMetrics(hrZone: .z2).isEmpty)
    }

    func testDistanceValueReadsBackInEitherUnit() throws {
        let m = CardioMetrics(distanceMeters: 5_000, distanceUnit: .kilometers)
        XCTAssertEqual(
            try XCTUnwrap(m.distanceValue(in: .kilometers)), 5,
            accuracy: tolerance)
        XCTAssertEqual(
            try XCTUnwrap(m.distanceValue(in: .miles)), 3.106855,
            accuracy: 1e-5)
        XCTAssertNil(CardioMetrics().distanceValue(in: .kilometers))
    }

    func testMetricsAreCodable() throws {
        let original = CardioMetrics(
            distanceMeters: 6_200, distanceUnit: .kilometers,
            avgHeartRate: 142, calories: 410, inclinePercent: 1.5,
            resistanceLevel: 8, hrZone: .z3)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CardioMetrics.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - 6. Free-text parsing

    func testParseDistanceHonoursTheEntryUnit() throws {
        XCTAssertEqual(
            try XCTUnwrap(CardioMetrics.parseDistance("5", unit: .kilometers)),
            5_000, accuracy: tolerance)
        XCTAssertEqual(
            try XCTUnwrap(CardioMetrics.parseDistance(" 3.1 ", unit: .miles)),
            4_988.9664, accuracy: tolerance)
    }

    func testParseDistanceRejectsUnusableInput() {
        for text in ["", "   ", "abc", "5k", "-2", "0", "nan", "inf"] {
            XCTAssertNil(
                CardioMetrics.parseDistance(text, unit: .kilometers),
                "\(text.debugDescription) should not parse to a distance")
        }
    }

    func testParseScalarMetrics() {
        XCTAssertEqual(CardioMetrics.parseHeartRate(" 142 "), 142)
        XCTAssertEqual(CardioMetrics.parseCalories("410"), 410)
        XCTAssertEqual(CardioMetrics.parseInclinePercent("1.5"), 1.5)
        XCTAssertEqual(CardioMetrics.parseInclinePercent("0"), 0)
        XCTAssertEqual(CardioMetrics.parseResistanceLevel("8.5"), 8.5)

        for text in ["", " ", "abc"] {
            XCTAssertNil(CardioMetrics.parseHeartRate(text))
            XCTAssertNil(CardioMetrics.parseCalories(text))
            XCTAssertNil(CardioMetrics.parseInclinePercent(text))
            XCTAssertNil(CardioMetrics.parseResistanceLevel(text))
        }

        // Incline is signed, so "-1" is valid there and only there.
        XCTAssertNil(CardioMetrics.parseHeartRate("-1"))
        XCTAssertNil(CardioMetrics.parseCalories("-1"))
        XCTAssertNil(CardioMetrics.parseResistanceLevel("-1"))
        XCTAssertEqual(CardioMetrics.parseInclinePercent("-1"), -1)
    }

    // MARK: - 7. Derived pace

    /// 5 km in 25:00 is exactly 5:00 /km.
    func testPaceForKnownDistanceAndDuration() throws {
        let pace = try XCTUnwrap(
            CardioDerived.paceSecondsPerUnit(
                distanceMeters: 5_000, durationSeconds: 1_500,
                unit: .kilometers))
        XCTAssertEqual(pace, 300, accuracy: tolerance)
        XCTAssertEqual(CardioDerived.formatPace(secondsPerUnit: pace), "5:00")
    }

    /// 6.2 km in 30:00 → 290.32… s/km, which displays as 4:50.
    func testPaceRoundsToTheDisplayedSecond() throws {
        let pace = try XCTUnwrap(
            CardioDerived.paceSecondsPerUnit(
                distanceMeters: 6_200, durationSeconds: 1_800,
                unit: .kilometers))
        XCTAssertEqual(pace, 290.322580, accuracy: 1e-5)
        XCTAssertEqual(CardioDerived.formatPace(secondsPerUnit: pace), "4:50")
    }

    func testPaceInMiles() throws {
        // 1 mile in 8:00.
        let pace = try XCTUnwrap(
            CardioDerived.paceSecondsPerUnit(
                distanceMeters: 1_609.344, durationSeconds: 480, unit: .miles))
        XCTAssertEqual(pace, 480, accuracy: tolerance)
        XCTAssertEqual(CardioDerived.formatPace(secondsPerUnit: pace), "8:00")
    }

    // MARK: - 8. Derived speed

    /// 5 km in 25:00 is 12 km/h.
    func testSpeedForKnownDistanceAndDuration() throws {
        let speed = try XCTUnwrap(
            CardioDerived.speedUnitsPerHour(
                distanceMeters: 5_000, durationSeconds: 1_500,
                unit: .kilometers))
        XCTAssertEqual(speed, 12, accuracy: tolerance)
        XCTAssertEqual(CardioDerived.formatSpeed(unitsPerHour: speed), "12.0")
    }

    func testSpeedInMiles() throws {
        // 1 mile in 6:00 → 10 mph.
        let speed = try XCTUnwrap(
            CardioDerived.speedUnitsPerHour(
                distanceMeters: 1_609.344, durationSeconds: 360, unit: .miles))
        XCTAssertEqual(speed, 10, accuracy: tolerance)
    }

    /// Pace and speed describe the same bout, so they must agree:
    /// `speed = 3600 / pace`.
    func testPaceAndSpeedAreConsistent() throws {
        for unit in DistanceUnit.allCases {
            let pace = try XCTUnwrap(
                CardioDerived.paceSecondsPerUnit(
                    distanceMeters: 7_500, durationSeconds: 2_100, unit: unit))
            let speed = try XCTUnwrap(
                CardioDerived.speedUnitsPerHour(
                    distanceMeters: 7_500, durationSeconds: 2_100, unit: unit))
            XCTAssertEqual(speed, 3_600 / pace, accuracy: 1e-6)
        }
    }

    // MARK: - 9. Derivation safety

    func testMissingDistanceProducesNoPaceOrSpeed() {
        XCTAssertNil(
            CardioDerived.paceSecondsPerUnit(
                distanceMeters: nil, durationSeconds: 1_800, unit: .kilometers))
        XCTAssertNil(
            CardioDerived.speedUnitsPerHour(
                distanceMeters: nil, durationSeconds: 1_800, unit: .kilometers))
    }

    func testMissingDurationProducesNoPaceOrSpeed() {
        XCTAssertNil(
            CardioDerived.paceSecondsPerUnit(
                distanceMeters: 5_000, durationSeconds: nil, unit: .kilometers))
        XCTAssertNil(
            CardioDerived.speedUnitsPerHour(
                distanceMeters: 5_000, durationSeconds: nil, unit: .kilometers))
    }

    /// The divide-by-zero case.
    func testZeroOrNegativeDurationProducesNoPaceOrSpeed() {
        for duration in [0, -1, -1_800] {
            XCTAssertNil(
                CardioDerived.paceSecondsPerUnit(
                    distanceMeters: 5_000, durationSeconds: duration,
                    unit: .kilometers),
                "duration \(duration) must not produce a pace")
            XCTAssertNil(
                CardioDerived.speedUnitsPerHour(
                    distanceMeters: 5_000, durationSeconds: duration,
                    unit: .kilometers),
                "duration \(duration) must not produce a speed")
        }
    }

    /// The other divide-by-zero case: a zero distance is rejected upstream by
    /// normalization, so pace never divides by zero units.
    func testZeroOrNegativeDistanceProducesNoPaceOrSpeed() {
        for distance in [0.0, -1, -5_000] {
            XCTAssertNil(
                CardioDerived.paceSecondsPerUnit(
                    distanceMeters: distance, durationSeconds: 1_800,
                    unit: .kilometers))
            XCTAssertNil(
                CardioDerived.speedUnitsPerHour(
                    distanceMeters: distance, durationSeconds: 1_800,
                    unit: .kilometers))
        }
    }

    func testNonFiniteDistanceProducesNoPaceOrSpeed() {
        for distance in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(
                CardioDerived.paceSecondsPerUnit(
                    distanceMeters: distance, durationSeconds: 1_800,
                    unit: .kilometers))
            XCTAssertNil(
                CardioDerived.speedUnitsPerHour(
                    distanceMeters: distance, durationSeconds: 1_800,
                    unit: .kilometers))
        }
    }

    /// Nothing the derivation returns may be NaN or infinite — a chart axis
    /// fed either one is unrecoverable.
    func testDerivedValuesAreAlwaysFinite() throws {
        let distances: [Double?] = [nil, 0, -1, .nan, .infinity, 1, 5_000, 999_999]
        let durations: [Int?] = [nil, -1, 0, 1, 1_800, 21_600]

        for unit in DistanceUnit.allCases {
            for distance in distances {
                for duration in durations {
                    if let pace = CardioDerived.paceSecondsPerUnit(
                        distanceMeters: distance, durationSeconds: duration,
                        unit: unit)
                    {
                        XCTAssertTrue(pace.isFinite)
                        XCTAssertGreaterThan(pace, 0)
                    }
                    if let speed = CardioDerived.speedUnitsPerHour(
                        distanceMeters: distance, durationSeconds: duration,
                        unit: unit)
                    {
                        XCTAssertTrue(speed.isFinite)
                        XCTAssertGreaterThan(speed, 0)
                    }
                }
            }
        }
    }

    func testInstanceHelpersMatchTheStaticDerivation() throws {
        let m = CardioMetrics(distanceMeters: 5_000, distanceUnit: .kilometers)
        XCTAssertEqual(
            m.paceSecondsPerUnit(durationSeconds: 1_500, in: .kilometers),
            CardioDerived.paceSecondsPerUnit(
                distanceMeters: 5_000, durationSeconds: 1_500,
                unit: .kilometers))
        XCTAssertEqual(
            m.speedUnitsPerHour(durationSeconds: 1_500, in: .kilometers),
            CardioDerived.speedUnitsPerHour(
                distanceMeters: 5_000, durationSeconds: 1_500,
                unit: .kilometers))

        XCTAssertNil(
            CardioMetrics().paceSecondsPerUnit(
                durationSeconds: 1_500, in: .kilometers))
    }

    // MARK: - 10. Formatting

    func testFormatPace() {
        XCTAssertEqual(CardioDerived.formatPace(secondsPerUnit: 300), "5:00")
        XCTAssertEqual(CardioDerived.formatPace(secondsPerUnit: 290), "4:50")
        XCTAssertEqual(CardioDerived.formatPace(secondsPerUnit: 65), "1:05")
        XCTAssertEqual(
            CardioDerived.formatPace(secondsPerUnit: 4_500), "75:00",
            "very slow paces stay in minutes so they cannot be misread as a "
                + "duration")

        XCTAssertNil(CardioDerived.formatPace(secondsPerUnit: 0))
        XCTAssertNil(CardioDerived.formatPace(secondsPerUnit: -300))
        XCTAssertNil(CardioDerived.formatPace(secondsPerUnit: .nan))
        XCTAssertNil(CardioDerived.formatPace(secondsPerUnit: .infinity))
    }

    func testFormatSpeed() {
        XCTAssertEqual(CardioDerived.formatSpeed(unitsPerHour: 12), "12.0")
        XCTAssertEqual(CardioDerived.formatSpeed(unitsPerHour: 12.44), "12.4")
        XCTAssertEqual(CardioDerived.formatSpeed(unitsPerHour: 0), "0.0")

        XCTAssertNil(CardioDerived.formatSpeed(unitsPerHour: -1))
        XCTAssertNil(CardioDerived.formatSpeed(unitsPerHour: .nan))
        XCTAssertNil(CardioDerived.formatSpeed(unitsPerHour: .infinity))
    }

    func testFormatDistanceTrimsTrailingZeros() {
        XCTAssertEqual(CardioDerived.formatDistance(value: 5), "5")
        XCTAssertEqual(CardioDerived.formatDistance(value: 6.2), "6.2")
        XCTAssertEqual(CardioDerived.formatDistance(value: 6.25), "6.25")
        XCTAssertEqual(CardioDerived.formatDistance(value: 6.253), "6.25")
        XCTAssertEqual(CardioDerived.formatDistance(value: 0), "0")

        XCTAssertNil(CardioDerived.formatDistance(value: -1))
        XCTAssertNil(CardioDerived.formatDistance(value: .nan))
        XCTAssertNil(CardioDerived.formatDistance(value: .infinity))
    }

    /// Formatting must not localize its separator, or the value stops
    /// round-tripping through `Double(_:)` when it seeds a `.decimalPad` field.
    /// Matches the guarantee `AppSettings.formatWeight` already makes.
    func testFormattedValuesRoundTripThroughDouble() throws {
        for value in [5.0, 6.2, 6.25, 12.4] {
            let text = try XCTUnwrap(CardioDerived.formatDistance(value: value))
            XCTAssertNotNil(Double(text), "\(text) should parse back")
        }
        let speed = try XCTUnwrap(CardioDerived.formatSpeed(unitsPerHour: 12.44))
        XCTAssertNotNil(Double(speed))
    }
}

// ======================================================
// MARK: - Distance unit preference
// ======================================================

/// `AppSettings.distanceIsMetric` and its locale-derived default.
///
/// The stored-preference tests write to `UserDefaults.standard` (the accessor
/// reads it directly, matching `weightIsKg`), so each one saves and restores the
/// prior value rather than leaking a unit change into the rest of the suite.
final class DistanceUnitPreferenceTests: XCTestCase {

    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(
            forKey: AppSettings.Keys.distanceIsMetric)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(
                savedValue, forKey: AppSettings.Keys.distanceIsMetric)
        } else {
            UserDefaults.standard.removeObject(
                forKey: AppSettings.Keys.distanceIsMetric)
        }
        super.tearDown()
    }

    // MARK: Locale default

    func testUSLocaleDefaultsToMiles() {
        XCTAssertFalse(
            AppSettings.defaultDistanceIsMetric(locale: Locale(identifier: "en_US")))
    }

    func testMetricLocalesDefaultToKilometers() {
        for identifier in ["ko_KR", "en_DE", "fr_FR", "ja_JP"] {
            XCTAssertTrue(
                AppSettings.defaultDistanceIsMetric(
                    locale: Locale(identifier: identifier)),
                "\(identifier) should default to metric")
        }
    }

    /// The UK measurement system is metric for everything except road distance,
    /// and UK runners commonly train in km.
    func testUKLocaleDefaultsToKilometers() {
        XCTAssertTrue(
            AppSettings.defaultDistanceIsMetric(locale: Locale(identifier: "en_GB")))
    }

    // MARK: Stored preference

    func testStoredPreferenceOverridesTheLocaleDefault() {
        AppSettings.distanceIsMetric = false
        XCTAssertFalse(AppSettings.distanceIsMetric)
        XCTAssertEqual(AppSettings.distanceUnit, .miles)

        AppSettings.distanceIsMetric = true
        XCTAssertTrue(AppSettings.distanceIsMetric)
        XCTAssertEqual(AppSettings.distanceUnit, .kilometers)
    }

    func testUnsetPreferenceFallsBackToTheLocaleDefault() {
        UserDefaults.standard.removeObject(
            forKey: AppSettings.Keys.distanceIsMetric)
        XCTAssertEqual(
            AppSettings.distanceIsMetric, AppSettings.defaultDistanceIsMetric())
    }

    /// The preference is display-only; it must not be able to change stored
    /// data, which is always meters.
    func testChangingThePreferenceDoesNotAlterStoredDistance() {
        let metrics = CardioMetrics(
            distanceMeters: 5_000, distanceUnit: .kilometers)

        AppSettings.distanceIsMetric = false
        XCTAssertEqual(metrics.distanceMeters, 5_000)
        XCTAssertEqual(
            metrics.distanceUnit, .kilometers,
            "a logged bout keeps the unit it was entered in")
    }
}
