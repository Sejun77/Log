import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 9 — Exercise CSV **v2**.
///
/// v2 appends exactly one column, `isCardio`, to the end of the v1 order. The
/// header itself identifies the format (there is no version-marker column),
/// which is what lets a file exported by any earlier build keep importing
/// untouched. This file's two jobs are proving that old files still work and
/// that a cardio exercise survives a full export → import round-trip.
final class ExerciseCSVCardioTests: XCTestCase {

    private static let headerV1 =
        "name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes\r\n"
    private static let headerV2 =
        "name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes,isCardio\r\n"

    private func parseRows(_ text: String) -> ExerciseCSV.ParseReport {
        guard case let .success(report) = ExerciseCSV.parse(text) else {
            XCTFail("expected a successful parse")
            return .init(valid: [], skipped: [], rejected: [])
        }
        return report
    }

    // MARK: - 1. Export includes isCardio

    func testHeaderAppendsIsCardioAfterTheV1Columns() {
        XCTAssertEqual(ExerciseCSV.header.last, "isCardio")
        XCTAssertEqual(Array(ExerciseCSV.header.dropLast()), ExerciseCSV.headerV1)
        XCTAssertEqual(
            ExerciseCSV.headerV1,
            ["name", "bodyPart", "equipmentType", "setupDefaults",
             "isTimeBased", "notes"],
            "existing columns keep their order and their indices")
    }

    func testExportWritesIsCardioForACardioExercise() {
        let ex = Exercise(name: "Treadmill Run", bodyPart: "Cardio")
        ex.setTimeBased(true)
        ex.setCardio(true)

        XCTAssertEqual(
            ExerciseCSV.export(exercises: [ex]),
            Self.headerV2 + "Treadmill Run,Cardio,,,true,,true")
    }

    func testExportWritesFalseForStrengthAndTimedHold() {
        let bench = Exercise(name: "Bench")
        let plank = Exercise(name: "Plank")
        plank.setTimeBased(true)

        let csv = ExerciseCSV.export(exercises: [bench, plank])
        XCTAssertEqual(
            csv, Self.headerV2 + "Bench,,,,false,,false\r\nPlank,,,,true,,false")
    }

    // MARK: - 2/3. Old v1 files still import, defaulting isCardio to false

    func testV1HeaderIsStillAccepted() {
        XCTAssertEqual(ExerciseCSV.format(for: ExerciseCSV.headerV1), .v1)
        XCTAssertEqual(ExerciseCSV.format(for: ExerciseCSV.header), .v2)
        XCTAssertNil(ExerciseCSV.format(for: ["name", "bodyPart"]))
    }

    func testV1FileParsesAndDefaultsIsCardioToFalse() {
        let report = parseRows(
            Self.headerV1 + "Bench,Chest,Barbell,,false,note\r\n"
                + "Plank,Core,,,true,")

        XCTAssertTrue(report.rejected.isEmpty)
        XCTAssertEqual(report.valid.map(\.name), ["Bench", "Plank"])
        XCTAssertEqual(report.valid.map(\.isCardio), [false, false])
        XCTAssertEqual(report.valid.map(\.isTimeBased), [false, true])
        XCTAssertEqual(report.valid.first?.notes, "note")
    }

    /// A v1 row still has six columns, so its wrong-column-count boundary is
    /// unchanged — a v2 row pasted into a v1 file is an error, not a silent fix.
    func testV1FileRejectsASevenColumnRow() {
        let report = parseRows(Self.headerV1 + "Bench,Chest,,,false,,true")
        XCTAssertEqual(
            report.rejected.map(\.reason),
            [.wrongColumnCount(expected: 6, found: 7)])
    }

    func testV1HeaderIsAcceptedCaseInsensitivelyAndTrimmed() {
        guard case .success = ExerciseCSV.parse(
            " Name , BodyPart , EquipmentType , SetupDefaults , IsTimeBased , Notes \r\n"
                + "Bench,,,,false,")
        else { return XCTFail("expected the lenient v1 header to be accepted") }
    }

    func testV2HeaderIsAcceptedCaseInsensitivelyAndTrimmed() {
        guard case .success = ExerciseCSV.parse(
            " Name , BodyPart , EquipmentType , SetupDefaults , IsTimeBased , Notes , IsCardio \r\n"
                + "Bench,,,,false,,false")
        else { return XCTFail("expected the lenient v2 header to be accepted") }
    }

    // MARK: - 4/5. isCardio == true

