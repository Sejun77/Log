import XCTest

@testable import Log

/// Pure tests for the RFC 4180 `CSVCodec`. No SwiftData harness — the codec is
/// value-in / value-out.
final class CSVCodecTests: XCTestCase {

    // MARK: - encode

    func testEncodeSimpleGridUsesCRLFBetweenRowsNoTrailingNewline() {
        let out = CSVCodec.encode([["a", "b"], ["c", "d"]])
        XCTAssertEqual(out, "a,b\r\nc,d")
    }

    func testEncodeQuotesFieldsContainingDelimiterQuoteOrNewline() {
        XCTAssertEqual(CSVCodec.encode([["a,b"]]), "\"a,b\"")
        XCTAssertEqual(CSVCodec.encode([["say \"hi\""]]), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVCodec.encode([["line1\nline2"]]), "\"line1\nline2\"")
        XCTAssertEqual(CSVCodec.encode([["has\rCR"]]), "\"has\rCR\"")
    }

    func testEncodeLeavesPlainFieldsUnquotedIncludingSurroundingSpaces() {
        // Leading/trailing spaces are preserved verbatim, not quoted.
        XCTAssertEqual(CSVCodec.encode([["  padded  ", "plain"]]), "  padded  ,plain")
    }

    // MARK: - parse basics

    func testParseEmptyStringYieldsNoRows() {
        XCTAssertEqual(CSVCodec.parse(""), [])
    }

    func testParseSimpleRows() {
        XCTAssertEqual(CSVCodec.parse("a,b\r\nc,d"), [["a", "b"], ["c", "d"]])
    }

    func testParseAcceptsLFAndLoneCRAndCRLFRowBreaks() {
        XCTAssertEqual(CSVCodec.parse("a,b\nc,d"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(CSVCodec.parse("a,b\rc,d"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(CSVCodec.parse("a,b\r\nc,d"), [["a", "b"], ["c", "d"]])
    }

    func testParseTrailingNewlineDoesNotCreateEmptyRow() {
        XCTAssertEqual(CSVCodec.parse("a,b\r\n"), [["a", "b"]])
        XCTAssertEqual(CSVCodec.parse("a,b\n"), [["a", "b"]])
    }

    func testParseBlankLineYieldsSingleEmptyField() {
        // A blank middle line becomes a one-element [""] record.
        XCTAssertEqual(CSVCodec.parse("a\n\nb"), [["a"], [""], ["b"]])
    }

    func testParseTrailingCommaProducesTrailingEmptyField() {
        XCTAssertEqual(CSVCodec.parse("a,"), [["a", ""]])
    }

    func testParseLeadingCommaProducesLeadingEmptyField() {
        XCTAssertEqual(CSVCodec.parse(",a"), [["", "a"]])
    }

    // MARK: - parse quoting

    func testParseQuotedFieldWithEmbeddedComma() {
        XCTAssertEqual(CSVCodec.parse("\"a,b\",c"), [["a,b", "c"]])
    }

    func testParseQuotedFieldWithDoubledQuoteEscape() {
        XCTAssertEqual(CSVCodec.parse("\"say \"\"hi\"\"\""), [["say \"hi\""]])
    }

    func testParseQuotedFieldWithEmbeddedNewlineStaysOneField() {
        XCTAssertEqual(CSVCodec.parse("\"line1\r\nline2\",c"), [["line1\r\nline2", "c"]])
    }

    func testParseQuotedEmptyFieldIsOneEmptyField() {
        XCTAssertEqual(CSVCodec.parse("\"\""), [[""]])
    }

    func testParseStripsLeadingBOM() {
        XCTAssertEqual(CSVCodec.parse("\u{FEFF}a,b"), [["a", "b"]])
    }

    // MARK: - round trip

    func testRoundTripPreservesTrickyFields() {
        let grid = [
            ["name", "notes"],
            ["a,b", "say \"hi\""],
            ["multi\nline", "  spaced  "],
            ["", "plain"],
        ]
        XCTAssertEqual(CSVCodec.parse(CSVCodec.encode(grid)), grid)
    }
}
