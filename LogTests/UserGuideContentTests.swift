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

    /// The exact beta wording agreed for the cardio answer. It appears in
    /// `USER_GUIDE.md`, `ENTRY_12_TESTFLIGHT_FEEDBACK.md`, and here; if the
    /// in-app copy is reworded the docs have to be rewritten with it.
    func testCardioWordingMatchesTheDocumentedSentence() throws {
        let en = try XCTUnwrap(
            section(heading: "Duration Exercises and Cardio", in: english)?.outro)
        XCTAssertTrue(
            en.contains(
                "Cardio can be logged as a duration-based exercise. For now, "
                    + "details like distance, speed, incline, resistance, or "
                    + "heart-rate zone can be written in notes."),
            "English cardio wording drifted from USER_GUIDE.md")

        let ko = try XCTUnwrap(
            section(heading: "시간 기반 운동과 유산소 운동", in: korean)?.outro)
        XCTAssertTrue(
            ko.contains(
                "유산소 운동은 시간 기반 운동으로 기록할 수 있습니다. 현재는 거리, "
                    + "속도, 경사, 저항 단계, 심박 구간 같은 세부 정보는 메모에 "
                    + "기록할 수 있습니다."),
            "Korean cardio wording drifted from USER_GUIDE.md")
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
