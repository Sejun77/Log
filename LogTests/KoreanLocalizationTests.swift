import XCTest

@testable import Log

/// Verifies the Korean localization cleanup for the next TestFlight build:
///
///  1. Seeded/default exercise **body parts** (persisted as English canonical
///     strings like "Chest") localize to Korean at display time via the string
///     catalog — the same path Exercise Detail and the grouped section headers
///     use, and now the Exercises list row too.
///  2. English display is unchanged (the catalog lookup falls back to the
///     English key, exactly as `LocalizedStringKey` does at render time).
///  3. The two Settings footer descriptions that previously bound `Text`'s
///     non-localizing verbatim initializer (via `"a" + "b"` concatenation) now
///     exist in the catalog with Korean translations.
///
/// These assert against the *compiled* per-language `.strings` in the app
/// bundle (LogTests is app-hosted), so they exercise the real localization
/// resources rather than re-reading the source `.xcstrings`.
final class KoreanLocalizationTests: XCTestCase {

    // MARK: - Bundle helpers

    /// The host `Log.app` bundle. `Exercise` is a concrete `@Model` class in the
    /// app module, so `Bundle(for:)` resolves the app bundle under test.
    private var appBundle: Bundle { Bundle(for: Exercise.self) }

    private func localizationBundle(
        _ language: String,
        file: StaticString = #filePath,
        line: UInt = #line
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

    /// Localized lookup with the key itself as the fallback value — this mirrors
    /// `LocalizedStringKey`'s render-time behavior, where a missing key renders
    /// its literal text. (Xcode omits identity entries from the source-language
    /// `.strings`, so `value: key` is required for the English assertions.)
    private func localized(_ key: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    // MARK: - Fixtures

    /// Exact keys produced by the two `SettingsView` footers (must stay in sync
    /// with the `+`-concatenated literals wrapped in `LocalizedStringKey`).
    private static let bodyweightFooterKey =
        "Used for bodyweight-inclusive exercises (e.g. pull-ups, dips) "
        + "in History load metrics. Leave empty if not set. Stored in the "
        + "unit shown above."

    private static let dataFooterKey =
        "Import a CSV of exercises (name,bodyPart,equipmentType,setupDefaults,"
        + "isTimeBased,notes). New names are added as custom exercises; existing "
        + "names are skipped. Import a routine JSON to add it as a new routine "
        + "(existing routines are never overwritten; missing exercises are created "
        + "as custom). Nothing is overwritten or deleted. Export saves your "
        + "exercise library or workout history as CSV."

    // MARK: - Body part: Korean localization for seeded/default exercises

    /// A spot-check of specific canonical → Korean mappings so a broken or
    /// dropped translation is caught with a readable failure.
    func testKnownBodyPartsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let expected: [String: String] = [
            "Chest": "가슴",
            "Back": "등",
            "Cardio": "유산소",
            "Full Body": "전신",
        ]
        for (english, korean) in expected {
            XCTAssertEqual(
                localized(english, in: ko), korean,
                "Body part \(english) should localize to \(korean) in Korean"
            )
        }
    }

    /// Every canonical body part offered in the picker must have a non-identity
    /// Korean translation, so seeded/default exercises never surface English
    /// body parts when the phone language is Korean.
    func testAllCanonicalBodyPartsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for bp in ExerciseDetailView.canonicalBodyParts {
            let value = localized(bp, in: ko)
            XCTAssertFalse(
                value.isEmpty, "\(bp) localized to empty string"
            )
            XCTAssertNotEqual(
                value, bp,
                "Canonical body part \(bp) has no Korean translation "
                + "(still renders English)"
            )
        }
    }

