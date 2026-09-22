import XCTest

@testable import Log

/// Coverage for the point-of-use term explanations added by
/// `ux/training-term-help`: the technique descriptions consolidated into
/// `TechniqueHelp`, and the RIR/RPE and e1RM copy.
///
/// These are pure copy namespaces, so the meaningful assertions are
/// *exhaustiveness*, *distinctness* and *Korean parity* — not rendering. The
/// `InfoButton`s themselves are deliberately untested: a snapshot of a glyph
/// asserts nothing these do not.
final class TrainingTermHelpTests: XCTestCase {

    // MARK: - Bundles

    /// The host `Log.app` bundle (LogTests is app-hosted), so these read the
    /// compiled per-language `.strings` rather than the source `.xcstrings` —
    /// the same approach `KoreanLocalizationTests` takes.
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

    /// Key-as-fallback lookup, mirroring `LocalizedStringKey` at render time.
    private func localized(_ key: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    // MARK: - TechniqueHelp: exhaustiveness

    /// Every technique the app models has a description, and none is blank.
    /// `allCases` is the point: a new `TechniqueType` fails here rather than
    /// rendering an empty line in the picker and the detail sheet.
    func testEveryTechniqueTypeHasANonEmptyDescription() {
        for type in TechniqueType.allCases {
            let description = TechniqueHelp.description(for: type)
            XCTAssertFalse(
                description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(type) has no description"
            )
        }
    }

    /// No two techniques share a description — a copy-paste that leaves Cluster
    /// describing Rest-Pause is exactly the drift this namespace exists to stop.
    func testTechniqueDescriptionsAreDistinct() {
        let descriptions = TechniqueType.allCases.map {
            TechniqueHelp.description(for: $0)
        }
        XCTAssertEqual(
            Set(descriptions).count, TechniqueType.allCases.count,
            "Two techniques share the same description"
        )
    }

    /// A description must not be the technique's own name: "Cluster: Cluster."
    /// explains nothing, and the pre-consolidation Cluster copy ("Intra-set
    /// pause clusters.") was a near miss of exactly that kind.
    func testTechniqueDescriptionsDoNotMerelyRepeatTheName() {
        for type in TechniqueType.allCases {
            let description = TechniqueHelp.description(for: type)
            XCTAssertNotEqual(
                description.lowercased(), type.displayName.lowercased(),
                "\(type)'s description just repeats its name"
            )
            XCTAssertGreaterThan(
                description.count, type.displayName.count,
                "\(type)'s description is no more informative than its name"
            )
        }
    }

    /// The five reused descriptions must stay byte-identical to the literals the
    /// Add Technique picker already shipped, because that is what keeps their
    /// existing string-catalog keys — and therefore their existing Korean —
    /// resolving. Changing one without adding the new key is a silent fallback
    /// to English, which the Korean assertions below would then catch.
    func testReusedTechniqueDescriptionsKeepTheirExistingKeys() {
        XCTAssertEqual(
            TechniqueHelp.description(for: .dropset),
            "Reduce weight immediately after reaching failure.")
        XCTAssertEqual(
            TechniqueHelp.description(for: .partialReps),
            "Continue with partial range of motion after failure.")
        XCTAssertEqual(
            TechniqueHelp.description(for: .restPause),
            "Short intra-set rest, then continue.")
        XCTAssertEqual(
            TechniqueHelp.description(for: .toFailure),
            "Push until technical failure.")
        XCTAssertEqual(
            TechniqueHelp.description(for: .tempoOverride),
            "Override tempo for this exercise.")
    }

    /// AMRAP's description must be set-neutral. It is rendered both in the
    /// routine picker and beside whichever set a snapshot targets in an active
    /// workout, and the two wordings it replaced ("on last set" / "on this
    /// set") each read wrong in the other place.
    func testAMRAPDescriptionIsSetNeutral() {
        let description = TechniqueHelp.description(for: .amrap).lowercased()
        XCTAssertFalse(description.contains("last set"))
        XCTAssertFalse(description.contains("this set"))
    }

    // MARK: - TechniqueHelp: Korean parity

    func testEveryTechniqueDescriptionIsLocalizedToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for type in TechniqueType.allCases {
            let key = TechniqueHelp.description(for: type)
            let value = localized(key, in: ko)
            XCTAssertNotEqual(
                value, key,
                "\(type)'s description has no Korean translation "
                + "(still renders English)"
            )
            XCTAssertFalse(value.isEmpty, "\(type) localized to empty string")
        }
    }

    func testTechniqueDescriptionsRenderTheirLiteralInEnglish() throws {
        let en = try XCTUnwrap(localizationBundle("en"))
        for type in TechniqueType.allCases {
            let key = TechniqueHelp.description(for: type)
            XCTAssertEqual(localized(key, in: en), key)
        }
    }

