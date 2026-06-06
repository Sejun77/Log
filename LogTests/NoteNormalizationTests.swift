import XCTest

@testable import Log

/// Slice 1 — `normalizedOptionalNote(_:)` is the pure helper that backs the
/// local-draft session-notes / exercise-notes editors (active workout). It
/// pins the exact clear/trim contract the old inline bindings produced:
///   - empty or whitespace/newline-only input → nil (clears the note)
///   - non-empty input → the **original, untrimmed** text (leading/trailing
///     whitespace inside an otherwise non-blank note is preserved verbatim)
final class NoteNormalizationTests: XCTestCase {

    func testEmptyStringIsNil() {
        XCTAssertNil(normalizedOptionalNote(""))
    }

    func testWhitespaceOnlyIsNil() {
        XCTAssertNil(normalizedOptionalNote("   "))
    }

    func testNewlinesAndTabsOnlyIsNil() {
        XCTAssertNil(normalizedOptionalNote("\n\t \n"))
    }

    func testNonEmptyPreservesOriginalText() {
        XCTAssertEqual(normalizedOptionalNote("Felt strong today"), "Felt strong today")
    }

    func testNonEmptyPreservesSurroundingWhitespaceVerbatim() {
        // Trim only decides emptiness; a non-blank note keeps its exact text.
        XCTAssertEqual(normalizedOptionalNote("  keep spaces  "), "  keep spaces  ")
    }

    func testInteriorNewlinesPreserved() {
        XCTAssertEqual(normalizedOptionalNote("line 1\nline 2"), "line 1\nline 2")
    }
}
