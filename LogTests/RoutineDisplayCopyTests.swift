import XCTest

@testable import Log

/// Build 10 low-risk UI polish — the pure copy rules behind four of the audit
/// items, so the wording is pinned without a UI harness.
final class RoutineDisplayCopyTests: XCTestCase {

    // ==================================================
    // MARK: - M11 — block detail title
    // ==================================================

    func test_singleExerciseBlockTitlesWithTheExerciseName() {
        XCTAssertEqual(
            BlockDetailTitle.title(
                exerciseNames: ["Bench Press"], isSuperset: false),
            "Bench Press")
    }

    func test_supersetJoinsItsMembers() {
        XCTAssertEqual(
            BlockDetailTitle.title(
                exerciseNames: ["Bench Press", "Barbell Row"],
                isSuperset: true),
            "Bench Press + Barbell Row",
            "matching the routine editor's own row title, so the row that "
                + "pushes this screen and the screen cannot disagree")
    }

    /// The kind word is the fallback, not the default.
    func test_blockWithNoResolvableExercisesKeepsTheKindWord() {
        XCTAssertEqual(
            BlockDetailTitle.title(exerciseNames: [], isSuperset: false),
            "Block")
        XCTAssertEqual(
            BlockDetailTitle.title(exerciseNames: [], isSuperset: true),
            "Superset")
    }

    func test_blankNamesAreIgnoredRatherThanJoinedAsEmptySegments() {
        XCTAssertEqual(
            BlockDetailTitle.title(
                exerciseNames: ["Squat", "   ", ""], isSuperset: true),
            "Squat")
        XCTAssertEqual(
            BlockDetailTitle.title(
                exerciseNames: ["  "], isSuperset: false),
            "Block")
    }

    // ==================================================
    // MARK: - M7 — effort progression labels
    // ==================================================

    /// Whole phrases per metric, not the generic Start/End keys composed with a
    /// metric name — those are the keys the workout-ending controls own.
    func test_effortLabelsAreWholePhrasesPerMetric() {
        XCTAssertEqual(EffortTargetLabels.start(.rir), "Start RIR")
        XCTAssertEqual(EffortTargetLabels.end(.rir), "End RIR")
        XCTAssertEqual(EffortTargetLabels.start(.rpe), "Start RPE")
        XCTAssertEqual(EffortTargetLabels.end(.rpe), "End RPE")
    }

    func test_effortLabelsAreNotComposedFromTheGenericKeys() {
        // If these were rebuilt from `String(localized: "Start") + metric`, the
        // English would be identical — so the assertion that matters is that
        // the *keys* differ, which the Korean suite checks. Here we pin that
        // the two ends are distinguishable and metric-specific.
        XCTAssertNotEqual(
            EffortTargetLabels.start(.rir), EffortTargetLabels.end(.rir))
        XCTAssertNotEqual(
            EffortTargetLabels.start(.rir), EffortTargetLabels.start(.rpe))
    }

    // ==================================================
    // MARK: - L5 — Cardio Plan total vs target distance
    // ==================================================

    private func evaluate(
        target: Double?, total: Double?, unit: DistanceUnit = .kilometers
    ) -> CardioPlanTargetCheck.Result {
        CardioPlanTargetCheck.evaluate(
            targetMeters: target, segmentTotalMeters: total,
            displayUnit: unit)
    }

    func test_mismatchIsReportedWithBothValues() {
        XCTAssertEqual(
            evaluate(target: 5_000, total: 3_000),
            .mismatch(total: "3 km", target: "5 km"))
    }

    func test_matchingTotalShowsNoWarning() {
        XCTAssertEqual(evaluate(target: 5_000, total: 5_000), .total("5 km"))
    }

    /// Agreement is decided on the rendered text, so a difference the user
    /// cannot see is not a mismatch.
    func test_differenceBelowDisplayPrecisionIsNotAMismatch() {
        XCTAssertEqual(
            evaluate(target: 5_000, total: 5_001), .total("5 km"),
            "one metre apart renders identically; warning would be noise")
    }

    func test_noTargetStillStatesTheTotal() {
        XCTAssertEqual(evaluate(target: nil, total: 3_000), .total("3 km"))
    }

    /// A duration-only plan has no total to state and nothing to compare.
    func test_noSegmentDistancesShowsNothing() {
        XCTAssertEqual(evaluate(target: 5_000, total: nil), .nothingToShow)
        XCTAssertEqual(evaluate(target: nil, total: nil), .nothingToShow)
        XCTAssertEqual(
            evaluate(target: 5_000, total: 0), .nothingToShow,
            "a zero total is 'no distances', not 'zero distance'")
    }

    /// Both sides render in the reader's unit, so the comparison can never
    /// contradict the two numbers beside it.
    func test_comparisonUsesTheDisplayUnitOnBothSides() {
        XCTAssertEqual(
            evaluate(target: 5_000, total: 3_000, unit: .miles),
            .mismatch(total: "1.86 mi", target: "3.11 mi"))
        XCTAssertEqual(
            evaluate(target: 5_000, total: 5_000, unit: .miles),
            .total("3.11 mi"))
    }

    func test_captionsReadAsOneLineEach() {
        XCTAssertEqual(
            CardioPlanTargetCheck.totalCaption("3 km"), "Segment total: 3 km")
        XCTAssertEqual(
            CardioPlanTargetCheck.mismatchCaption,
            "Does not match the target distance.")
    }

    // ==================================================
    // MARK: - L4 — switch confirmation names the incoming exercise
    // ==================================================

    private func impact(slot: Int, partner: Int = 0)
        -> ExerciseSwitchDeletionImpact
    {
        ExerciseSwitchDeletionImpact(
            slotLoggedSets: slot, partnerLoggedSets: partner)
    }

    func test_switchMessageNamesTheIncomingExercise() {
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.message(
                for: impact(slot: 1), incomingExerciseName: "Machine Press"),
            "Switching to Machine Press will remove 1 logged set for this exercise.")
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.message(
                for: impact(slot: 3), incomingExerciseName: "Machine Press"),
            "Switching to Machine Press will remove 3 logged sets for this exercise.")
    }

    func test_switchMessageNamesTheExerciseInTheSupersetWording() {
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.message(
                for: impact(slot: 1, partner: 0).withPartner(1),
                incomingExerciseName: "Machine Press"),
            "Switching to Machine Press will remove 2 logged sets from this block.")
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.message(
                for: impact(slot: 0, partner: 1),
                incomingExerciseName: "Machine Press"),
            "Switching to Machine Press will remove 1 logged set from this block.")
    }

    /// An unresolvable or deleted exercise falls back to the original wording
    /// rather than rendering an empty name into the sentence.
    func test_missingNameFallsBackToTheUnnamedWording() {
        for name in [nil, "", "   "] as [String?] {
            XCTAssertEqual(
                ExerciseSwitchConfirmationCopy.message(
                    for: impact(slot: 1), incomingExerciseName: name),
                "Switching exercises will remove 1 logged set for this exercise.",
                "name: \(String(describing: name))")
        }
    }

    /// The gate itself is unchanged: nothing removed, no confirmation.
    func test_noImpactStillReturnsNilWhateverTheName() {
        XCTAssertNil(
            ExerciseSwitchConfirmationCopy.message(
                for: impact(slot: 0), incomingExerciseName: "Machine Press"))
    }
}

private extension ExerciseSwitchDeletionImpact {
    func withPartner(_ n: Int) -> ExerciseSwitchDeletionImpact {
        ExerciseSwitchDeletionImpact(
            slotLoggedSets: slotLoggedSets, partnerLoggedSets: n)
    }
}