    /// The seed catalogue itself must only use body parts that are canonical and
    /// Korean-localized — this ties the shipped default data to the localization
    /// coverage above, so a future seed addition with an unlocalized body part
    /// fails here instead of shipping English text to Korean users.
    func testSeededExerciseBodyPartsAreCanonicalAndLocalized() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let canonical = Set(ExerciseDetailView.canonicalBodyParts)
        for seed in ExerciseCatalog.v1 {
            guard let bp = seed.bodyPart else { continue }
            XCTAssertTrue(
                canonical.contains(bp),
                "Seed \(seed.name) uses non-canonical body part \(bp)"
            )
            XCTAssertNotEqual(
                localized(bp, in: ko), bp,
                "Seed body part \(bp) has no Korean translation"
            )
        }
    }

    // MARK: - Body part: English unchanged

    /// In English, every canonical body part renders its own literal text —
    /// unchanged by the Korean work, and distinct from the Korean value.
    func testBodyPartEnglishDisplayUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for bp in ExerciseDetailView.canonicalBodyParts {
            XCTAssertEqual(
                localized(bp, in: en), bp,
                "English body part \(bp) should render its literal text"
            )
            XCTAssertNotEqual(
                localized(bp, in: ko), localized(bp, in: en),
                "\(bp) should differ between Korean and English"
            )
        }
    }

    // MARK: - Settings footer descriptions

    func testSettingsFooterDescriptionsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in [Self.bodyweightFooterKey, Self.dataFooterKey] {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty)
            XCTAssertNotEqual(
                value, key,
                "Settings footer still renders English in Korean: \(key.prefix(40))…"
            )
        }
    }

    func testSettingsFooterDescriptionsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        // Source-language entries render their literal English text.
        XCTAssertEqual(localized(Self.bodyweightFooterKey, in: en), Self.bodyweightFooterKey)
        XCTAssertEqual(localized(Self.dataFooterKey, in: en), Self.dataFooterKey)
    }

    // MARK: - Active-workout setup notes editing

    /// Exact keys introduced by the in-workout setup-notes editing flow
    /// (`SetupNotesEditSheet` + the Equipment & Setup section's edit row).
    /// (The sheet's section header reuses the pre-existing "Setup" key — a
    /// dedicated "Setup Notes" key would collide with "Setup & Notes" in
    /// generated string symbols.)
    private static let setupNotesEditingKeys = [
        "Edit Setup Notes",
        "No setup notes yet.",
        "Setup notes are saved to the exercise and reused across routines and workouts.",
    ]

    /// Every user-facing string of the setup-notes editing flow must have a
    /// non-identity Korean translation, so Korean-family testers never see
    /// English text in the new active-workout affordance.
    func testSetupNotesEditingStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.setupNotesEditingKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Setup-notes editing string has no Korean translation "
                + "(still renders English): \(key)"
            )
        }
    }

    func testSetupNotesEditingStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.setupNotesEditingKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    // MARK: - Exercise Detail cardio toggle (Cardio Slice 2)

    /// Exact keys introduced by the Exercise Detail **Cardio** toggle. "Cardio"
    /// itself is shared with the canonical body part (already asserted above),
    /// and is included here so a future rename of either use site fails loudly.
    private static let cardioToggleKeys = [
        "Cardio",
        "Use for running, cycling, rowing, walking, or machine cardio.",
    ]

    func testCardioToggleStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.cardioToggleKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Cardio toggle string has no Korean translation "
                + "(still renders English): \(key)"
            )
        }
    }

    func testCardioToggleStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.cardioToggleKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    // MARK: - Active-workout cardio Details section (Cardio Slice 4)

    /// Every label in the active-workout cardio Details disclosure. Unit
    /// symbols (`km`, `mi`, `bpm`, `kcal`, `%`, `Z3`) are deliberately absent —
    /// they render identically in every language the app ships, matching how
    /// `kg` / `lb` / `s` are already handled.
    private static let cardioDetailsKeys = [
        "Details",
        "Distance",
        "Unit",
        "Average Heart Rate",
        "Heart-Rate Zone",
        "Calories",
        "Incline / Decline",
        "Resistance",
        "Pace",
        "Speed",
        "None",
    ]

    /// Strings introduced by the Slice 4 polish patches.
    ///
    /// The pace labels name their unit ("Pace (min/km)") because "/km" on the
    /// value alone did not explain itself; the unit inside the parentheses is
    /// language-neutral, like `kg` / `lb` / `s`, so only the word around it is
    /// translated. The two set labels are the History row vocabulary — "Drop
    /// Set" is deliberately absent because it reuses the key the active-workout
    /// row already ships (asserted separately below).
    private static let cardioPolishKeys = [
        "Pace (min/km)",
        "Pace (min/mi)",
        "Working Set",
        "Warm-up Set",
        // Pre-archive polish — the History label for the single aggregate
        // cardio entry. Not a `SetKind`: the row stores `.working` and is
        // renamed at render, so it needs its own key.
        "Cardio Set",
        // Slice 5 — the routine editor's cardio distance target. The unit
        // shown beside it is language-neutral, like every other unit symbol.
        "Target distance",
        // Slice 8 — the Settings control, which is now the only distance-unit
        // control in the app. Its "km" / "mi" segments stay untranslated,
        // matching kg / lb / s. The footer that once explained the old
        // "applies to new entries" rule is gone with the rule itself.
        "Distance unit",
    ]

    func testCardioPolishStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.cardioPolishKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Slice 4 polish string has no Korean translation "
                + "(still renders English): \(key)"
            )
        }
    }

    func testCardioPolishStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.cardioPolishKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    /// Every History row label, in Korean. `SetKind.historyRowLabel` is the one
    /// place these are produced, so its keys and the catalog must agree.
    func testHistorySetLabelsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let expected: [SetKind: (String, String)] = [
            .working: ("Working Set", "메인 세트"),
            .warmup: ("Warm-up Set", "워밍업 세트"),
            .dropset: ("Drop Set", "드롭 세트"),
        ]
        for kind in SetKind.allCases {
            let (key, korean) = try XCTUnwrap(expected[kind])
            XCTAssertEqual(kind.historyRowLabel, key)
            XCTAssertEqual(localized(key, in: ko), korean)
        }

        // The cardio aggregate row is renamed at render, not stored, so it has
        // no `SetKind` to loop over — but it is the same row vocabulary and
        // must be translated alongside the rest.
        XCTAssertEqual(localized("Cardio Set", in: ko), "유산소 세트")
    }

    func testCardioDetailsStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.cardioDetailsKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Cardio Details string has no Korean translation "
                + "(still renders English): \(key)"
            )
        }
    }

    func testCardioDetailsStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.cardioDetailsKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    // MARK: - Assisted cardio migration prompt (Cardio Slice 10)

    /// Every string in the one-time "Update Cardio Exercises" alert. It is the
    /// first thing an upgrading Korean tester sees, and it asks them to approve
    /// a change to their own data — mixed-language copy there is worse than
    /// anywhere else in the app.
    private static let cardioMigrationPromptKeys = [
        "Update Cardio Exercises",
        "Log now supports dedicated cardio tracking. Older exercises in the "
            + "Cardio category can be updated to use distance, pace, heart "
            + "rate, calories, incline, and resistance fields.",
        "Mark as Cardio",
        "Not Now",
    ]

    func testCardioMigrationPromptStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.cardioMigrationPromptKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Cardio migration prompt string has no Korean translation "
                + "(still renders English): \(key)"
            )
        }
    }

    func testCardioMigrationPromptStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.cardioMigrationPromptKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    // MARK: - History cardio charts (Cardio Slice 11)

    /// Strings introduced by the cardio progression charts. The metric titles
    /// "Distance", "Pace", and "Calories" are shared with the active-workout
    /// Details section (asserted above) and are deliberately not repeated here;
    /// what is new is the abbreviated heart-rate title and the four empty
    /// states, which name the specific field that is missing.
    private static let cardioChartKeys = [
        "Avg HR",
        "No distance logged for this exercise yet.",
        "No pace yet — a session needs both a distance and a duration.",
        "No calories logged for this exercise yet.",
        "No heart rate logged for this exercise yet.",
    ]

    func testCardioChartStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.cardioChartKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Cardio chart string has no Korean translation "
                + "(still renders English): \(key)"
            )
        }
    }

    func testCardioChartStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.cardioChartKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    // MARK: - Structured cardio editor (Slice 12C)

    /// Every string the routine editor's Structured Cardio screen introduces.
    /// The four segment-type names are the ones that matter most: they are the
    /// vocabulary of the feature, and they render inside an otherwise Korean
    /// routine editor.
    private static let structuredCardioKeys = [
        "Structured Cardio",
        "Segments",
        "Add Segment",
        "Add warm-up, work, recovery, or cool-down segments.",
        "Remove Segment",
        "Every field is optional. Fill in at least one.",
        "This plan is full.",
        "Warm-up",
        "Work",
        "Recovery",
        "Cool-down",
    ]

    func testStructuredCardioStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.structuredCardioKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Structured cardio string has no Korean translation "
                + "(still renders English): \(key)"
            )
        }
    }

    func testStructuredCardioStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.structuredCardioKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    /// `CardioSegmentKind.label` is the single source of the four type names —
    /// the editor renders it through `LocalizedStringKey`, so every case must
    /// have a catalog entry or a Korean user sees an English row.
    func testEverySegmentKindLabelLocalizes() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        XCTAssertEqual(CardioSegmentKind.allCases.count, 4)
        for kind in CardioSegmentKind.allCases {
            XCTAssertNotEqual(
                localized(kind.label, in: ko), kind.label,
                "Segment kind \(kind.rawValue) has no Korean translation")
        }
    }

    /// Every metric title in the History picker is rendered through
    /// `LocalizedStringKey`, so each one either has a translation or falls back
    /// to its English literal. This pins the cardio titles specifically: they
    /// are the ones a Korean tester meets in a menu of otherwise Korean text.
    func testCardioMetricTitlesLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let cardioTitles = ProgressMetric.allCases
            .filter(\.isCardioOnly)
            .map(\.title)

        XCTAssertEqual(cardioTitles.count, 4)
        for title in cardioTitles {
            XCTAssertNotEqual(
                localized(title, in: ko), title,
                "Cardio metric title \(title) has no Korean translation"
            )
        }
    }

    // MARK: - Destructive exercise-switch confirmation

    /// Exact keys produced by `ExerciseSwitchConfirmationCopy`. A Korean tester
    /// meets these at the moment logged sets are about to be destroyed, so an
    /// untranslated string here is the worst place for one.
    private static let switchConfirmationKeys = [
        "Switch exercise?",
        "Switch and Remove Sets",
        "Switching exercises will remove 1 logged set for this exercise.",
        "Switching exercises will remove %lld logged sets for this exercise.",
        "Switching exercises will remove 1 logged set from this block.",
        "Switching exercises will remove %lld logged sets from this block.",
    ]

    func testSwitchConfirmationStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.switchConfirmationKeys {
            XCTAssertNotEqual(
                localized(key, in: ko), key,
                "Switch confirmation string has no Korean translation: \(key)"
            )
        }
    }

    func testSwitchConfirmationStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.switchConfirmationKeys {
            XCTAssertEqual(localized(key, in: en), key)
        }
    }

    /// The plural forms must keep their `%lld` placeholder in Korean, or the
    /// count renders as literal text.
    func testKoreanSwitchConfirmationKeepsCountPlaceholder() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.switchConfirmationKeys where key.contains("%lld") {
            XCTAssertTrue(
                localized(key, in: ko).contains("%lld"),
                "Korean translation dropped the count placeholder: \(key)"
            )
        }
    }

    // MARK: - Alternative Exercises (Phase D)

    /// Every string the routine editor's Alternative Exercises screens
    /// introduce. The three tools an alternative can carry (`Warmup`,
    /// `Techniques`, `Structured Cardio`) are deliberately **not** here: the
    /// summary reuses those existing keys rather than inventing a second name
    /// for each, and they are already covered above.
    private static let alternativeExerciseKeys = [
        "Alternative Exercises",
        "Add Alternative",
        "No alternatives added",
        "Alternatives appear when you switch this exercise during a workout.",
        "Off",
        "Enabled",
        "This is already the slot's exercise.",
    ]

    func testAlternativeExerciseStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.alternativeExerciseKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Alternative Exercises string has no Korean translation "
                + "(still renders English): \(key)"
            )
        }
    }

    func testAlternativeExerciseStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.alternativeExerciseKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    /// Every string the active workout's Prepared Alternatives sheet
    /// introduces. A Korean user meets these mid-set, one tap from switching an
    /// exercise, so an untranslated string here is expensive.
    private static let preparedAlternativeKeys = [
        "Prepared Alternatives",
        "Other Options",
        "Choose another exercise…",
        "Exercise unavailable",
    ]

    func testPreparedAlternativeStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.preparedAlternativeKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Prepared Alternatives string has no Korean translation "
                + "(still renders English): \(key)"
            )
        }
    }

    func testPreparedAlternativeStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.preparedAlternativeKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    /// The switch flow's other two screens are already localized: the sheet
    /// hands off to the existing picker and the existing destructive
    /// confirmation, so a Korean switch is Korean end to end.
    func testSwitchFlowHandoffStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in ["Pick Exercise", "Cancel", "Switch and Remove Sets"] {
            XCTAssertNotEqual(
                localized(key, in: ko), key,
                "Switch flow string has no Korean translation: \(key)")
        }
    }

    /// The summary's presence flags reuse the prescription editor's own row
    /// titles, so an alternative's subtitle is Korean end to end.
    func testAlternativeSummaryFlagLabelsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in ["Warmup", "Techniques", "Structured Cardio", "None"] {
            XCTAssertNotEqual(
                localized(key, in: ko), key,
                "Alternative summary flag has no Korean translation: \(key)"
            )
        }
    }

    // MARK: - Effort targets (RIR/RPE modes)

    /// Every string the final effort-target system introduces, plus the four
    /// it **reuses** rather than inventing new names for (`None`,
    /// `Progression`, `Start`, `End`, `Set %lld`, `Effort`). A Korean lifter
    /// meets these while programming a routine, so an untranslated row here
    /// means an English word in the middle of a Korean form.
    private static let effortTargetKeys = [
        "Effort",
        "None",
        "Same Target",
        "Progression",
        "Custom Per Set",
        "Start",
        "End",
        "Set %lld",
        "Set targets: %@",
        "Add at least one set to enter per-set targets.",
        // Build 10 C6 — the two in-session read-only messages, reworded from
        // "not available yet" (a roadmap claim about settled behavior) to the
        // rule they actually state. Same two screens, same two strings' jobs;
        // `testTheNotAvailableYetCopyIsGone` pins that the old keys are gone.
        "Progression targets are fixed for this session.",
        "Per-set targets are fixed for this session.",
    ]

    func testEffortTargetStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.effortTargetKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Effort target string has no Korean translation "
                + "(still renders English): \(key)"
            )
        }
    }

    func testEffortTargetStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.effortTargetKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    /// The per-set row label carries the set number; a translation that dropped
    /// the placeholder would render every row as the same untitled stepper.
    func testKoreanPerSetRowLabelKeepsTheNumberPlaceholder() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        XCTAssertTrue(localized("Set %lld", in: ko).contains("%lld"))
        XCTAssertTrue(localized("Set targets: %@", in: ko).contains("%@"))
    }

    /// The Settings → Help → User Guide path itself, plus the info-button
    /// label that sits beside it in the design system.
    ///
    /// These went untranslated while the guide *content* was fully localized,
    /// which is the worst version of the bug: a Korean tester is told to open
    /// 설정 → 도움말 → 사용자 가이드 and finds two English rows on the way to a
    /// Korean document.
    private static let guideAndHelpKeys = [
        "Help",
        "User Guide",
        "More information",
    ]

    func testGuideAndHelpStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.guideAndHelpKeys {
            XCTAssertNotEqual(
                localized(key, in: ko), key,
                "Guide/help string has no Korean translation: \(key)"
            )
        }
    }

    func testGuideAndHelpStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.guideAndHelpKeys {
            XCTAssertEqual(localized(key, in: en), key)
        }
    }

    // MARK: - Alternative Exercises usage & deletion (Build 10 C1)

    /// The strings that make an exercise's alternative usage visible: the
    /// Exercise Detail summary line, the per-routine row suffix, and the delete
    /// confirmation's warning about prepared work.
    ///
    /// The last two matter most for a Korean tester. Before this slice the
    /// screen told them an exercise several routines relied on was "0개 루틴에서
    /// 사용", and the delete dialog said nothing at all about the prepared
    /// alternatives it was about to remove — a destructive action explained in
    /// neither language.
    private static let alternativeUsageKeys = [
        "%lld alternative",
        "%lld alternatives",
        "%lld slots",
        "Used as %lld alternative",
        "Used as %lld alternatives",
        "It is also used as %lld prepared alternative, which will be removed.",
        "It is also used as %lld prepared alternatives, which will be removed.",
        // Reused, not new — the head of the alternative-only delete message.
        "Delete \u{201C}%@\u{201D}? This cannot be undone.",
    ]

    func testAlternativeUsageStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.alternativeUsageKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Alternative usage string has no Korean translation "
                    + "(still renders English): \(key)"
            )
        }
    }

    func testAlternativeUsageStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.alternativeUsageKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)"
            )
        }
    }

    /// Every one of these carries a count or a name. A translation that dropped
    /// the placeholder would render "대체 운동 %lld개" as literal text, or — on the
    /// delete confirmation — drop the exercise name from a destructive prompt.
    func testKoreanAlternativeUsageStringsKeepTheirPlaceholders() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.alternativeUsageKeys {
            let value = localized(key, in: ko)
            if key.contains("%lld") {
                XCTAssertTrue(
                    value.contains("%lld"),
                    "Korean translation dropped the count placeholder: \(key)"
                )
            }
            if key.contains("%@") {
                XCTAssertTrue(
                    value.contains("%@"),
                    "Korean translation dropped the name placeholder: \(key)"
                )
            }
        }
    }

    // MARK: - History planned effort (Build 10 H5a)

    /// The one new label History gains. It must read as **planned**, not
    /// achieved: no logged RIR/RPE exists anywhere in the app, so wording that
    /// implied a measured result would be claiming something the app never
    /// observed.
    func testPlannedEffortLabelLocalizesToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let en = try XCTUnwrap(localizationBundle("en"))

        XCTAssertEqual(localized("Planned effort", in: ko), "계획 강도")
        XCTAssertEqual(localized("Planned effort", in: en), "Planned effort")
    }

    /// Neither language may call it an achieved or logged result.
    func testPlannedEffortLabelDoesNotImplyALoggedResult() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let korean = localized("Planned effort", in: ko)

        XCTAssertTrue(
            korean.contains("계획"),
            "the Korean label must say this is planned: \(korean)")
        for claimed in ["실제", "달성", "기록한"] {
            XCTAssertFalse(
                korean.contains(claimed),
                "the label must not imply a logged result: \(korean)")
        }
    }

    // MARK: - Effort target clarity (Build 10 C6)

    /// Every string this slice adds. Named through `EffortTargetHelp` rather
    /// than re-typed, so the view and the test cannot drift onto two different
    /// keys.
    private static var effortClarityKeys: [String] {
        [
            EffortTargetHelp.modesTitle,
            EffortTargetHelp.modesMessage,
            EffortTargetHelp.savedWhileAutoregOff,
            "Progression targets are fixed for this session.",
            "Per-set targets are fixed for this session.",
        ]
    }

    func testEffortClarityStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.effortClarityKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Effort clarity string has no Korean translation "
                    + "(still renders English): \(key)")
        }
    }

    func testEffortClarityStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.effortClarityKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)")
        }
    }

    /// The info alert must name all four modes the picker offers, in both
    /// languages, using the picker's own translations for each.
    func testEffortModeExplanationCoversAllFourModes() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let english = EffortTargetHelp.modesMessage
        let korean = localized(EffortTargetHelp.modesMessage, in: ko)

        for mode in ["None", "Same Target", "Progression", "Custom Per Set"] {
            XCTAssertTrue(
                english.contains(mode),
                "the explanation must name the \(mode) mode")
            let translated = localized(mode, in: ko)
            XCTAssertTrue(
                korean.contains(translated),
                "the Korean explanation must use the picker's own name for "
                    + "\(mode) (\(translated))")
        }
    }

    /// M5 — the in-session copy stated a roadmap ("not available yet") for
    /// behavior that is deliberate and settled. The old keys are gone, not just
    /// unused: a missing key resolves to itself, so this asserts absence.
    func testTheNotAvailableYetCopyIsGone() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in [
            "Progression editing during workout is not available yet.",
            "Per-set effort editing during workout is not available yet.",
        ] {
            XCTAssertEqual(
                localized(key, in: ko), key,
                "the superseded roadmap copy is still in the catalog: \(key)")
        }

        for key in Self.effortClarityKeys {
            XCTAssertFalse(
                localized(key, in: ko).contains("아직"),
                "the replacement copy still reads as unfinished: \(key)")
        }
    }

    /// The saved-targets row has to say both halves — that the work is kept,
    /// and what to do to edit it again.
    func testSavedTargetsRowNamesTheSettingToTurnBackOn() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let value = localized(EffortTargetHelp.savedWhileAutoregOff, in: ko)

        XCTAssertTrue(value.contains("저장"), "must say the targets are saved")
        XCTAssertTrue(value.contains("RIR/RPE"), "must name the setting")
        XCTAssertTrue(value.contains("설정"), "must point at Settings")
    }

    // MARK: - User Guide language picker (Build 10 C5)

    /// The picker's accessibility label is the only new string the guide
    /// language selector introduces — the two segment titles are deliberately
    /// unlocalized, each naming its own language.
    func testGuideLanguagePickerLabelLocalizesToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let en = try XCTUnwrap(localizationBundle("en"))

        XCTAssertEqual(localized("Guide language", in: ko), "가이드 언어")
        XCTAssertEqual(localized("Guide language", in: en), "Guide language")
    }

    // MARK: - Alternative Exercises discoverability (Build 10 C4)

    /// Every string the discoverability slice puts on a new surface — the
    /// routine editor's block subtitle, the Start Workout summary, the active
    /// workout's Switch Exercise badge, and the switch sheet's title and
    /// subtitle. Only `Replacing %@` is new: the counts and the two titles
    /// reuse keys the app already ships, which is the point — one Korean name
    /// for one thing, on every screen it appears.
    private static let alternativeDiscoverabilityKeys = [
        "%lld alternative",
        "%lld alternatives",
        "Switch Exercise",
        "Prepared Alternatives",
        "Replacing %@",
    ]

    func testAlternativeDiscoverabilityStringsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in Self.alternativeDiscoverabilityKeys {
            let value = localized(key, in: ko)
            XCTAssertFalse(value.isEmpty, "\(key) localized to empty string")
            XCTAssertNotEqual(
                value, key,
                "Alternatives discoverability string has no Korean "
                    + "translation (still renders English): \(key)")
        }
    }

    func testAlternativeDiscoverabilityStringsEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in Self.alternativeDiscoverabilityKeys {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)")
        }
    }

    /// The count strings carry their placeholder, and both grammatical numbers
    /// resolve to the same Korean — Korean has no plural inflection, so a
    /// second wording here would be a bug, not a nicety.
    func testAlternativeCountsKeepTheirPlaceholderAndAgree() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let singular = localized("%lld alternative", in: ko)
        let plural = localized("%lld alternatives", in: ko)

        XCTAssertTrue(
            singular.contains("%lld"),
            "Korean translation dropped the count placeholder: \(singular)")
        XCTAssertTrue(
            plural.contains("%lld"),
            "Korean translation dropped the count placeholder: \(plural)")
        XCTAssertEqual(
            singular, plural,
            "Korean has no plural inflection — one wording for both")
        XCTAssertTrue(
            plural.contains("대체 운동"),
            "the count must reuse the app's name for the feature: \(plural)")
    }

    /// The switch sheet's subtitle keeps the exercise name it is given.
    func testReplacingSubtitleKeepsTheExerciseName() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let value = localized("Replacing %@", in: ko)

        XCTAssertTrue(
            value.contains("%@"),
            "Korean translation dropped the exercise name: \(value)")
        XCTAssertNotEqual(
            localized("Switch Exercise", in: ko), value,
            "the sheet's title and its subtitle must not read the same")
    }

    // MARK: - End vs Finish (Build 10)

    /// The two ways out of an active workout are different actions: **End**
    /// leaves it (Save & Exit / Discard), **Finish** completes it and saves it
    /// to History. Through Build 9 both dialogs asked the same Korean question
    /// — "운동을 종료할까요?" — so a Korean lifter could not tell from the title
    /// which one they had opened. The titles must stay distinct, and each must
    /// use its own verb: 중단 for the exit, 완료 for the finish (matching the
    /// Finish button and "운동 완료").
    func testEndAndFinishDialogTitlesAreDistinctInKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let end = localized("End workout?", in: ko)
        let finish = localized("Finish this workout?", in: ko)

        XCTAssertNotEqual(
            end, finish,
            "The End and Finish dialogs must not share a Korean title")
        XCTAssertEqual(end, "운동을 중단할까요?")
        XCTAssertEqual(finish, "운동을 완료할까요?")
        XCTAssertTrue(
            finish.contains("완료"),
            "The finish dialog must say 완료, like the Finish button it confirms")
        XCTAssertFalse(
            end.contains("완료"),
            "The exit dialog must not claim the workout is being completed")
    }

    func testEndAndFinishDialogTitlesEnglishUnchanged() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for key in ["End workout?", "Finish this workout?"] {
            XCTAssertEqual(
                localized(key, in: en), key,
                "English should render the literal key text for \(key)")
        }
    }

    // MARK: - Set kind labels in the routine block detail (Build 10)

    /// The routine block detail used to render `SetTemplate.kindRaw.capitalized`
    /// — the persisted English raw value — so a Korean routine listed its sets
    /// as "Working", "Warmup", "Dropset". It now renders `kind.historyRowLabel`,
    /// whose keys are these. Each must have a Korean translation, and none may
    /// be a capitalized raw value.
    private static let setKindLabelKeys = [
        "Working Set", "Warm-up Set", "Drop Set",
    ]

    func testSetKindRowLabelsLocalizeToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let leakedRawValues = Set(SetKind.allCases.map { $0.rawValue.capitalized })

        for key in Self.setKindLabelKeys {
            let value = localized(key, in: ko)
            XCTAssertNotEqual(
                value, key,
                "Set kind label has no Korean translation: \(key)")
            XCTAssertFalse(
                leakedRawValues.contains(value),
                "Korean set kind label is a raw enum value: \(value)")
        }
    }

    /// A new `SetKind` case must arrive with a label key above, or the block
    /// detail silently gains an untested row label. Asserted on the raw values
    /// rather than on `historyRowLabel`, which resolves against the host app's
    /// own language and so is not a fixed string inside a test.
    func testEverySetKindHasACoveredRowLabel() {
        XCTAssertEqual(
            Set(SetKind.allCases.map(\.rawValue)),
            ["warmup", "working", "dropset"],
            "A SetKind case was added or renamed — add its row label key to "
                + "setKindLabelKeys so its Korean translation is checked")
        XCTAssertEqual(Self.setKindLabelKeys.count, SetKind.allCases.count)
    }

    // MARK: - Cardio Plan naming (Build 10)

    /// The routine editor row and the plan editor title used to say
    /// "Structured Cardio" while the active workout, History and the guide all
    /// said "Cardio Plan". One name now, in both languages.
    func testCardioPlanRowLocalizesToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let en = try XCTUnwrap(localizationBundle("en"))

        XCTAssertEqual(localized("Cardio Plan", in: ko), "유산소 계획")
        XCTAssertEqual(localized("Cardio Plan", in: en), "Cardio Plan")
    }

    // MARK: - Techniques row wording (Build 10)

    /// The routine editor's Techniques row rendered "운동 기법        3 테크닉":
    /// the title and its own count used two different Korean words for the same
    /// thing. The count now reuses the row's name.
    func testTechniqueCountReusesTheRowsKoreanName() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let count = localized("%lld technique%@", in: ko)

        XCTAssertEqual(localized("Techniques", in: ko), "운동 기법")
        XCTAssertTrue(
            count.contains("운동 기법"),
            "The technique count must use the row's own name: \(count)")
        XCTAssertFalse(
            count.contains("테크닉"),
            "The Techniques row still mixes 운동 기법 and 테크닉: \(count)")
        XCTAssertTrue(
            count.contains("%1$lld"),
            "Korean translation dropped the count placeholder: \(count)")
    }

    // MARK: - Active workout navigation copy (manual-test polish)

    /// The active workout's bottom bar rendered its Back button through the
    /// bare `"Back"` key — which is also the canonical **body part**, so the
    /// navigation control read `등` (the anatomical back) next to a correctly
    /// labelled `다음`. The button now has its own key.
    func testActiveWorkoutBackButtonIsNavigationNotBodyPart() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let en = try XCTUnwrap(localizationBundle("en"))
        let korean = localized(ActiveWorkoutNavCopy.backKey, in: ko)

        XCTAssertNotEqual(
            korean, "등",
            "The navigation button must not use the body part's translation")
        XCTAssertTrue(
            ["이전", "뒤로"].contains(korean),
            "Expected a navigation word (이전 / 뒤로), got: \(korean)")
        XCTAssertEqual(
            korean, "이전",
            "이전 is the chosen wording — it pairs with 다음 as an ordinal step")
        XCTAssertEqual(
            localized(ActiveWorkoutNavCopy.backKey, in: en), "Back",
            "English is unchanged; the key carries an explicit en value "
                + "because it is not itself English text")
        XCTAssertEqual(
            ActiveWorkoutNavCopy.backTitle, "Back",
            "The test bundle runs in English, so the helper resolves to Back")
    }

    /// The two buttons of the bottom bar read as a pair.
    func testActiveWorkoutNextIsUnchanged() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        XCTAssertEqual(localized("Next", in: ko), "다음")
    }

    // MARK: - Build 10 low-risk polish keys

    /// Audit M7 — the progression ends had been composed from the generic
    /// `Start` / `End` keys, and `End` is the workout-ending word: a Korean
    /// user editing a ramp read `종료 RIR`, "quit RIR".
    func testEffortProgressionLabelsAreNaturalKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let en = try XCTUnwrap(localizationBundle("en"))

        XCTAssertEqual(localized("Start RIR", in: ko), "시작 RIR")
        XCTAssertEqual(localized("End RIR", in: ko), "마지막 RIR")
        XCTAssertEqual(localized("Start RPE", in: ko), "시작 RPE")
        XCTAssertEqual(localized("End RPE", in: ko), "마지막 RPE")

        for key in ["End RIR", "End RPE"] {
            XCTAssertFalse(
                localized(key, in: ko).contains("종료"),
                "\(key) must not reuse the workout-ending word")
        }
        XCTAssertEqual(localized("Start RIR", in: en), "Start RIR")
        XCTAssertEqual(localized("End RIR", in: en), "End RIR")
    }

    /// The generic keys keep their own meanings — the fix adds keys rather
    /// than repointing the ones the workout controls own.
    func testGenericStartAndEndAreUnchanged() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        XCTAssertEqual(localized("Start", in: ko), "시작")
        XCTAssertEqual(localized("End", in: ko), "종료")
    }

    /// Audit M7's other half — the button and the guide step now say the same
    /// thing, and it is the screen's own title.
    func testStartWorkoutButtonMatchesTheScreenTitle() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let en = try XCTUnwrap(localizationBundle("en"))
        XCTAssertEqual(localized("Start Workout", in: ko), "운동 시작")
        XCTAssertEqual(localized("Start Workout", in: en), "Start Workout")
    }

    /// Audit M2 — the Cardio Plan checklist says what a tick is worth.
    func testCardioChecklistSessionOnlyCaptionLocalizes() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let korean = localized(
            "Checklist only — not saved as results.", in: ko)

        XCTAssertEqual(korean, "체크리스트 전용 — 결과로 저장되지 않음")
        XCTAssertNotEqual(
            korean, "Checklist only — not saved as results.",
            "the caption must be translated, not fall through to English")
    }

    /// Audit L5 — the segment total and its mismatch cue.
    func testCardioSegmentTotalCopyLocalizes() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let total = localized("Segment total: %@", in: ko)

        XCTAssertEqual(total, "구간 합계: %@")
        XCTAssertTrue(
            total.contains("%@"),
            "Korean dropped the distance placeholder: \(total)")
        XCTAssertEqual(
            localized("Does not match the target distance.", in: ko),
            "목표 거리와 일치하지 않습니다.")
    }

    /// Audit L7 — the superset effort marker. Korean has no plural form, so
    /// both count keys share one translation.
    func testSupersetEffortMarkerLocalizes() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in ["%lld effort target", "%lld effort targets"] {
            let value = localized(key, in: ko)
            XCTAssertEqual(value, "강도 목표 %lld개")
            XCTAssertTrue(
                value.contains("%lld"),
                "\(key) dropped its count placeholder: \(value)")
        }
    }

    /// Audit L4 — the destructive switch warning now names what it buys.
    /// The two-placeholder variants must stay positional in both languages,
    /// because Korean puts the count after the noun.
    func testNamedSwitchWarningsLocalizeAndKeepPlaceholders() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let en = try XCTUnwrap(localizationBundle("en"))

        let singularKeys = [
            "Switching to %@ will remove 1 logged set for this exercise.",
            "Switching to %@ will remove 1 logged set from this block.",
        ]
        for key in singularKeys {
            let value = localized(key, in: ko)
            XCTAssertNotEqual(value, key, "\(key) is untranslated")
            XCTAssertTrue(
                value.contains("%@"),
                "\(key) dropped the exercise-name placeholder: \(value)")
            XCTAssertTrue(
                value.contains("(으)로"),
                "the particle keeps a consonant- or vowel-final name correct")
        }

        let pluralKeys = [
            "Switching to %@ will remove %lld logged sets for this exercise.",
            "Switching to %@ will remove %lld logged sets from this block.",
        ]
        for key in pluralKeys {
            for (bundle, language) in [(ko, "ko"), (en, "en")] {
                let value = localized(key, in: bundle)
                XCTAssertTrue(
                    value.contains("%1$@") && value.contains("%2$lld"),
                    "\(language) must be positional for two placeholders: "
                        + value)
            }
        }
    }

    /// The unnamed originals stay — they are the fallback for an exercise that
    /// cannot be resolved.
    func testUnnamedSwitchWarningsAreStillTranslated() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in [
            "Switching exercises will remove 1 logged set for this exercise.",
            "Switching exercises will remove %lld logged sets for this exercise.",
            "Switching exercises will remove 1 logged set from this block.",
            "Switching exercises will remove %lld logged sets from this block.",
        ] {
            XCTAssertNotEqual(
                localized(key, in: ko), key, "\(key) is untranslated")
        }
    }

    /// Audit M11 — the block detail titles fall back to these two words only
    /// when every exercise is gone.
    func testBlockDetailFallbackTitlesLocalize() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        XCTAssertEqual(localized("Block", in: ko), "블록")
        XCTAssertEqual(localized("Superset", in: ko), "슈퍼세트")
    }

    /// The body part keeps its own translation — the fix adds a key, it does
    /// not repoint the existing one.
    func testBodyPartBackStillTranslatesToTheAnatomicalBack() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let en = try XCTUnwrap(localizationBundle("en"))

        XCTAssertEqual(localized("Back", in: ko), "등")
        XCTAssertEqual(localized("Back", in: en), "Back")
        XCTAssertNotEqual(
            ActiveWorkoutNavCopy.backKey, "Back",
            "The navigation button must not share the body part's key")
    }
}