    func testIsCardioTrueParsesAsCardio() {
        let report = parseRows(Self.headerV2 + "Treadmill Run,Cardio,,,true,,true")
        let row = report.valid.first
        XCTAssertEqual(row?.isCardio, true)
        XCTAssertEqual(row?.isTimeBased, true)
    }

    func testIsCardioAcceptsTheSameLenientTruthyFalsyValuesAsIsTimeBased() {
        let report = parseRows(
            Self.headerV2
                + "A,,,,true,,TRUE\r\nB,,,,true,,Yes\r\nC,,,,true,,1\r\n"
                + "D,,,,true,,false\r\nE,,,,true,,no\r\nF,,,,true,,0\r\nG,,,,true,,")
        XCTAssertEqual(
            report.valid.map(\.isCardio),
            [true, true, true, false, false, false, false])
    }

    /// Cardio implies time-based on the model, so a hand-edited row claiming
    /// cardio without time-based is normalized *up* to cardio rather than
    /// silently degraded to strength by `trackingMode`.
    func testCardioWithoutTimeBasedIsNormalizedToTimeBased() {
        let report = parseRows(Self.headerV2 + "Rower,Cardio,,,false,,true")
        let row = report.valid.first
        XCTAssertEqual(row?.isCardio, true)
        XCTAssertEqual(
            row?.isTimeBased, true, "cardio implies time-based")
    }

    func testRowInitializerAppliesTheSameNormalization() {
        let row = ExerciseCSVRow(name: "Bike", isTimeBased: false, isCardio: true)
        XCTAssertTrue(row.isTimeBased)
        XCTAssertTrue(row.isCardio)
    }

    // MARK: - 6. isCardio == false leaves timed holds alone

    func testTimedHoldStaysATimedHold() {
        let report = parseRows(Self.headerV2 + "Plank,Core,,,true,,false")
        let row = report.valid.first
        XCTAssertEqual(row?.isTimeBased, true)
        XCTAssertEqual(row?.isCardio, false, "a timed hold is not cardio")
    }

    func testStrengthRowStaysStrength() {
        let report = parseRows(Self.headerV2 + "Bench,Chest,Barbell,,false,,false")
        XCTAssertEqual(report.valid.first?.isTimeBased, false)
        XCTAssertEqual(report.valid.first?.isCardio, false)
    }

    // MARK: - Malformed isCardio

    /// Consistent with `isTimeBased`: a value we cannot read is rejected with
    /// the raw text, not reinterpreted as false.
    func testUnparseableIsCardioRejectsTheRow() {
        let report = parseRows(Self.headerV2 + "Bench,Chest,,,false,,maybe")
        XCTAssertEqual(report.rejected.map(\.reason), [.invalidIsCardio("maybe")])
        XCTAssertEqual(report.rejected.first?.row, 2)
        XCTAssertTrue(report.valid.isEmpty)
    }

    /// Someone whose file has a genuinely broken header should not conclude
    /// their pre-cardio export is unusable.
    func testHeaderMismatchMessageSaysTheOlderHeaderIsAccepted() {
        guard case let .failure(error) = ExerciseCSV.parse("name,bodyPart\r\nBench,Chest")
        else { return XCTFail("expected a header mismatch failure") }
        XCTAssertTrue(error.message.contains("isCardio"))
        XCTAssertTrue(error.message.contains("older header"))
    }

    func testInvalidIsCardioMessageMentionsTheValue() {
        XCTAssertEqual(
            ExerciseCSV.RejectReason.invalidIsCardio("maybe").message,
            "Invalid isCardio value \"maybe\" (use true or false).")
    }

    func testV2RowWithMissingIsCardioCellIsAColumnCountReject() {
        let report = parseRows(Self.headerV2 + "Bench,Chest,,,false,")
        XCTAssertEqual(
            report.rejected.map(\.reason),
            [.wrongColumnCount(expected: 7, found: 6)])
    }

    // MARK: - 7. Round trip

    func testRoundTripPreservesIsCardioAcrossAllThreeModes() {
        let bench = Exercise(name: "Bench", bodyPart: "Chest")
        let plank = Exercise(name: "Plank", bodyPart: "Core")
        plank.setTimeBased(true)
        let run = Exercise(name: "Treadmill Run", bodyPart: "Cardio")
        run.setTimeBased(true)
        run.setCardio(true)

        let exercises = [bench, plank, run]
        let report = parseRows(ExerciseCSV.export(exercises: exercises))

        XCTAssertEqual(report.valid, ExerciseCSV.rows(from: exercises))
        XCTAssertEqual(report.valid.map(\.isCardio), [false, false, true])
        XCTAssertEqual(report.valid.map(\.isTimeBased), [false, true, true])
    }
}

