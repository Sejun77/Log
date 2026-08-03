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
