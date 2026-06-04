import XCTest

@testable import Log

/// Bodyweight load metrics slice — pure helpers behind the Settings bodyweight
/// input, the per-exercise `includesBodyweightInLoad` default, effective-load
/// computation, and the metric-availability matrix.
final class BodyweightLoadMetricTests: XCTestCase {

    // MARK: - normalizedBodyweight

    func testNormalizedBodyweightEmptyIsNil() {
        XCTAssertNil(normalizedBodyweight(""))
        XCTAssertNil(normalizedBodyweight("   "))
    }

    func testNormalizedBodyweightZeroIsNil() {
        XCTAssertNil(normalizedBodyweight("0"))
    }

    func testNormalizedBodyweightNegativeIsNil() {
        XCTAssertNil(normalizedBodyweight("-1"))
    }

    func testNormalizedBodyweightInvalidIsNil() {
        XCTAssertNil(normalizedBodyweight("abc"))
    }

    func testNormalizedBodyweightDecimalParses() {
        XCTAssertEqual(normalizedBodyweight("72.5"), 72.5)
        XCTAssertEqual(normalizedBodyweight(" 70 "), 70)
    }

    // MARK: - defaultIncludesBodyweightInLoad

    func testDefaultIncludesBodyweightForBodyweightEquipment() {
        XCTAssertTrue(defaultIncludesBodyweightInLoad(equipmentType: "Bodyweight"))
        XCTAssertTrue(defaultIncludesBodyweightInLoad(equipmentType: " bodyweight "))
        XCTAssertTrue(defaultIncludesBodyweightInLoad(equipmentType: "BODYWEIGHT"))
    }

    func testDefaultIncludesBodyweightFalseForOthers() {
        XCTAssertFalse(defaultIncludesBodyweightInLoad(equipmentType: "Dip Belt"))
        XCTAssertFalse(defaultIncludesBodyweightInLoad(equipmentType: "Barbell"))
        XCTAssertFalse(defaultIncludesBodyweightInLoad(equipmentType: nil))
    }

    // MARK: - effectiveLoad

    func testEffectiveLoadPureBodyweight() {
        // Pull-up: no logged weight, bodyweight counts.
        XCTAssertEqual(
            effectiveLoad(loggedWeight: nil, includesBodyweight: true, userBodyweight: 70), 70)
    }

    func testEffectiveLoadWeightedBodyweight() {
        // Weighted pull-up: bodyweight + added weight.
        XCTAssertEqual(
            effectiveLoad(loggedWeight: 20, includesBodyweight: true, userBodyweight: 70), 90)
    }

    func testEffectiveLoadNormalWeighted() {
        XCTAssertEqual(
            effectiveLoad(loggedWeight: 100, includesBodyweight: false, userBodyweight: 70), 100)
    }

    func testEffectiveLoadBodyweightInclusiveButNoUserBodyweight() {
        XCTAssertNil(
            effectiveLoad(loggedWeight: nil, includesBodyweight: true, userBodyweight: nil))
    }

    func testEffectiveLoadNonBodyweightNoUserBodyweight() {
        XCTAssertEqual(
            effectiveLoad(loggedWeight: 60, includesBodyweight: false, userBodyweight: nil), 60)
    }

    // MARK: - availableProgressMetrics (load matrix)

    func testTimeBasedAlwaysDuration() {
        for equip in [true, false] {
            for inc in [true, false] {
                for has in [true, false] {
                    XCTAssertEqual(
                        availableProgressMetrics(
                            isTimeBased: true, isBodyweightEquipment: equip,
                            includesBodyweight: inc, hasUserBodyweight: has),
                        [.totalDuration]
                    )
                }
            }
        }
    }

    func testBodyweightWithUserBodyweightOffersLoadAndReps() {
        let metrics = availableProgressMetrics(
            isTimeBased: false, isBodyweightEquipment: true,
            includesBodyweight: true, hasUserBodyweight: true)
        XCTAssertEqual(metrics, [.e1rm, .volume, .bestWeight, .totalReps, .bestReps])
    }

    func testBodyweightFlagOnWithoutUserBodyweightOffersRepsOnly() {
        let metrics = availableProgressMetrics(
            isTimeBased: false, isBodyweightEquipment: true,
            includesBodyweight: true, hasUserBodyweight: false)
        XCTAssertEqual(metrics, [.totalReps, .bestReps])
        XCTAssertFalse(metrics.contains(.e1rm))
        XCTAssertFalse(metrics.contains(.volume))
        XCTAssertFalse(metrics.contains(.bestWeight))
    }

    // Regression: pure Bodyweight equipment with the flag OFF has no logged
    // weight (input hidden) and no added bodyweight → reps-based metrics only.
    func testBodyweightEquipmentFlagOffIsRepsOnly() {
        for has in [true, false] {
            let metrics = availableProgressMetrics(
                isTimeBased: false, isBodyweightEquipment: true,
                includesBodyweight: false, hasUserBodyweight: has)
            XCTAssertEqual(metrics, [.totalReps, .bestReps])
            XCTAssertFalse(metrics.contains(.e1rm))
            XCTAssertFalse(metrics.contains(.volume))
            XCTAssertFalse(metrics.contains(.bestWeight))
        }
    }

    func testNonBodyweightFlagOnWithUserBodyweightOffersLoadAndReps() {
        let metrics = availableProgressMetrics(
            isTimeBased: false, isBodyweightEquipment: false,
            includesBodyweight: true, hasUserBodyweight: true)
        XCTAssertEqual(metrics, [.e1rm, .volume, .bestWeight, .totalReps, .bestReps])
    }

    func testNonBodyweightFlagOnWithoutUserBodyweightOffersRepsOnly() {
        let metrics = availableProgressMetrics(
            isTimeBased: false, isBodyweightEquipment: false,
            includesBodyweight: true, hasUserBodyweight: false)
        XCTAssertEqual(metrics, [.totalReps, .bestReps])
    }

    func testNonBodyweightFlagOffUnchangedRegardlessOfUserBodyweight() {
        for has in [true, false] {
            XCTAssertEqual(
                availableProgressMetrics(
                    isTimeBased: false, isBodyweightEquipment: false,
                    includesBodyweight: false, hasUserBodyweight: has),
                [.e1rm, .volume, .bestWeight, .totalReps]
            )
        }
    }
}
