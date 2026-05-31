import XCTest

@testable import Log

/// Tests for the `Exercise` → `exercises.csv` projection (CSV Slice 2). The
/// mapping is pure: `Exercise` model instances are constructed directly (no
/// `ModelContext`) and only their stored properties are read.
final class ExerciseCSVExportTests: XCTestCase {

    // MARK: - rows(from:)

    func testRowsMapAllSixDefinitionFields() {
        let ex = Exercise(
            name: "Bench",
            bodyPart: "Chest",
            notes: "Keep elbows tucked",
            equipmentType: "Barbell",
            setupDefaults: "Arch, feet planted"
        )
        ex.isTimeBased = false

        XCTAssertEqual(
            ExerciseCSV.rows(from: [ex]),
            [ExerciseCSVRow(
                name: "Bench", bodyPart: "Chest", equipmentType: "Barbell",
                setupDefaults: "Arch, feet planted", isTimeBased: false,
                notes: "Keep elbows tucked"
            )]
        )
    }

    func testRowsPreserveGivenOrderAndIgnoreModelOrderField() {
        // `order` / `isCustom` must not influence the projection or sequence.
        let a = Exercise(name: "A", isCustom: false); a.order = 99
        let b = Exercise(name: "B", isCustom: true);  b.order = 1
        XCTAssertEqual(ExerciseCSV.rows(from: [a, b]).map(\.name), ["A", "B"])
    }

    func testRowsNormalizeEmptyAndWhitespaceOptionalsToNil() {
        let ex = Exercise(
            name: "Plank", bodyPart: "  ", notes: "",
            equipmentType: nil, setupDefaults: "   "
        )
        let row = ExerciseCSV.rows(from: [ex]).first
        XCTAssertNil(row?.bodyPart)
        XCTAssertNil(row?.equipmentType)
        XCTAssertNil(row?.setupDefaults)
        XCTAssertNil(row?.notes)
    }

    func testRowsCarryTimeBasedFlag() {
        let ex = Exercise(name: "Plank", bodyPart: "Core", equipmentType: "Bodyweight")
        ex.isTimeBased = true
        XCTAssertEqual(ExerciseCSV.rows(from: [ex]).first?.isTimeBased, true)
    }

    // MARK: - export(exercises:)

    func testExportExercisesEmitsCanonicalHeaderThenRecords() {
        let ex = Exercise(name: "Bench", bodyPart: "Chest", equipmentType: "Barbell")
        XCTAssertEqual(
            ExerciseCSV.export(exercises: [ex]),
            "name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes\r\n"
                + "Bench,Chest,Barbell,,false,"
        )
    }

    func testExportExercisesEmptyIsHeaderOnly() {
        XCTAssertEqual(
            ExerciseCSV.export(exercises: []),
            "name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes"
        )
    }

    func testExportExercisesQuotesCommasQuotesAndNewlines() {
        let ex = Exercise(
            name: "Row, Bent",
            bodyPart: "Back",
            notes: "line1\nline2",
            equipmentType: "say \"go\""
        )
        let csv = ExerciseCSV.export(exercises: [ex])
        XCTAssertTrue(csv.contains("\"Row, Bent\""))
        XCTAssertTrue(csv.contains("\"say \"\"go\"\"\""))
        XCTAssertTrue(csv.contains("\"line1\nline2\""))
    }

    func testExportExercisesWritesTimeBasedExerciseAsTrue() {
        let ex = Exercise(name: "Plank", bodyPart: "Core", equipmentType: "Bodyweight")
        ex.isTimeBased = true
        XCTAssertTrue(
            ExerciseCSV.export(exercises: [ex]).hasSuffix("Plank,Core,Bodyweight,,true,")
        )
    }

    // MARK: - round trip through the parser

    func testExportExercisesRoundTripsThroughParseToSameRows() {
        let bench = Exercise(
            name: "Bench", bodyPart: "Chest", notes: "say \"go\"",
            equipmentType: "Barbell", setupDefaults: "Arch, feet planted"
        )
        let plank = Exercise(name: "Plank", bodyPart: "Core", equipmentType: "Bodyweight")
        plank.isTimeBased = true
        let exs: [Exercise] = [bench, plank]
        let expectedRows = ExerciseCSV.rows(from: exs)
        guard case let .success(report) = ExerciseCSV.parse(
            ExerciseCSV.export(exercises: exs)
        ) else { return XCTFail("expected success") }
        XCTAssertEqual(report.valid, expectedRows)
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(report.rejected.isEmpty)
    }
}
