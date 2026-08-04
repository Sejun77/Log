import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 4 polish — pace **wording**.
///
/// Review found "/km" unexplained: the value is fine once you know what it is,
/// but nothing on screen said so. The field label now carries the unit —
/// "Pace (min/km)" / "Pace (min/mi)" — and never the ambiguous "time/km".
///
/// The arithmetic is deliberately untouched (`pace = durationSeconds /
/// distance`), and the first half of this file exists to prove that: the value
/// format and every derived number are asserted against the same literals the
/// pre-patch tests use.
@MainActor
final class CardioPaceLabelTests: SwiftDataTestHarness {

    private let km = DistanceUnit.kilometers
    private let mi = DistanceUnit.miles

    // MARK: - 5. The calculation and the value format are unchanged

    /// 5 km in 25:00 is a 5:00 /km pace — duration ÷ distance, nothing else.
    func testPaceIsDurationDividedByDistance() throws {
        let pace = try XCTUnwrap(
            CardioDerived.paceSecondsPerUnit(
                distanceMeters: 5_000, durationSeconds: 1_500, unit: km))
        XCTAssertEqual(pace, 300, accuracy: 0.000_1)
        XCTAssertEqual(CardioDerived.formatPace(secondsPerUnit: pace), "5:00")
    }

    func testPaceInMilesIsUnchanged() throws {
        let pace = try XCTUnwrap(
            CardioDerived.paceSecondsPerUnit(
                distanceMeters: 1_609.344, durationSeconds: 480, unit: mi))
        XCTAssertEqual(pace, 480, accuracy: 0.000_1)
        XCTAssertEqual(CardioDerived.formatPace(secondsPerUnit: pace), "8:00")
    }

    /// The rendered value keeps its established "5:00 /km" shape — the entry
    /// preview and the History line both build it the same way.
    func testDraftPaceTextStillRendersValueWithSlashUnit() {
        var draft = CardioEntryDraft(unit: km, distance: "5")
        XCTAssertEqual(draft.paceText(durationSeconds: 1_500), "5:00 /km")

        draft.unit = mi
        XCTAssertEqual(draft.paceText(durationSeconds: 2_400), "8:00 /mi")
    }

    func testHistoryPaceSegmentStillRendersValueWithSlashUnit() {
        let log = SetLog(
            indexInExercise: 0, reps: 0, weight: nil, durationSeconds: 1_500)
        context.insert(log)
        log.applyCardioMetrics(
            CardioMetrics(distanceMeters: 5_000, distanceUnit: km))

        XCTAssertEqual(
            CardioHistorySummary.secondaryLines(for: log, fallbackUnit: km),
            ["5 km · 5:00 /km"])
    }

    // MARK: - 6. The label is clearer

    func testPaceLabelNamesTheUnit() {
        XCTAssertEqual(km.paceFieldLabel, "Pace (min/km)")
        XCTAssertEqual(mi.paceFieldLabel, "Pace (min/mi)")
    }

    func testPaceUnitSymbolIsMinutesPerUnit() {
        XCTAssertEqual(km.paceUnitSymbol, "min/km")
        XCTAssertEqual(mi.paceUnitSymbol, "min/mi")
    }

    /// Both labels still start with the word users already recognize, so the
    /// unit reads as a clarification rather than a rename.
    func testPaceLabelStillStartsWithPace() {
        for unit in DistanceUnit.allCases {
            XCTAssertTrue(
                unit.paceFieldLabel.hasPrefix("Pace"),
                "pace label no longer names the quantity: \(unit.paceFieldLabel)")
        }
    }

    /// "time/km" reads like a spreadsheet column, not a quantity, and is
    /// explicitly out of bounds for user-facing pace wording.
    func testNoLabelUsesTimePerUnitWording() {
        for unit in DistanceUnit.allCases {
            XCTAssertFalse(
                unit.paceFieldLabel.localizedCaseInsensitiveContains("time/"),
                "pace label uses the rejected \"time/unit\" wording: "
                    + unit.paceFieldLabel)
        }
    }

    func testEachUnitHasItsOwnLabel() {
        XCTAssertNotEqual(km.paceFieldLabel, mi.paceFieldLabel)
    }
}
