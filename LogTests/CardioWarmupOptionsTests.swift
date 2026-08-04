import XCTest

@testable import Log

/// Cardio Phase 1, Slice 4 polish — warm-up options for a cardio slot.
///
/// "Fixed Weight" and "% of Working" describe nothing a treadmill or a rower
/// can do, so cardio hides them exactly as bodyweight already does. Everything
/// else must be provably untouched: strength keeps both weight-based options,
/// and a basic duration exercise (a timed hold such as Plank) is not affected
/// by this rule at all.
///
/// These exercise the pure rules behind the `WarmupStepEditSheet` picker —
/// `warmupHidesWeight`, `warmupKinds`, `warmupKindLabel`, `warmupSavedWeight` —
/// which is the whole reason they are free functions rather than view state.
final class CardioWarmupOptionsTests: XCTestCase {

    /// The two option labels this patch exists to keep away from cardio.
    private let weightBasedLabels = ["Fixed Weight", "% of Working"]

    private func labels(
        isBodyweight: Bool, isCardio: Bool, currentKind: WarmupStepKind? = nil
    ) -> [String] {
        warmupKinds(
            isBodyweight: isBodyweight, isCardio: isCardio,
            currentKind: currentKind
        )
        .map {
            warmupKindLabel($0, isBodyweight: isBodyweight, isCardio: isCardio)
        }
    }

    // MARK: - 7. Cardio excludes the weight-based options

    func testCardioExcludesPercentOfWorkingKind() {
        XCTAssertFalse(
            warmupKinds(isBodyweight: false, isCardio: true)
                .contains(.percentage))
    }

    func testCardioOffersNoWeightBasedLabel() {
        let offered = labels(isBodyweight: false, isCardio: true)
        for banned in weightBasedLabels {
            XCTAssertFalse(
                offered.contains(banned),
                "cardio still offers the weight-based option \"\(banned)\": "
                    + "\(offered)")
        }
    }

    /// What cardio *does* keep: a reps step and a note-only step, the same two
    /// a bodyweight exercise gets, in the same order.
    func testCardioKeepsRepsAndNoteOnly() {
        XCTAssertEqual(
            warmupKinds(isBodyweight: false, isCardio: true),
            [.fixedReps, .noteOnly])
        XCTAssertEqual(
            labels(isBodyweight: false, isCardio: true), ["Reps", "Note Only"])
    }

    func testCardioFixedRepsStepSavesNoWeight() {
        XCTAssertNil(
            warmupSavedWeight(
                kind: .fixedReps, isBodyweight: false, isCardio: true,
                weightText: "60.5"))
    }

    /// A cardio exercise that is also flagged bodyweight (both flags true) is
    /// no different — the rule is an either/or.
    func testCardioAndBodyweightTogetherBehaveTheSame() {
        XCTAssertEqual(
            warmupKinds(isBodyweight: true, isCardio: true),
            [.fixedReps, .noteOnly])
        XCTAssertNil(
            warmupSavedWeight(
                kind: .fixedReps, isBodyweight: true, isCardio: true,
                weightText: "20"))
    }

    /// Editing a legacy `.percentage` step on a slot that has since become
    /// cardio must not orphan the `Picker` selection.
    func testCardioEditWithLegacyPercentageKeepsThatKindSelectable() {
        let kinds = warmupKinds(
            isBodyweight: false, isCardio: true, currentKind: .percentage)
        XCTAssertEqual(kinds, [.fixedReps, .noteOnly, .percentage])
    }

    /// …but saving it still clears any weight it carried.
    func testCardioLegacyPercentageStepSavesNoWeight() {
        XCTAssertNil(
            warmupSavedWeight(
                kind: .percentage, isBodyweight: false, isCardio: true,
                weightText: "80"))
    }

    // MARK: - 8. Strength is unchanged

    func testStrengthStillOffersBothWeightBasedOptions() {
        XCTAssertEqual(
            warmupKinds(isBodyweight: false, isCardio: false),
            [.fixedReps, .percentage, .noteOnly])

        let offered = labels(isBodyweight: false, isCardio: false)
        for expected in weightBasedLabels {
            XCTAssertTrue(
                offered.contains(expected),
                "strength lost the \"\(expected)\" warm-up option: \(offered)")
        }
    }

    func testStrengthFixedRepsStepStillSavesItsWeight() {
        XCTAssertEqual(
            warmupSavedWeight(
                kind: .fixedReps, isBodyweight: false, isCardio: false,
                weightText: "60.5"),
            60.5)
    }

    func testStrengthPercentageStepStillSavesNoWeight() {
        XCTAssertNil(
            warmupSavedWeight(
                kind: .percentage, isBodyweight: false, isCardio: false,
                weightText: "60"))
    }

    // MARK: - 9. Basic duration exercises are unchanged

    /// A timed hold is time-based but **not** cardio, so it passes
    /// `isCardio: false` and keeps precisely the options it had before this
    /// patch. The rule keys off cardio, never off duration.
    func testTimedHoldIsNotAffectedByTheCardioRule() {
        let timedHold = Exercise(name: "Plank")
        timedHold.setTimeBased(true)

        XCTAssertEqual(timedHold.trackingMode, .timedHold)
        XCTAssertFalse(timedHold.isCardio)

        let isCardio = timedHold.trackingMode == .cardio
        XCTAssertEqual(
            warmupKinds(isBodyweight: false, isCardio: isCardio),
            [.fixedReps, .percentage, .noteOnly])
        XCTAssertEqual(
            warmupSavedWeight(
                kind: .fixedReps, isBodyweight: false, isCardio: isCardio,
                weightText: "10"),
            10)
    }

    /// The flag the views pass is derived from `trackingMode`, so pin the
    /// derivation the same way the call site does it.
    func testTrackingModeDrivesTheCardioFlag() {
        let cardio = Exercise(name: "Treadmill Run")
        cardio.setTimeBased(true)
        cardio.setCardio(true)
        XCTAssertEqual(cardio.trackingMode, .cardio)
        XCTAssertTrue(warmupHidesWeight(
            isBodyweight: false, isCardio: cardio.trackingMode == .cardio))

        let strength = Exercise(name: "Bench Press")
        XCTAssertEqual(strength.trackingMode, .strength)
        XCTAssertFalse(warmupHidesWeight(
            isBodyweight: false, isCardio: strength.trackingMode == .cardio))
    }

    // MARK: - Invariants

    func testNoDuplicateKindsForAnyCombination() {
        for current: WarmupStepKind? in [nil, .fixedReps, .percentage, .noteOnly] {
            for bw in [true, false] {
                for cardio in [true, false] {
                    let kinds = warmupKinds(
                        isBodyweight: bw, isCardio: cardio,
                        currentKind: current)
                    XCTAssertEqual(
                        kinds.count, Set(kinds).count,
                        "duplicate kinds for bw=\(bw) cardio=\(cardio) "
                            + "current=\(String(describing: current))")
                }
            }
        }
    }

    /// `warmupHidesWeight` is the single rule both the picker and the save path
    /// read, so a future third reason to hide weight only has to be added once.
    func testHidesWeightIsTrueForBodyweightOrCardioOnly() {
        XCTAssertFalse(warmupHidesWeight(isBodyweight: false, isCardio: false))
        XCTAssertTrue(warmupHidesWeight(isBodyweight: true, isCardio: false))
        XCTAssertTrue(warmupHidesWeight(isBodyweight: false, isCardio: true))
        XCTAssertTrue(warmupHidesWeight(isBodyweight: true, isCardio: true))
    }
}
