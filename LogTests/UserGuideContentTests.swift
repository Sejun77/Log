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

    /// Structured Cardio Slice 12D — the checklist is now visible during a
    /// workout, so the guide describes it. The sentence that matters most is
    /// the one that says a tick is **not** a record: a user who thinks the app
    /// saved their segments would be misled about what History contains.
    func testGuideExplainsTheStructuredCardioChecklist() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        XCTAssertTrue(
            en.contains(
                "During the workout the slot shows them as a Cardio Plan "
                    + "checklist above the set row"),
            "English structured-cardio wording drifted from USER_GUIDE.md")
        XCTAssertTrue(
            en.contains(
                "the ticks are not saved to your history, nothing has to be "
                    + "ticked before you log, and the bout is still recorded as "
                    + "one cardio set"),
            "The guide must not imply a tick is a logged result")

        let ko = try XCTUnwrap(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean)?.outro)
        XCTAssertTrue(
            ko.contains("운동 중에는 세트 행 위에 유산소 계획 체크리스트로 표시되며"),
            "Korean structured-cardio wording drifted from USER_GUIDE.md")
        XCTAssertTrue(
            ko.contains(
                "체크 표시는 기록에 저장되지 않고, 기록하기 전에 모든 구간을 "
                    + "체크할 필요도 없으며"),
            "The Korean guide must not imply a tick is a logged result")
    }

    /// Structured Cardio Slice 12E — History now shows the planned segments,
    /// so the guide says so. The sentence that matters is the one drawing the
    /// line between *planned* and *performed*: a user who read the Planned
    /// section as a record of which segments they completed would be misled
    /// about what the app observed.
    func testGuideExplainsThePlannedSectionInHistory() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        XCTAssertTrue(
            en.contains(
                "After the workout, History shows that plan again under "
                    + "Planned, above the logged sets."),
            "English History wording drifted from USER_GUIDE.md")
        XCTAssertTrue(
            en.contains(
                "These are planned segments only — not a record of which ones "
                    + "you did."),
            "The guide must not present the Planned section as what was done")
        XCTAssertTrue(
            en.contains(
                "Routines you export and import carry their structured "
                    + "segments with them"),
            "English transfer wording drifted from USER_GUIDE.md")

        let ko = try XCTUnwrap(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean)?.outro)
        XCTAssertTrue(
            ko.contains("운동을 마치면 기록 탭에서 기록된 세트 위에 계획 항목으로"),
            "Korean History wording drifted from USER_GUIDE.md")
        XCTAssertTrue(
            ko.contains(
                "여기에는 계획된 구간만 표시되며, 어떤 구간을 수행했는지에 대한 "
                    + "기록은 아닙니다."),
            "The Korean guide must not present Planned as what was done")
        XCTAssertTrue(
            ko.contains("루틴을 내보내고 가져올 때는 구성한 구간도 함께 이동하며"),
            "Korean transfer wording drifted from USER_GUIDE.md")
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
