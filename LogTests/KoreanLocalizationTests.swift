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
}
