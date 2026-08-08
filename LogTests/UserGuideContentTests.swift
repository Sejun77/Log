import XCTest

@testable import Log

/// The in-app User Guide mirrors `USER_GUIDE.md` by hand — there is no parsing
/// or shared source, which is deliberate (no runtime file dependency), but it
/// means the two languages and the two copies can drift silently.
///
/// These tests pin the properties that matter for testers: the English and
/// Korean guides stay structurally aligned, the sentences the repo guide also
/// carries are present verbatim in both, and the cardio answer stays short.
///
/// That last one needs its own guard. The cardio section has twice been walked
/// back from a wall of text, because every slice that shipped a cardio behavior
/// also wanted to explain it. `testCardioSectionStaysShort` caps its length and
/// `testRemovedImplementationPhrasesStayGone` names the sentences that keep
/// coming back, so the next round of growth fails a test instead of a review.
final class UserGuideContentTests: XCTestCase {

    private var english: [GuideSection] { UserGuideView.englishGuide }
    private var korean: [GuideSection] { UserGuideView.koreanGuide }

    // MARK: - 1. Structural sync

    func testBothLanguagesHaveTheSameSectionCount() {
        XCTAssertEqual(
            english.count, korean.count,
            "A section added to one language must be added to the other")
    }

    /// Section-by-section shape, so a bullet added to only one language fails
    /// with a readable index rather than a vague count mismatch.
    func testSectionsAlignItemForItem() {
        for (index, pair) in zip(english, korean).enumerated() {
            let (en, ko) = pair
            XCTAssertEqual(
                en.items.count, ko.items.count,
                "Section \(index) (\"\(en.heading)\" / \"\(ko.heading)\") "
                    + "has mismatched item counts")
            XCTAssertEqual(
                en.ordered, ko.ordered,
                "Section \(index) (\"\(en.heading)\") has mismatched list style")
            XCTAssertEqual(
                en.intro == nil, ko.intro == nil,
                "Section \(index) (\"\(en.heading)\") has a one-sided intro")
            XCTAssertEqual(
                en.outro == nil, ko.outro == nil,
                "Section \(index) (\"\(en.heading)\") has a one-sided outro")
        }
    }

    func testNoSectionIsEmpty() {
        for section in english + korean {
            XCTAssertFalse(section.heading.isEmpty)
        }
    }

    // MARK: - 2. Duration & cardio section

    private func section(heading: String, in guide: [GuideSection])
        -> GuideSection?
    {
        guide.first { $0.heading == heading }
    }

