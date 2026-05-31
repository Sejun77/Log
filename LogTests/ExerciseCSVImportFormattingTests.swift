import XCTest

@testable import Log

/// Pure tests for the only extracted formatting helper in the import UI —
/// `ExerciseCSVImportButton.resultMessage(_:)`. The rest of Slice 5 is SwiftUI
/// glue verified manually.
final class ExerciseCSVImportFormattingTests: XCTestCase {

    private func report(
        inserted: Int, skipped: Int, rejected: Int
    ) -> ExerciseCSVImporter.ImportReport {
        ExerciseCSVImporter.ImportReport(
            insertedNames: (0..<inserted).map { "Ins\($0)" },
            skippedDuplicateNames: (0..<skipped).map { "Dup\($0)" },
            parseRejected: (0..<rejected).map {
                ExerciseCSV.RejectedRow(row: $0 + 2, reason: .missingName, fields: [])
            },
            parseSkipped: []
        )
    }

    func testInsertOnlyLineWithPluralization() {
        XCTAssertEqual(
            ExerciseCSVImportButton.resultMessage(report(inserted: 1, skipped: 0, rejected: 0)),
            "Added 1 exercise."
        )
        XCTAssertEqual(
            ExerciseCSVImportButton.resultMessage(report(inserted: 3, skipped: 0, rejected: 0)),
            "Added 3 exercises."
        )
    }

    func testZeroInsertsStillReportsAddedLine() {
        XCTAssertEqual(
            ExerciseCSVImportButton.resultMessage(report(inserted: 0, skipped: 0, rejected: 0)),
            "Added 0 exercises."
        )
    }

    func testDuplicateLineOnlyShownWhenNonZeroAndPluralized() {
        let msg = ExerciseCSVImportButton.resultMessage(report(inserted: 2, skipped: 1, rejected: 0))
        XCTAssertEqual(msg, "Added 2 exercises.\nSkipped 1 duplicate name.")

        let msg2 = ExerciseCSVImportButton.resultMessage(report(inserted: 2, skipped: 3, rejected: 0))
        XCTAssertTrue(msg2.contains("Skipped 3 duplicate names."))
    }

    func testRejectedLineOnlyShownWhenNonZeroAndPluralized() {
        let msg = ExerciseCSVImportButton.resultMessage(report(inserted: 0, skipped: 0, rejected: 1))
        XCTAssertEqual(msg, "Added 0 exercises.\nIgnored 1 invalid row.")

        let msg2 = ExerciseCSVImportButton.resultMessage(report(inserted: 0, skipped: 0, rejected: 4))
        XCTAssertTrue(msg2.contains("Ignored 4 invalid rows."))
    }

    func testAllThreeLinesTogether() {
        XCTAssertEqual(
            ExerciseCSVImportButton.resultMessage(report(inserted: 5, skipped: 2, rejected: 3)),
            "Added 5 exercises.\nSkipped 2 duplicate names.\nIgnored 3 invalid rows."
        )
    }
}
