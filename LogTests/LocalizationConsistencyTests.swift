import XCTest

@testable import Log

/// Coverage for `ux/korean-localization-consistency`: the shared display
/// formatters (`DurationDisplay`, `TechniqueSummaryCopy`), the canonical
/// technique names, and the Korean parity of the labels this slice touched.
///
/// The shape of every Korean assertion here is deliberate. Each one resolves
/// its string through **the same call the app makes** — `String(localized:)`
/// against the Korean bundle — rather than against a key spelled out by hand.
/// A format key that does not match what the compiler generates for the
/// interpolation therefore fails here, which is the only way to catch the
/// failure mode this slice exists to fix: a lookup that silently falls back to
/// English inside an otherwise-Korean screen.
final class LocalizationConsistencyTests: XCTestCase {

    // MARK: - Bundles

    private var appBundle: Bundle { Bundle(for: Exercise.self) }

    private func localizationBundle(
        _ language: String, file: StaticString = #filePath, line: UInt = #line
    ) -> Bundle? {
        guard
            let path = appBundle.path(forResource: language, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            XCTFail("Missing \(language).lproj in the app bundle", file: file, line: line)
            return nil
        }
        return bundle
    }

    private func localized(_ key: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private var koBundle: Bundle { get throws { try XCTUnwrap(localizationBundle("ko")) } }
    private let koLocale = Locale(identifier: "ko")

    // MARK: - Technique names: one canonical localized source

    /// Every technique name resolves in Korean, and only AMRAP is allowed to
    /// render identically — the same rule the previous slice established, now
    /// covering the two screens that used to hold private English switches
    /// (`TechniquePlanRow.title`, `TechniqueParamEditView.typeName`).
    func testEveryTechniqueNameIsLocalizedToKorean() throws {
        let ko = try koBundle
        var identical: Set<TechniqueType> = []
        for type in TechniqueType.allCases {
            let name = localized(type.displayName, in: ko)
            XCTAssertFalse(name.isEmpty, "\(type) localized to empty")
            if name == type.displayName { identical.insert(type) }
        }
        XCTAssertEqual(
            identical, [.amrap],
            "Only AMRAP may be identical in Korean; anything else here is an "
            + "untranslated technique name leaking into Korean UI")
    }

    /// English names are unchanged by the consolidation.
    func testTechniqueNamesEnglishUnchanged() {
        XCTAssertEqual(TechniqueType.dropset.displayName, "Drop Set")
        XCTAssertEqual(TechniqueType.partialReps.displayName, "Partial Reps")
        XCTAssertEqual(TechniqueType.restPause.displayName, "Rest-Pause")
        XCTAssertEqual(TechniqueType.amrap.displayName, "AMRAP")
        XCTAssertEqual(TechniqueType.toFailure.displayName, "To Failure")
        XCTAssertEqual(TechniqueType.cluster.displayName, "Cluster")
        XCTAssertEqual(TechniqueType.tempoOverride.displayName, "Tempo Override")
    }

    // MARK: - DurationDisplay: English output

    /// English keeps the compact unit letters.
    func testDurationDisplayEnglishOutput() {
        XCTAssertEqual(DurationDisplay.seconds(30), "30s")
        XCTAssertEqual(DurationDisplay.seconds(0), "0s")
        XCTAssertEqual(DurationDisplay.secondsRange(30, 45), "30–45s")
        XCTAssertEqual(DurationDisplay.rest(90), "90s rest")
        XCTAssertEqual(DurationDisplay.labeledDuration(45), "Duration 45s")
    }

    /// `compact` decomposes and keeps English letters at every magnitude.
    func testCompactEnglishOutput() {
        XCTAssertEqual(DurationFormat.compact(45), "45s")
        XCTAssertEqual(DurationFormat.compact(90), "1m 30s")
        XCTAssertEqual(DurationFormat.compact(300), "5m")
        XCTAssertEqual(DurationFormat.compact(3_900), "1h 5m")
        XCTAssertEqual(DurationFormat.compact(3_930), "1h 5m 30s")
        XCTAssertEqual(DurationFormat.compact(0), "0s")
        XCTAssertEqual(DurationDisplay.compact(90), "1m 30s")
    }

    /// `elapsed` replaced two byte-identical copies of this arithmetic
    /// (`WorkoutRowFormat.duration` and `HistoryView`'s detail row), so its
    /// exact output is pinned — including the zero-padded minutes and the
    /// "never 0m" floor a finished workout has always had.
    func testElapsedEnglishOutputAndEdgeCases() {
        XCTAssertEqual(DurationDisplay.elapsed(3900), "1h 05m")
        XCTAssertEqual(DurationDisplay.elapsed(7_200), "2h 00m")
        XCTAssertEqual(DurationDisplay.elapsed(300), "5m")
        XCTAssertEqual(DurationDisplay.elapsed(0), "1m", "floors at one minute")
        XCTAssertEqual(DurationDisplay.elapsed(-10), "1m", "negative floors too")
    }

    /// Negative input is floored rather than rendered.
    func testDurationDisplayFloorsNegativeInput() {
        XCTAssertEqual(DurationDisplay.seconds(-5), "0s")
        XCTAssertEqual(DurationDisplay.rest(-5), "0s rest")
        XCTAssertEqual(DurationUnitText.minutes(-5), "0m")
        XCTAssertEqual(DurationUnitText.hours(-5), "0h")
    }

    // MARK: - DurationDisplay: Korean (the revised time policy)

    /// **The policy test.** Time units are words, so Korean spells them:
    /// `30s` → `30초`, `1m 30s` → `1분 30초`, `1h 5m` → `1시간 5분`. Each
    /// string resolves through the same `String(localized:)` call the app
    /// makes, so a format key that does not match the catalog fails here.
    func testTimeUnitsAreSpelledOutInKorean() throws {
        let ko = try koBundle

        let s = String(localized: "\("30")s", bundle: ko, locale: koLocale)
        XCTAssertEqual(s, "30초")
        let m = String(localized: "\("1")m", bundle: ko, locale: koLocale)
        XCTAssertEqual(m, "1분")
        let h = String(localized: "\("1")h", bundle: ko, locale: koLocale)
        XCTAssertEqual(h, "1시간")

        // compact() joins those pieces with a space, so Korean composes to
        // "1분 30초" and "1시간 5분" without the formatter knowing any Korean.
        XCTAssertEqual([m, s].joined(separator: " "), "1분 30초")
        let fiveM = String(localized: "\("5")m", bundle: ko, locale: koLocale)
        XCTAssertEqual([h, fiveM].joined(separator: " "), "1시간 5분")
    }

    /// The range, rest and labelled forms in Korean.
    func testDurationPhrasesInKorean() throws {
        let ko = try koBundle

        let range = String(
            localized: "\("30")–\("45")s", bundle: ko, locale: koLocale)
        XCTAssertEqual(range, "30–45초")

        let rest = String(
            localized: "\("90초") rest", bundle: ko, locale: koLocale)
        XCTAssertEqual(rest, "휴식 90초")

        let labeled = String(
            localized: "Duration \("45초")", bundle: ko, locale: koLocale)
        XCTAssertEqual(labeled, "시간 45초")

        let hours = String(localized: "\("1")h", bundle: ko, locale: koLocale)
            + " "
            + String(localized: "\("05")m", bundle: ko, locale: koLocale)
        XCTAssertEqual(hours, "1시간 05분")
    }

    /// No bare `s` / `m` / `h` may survive in Korean output. Sweeps the whole
    /// API surface rather than spot-checking, because the failure this slice
    /// fixes is exactly one screen being missed.
    func testNoBareLatinTimeUnitsRemainInKorean() throws {
        let ko = try koBundle
        let samples = [
            String(localized: "\("30")s", bundle: ko, locale: koLocale),
            String(localized: "\("5")m", bundle: ko, locale: koLocale),
            String(localized: "\("2")h", bundle: ko, locale: koLocale),
            String(localized: "\("30")–\("45")s", bundle: ko, locale: koLocale),
            String(localized: "\("90초") rest", bundle: ko, locale: koLocale),
            String(localized: "Duration \("45초")", bundle: ko, locale: koLocale),
            String(
                format: ko.localizedString(
                    forKey: "activeWorkout.timer.duration", value: "", table: nil),
                "45초"),
            String(
                format: ko.localizedString(
                    forKey: "activeWorkout.timer.rest", value: "", table: nil),
                "30초"),
        ]
        for sample in samples {
            let stripped = sample.filter { !$0.isNumber && $0 != "–" && $0 != ":" && $0 != " " }
            XCTAssertFalse(
                stripped.contains("s") || stripped.contains("m")
                    || stripped.contains("h"),
                "Korean time output still carries a Latin unit letter: \(sample)")
        }
    }

    /// Tempo steppers read their seconds through the shared formatter, so a
    /// tempo phase is `3s` in English and `3초` in Korean like every other
    /// duration. (`TempoEditorView` is used by both the routine prescription
    /// and the active-workout plan sheet.)
    func testTempoSecondsUseTheSharedFormatter() throws {
        XCTAssertEqual(DurationDisplay.seconds(3), "3s")
        let ko = try koBundle
        XCTAssertEqual(
            String(localized: "\("3")s", bundle: ko, locale: koLocale), "3초")
    }

    // MARK: - TechniqueSummaryCopy: English output

    func testTechniqueSummaryCopyEnglishOutput() {
        XCTAssertEqual(TechniqueSummaryCopy.appliesToSets(indices: [1]), "set 2")
        XCTAssertEqual(
            TechniqueSummaryCopy.appliesToSets(indices: [0, 2]), "sets 1,3")
        XCTAssertNil(TechniqueSummaryCopy.appliesToSets(indices: []))
        XCTAssertEqual(
            TechniqueSummaryCopy.allSets, "all",
            "symbolic key resolves to its English value")
        XCTAssertEqual(TechniqueSummaryCopy.rounds(2), "2 rounds")
        XCTAssertEqual(TechniqueSummaryCopy.reps(5), "5 reps")
        XCTAssertEqual(TechniqueSummaryCopy.dropPercent(20), "20% drop")
        XCTAssertEqual(TechniqueSummaryCopy.repsPerDrop(3), "3 reps/drop")
        XCTAssertEqual(TechniqueSummaryCopy.bracketed("all"), "[all]")
    }

    /// AMRAP stays AMRAP in both languages, like `kg` and `bpm`.
    func testDropsetEffortKeepsAMRAPUntranslated() throws {
        XCTAssertEqual(TechniqueSummaryCopy.dropsetEffort(.amrap), "AMRAP")
        XCTAssertEqual(
            TechniqueSummaryCopy.dropsetEffort(.fixedReps(3)), "3 reps/drop")
        let ko = try koBundle
        XCTAssertEqual(localized("AMRAP", in: ko), "AMRAP")
    }

    /// Empty and nil segments contribute nothing — no stray separators.
    func testJoinSkipsEmptyAndNilSegments() {
        XCTAssertEqual(
            TechniqueSummaryCopy.join(["a", nil, "", "b"]), "a · b")
        XCTAssertEqual(TechniqueSummaryCopy.join([nil, ""]), "")
    }

    // MARK: - TechniqueSummaryCopy: Korean

    /// Every natural-language fragment a technique preview can contain
    /// resolves in Korean. These are the words that used to be English
    /// literals joined into a `String` and rendered verbatim, which is what
    /// produced "sets 1,3 · 20% drop · AMRAP" on a Korean phone.
    func testTechniqueSummaryFragmentsResolveToKorean() throws {
        let ko = try koBundle

        let oneSet = String(localized: "set \("2")", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(oneSet, "set 2")
        XCTAssertTrue(oneSet.contains("2"))

        let manySets = String(localized: "sets \("1,3")", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(manySets, "sets 1,3")
        XCTAssertTrue(manySets.contains("1,3"))

        let numbered = String(localized: "set \(2)", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(numbered, "set 2")

        XCTAssertEqual(
            localized("technique.appliesTo.all", in: ko), "전체",
            "the symbolic key carries explicit en/ko values")

        let rounds = String(localized: "\(2) rounds", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(rounds, "2 rounds")

        let reps = String(localized: "\(5) reps", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(reps, "5 reps")

        let drop = String(localized: "\(20)% drop", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(drop, "20% drop")
        XCTAssertTrue(drop.contains("20"))

        let perDrop = String(localized: "\(3) reps/drop", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(perDrop, "3 reps/drop")
    }

    // MARK: - Plan summary (SessionPlan)

    /// The plan line's first half used English literals while its second half
    /// was localized; both halves now translate.
    func testSessionPlanSummaryFragmentsResolveToKorean() throws {
        let ko = try koBundle
        let sets = String(localized: "\(3) sets", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(sets, "3 sets")
        let repRange = String(localized: "\(8)–\(12) reps", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(repRange, "8–12 reps")
    }

    /// English output of the plan summary is unchanged.
    func testSessionPlanSummaryEnglishUnchanged() {
        var plan = SessionPlan()
        plan.sets = 3
        plan.repMin = 8
        plan.repMax = 12
        plan.restSecondsBetweenSets = 90
        XCTAssertEqual(
            plan.primarySummary(distanceUnit: .kilometers), "3 sets · 8–12 reps")
        XCTAssertEqual(
            plan.secondarySummary(effortSummary: nil), "90s rest")
    }

    // MARK: - Warm-up preview

    /// The warm-up preview's reps segment shares the technique vocabulary, so
    /// "× 5 reps" is no longer a stranded English literal.
    func testWarmupRepsFragmentIsLocalized() throws {
        let ko = try koBundle
        let reps = String(localized: "\(5) reps", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(reps, "5 reps")
        XCTAssertNotEqual(localized("1 rep", in: ko), "1 rep")
        XCTAssertNotEqual(localized("Reps", in: ko), "Reps")
        XCTAssertNotEqual(localized("% of working", in: ko), "% of working")
    }

    // MARK: - History metric titles

    /// Every progression metric title resolves in Korean except the ones that
    /// are deliberately universal notation. Pinned as an explicit set so a new
    /// metric cannot ship untranslated by accident.
    func testProgressMetricTitlesAreLocalized() throws {
        let ko = try koBundle
        var identical: [String] = []
        for metric in ProgressMetric.allCases {
            let title = metric.title
            XCTAssertFalse(title.isEmpty, "\(metric) has no title")
            if localized(title, in: ko) == title { identical.append(title) }
        }
        XCTAssertEqual(
            Set(identical), ["e1RM"],
            "Only e1RM stays untranslated (an abbreviation, like kg/bpm); "
            + "everything else here is a missing Korean metric label")
    }

    func testProgressMetricTitlesEnglishUnchanged() {
        XCTAssertEqual(ProgressMetric.e1rm.title, "e1RM")
        XCTAssertEqual(ProgressMetric.bestWeight.title, "Best wt")
        XCTAssertEqual(ProgressMetric.bestReps.title, "Best reps")
    }

    /// The toolbar timer labels use symbolic keys (a collision with
    /// `Duration %@` forced it), so they are checked through the catalog
    /// directly rather than through an English key.
    func testActiveWorkoutTimerLabelsAreLocalized() throws {
        let ko = try koBundle
        XCTAssertEqual(ActiveWorkoutTimerLabel.duration(45), "Duration: 45s")
        XCTAssertEqual(ActiveWorkoutTimerLabel.rest(30), "Rest: 30s")
        XCTAssertEqual(
            ko.localizedString(
                forKey: "activeWorkout.timer.duration", value: "", table: nil),
            "시간: %@")
        XCTAssertEqual(
            ko.localizedString(
                forKey: "activeWorkout.timer.rest", value: "", table: nil),
            "휴식: %@")
    }

    // MARK: - Cardio segments

    /// Every user-facing "segment" word. The catalog already held 구간 for
    /// Segments / Add Segment / Remove Segment; what leaked English was the
    /// plan summary, which composed its count from literals and rendered the
    /// result verbatim.
    func testSegmentVocabularyIsLocalized() throws {
        let ko = try koBundle
        for key in ["Segments", "Add Segment", "Remove Segment"] {
            XCTAssertNotEqual(localized(key, in: ko), key, "No Korean: \(key)")
        }
        XCTAssertNotEqual(localized("No segments", in: ko), "No segments")

        let one = String(localized: "\(1) segment", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(one, "1 segment")
        let many = String(localized: "\(6) segments", bundle: ko, locale: koLocale)
        XCTAssertNotEqual(many, "6 segments")
        XCTAssertTrue(many.contains("6"))
    }

    /// The four segment kinds are composed into summary strings that render
    /// verbatim, so they must arrive localized.
    func testSegmentKindLabelsAreLocalized() throws {
        let ko = try koBundle
        for kind in CardioSegmentKind.allCases {
            XCTAssertFalse(kind.label.isEmpty, "\(kind) has no label")
            XCTAssertNotEqual(
                localized(kind.label, in: ko), kind.label,
                "\(kind) has no Korean, so cardio summaries render half English")
        }
    }

    func testSegmentKindLabelsEnglishUnchanged() {
        XCTAssertEqual(CardioSegmentKind.warmUp.label, "Warm-up")
        XCTAssertEqual(CardioSegmentKind.work.label, "Work")
        XCTAssertEqual(CardioSegmentKind.recovery.label, "Recovery")
        XCTAssertEqual(CardioSegmentKind.coolDown.label, "Cool-down")
    }

    // MARK: - Workout status

    /// The History row's status pill. The catalog already held 진행 중; the
    /// pill took a `String`, which renders verbatim.
    func testInProgressIsLocalized() throws {
        let ko = try koBundle
        XCTAssertEqual(localized("In Progress", in: ko), "진행 중")
    }

    // MARK: - No empty translations

    /// A catalog entry whose Korean is blank renders as nothing at all, which
    /// is worse than English. Sweeps every key this slice added.
    func testNoEmptyKoreanValuesForTouchedKeys() throws {
        let ko = try koBundle
        for key in [
            "set %@", "sets %@", "technique.appliesTo.all",
            "%lld rounds", "%lld reps",
            "%lld%% drop", "%lld reps/drop", "%llds rest", "Duration %@",
            "Best wt", "Best reps", "No segments",
        ] {
            let value = localized(key, in: ko)
            XCTAssertFalse(
                value.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(key) localizes to an empty string")
        }
    }
}