    func testDurationAndCardioSectionExistsInBothLanguages() throws {
        XCTAssertNotNil(
            section(heading: "Duration Exercises and Cardio", in: english))
        XCTAssertNotNil(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean))
    }

    /// Every word of one guide, so a phrase can be hunted across the whole
    /// document rather than only in the section it was last seen in. Deleted
    /// prose has a habit of reappearing one section over.
    private func allText(of guide: [GuideSection]) -> String {
        guide
            .flatMap { [$0.heading, $0.intro ?? "", $0.outro ?? ""] + $0.items }
            .joined(separator: "\n\n")
    }

    /// The cardio answer is two short paragraphs. It has twice grown into a
    /// wall of text by accretion — eleven paragraphs at its worst, most of them
    /// explaining *why the app behaves as it does* rather than what to do — so
    /// the length is pinned, not just the wording.
    func testCardioSectionStaysShort() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        let ko = try XCTUnwrap(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean)?.outro)

        for (language, outro) in [("English", en), ("Korean", ko)] {
            let paragraphs = outro.components(separatedBy: "\n\n")
            XCTAssertLessThanOrEqual(
                paragraphs.count, 2,
                "\(language) cardio guidance grew back past two paragraphs")
        }
    }

    /// Implementation detail that has been deleted from the guide and must not
    /// come back — anywhere in it, in either language.
    ///
    /// Each of these answered a question no user asked: how prefill picks its
    /// values, what a tick does and does not persist, how the one-time cardio
    /// migration prompt behaves, when a unit conversion is recomputed. They
    /// document the build, not the app.
    func testRemovedImplementationPhrasesStayGone() {
        let removed = [
            // Checklist persistence internals.
            "the ticks are not saved",
            "nothing has to be ticked",
            // Prefill internals.
            "heart rate, heart-rate zone, and calories are not filled in",
            // One-time migration prompt.
            "nothing changes unless you accept",
            // Unit-conversion internals.
            "Changing the unit changes only how distances are shown",
            "re-read",
            // Snapshot immutability.
            "frozen snapshot",
            // Chart edge cases — which sessions plot no pace point, and which
            // end of an inverted scale the record marker sits on. True, and
            // nothing a user needs told.
            "has no pace point",
            "rosette",
            "페이스 점이 표시되지",
            "가장 빠른 세션에 붙습니다",
            // Earlier rounds of the same cleanup.
            "there is no unit picker on the set row",
            "editing the routine later never changes",
            "Save & Exit",
            "older routine files without them still import as before",
        ]

        for (language, guide) in [("English", english), ("Korean", korean)] {
            let text = allText(of: guide)
            for phrase in removed {
                XCTAssertFalse(
                    text.localizedCaseInsensitiveContains(phrase),
                    "\(language) guide: implementation detail is back — "
                        + "\"\(phrase)\"")
            }
        }
    }

    /// The whole cardio answer, verbatim. Three claims carry it, and each is
    /// something a user cannot work out from the UI alone:
    ///
    /// 1. which details a cardio exercise can record;
    /// 2. how to turn an exercise of your own into a cardio one;
    /// 3. that a Cardio Plan is **only a guide** and the workout is saved as
    ///    **one Cardio Set**, not a row per segment.
    ///
    /// Everything else the section used to say — how prefill behaves, what
    /// History freezes, how units convert — is either visible in the app or was
    /// never guidance.
    func testCardioWordingIsTheShortAgreedVersion() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        XCTAssertEqual(
            en,
            "Cardio exercises also let you record details such as distance, "
                + "calories, heart rate, incline or decline, resistance, and "
                + "heart-rate zone. In routines, cardio exercises can have a "
                + "target distance and an optional Cardio Plan. To make your "
                + "own cardio exercise, open the exercise, turn on Time-based, "
                + "then turn on Cardio."
                + "\n\n"
                + "A Cardio Plan is only a guide/checklist. Your workout is "
                + "still saved as one Cardio Set using the duration and "
                + "Details you log.",
            "English cardio wording drifted from USER_GUIDE.md")

        let ko = try XCTUnwrap(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean)?.outro)
        XCTAssertEqual(
            ko,
            "유산소 운동에서는 거리, 칼로리, 심박수, 경사 / 내리막, 저항, 심박 존 "
                + "같은 세부 정보도 기록할 수 있습니다. 루틴에서는 유산소 운동에 "
                + "목표 거리와 유산소 계획을 설정할 수 있습니다. 직접 유산소 운동을 "
                + "만들려면 해당 운동을 열고 시간 기반을 켠 다음 유산소를 켜세요."
                + "\n\n"
                + "유산소 계획은 안내용 체크리스트일 뿐입니다. 운동은 기록한 시간과 "
                + "세부 정보를 바탕으로 유산소 세트 하나로 저장됩니다.",
            "Korean cardio wording drifted from USER_GUIDE.md")
    }

    /// The one action the section must not lose again. It was dropped in the
    /// round that cut the section to two paragraphs and added back on review:
    /// nothing else in the guide says how an exercise becomes a cardio one, and
    /// the two toggles are not discoverable in the order they must be used.
    func testGuideSaysHowToMakeAnExerciseCardio() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        XCTAssertTrue(
            en.contains(
                "To make your own cardio exercise, open the exercise, turn on "
                    + "Time-based, then turn on Cardio."),
            "The guide no longer says how to make an exercise cardio")

        let ko = try XCTUnwrap(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean)?.outro)
        XCTAssertTrue(
            ko.contains(
                "직접 유산소 운동을 만들려면 해당 운동을 열고 시간 기반을 켠 다음 "
                    + "유산소를 켜세요."),
            "The Korean guide no longer says how to make an exercise cardio")
    }

    /// Both languages must make the same two claims. Korean has previously
    /// been left carrying detail English had already dropped.
    func testCardioPlanIsCalledAGuideInBothLanguages() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        XCTAssertTrue(en.contains("A Cardio Plan is only a guide/checklist."))
        XCTAssertTrue(en.contains("saved as one Cardio Set"))

        let ko = try XCTUnwrap(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean)?.outro)
        XCTAssertTrue(ko.contains("유산소 계획은 안내용 체크리스트일 뿐입니다."))
        XCTAssertTrue(ko.contains("유산소 세트 하나로 저장됩니다"))
    }

    /// One sentence in the History section, naming the only thing the
    /// surrounding text does not already imply: that the *planned* Cardio Plan
    /// is kept alongside the result. The metric-by-metric list it replaced
    /// simply repeated the Progression paragraph above it.
    func testCheckingHistoryDescribesCardioInOneSentence() throws {
        let en = try XCTUnwrap(
            section(heading: "Checking History", in: english)?.outro)
        XCTAssertTrue(
            en.contains(
                "Cardio history shows your logged cardio results and any "
                    + "Cardio Plan that was planned for the session."),
            "English cardio History wording drifted from USER_GUIDE.md")

        let ko = try XCTUnwrap(
            section(heading: "기록 확인하기", in: korean)?.outro)
        XCTAssertTrue(
            ko.contains(
                "유산소 기록에는 기록한 유산소 결과와 그 세션에 계획했던 유산소 "
                    + "계획이 표시됩니다."),
            "Korean cardio History wording drifted from USER_GUIDE.md")
    }

    /// Settings lists its units as bullets and says nothing more. The trailing
    /// paragraph that explained which surfaces a distance-unit change reaches
    /// is gone in both languages — the bullet already tells a user the setting
    /// exists, which is all the guide owes them.
    func testSettingsHasNoTrailingUnitsParagraph() throws {
        let en = try XCTUnwrap(section(heading: "Settings", in: english))
        let ko = try XCTUnwrap(section(heading: "설정", in: korean))

        XCTAssertNil(en.outro, "The Settings units paragraph is back (English)")
        XCTAssertNil(ko.outro, "The Settings units paragraph is back (Korean)")
        XCTAssertTrue(en.items.contains("choose distance unit for cardio: km or mi"))
        XCTAssertTrue(ko.items.contains("유산소 거리 단위 선택: km 또는 mi"))
    }

    /// The limits the guide quotes must be the limits the app enforces.
    func testGuideQuotesTheRealLimits() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english))
        XCTAssertTrue(
            en.items.contains("exercise duration can be set up to 6 hours"))
        XCTAssertTrue(en.items.contains("rest can be set up to 60 minutes"))

        XCTAssertEqual(DurationLimits.maxExerciseSeconds, 6 * 3_600)
        XCTAssertEqual(DurationLimits.maxRestSeconds, 60 * 60)
    }

    /// Duration slots hide reps, weight, tempo, and Tempo Override — the guide
    /// states it, so a regression in either place should surface here.
    func testGuideStatesTheDurationFieldRules() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english))
        XCTAssertTrue(
            en.items.contains(
                "duration exercises do not show reps, weight, or tempo"))
    }
}
