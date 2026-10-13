import XCTest

@testable import Log

/// Build 10 low-risk UI polish, plus the density pass that followed it — the
/// pure copy rules and display decisions behind those items, so the wording is
/// pinned without a UI harness.
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
            "Exercise")
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
            "Exercise")
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
            "Switching to Machine Press will remove 2 logged sets from this superset.")
        XCTAssertEqual(
            ExerciseSwitchConfirmationCopy.message(
                for: impact(slot: 0, partner: 1),
                incomingExerciseName: "Machine Press"),
            "Switching to Machine Press will remove 1 logged set from this superset.")
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

    // ==================================================
    // MARK: - Density pass — block detail member headers
    // ==================================================

    /// The reported repetition: `BlockDetailTitle` already titles the screen
    /// "Bench Press", so a section header saying it again printed the name
    /// twice within one screen height.
    func test_singleExerciseBlockDropsTheDuplicateMemberHeader() {
        XCTAssertFalse(
            BlockDetailMemberHeader.showsMemberHeaders(
                exerciseNames: ["Bench Press"], isSuperset: false))
    }

    /// …and the title it would have duplicated is the same string, computed
    /// from the same input. Pinning both together is what stops one of the two
    /// rules being changed alone.
    func test_theDroppedHeaderIsExactlyTheNavigationTitle() {
        let names = ["Bench Press"]
        XCTAssertEqual(
            BlockDetailTitle.title(exerciseNames: names, isSuperset: false),
            "Bench Press")
        XCTAssertFalse(
            BlockDetailMemberHeader.showsMemberHeaders(
                exerciseNames: names, isSuperset: false))
    }

    /// A superset always keeps its headers: there the name separates one
    /// member's sets and prescription from the next, and the title is a `+`
    /// join rather than any one member's name.
    func test_supersetKeepsItsMemberHeaders() {
        for names in [
            ["Bench Press", "Row"],
            ["Bench Press", "Bench Press"],
            ["Bench Press"],
            [],
        ] {
            XCTAssertTrue(
                BlockDetailMemberHeader.showsMemberHeaders(
                    exerciseNames: names, isSuperset: true),
                "names: \(names)")
        }
    }

    /// A non-superset block holding more than one named exercise keeps them
    /// too — the title joins both, so neither header is a repeat of it.
    func test_multiExerciseNormalBlockKeepsItsHeaders() {
        XCTAssertTrue(
            BlockDetailMemberHeader.showsMemberHeaders(
                exerciseNames: ["Bench Press", "Row"], isSuperset: false))
    }

    /// An all-deleted block fell back to the kind word ("Exercise") for its
    /// title, so a header would not be duplicating anything.
    func test_blockWithNoNamedExercisesKeepsHeaders() {
        XCTAssertTrue(
            BlockDetailMemberHeader.showsMemberHeaders(
                exerciseNames: [], isSuperset: false))
    }

    /// Blank and whitespace-only names are not names — the same filter
    /// `BlockDetailTitle` applies, so the two cannot disagree about whether
    /// this block has exactly one.
    func test_blankNamesAreNotCountedAsNames() {
        // One real name beside blanks: still "exactly one", still dropped.
        XCTAssertFalse(
            BlockDetailMemberHeader.showsMemberHeaders(
                exerciseNames: ["Bench Press", "", "   "], isSuperset: false))
        // Only blanks: nothing to duplicate, so headers stay.
        XCTAssertTrue(
            BlockDetailMemberHeader.showsMemberHeaders(
                exerciseNames: ["", "   "], isSuperset: false))
    }

    // ==================================================
    // MARK: - Density pass — superset info-button copy
    // ==================================================

    /// All three explanations are still present after moving off their
    /// footers. `all` is what the view iterates conceptually, so a dropped one
    /// fails here rather than silently vanishing from the screen.
    func test_allThreeSupersetExplanationsAreStillAvailable() {
        XCTAssertEqual(SupersetHelp.all.count, 3)
        for (title, message) in SupersetHelp.all {
            XCTAssertFalse(title.isEmpty)
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// Each message is the **verbatim string its footer used**, which is what
    /// lets it resolve to the catalog key it already had and keep its Korean.
    /// Retyping any of these without adding the new key is a silent fallback
    /// to English; this test is the tripwire.
    func test_supersetMessagesAreTheExactRetiredFooterStrings() {
        XCTAssertEqual(
            SupersetHelp.timingMessage,
            "A round runs one set of each exercise that still has sets remaining; shorter exercises drop out of the later rounds. Rest after round fires between completed rounds. Rest before next exercise fires after the final round, replacing round rest.")
        XCTAssertEqual(
            SupersetHelp.bulkSetsMessage,
            "Optional shortcut. Choose a count, then tap Apply to set every exercise in this superset to that many sets at once. Adjusting the stepper alone changes nothing — each exercise still keeps its own set count (edit it in that exercise's section below), so they can differ.")
        XCTAssertEqual(
            SupersetHelp.membershipMessage,
            "A superset must keep at least 2 exercises. The same exercise can appear more than once — each one logs independently.")
    }

    /// The titles are the section headers the glyphs sit in, so the alert is
    /// named after the thing the user tapped beside.
    func test_supersetInfoTitlesMatchTheirSectionHeaders() {
        XCTAssertEqual(SupersetHelp.timingTitle, "Timing")
        XCTAssertEqual(SupersetHelp.bulkSetsTitle, "Set All Exercises")
        XCTAssertEqual(SupersetHelp.membershipTitle, "Exercises")
    }

    /// The live constraint deliberately did **not** move behind a glyph: it is
    /// fired at the moment the floor is hit, not a description of the screen.
    /// It must therefore not be one of the three.
    func test_theMinimumExerciseAlertIsNotAnInfoButton() {
        let alert = "A superset must keep at least 2 exercises. To remove this superset entirely, delete it from the routine's exercise list."
        XCTAssertFalse(SupersetHelp.all.contains { $0.message == alert })
    }

    // ==================================================
    // MARK: - Density pass — cardio checklist info copy
    // ==================================================

    /// The copy says what the checkmarks are **for** — the first question a
    /// user asks about a control that looks like logging.
    func test_cardioChecklistInfoExplainsTheProgressPurpose() {
        let message = CardioChecklistHelp.message
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("checkmarks"), message)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("track your place"),
            message)
        // Titled with the section header the glyph sits in.
        XCTAssertEqual(CardioChecklistHelp.title, "Cardio Plan")
    }

    /// And it separates the two things that look alike: the plan History shows
    /// under the same `Cardio Plan` header, and the actual logged result.
    func test_cardioChecklistInfoDistinguishesPlanFromResult() {
        let message = CardioChecklistHelp.message
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("History"), message)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("cardio result"), message)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("duration and details"),
            message)
    }

    /// The claim that was reported as wrong, and the family of claims around
    /// it, must not come back.
    ///
    /// The first version said the ticks "are not saved as results and are
    /// cleared when the workout ends". Both halves are true of the code, and
    /// the message still read as false to a user who finishes a cardio workout
    /// and finds their Cardio Plan in History — that is
    /// `HistoryView.plannedCardioRows` rendering the frozen *plan* under the
    /// same header and layout as this checklist. The copy now answers "which of
    /// these is my result?" and makes no storage claim in either direction, so
    /// it stays true whichever way tick progress is surfaced later.
    func test_cardioChecklistInfoMakesNoStorageClaim() {
        let message = CardioChecklistHelp.message
        for banned in [
            "not saved",
            "cleared when the workout ends",
            "disappear",
            "only marks your place in this workout",
            "checklist only",
        ] {
            XCTAssertFalse(
                message.localizedCaseInsensitiveContains(banned),
                "info copy re-introduced the inaccurate claim '\(banned)': "
                    + message)
        }
    }

    /// Neither retired string is the current copy — the four-word footer this
    /// replaced, nor the first info message that replaced *it*.
    func test_cardioChecklistInfoIsNeitherRetiredWording() {
        XCTAssertNotEqual(
            CardioChecklistHelp.message,
            "Checklist only — not saved as results.")
        XCTAssertNotEqual(
            CardioChecklistHelp.message,
            "Ticking segments only marks your place in this workout. The ticks are not saved as results and are cleared when the workout ends — your cardio is still logged once, from the duration and details below.")
    }

    // ==================================================
    // MARK: - Active-workout progress label
    // ==================================================

    /// The noun follows the block's own kind. "Exercise 3 of 5" on a superset
    /// was the inaccuracy this replaced: the line directly beneath it shows
    /// two names joined by "+".
    func test_progressLabelNamesTheBlockKind() {
        XCTAssertEqual(
            BlockProgressLabel.text(position: 3, total: 5, isSuperset: false),
            "Exercise 3 of 5")
        XCTAssertEqual(
            BlockProgressLabel.text(position: 3, total: 5, isSuperset: true),
            "Superset 3 of 5")
    }

    /// The denominator is the routine's total block count in both cases — it
    /// is a position among all items, never a count of supersets. Changing the
    /// noun must not change what the 5 means.
    func test_progressLabelDenominatorIsTheSameForBothKinds() {
        for position in 1...4 {
            let single = BlockProgressLabel.text(
                position: position, total: 4, isSuperset: false)
            let superset = BlockProgressLabel.text(
                position: position, total: 4, isSuperset: true)
            XCTAssertTrue(
                single.hasSuffix("\(position) of 4"),
                "single-exercise label lost the position/total pair: \(single)")
            XCTAssertTrue(
                superset.hasSuffix("\(position) of 4"),
                "superset label lost the position/total pair: \(superset)")
        }
    }

    /// The kind comes from the block's flag, never from how many exercises it
    /// currently holds — a superset reduced to one member is still a superset.
    func test_progressLabelReadsTheFlagNotTheMemberCount() {
        XCTAssertEqual(
            BlockProgressLabel.text(position: 1, total: 1, isSuperset: true),
            "Superset 1 of 1")
    }

    // ==================================================
    // MARK: - Superset member removal confirmation
    // ==================================================

    func test_supersetRemovalNamesTheSingleMember() {
        XCTAssertEqual(
            SupersetMemberRemovalCopy.message(
                removalCount: 1, firstName: "Incline DB Press"),
            "\u{201C}Incline DB Press\u{201D} will be removed from this superset. "
                + "Its prescription, warmup, and technique plans will be deleted.")
    }

    /// A single member whose exercise has been deleted has no name to show.
    /// It used to fall through to the batch sentence and render
    /// "1 exercises will be removed"; it now takes a singular of its own.
    func test_supersetRemovalOfOneUnnamedMemberReadsSingular() {
        let message = SupersetMemberRemovalCopy.message(
            removalCount: 1, firstName: nil)
        XCTAssertEqual(
            message,
            "1 exercise will be removed from this superset. "
                + "Its prescription, warmup, and technique plans will be deleted.")
        XCTAssertFalse(message.contains("1 exercises"))
    }

    /// A blank or whitespace-only name is not a name — same singular.
    func test_supersetRemovalTreatsABlankNameAsUnnamed() {
        XCTAssertEqual(
            SupersetMemberRemovalCopy.message(
                removalCount: 1, firstName: "   "),
            SupersetMemberRemovalCopy.message(
                removalCount: 1, firstName: nil))
    }

    func test_supersetRemovalOfSeveralMembersReadsPlural() {
        XCTAssertEqual(
            SupersetMemberRemovalCopy.message(
                removalCount: 3, firstName: nil),
            "3 exercises will be removed from this superset. "
                + "Their prescriptions, warmups, and technique plans will be "
                + "deleted.")
    }

    // ==================================================
    // MARK: - Exercise delete confirmation — English plurals
    // ==================================================

    /// Each of the three counts pluralizes on its own. The sentence is
    /// assembled from localized noun phrases now, so this pins that the
    /// English still reads exactly as it did when a runtime "s" built it.
    func test_deleteConfirmationSingularsAndPlurals() {
        let singular = ExerciseDeletionImpact(
            routineCount: 1, supersetBlockCount: 1,
            normalReferenceCount: 1, alternativeCount: 0)
        XCTAssertEqual(
            singular.message(exerciseName: "Bench Press"),
            "Delete \u{201C}Bench Press\u{201D}? This will remove it from 1 routine, "
                + "delete 1 superset, and unlink 1 exercise reference. "
                + "This cannot be undone.")

        let plural = ExerciseDeletionImpact(
            routineCount: 3, supersetBlockCount: 2,
            normalReferenceCount: 4, alternativeCount: 0)
        XCTAssertEqual(
            plural.message(exerciseName: "Bench Press"),
            "Delete \u{201C}Bench Press\u{201D}? This will remove it from 3 routines, "
                + "delete 2 supersets, and unlink 4 exercise references. "
                + "This cannot be undone.")
    }

    /// Zero is plural in English, which is the case the old runtime suffix
    /// happened to get right and a naive `count > 1` check would break.
    func test_deleteConfirmationTreatsZeroAsPlural() {
        let impact = ExerciseDeletionImpact(
            routineCount: 1, supersetBlockCount: 0,
            normalReferenceCount: 1, alternativeCount: 0)
        XCTAssertTrue(
            impact.message(exerciseName: "Bench Press")
                .contains("delete 0 supersets,"),
            impact.message(exerciseName: "Bench Press"))
    }

    /// The alternatives sentence still appends to the direct-usage head — the
    /// localization change must not drop the second paragraph.
    func test_deleteConfirmationStillAppendsTheAlternativesSentence() {
        let impact = ExerciseDeletionImpact(
            routineCount: 2, supersetBlockCount: 1,
            normalReferenceCount: 1, alternativeCount: 2)
        let message = impact.message(exerciseName: "Fly")
        XCTAssertTrue(message.contains("2 routines"))
        XCTAssertTrue(
            message.hasSuffix(
                "It is also used as 2 prepared alternatives, which will be "
                    + "removed."))
    }
}

private extension ExerciseSwitchDeletionImpact {
    func withPartner(_ n: Int) -> ExerciseSwitchDeletionImpact {
        ExerciseSwitchDeletionImpact(
            slotLoggedSets: slotLoggedSets, partnerLoggedSets: n)
    }
}
