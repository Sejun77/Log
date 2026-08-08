import XCTest

@testable import Log

/// The in-app User Guide mirrors `USER_GUIDE.md` by hand — there is no parsing
/// or shared source, which is deliberate (no runtime file dependency), but it
/// means the two languages and the two copies can drift silently.
///
/// These tests pin the properties that matter for testers: the English and
/// Korean guides stay structurally aligned, and the sentences the repo guide
/// also carries — in particular the beta's cardio wording — are present
/// verbatim in both.
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

    /// The pre-archive polish cut the cardio answer down to what a user needs:
    /// the section had grown to eleven paragraphs, several of them explaining
    /// *why the app behaves as it does* (snapshot immutability, unit re-reads,
    /// draft persistence) rather than what to do. Those are development
    /// history, not guidance, and they are gone.
    ///
    /// This test is what keeps the section short. A regression here is almost
    /// always someone re-adding an implementation detail one paragraph at a
    /// time.
    func testCardioSectionStaysShort() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        let ko = try XCTUnwrap(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean)?.outro)

        for (language, outro) in [("English", en), ("Korean", ko)] {
            let paragraphs = outro.components(separatedBy: "\n\n")
            XCTAssertLessThanOrEqual(
                paragraphs.count, 6,
                "\(language) cardio guidance grew back past six paragraphs")
        }
    }

    /// The implementation-history sentences the polish removed. None of them
    /// told a user what to do; each existed to explain a past fix or an
    /// internal rule.
    func testCardioSectionCarriesNoImplementationHistory() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        let removed = [
            "re-reads in the new unit",
            "there is no unit picker on the set row",
            "editing the routine later never changes",
            "Save & Exit",
            "older routine files without them still import as before",
        ]
        for phrase in removed {
            XCTAssertFalse(
                en.localizedCaseInsensitiveContains(phrase),
                "Implementation detail is back in the cardio guide: \(phrase)")
        }
    }

    /// The unit explanation lives in Settings, in one sentence. The long
    /// version — which surface converts what, and when — described plumbing.
    func testSettingsKeepsDistanceUnitsToOneIdea() throws {
        let en = try XCTUnwrap(section(heading: "Settings", in: english)?.outro)
        XCTAssertTrue(
            en.contains(
                "Distance units affect cardio distance and pace display."),
            "English distance-unit wording drifted from USER_GUIDE.md")
        XCTAssertFalse(
            en.contains("Settings is the only place"),
            "The long distance-unit explanation is back")

        let ko = try XCTUnwrap(section(heading: "설정", in: korean)?.outro)
        XCTAssertTrue(
            ko.contains("거리 단위는 유산소 거리와 페이스 표시에 적용됩니다."),
            "Korean distance-unit wording drifted from USER_GUIDE.md")
    }

    /// The exact wording agreed for the cardio answer. It appears in
    /// `USER_GUIDE.md` and here; if the in-app copy is reworded the guide has
    /// to be rewritten with it.
    ///
    /// > **Superseded by Cardio Slice 4.** The beta answer — "details like
    /// > distance, speed, incline, resistance, or heart-rate zone can be
    /// > written in notes" — was true only while there was nowhere else to put
    /// > them. Slice 4 shipped the Details section on the active-workout cardio
    /// > row, so the guide now describes that instead. The historical sentence
    /// > is preserved in `ENTRY_12_TESTFLIGHT_FEEDBACK.md` as the record of what
    /// > beta testers were told at the time, and is deliberately not rewritten
    /// > there.
    func testCardioWordingMatchesTheDocumentedSentence() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        XCTAssertTrue(
            en.contains(
                "To track an exercise as cardio, open it in Exercises, turn on "
                    + "Time-based, then turn on Cardio."),
            "English cardio wording drifted from USER_GUIDE.md")
        XCTAssertTrue(
            en.contains(
                "Every one of these is optional, and pace and speed are worked "
                    + "out for you once a distance and a duration are entered."),
            "English cardio detail wording drifted from USER_GUIDE.md")

        let ko = try XCTUnwrap(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean)?.outro)
        XCTAssertTrue(
            ko.contains(
                "운동을 유산소로 기록하려면 운동 탭에서 해당 운동을 열고 시간 "
                    + "기반을 켠 다음 유산소를 켜세요."),
            "Korean cardio wording drifted from USER_GUIDE.md")
        XCTAssertTrue(
            ko.contains(
                "모두 선택 사항이며, 거리와 시간을 입력하면 페이스와 속도는 "
                    + "자동으로 계산됩니다."),
            "Korean cardio detail wording drifted from USER_GUIDE.md")
    }

    /// Structured Cardio (Slices 12D / 12E), stated in one paragraph rather
    /// than three. Two claims have to survive every rewording, because a user
    /// who gets either one wrong is misled about what the app saved:
    ///
    /// 1. the plan is a **guide**, and ticking a segment records nothing;
    /// 2. the result is **one Cardio Set**, not a row per segment.
    func testGuideSaysTheCardioPlanIsAGuideNotALog() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        XCTAssertTrue(
            en.contains("The Cardio Plan is a guide, not a log."),
            "English structured-cardio wording drifted from USER_GUIDE.md")
        XCTAssertTrue(
            en.contains(
                "the ticks are not saved and nothing has to be ticked before "
                    + "you log"),
            "The guide must not imply a tick is a logged result")
        XCTAssertTrue(
            en.contains(
                "the result is recorded as one Cardio Set, built from the "
                    + "duration and the Details fields"),
            "The guide must name the single aggregate cardio entry")

        let ko = try XCTUnwrap(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean)?.outro)
        XCTAssertTrue(
            ko.contains("유산소 계획은 기록이 아니라 안내입니다."),
            "Korean structured-cardio wording drifted from USER_GUIDE.md")
        XCTAssertTrue(
            ko.contains("체크 표시는 저장되지 않고 기록하기 전에 모두 체크할 필요도 없습니다"),
            "The Korean guide must not imply a tick is a logged result")
        XCTAssertTrue(
            ko.contains("결과는 시간과 세부 정보를 바탕으로 유산소 세트 하나로 기록됩니다"),
            "The Korean guide must name the single aggregate cardio entry")
    }

    /// What History holds for a cardio session, in one sentence, in the
    /// section about History — where a reader looking for it will be. The
    /// three paragraphs it replaced were in the cardio section and were mostly
    /// about snapshot immutability.
    func testCheckingHistoryDescribesCardioInOneSentence() throws {
        let en = try XCTUnwrap(
            section(heading: "Checking History", in: english)?.outro)
        XCTAssertTrue(
            en.contains(
                "Cardio history shows your logged distance, duration, pace, "
                    + "calories, heart rate, incline, resistance, and any "
                    + "Cardio Plan that was planned for the session."),
            "English cardio History wording drifted from USER_GUIDE.md")
        XCTAssertFalse(
            en.contains("re-read the moment you change it"),
            "The unit-refresh implementation detail is back")

        let ko = try XCTUnwrap(
            section(heading: "기록 확인하기", in: korean)?.outro)
        XCTAssertTrue(
            ko.contains(
                "유산소 기록에는 기록한 거리, 시간, 페이스, 칼로리, 심박수, 경사, "
                    + "저항과 그 세션에 계획했던 유산소 계획이 표시됩니다."),
            "Korean cardio History wording drifted from USER_GUIDE.md")
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