    func testNoParametersTrailerIsLocalized() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        XCTAssertNotEqual(
            localized(TechniqueHelp.noParameters, in: ko),
            TechniqueHelp.noParameters
        )
    }

    // MARK: - AutoregulationHelp

    /// Both metrics resolve to their own title and message, and nothing is
    /// blank — the switch is exhaustive over `EffortMetric` by construction.
    func testEveryEffortMetricHasTitleAndMessage() {
        for metric: EffortMetric in [.rir, .rpe] {
            XCTAssertFalse(AutoregulationHelp.title(for: metric).isEmpty)
            XCTAssertFalse(AutoregulationHelp.message(for: metric).isEmpty)
        }
        XCTAssertNotEqual(
            AutoregulationHelp.title(for: .rir),
            AutoregulationHelp.title(for: .rpe))
        XCTAssertNotEqual(
            AutoregulationHelp.message(for: .rir),
            AutoregulationHelp.message(for: .rpe))
    }

    /// Each acronym is expanded in its own title — the actual complaint was
    /// that "RIR" appears with nothing saying what the letters stand for.
    func testTitlesExpandTheAcronyms() {
        XCTAssertTrue(
            AutoregulationHelp.title(for: .rir).contains("Reps in Reserve"))
        XCTAssertTrue(
            AutoregulationHelp.title(for: .rpe)
                .contains("Rate of Perceived Exertion"))
    }

    /// The Settings alert is composed, not a fourth stored key: it must contain
    /// both definitions *and* the pre-existing scope sentence. This is what
    /// guarantees Settings and the prescription editor can never disagree about
    /// what RIR means.
    func testSettingsMessageContainsBothDefinitionsAndScope() {
        let message = AutoregulationHelp.settingsMessage()
        for piece in [
            AutoregulationHelp.rirTitle, AutoregulationHelp.rirMessage,
            AutoregulationHelp.rpeTitle, AutoregulationHelp.rpeMessage,
            AutoregulationHelp.autoregScopeMessage,
        ] {
            XCTAssertTrue(
                message.contains(piece),
                "Settings message is missing: \(piece)"
            )
        }
    }

    func testAutoregulationCopyIsLocalizedToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in [
            AutoregulationHelp.rirTitle, AutoregulationHelp.rirMessage,
            AutoregulationHelp.rpeTitle, AutoregulationHelp.rpeMessage,
            AutoregulationHelp.autoregScopeMessage,
        ] {
            XCTAssertNotEqual(
                localized(key, in: ko), key,
                "No Korean translation for: \(key)"
            )
        }
    }

    // MARK: - TechniqueConflictCopy: English output preserved

    /// The two availability messages are asserted verbatim by
    /// `BodyweightTechniqueTests` and `SwitchExerciseTempoAndPrefillTests`.
    /// `String(localized:)` returns the key itself in English, so the move to
    /// the catalog must leave them byte-identical — re-asserted here so a
    /// reworded key fails next to the reason rather than three files away.
    func testAvailabilityMessagesKeepByteIdenticalEnglish() {
        XCTAssertEqual(
            techniqueConflictMessage(
                for: .dropset, isBodyweight: true, usesDuration: false),
            "Not available for bodyweight exercises.")
        XCTAssertEqual(
            techniqueConflictMessage(
                for: .amrap, isBodyweight: false, usesDuration: true),
            "Not available for duration-based exercises.")
    }

    /// English output of every conflict message, spelled out. Two sentences
    /// changed deliberately when they moved to shared format keys, and this is
    /// where that is recorded: the per-set editor's "already on set N" now
    /// reads "already exists on set N" (it was the same sentence as the
    /// picker's), and the pairwise messages interpolate `displayName` instead
    /// of hard-coding names, which turns "Dropset" into "Drop Set".
    func testConflictMessagesEnglishOutput() {
        XCTAssertEqual(
            TechniqueConflictCopy.duplicateOnSet(.partialReps, setNumber: 2),
            "Partial Reps already exists on set 2.")
        XCTAssertEqual(
            TechniqueConflictCopy.duplicateOnThisSet(.restPause),
            "Rest-Pause is already on this set.")
        XCTAssertEqual(
            TechniqueConflictCopy.cannotShareSet(.restPause, .cluster),
            "Rest-Pause and Cluster can't share a set.")
        XCTAssertEqual(
            TechniqueConflictCopy.cannotShareSet(.cluster, .amrap),
            "Cluster and AMRAP can't share a set.")
        XCTAssertEqual(
            TechniqueConflictCopy.cannotCombine(.cluster, with: .dropset),
            "Cluster can't combine with Drop Set on the same set.")
        XCTAssertEqual(
            TechniqueConflictCopy.dropsetAlreadyDefinesEffort(),
            "Drop Set already defines AMRAP/fixed reps; remove it to use AMRAP.")
        XCTAssertEqual(
            TechniqueConflictCopy.amrapOverlapBlocksFixedReps(),
            "AMRAP exists on an overlapping set; can't use fixed reps.")
    }

    /// The pairwise helper still returns these through the real conflict rules,
    /// unchanged — the rules themselves were not touched.
    func testPairConflictStillReturnsTheSameEnglishText() {
        XCTAssertEqual(
            techniquePairConflict(.restPause, .cluster),
            "Rest-Pause and Cluster can't share a set.")
        XCTAssertEqual(
            techniquePairConflict(.cluster, .restPause),
            "Rest-Pause and Cluster can't share a set.",
            "order-independent: the message names the pair in rule order")
        XCTAssertEqual(
            techniquePairConflict(.amrap, .amrap),
            "AMRAP is already on this set.")
    }

    // MARK: - TechniqueConflictCopy: Korean

    /// **The test that matters for the reported bug.** It resolves each message
    /// through `String(localized:)` against the Korean bundle — the same call
    /// the app makes, with the same compiler-generated format key — so a key
    /// that does not match the catalog fails here instead of shipping
    /// "부분 반복 already exists on set 2." to a Korean phone.
    ///
    /// Asserting "not the English text" rather than an exact Korean string
    /// keeps it from breaking on a retranslation while still catching the only
    /// failure mode there is: falling back to English.
    func testConflictMessagesResolveToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        let koLocale = Locale(identifier: "ko")
        let name = "TECHNIQUE"

        let duplicate = String(
            localized: "\(name) already exists on set \(2).",
            bundle: ko, locale: koLocale)
        XCTAssertNotEqual(duplicate, "\(name) already exists on set 2.")
        XCTAssertTrue(duplicate.contains(name))
        XCTAssertTrue(duplicate.contains("2"))

        let onThisSet = String(
            localized: "\(name) is already on this set.",
            bundle: ko, locale: koLocale)
        XCTAssertNotEqual(onThisSet, "\(name) is already on this set.")

        let shareSet = String(
            localized: "\(name) and \("OTHER") can't share a set.",
            bundle: ko, locale: koLocale)
        XCTAssertNotEqual(shareSet, "\(name) and OTHER can't share a set.")
        XCTAssertTrue(shareSet.contains(name))
        XCTAssertTrue(shareSet.contains("OTHER"))

        let combine = String(
            localized: "\(name) can't combine with \("OTHER") on the same set.",
            bundle: ko, locale: koLocale)
        XCTAssertNotEqual(
            combine, "\(name) can't combine with OTHER on the same set.")

        let definesEffort = String(
            localized:
                "\(name) already defines AMRAP/fixed reps; remove it to use AMRAP.",
            bundle: ko, locale: koLocale)
        XCTAssertNotEqual(
            definesEffort,
            "\(name) already defines AMRAP/fixed reps; remove it to use AMRAP.")
    }

    /// The parameterless conflict messages, checked the same way.
    func testParameterlessConflictMessagesAreLocalizedToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        for key in [
            "Not available for bodyweight exercises.",
            "Not available for duration-based exercises.",
            "AMRAP exists on an overlapping set; can't use fixed reps.",
        ] {
            XCTAssertNotEqual(
                localized(key, in: ko), key,
                "No Korean translation for: \(key)"
            )
        }
    }

    /// The names interpolated into those messages are themselves Korean on a
    /// Korean phone — the other half of "no mixed Korean/English". Together
    /// with the format-key test above, this covers both halves of every
    /// sentence the picker can show.
    ///
    /// `AMRAP` is the deliberate exception: it is an internationally used
    /// acronym that the catalog maps to itself, the same call this app makes
    /// for `kg`, `km` and `bpm`. It is pinned as an exception rather than
    /// skipped, so a *new* technique name that ships untranslated fails here
    /// instead of quietly joining it.
    func testTechniqueNamesInConflictMessagesAreLocalizedToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        var identicalInKorean: Set<TechniqueType> = []

        for type in TechniqueType.allCases {
            // `displayName` reads the English key; on a Korean device the same
            // lookup resolves to this value.
            let koreanName = localized(type.displayName, in: ko)
            XCTAssertFalse(
                koreanName.isEmpty, "\(type) localized to an empty name")
            if koreanName == type.displayName { identicalInKorean.insert(type) }
        }

        XCTAssertEqual(
            identicalInKorean, [.amrap],
            "Only AMRAP may render identically in Korean; any other technique "
            + "here has no Korean translation, so a conflict message naming it "
            + "would render half English"
        )
    }

    // MARK: - ProgressionMetricHelp (e1RM)

    /// Says what the estimate *is* and that it comes from logged sets — the
    /// half that stops it reading as a max the user actually lifted.
    func testE1RMHelpDescribesAnEstimateFromLoggedSets() {
        let message = ProgressionMetricHelp.e1RMMessage.lowercased()
        XCTAssertTrue(message.contains("estimate"))
        XCTAssertTrue(message.contains("logged sets"))
        XCTAssertEqual(ProgressionMetricHelp.e1RMTitle, ProgressMetric.e1rm.title)
    }

    func testE1RMHelpIsLocalizedToKorean() throws {
        let ko = try XCTUnwrap(localizationBundle("ko"))
        XCTAssertNotEqual(
            localized(ProgressionMetricHelp.e1RMMessage, in: ko),
            ProgressionMetricHelp.e1RMMessage
        )
    }
}
