import XCTest

@testable import Log

/// Pure tests for the `exercises.csv` parser / validator / exporter. No
/// SwiftData harness — the layer is value-in / value-out (the DB dedupe +
/// insert behavior is a later slice).
final class ExerciseCSVTests: XCTestCase {

    // MARK: - export

    func testExportEmitsHeaderThenOneRecordPerRow() {
        let csv = ExerciseCSV.export([
            ExerciseCSVRow(name: "Bench", bodyPart: "Chest", equipmentType: "Barbell"),
        ])
        XCTAssertEqual(
            csv,
            "name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes\r\n"
                + "Bench,Chest,Barbell,,false,"
        )
    }

    func testExportWritesNilOptionalsAsEmptyAndBoolAsTrueFalse() {
        let csv = ExerciseCSV.export([
            ExerciseCSVRow(name: "Plank", isTimeBased: true),
        ])
        XCTAssertEqual(
            csv,
            "name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes\r\n"
                + "Plank,,,,true,"
        )
    }

    func testExportQuotesFieldsNeedingEscaping() {
        let csv = ExerciseCSV.export([
            ExerciseCSVRow(name: "Row, Bent", notes: "say \"go\""),
        ])
        XCTAssertTrue(csv.contains("\"Row, Bent\""))
        XCTAssertTrue(csv.contains("\"say \"\"go\"\"\""))
    }

    func testEmptyExportIsHeaderOnly() {
        XCTAssertEqual(
            ExerciseCSV.export([]),
            "name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes"
        )
    }

    // MARK: - round trip

    func testExportThenParseRecoversValidRows() {
        let rows = [
            ExerciseCSVRow(
                name: "Bench", bodyPart: "Chest", equipmentType: "Barbell",
                setupDefaults: "Arch, feet planted", isTimeBased: false,
                notes: "say \"go\""
            ),
            ExerciseCSVRow(name: "Plank", bodyPart: "Core", isTimeBased: true),
        ]
        guard case let .success(report) = ExerciseCSV.parse(ExerciseCSV.export(rows)) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(report.valid, rows)
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(report.rejected.isEmpty)
    }

    // MARK: - header validation (whole-file failure)

    func testParseEmptyFileFailsWithEmptyHeaderError() {
        XCTAssertEqual(ExerciseCSV.parse(""), .failure(.empty))
    }

    func testParseHeaderOnlyYieldsEmptyButValidReport() {
        guard case let .success(report) = ExerciseCSV.parse(
            "name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes"
        ) else { return XCTFail("expected success") }
        XCTAssertEqual(report, .init(valid: [], skipped: [], rejected: []))
    }

    func testParseAcceptsHeaderCaseInsensitivelyAndTrimmed() {
        guard case .success = ExerciseCSV.parse(
            " Name , BodyPart , EquipmentType , SetupDefaults , isTimeBased , Notes \r\nBench,,,,false,"
        ) else { return XCTFail("expected success with lenient header") }
    }

    func testParseRejectsWrongColumnHeader() {
        let result = ExerciseCSV.parse("name,bodyPart\r\nBench,Chest")
        guard case let .failure(err) = result, case .mismatch = err else {
            return XCTFail("expected header mismatch failure")
        }
    }

    func testParseRejectsReorderedHeader() {
        let result = ExerciseCSV.parse(
            "bodyPart,name,equipmentType,setupDefaults,isTimeBased,notes\r\nChest,Bench,,,,"
        )
        guard case .failure(.mismatch) = result else {
            return XCTFail("expected header mismatch on reordered columns")
        }
    }

    // MARK: - row partitioning

    private static let header =
        "name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes\r\n"

    private func parseDataRows(_ body: String) -> ExerciseCSV.ParseReport {
        guard case let .success(report) = ExerciseCSV.parse(Self.header + body) else {
            XCTFail("expected success")
            return .init(valid: [], skipped: [], rejected: [])
        }
        return report
    }

