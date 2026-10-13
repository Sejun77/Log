import XCTest

@testable import Log

/// Pure tests for the routine-JSON import helper logic that the Slice-D UI
/// depends on: `RoutineTransfer.preview` (no-insert projection) and the
/// `RoutineJSONImportButton` result / error message formatting. No SwiftData —
/// value-in / value-out.
@MainActor
final class RoutineJSONImportFormattingTests: XCTestCase {

    // MARK: - DTO builders

    private func slot(_ name: String, order: Int = 0) -> RoutineTransferSlotDTO {
        RoutineTransferSlotDTO(
            order: order, exerciseName: name, exerciseBodyPart: nil,
            exerciseEquipmentType: nil, exerciseIsTimeBased: nil,
            templateNotes: nil, setTemplates: [], prescription: nil)
    }

    private func block(_ order: Int, _ slots: [RoutineTransferSlotDTO])
        -> RoutineTransferBlockDTO
    {
        RoutineTransferBlockDTO(
            order: order, isSuperset: false, restAfterSeconds: nil,
            supersetRoundRestSeconds: nil, slots: slots)
    }

    private func doc(_ name: String, _ blocks: [RoutineTransferBlockDTO])
        -> RoutineTransferDocument
    {
        RoutineTransferDocument(
            routine: RoutineTransferRoutineDTO(
                name: name, notes: nil, blocks: blocks))
    }

    // MARK: - preview()

    func testPreviewCountsMatchedCreatedAndStructure() {
        let d = doc("Push", [
            block(0, [slot("Bench", order: 0), slot("Fly", order: 1)]),
            block(1, [slot("Plank")]),
        ])
        let p = RoutineTransfer.preview(d, existingExerciseNames: ["Bench"])

        XCTAssertEqual(p.sourceRoutineName, "Push")
        XCTAssertEqual(p.blockCount, 2)
        XCTAssertEqual(p.slotCount, 3)
        XCTAssertEqual(p.matchedExerciseNames, ["Bench"])
        XCTAssertEqual(p.createdExerciseNames, ["Fly", "Plank"])
        XCTAssertEqual(p.skippedSlotCount, 0)
    }

    func testPreviewMatchesCaseInsensitivelyAndReportsExistingDisplayName() {
        let d = doc("R", [block(0, [slot("  bench  ")])])
        let p = RoutineTransfer.preview(d, existingExerciseNames: ["Bench"])
        XCTAssertEqual(p.matchedExerciseNames, ["Bench"])  // existing display name
        XCTAssertTrue(p.createdExerciseNames.isEmpty)
    }

    func testPreviewDedupesCreatedAcrossBlocks() {
        let d = doc("R", [
            block(0, [slot("NewEx", order: 0)]),
            block(1, [slot("newex", order: 0)]),
        ])
        let p = RoutineTransfer.preview(d, existingExerciseNames: [])
        XCTAssertEqual(p.createdExerciseNames, ["NewEx"])
        XCTAssertEqual(p.slotCount, 2)
    }

    func testPreviewSkipsEmptyNamesAndDropsEmptyBlocks() {
        let d = doc("R", [
            block(0, [slot("", order: 0), slot("Bench", order: 1)]),
            block(1, [slot("   ")]),  // all-empty → dropped
        ])
        let p = RoutineTransfer.preview(d, existingExerciseNames: [])
        XCTAssertEqual(p.skippedSlotCount, 2)
        XCTAssertEqual(p.blockCount, 1)
        XCTAssertEqual(p.slotCount, 1)
        XCTAssertEqual(p.createdExerciseNames, ["Bench"])
    }

    // MARK: - resultMessage()

    func testResultMessageFull() {
        var r = RoutineTransfer.ImportReport()
        r.importedRoutineName = "Push A"
        r.blockCount = 2
        r.slotCount = 3
        r.createdExerciseNames = ["Fly", "Plank"]
        r.matchedExerciseNames = ["Bench"]
        r.skippedSlotCount = 1

        let msg = RoutineJSONImportButton.resultMessage(r)
        XCTAssertTrue(msg.contains("Imported “Push A”."))
        XCTAssertTrue(msg.contains("3 exercises."))
        XCTAssertTrue(msg.contains("Created 2 new exercises."))
        XCTAssertTrue(msg.contains("Linked 1 existing exercise."))   // singular
        XCTAssertTrue(msg.contains("Skipped 1 exercise with no name."))
    }

    func testResultMessageMinimalSingulars() {
        var r = RoutineTransfer.ImportReport()
        r.importedRoutineName = "R"
        r.blockCount = 1
        r.slotCount = 1
        let msg = RoutineJSONImportButton.resultMessage(r)
        XCTAssertTrue(msg.contains("1 exercise."))
        XCTAssertFalse(msg.contains("Created"))
        XCTAssertFalse(msg.contains("Linked"))
        XCTAssertFalse(msg.contains("Skipped"))
    }

    // MARK: - errorMessage()

    func testErrorMessageUnsupportedVersion() {
        let msg = RoutineJSONImportButton.errorMessage(
            RoutineTransferError.unsupportedSchemaVersion(found: 2, supported: 1))
        XCTAssertTrue(msg.contains("newer version"))
    }

    func testErrorMessageDecodingError() {
        var captured: Error?
        do {
            _ = try JSONDecoder().decode(
                RoutineTransferDocument.self, from: Data("{}".utf8))
        } catch {
            captured = error
        }
        XCTAssertTrue(captured is DecodingError)
        let msg = RoutineJSONImportButton.errorMessage(captured!)
        XCTAssertTrue(msg.contains("valid routine JSON"))
    }

    // MARK: - skippedPreviewMessage()

    /// The preview footer counts the same thing the result alert does, so the
    /// two must agree on what an entry with no exercise name is called.
    func testSkippedPreviewMessageSingularAndPlural() {
        XCTAssertEqual(
            RoutineJSONImportButton.skippedPreviewMessage(1),
            "1 exercise has no name and will be skipped.")
        XCTAssertEqual(
            RoutineJSONImportButton.skippedPreviewMessage(3),
            "3 exercises have no name and will be skipped.")
    }

    /// The import copy counts exercises, never the internal block grouping —
    /// a two-superset routine and a six-single-exercise routine both import
    /// "6 exercises."
    func testResultMessageCountsExercisesNotBlocks() {
        var r = RoutineTransfer.ImportReport()
        r.importedRoutineName = "Push A"
        r.blockCount = 2
        r.slotCount = 6

        let msg = RoutineJSONImportButton.resultMessage(r)
        XCTAssertTrue(msg.contains("6 exercises."))
        XCTAssertFalse(msg.lowercased().contains("block"))
        XCTAssertFalse(msg.lowercased().contains("slot"))
    }
}