/// The SwiftData half of Slice 9's Exercise CSV work: what the importer
/// actually materializes. The importer goes through `setTimeBased` /
/// `setCardio` rather than assigning the flags, so no imported row can produce
/// an `Exercise` whose `trackingMode` disagrees with its stored columns.
@MainActor
final class ExerciseCSVCardioImportTests: SwiftDataTestHarness {

    private func imported(_ rows: [ExerciseCSVRow]) throws -> [Exercise] {
        ExerciseCSVImporter.importRows(rows, into: context)
        return try context.fetch(FetchDescriptor<Exercise>())
    }

    private func imported(name: String, from rows: [ExerciseCSVRow]) throws
        -> Exercise
    {
        try XCTUnwrap(try imported(rows).first { $0.name == name })
    }

    func testImportingACardioRowCreatesACardioExercise() throws {
        let ex = try imported(
            name: "Treadmill Run",
            from: [ExerciseCSVRow(
                name: "Treadmill Run", bodyPart: "Cardio", isTimeBased: true,
                isCardio: true)])

        XCTAssertTrue(ex.isCardio)
        XCTAssertTrue(ex.isTimeBased)
        XCTAssertEqual(ex.trackingMode, .cardio)
        XCTAssertTrue(ex.isCustom, "imported rows are always user data")
    }

    func testImportingCardioWithoutTimeBasedStillLandsAsCardio() throws {
        // The row initializer normalizes, and `setTimeBased`/`setCardio` on the
        // model enforce the same invariant — belt and braces.
        let ex = try imported(
            name: "Rower",
            from: [ExerciseCSVRow(name: "Rower", isTimeBased: false, isCardio: true)])

        XCTAssertEqual(ex.trackingMode, .cardio)
        XCTAssertTrue(ex.isTimeBased)
    }

    func testImportingATimedHoldDoesNotBecomeCardio() throws {
        let ex = try imported(
            name: "Plank",
            from: [ExerciseCSVRow(
                name: "Plank", bodyPart: "Core", isTimeBased: true,
                isCardio: false)])

        XCTAssertTrue(ex.isTimeBased)
        XCTAssertFalse(ex.isCardio)
        XCTAssertEqual(ex.trackingMode, .timedHold)
    }

    func testImportingAStrengthRowStaysStrength() throws {
        let ex = try imported(
            name: "Bench",
            from: [ExerciseCSVRow(name: "Bench", bodyPart: "Chest")])

        XCTAssertFalse(ex.isTimeBased)
        XCTAssertFalse(ex.isCardio)
        XCTAssertEqual(ex.trackingMode, .strength)
    }

    /// End to end: a v1 file with no `isCardio` column imports, and nothing it
    /// creates is cardio.
    func testLegacyV1FileImportsWithNothingMarkedCardio() throws {
        let text = "name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes\r\n"
            + "Bench,Chest,Barbell,,false,\r\nPlank,Core,,,true,"
        guard case let .success(report) = ExerciseCSV.parse(text) else {
            return XCTFail("a v1 file must still parse")
        }

        let result = ExerciseCSVImporter.import(report, into: context)
        XCTAssertEqual(result.insertedNames, ["Bench", "Plank"])

        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertTrue(exercises.allSatisfy { !$0.isCardio })
        XCTAssertEqual(
            try XCTUnwrap(exercises.first { $0.name == "Plank" }).trackingMode,
            .timedHold)
    }

    /// End to end: a v2 file's cardio marking survives export → import.
    func testV2FileRoundTripsCardioThroughTheImporter() throws {
        let run = Exercise(name: "Treadmill Run", bodyPart: "Cardio")
        run.setTimeBased(true)
        run.setCardio(true)
        let plank = Exercise(name: "Plank", bodyPart: "Core")
        plank.setTimeBased(true)

        guard case let .success(report) = ExerciseCSV.parse(
            ExerciseCSV.export(exercises: [run, plank]))
        else { return XCTFail("expected the v2 export to parse") }
        ExerciseCSVImporter.import(report, into: context)

        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(
            try XCTUnwrap(exercises.first { $0.name == "Treadmill Run" })
                .trackingMode, .cardio)
        XCTAssertEqual(
            try XCTUnwrap(exercises.first { $0.name == "Plank" }).trackingMode,
            .timedHold)
    }
}