    func testBlankAndAllCommaRowsAreSkippedAsEmpty() {
        let report = parseDataRows("\nBench,,,,false,\n,,,,,")
        XCTAssertEqual(report.valid.map(\.name), ["Bench"])
        XCTAssertEqual(report.skipped.map(\.reason), [.emptyRow, .emptyRow])
        // Blank line is row 2, the valid Bench row is 3, the all-comma row is 4.
        XCTAssertEqual(report.skipped.map(\.row), [2, 4])
    }

    func testWrongColumnCountIsRejected() {
        let report = parseDataRows("Bench,Chest,Barbell")
        XCTAssertEqual(
            report.rejected.map(\.reason),
            [.wrongColumnCount(expected: 6, found: 3)]
        )
        XCTAssertEqual(report.rejected.first?.row, 2)
    }

    func testMissingNameIsRejected() {
        let report = parseDataRows("   ,Chest,Barbell,,false,note")
        XCTAssertEqual(report.rejected.map(\.reason), [.missingName])
    }

    func testInvalidIsTimeBasedIsRejectedWithRawValue() {
        let report = parseDataRows("Bench,Chest,Barbell,,maybe,")
        XCTAssertEqual(
            report.rejected.map(\.reason),
            [.invalidIsTimeBased("maybe")]
        )
    }

    func testIsTimeBasedAcceptsLenientTruthyFalsyAndEmpty() {
        let report = parseDataRows(
            "A,,,,TRUE,\nB,,,,Yes,\nC,,,,1,\nD,,,,false,\nE,,,,no,\nF,,,,0,\nG,,,,,"
        )
        XCTAssertEqual(
            report.valid.map(\.isTimeBased),
            [true, true, true, false, false, false, false]
        )
    }

    func testInFileDuplicateNameIsSkippedKeepingFirstCaseInsensitive() {
        let report = parseDataRows("Bench,Chest,,,false,\nBENCH,Back,,,true,")
        XCTAssertEqual(report.valid.count, 1)
        XCTAssertEqual(report.valid.first?.bodyPart, "Chest")  // first kept
        XCTAssertEqual(
            report.skipped.map(\.reason),
            [.duplicateNameInFile("BENCH")]
        )
    }

    func testNonCanonicalBodyPartIsAcceptedSoftValidation() {
        let report = parseDataRows("Bench,Forearms,Anvil,,false,")
        XCTAssertEqual(report.valid.first?.bodyPart, "Forearms")
        XCTAssertEqual(report.valid.first?.equipmentType, "Anvil")
        XCTAssertTrue(report.rejected.isEmpty)
    }

    func testFieldsAreTrimmedAndEmptyOptionalsBecomeNil() {
        let report = parseDataRows("  Bench  , Chest ,,, false , ")
        let row = report.valid.first
        XCTAssertEqual(row?.name, "Bench")
        XCTAssertEqual(row?.bodyPart, "Chest")
        XCTAssertNil(row?.equipmentType)
        XCTAssertNil(row?.setupDefaults)
        XCTAssertNil(row?.notes)
        XCTAssertEqual(row?.isTimeBased, false)
    }

    func testMixedFilePartitionsValidSkippedAndRejectedTogether() {
        let report = parseDataRows(
            "Bench,Chest,,,false,\n"      // row 2 valid
                + ",,,,,\n"                // row 3 skipped (empty)
                + "Squat,Quads,bad\n"      // row 4 rejected (column count)
                + "Bench,Back,,,true,\n"   // row 5 skipped (duplicate)
                + "Plank,Core,,,true,"     // row 6 valid
        )
        XCTAssertEqual(report.valid.map(\.name), ["Bench", "Plank"])
        XCTAssertEqual(report.skipped.map(\.row), [3, 5])
        XCTAssertEqual(report.rejected.map(\.row), [4])
    }
}
