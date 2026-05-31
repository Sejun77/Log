import SwiftData
import XCTest

@testable import Log

/// SwiftData coverage for `ExerciseCSVImporter` (CSV Slice 4): additive insert
/// of new rows as user data, case-insensitive dedupe, order append, and the
/// data-safety guarantees (no mutation of existing rows; routines/workouts/
/// history untouched).
@MainActor
final class ExerciseCSVImporterTests: SwiftDataTestHarness {

    private func allExercises() throws -> [Exercise] {
        try context.fetch(FetchDescriptor<Exercise>())
    }

    private func row(
        _ name: String, bodyPart: String? = nil, equipmentType: String? = nil,
        setupDefaults: String? = nil, isTimeBased: Bool = false, notes: String? = nil
    ) -> ExerciseCSVRow {
        ExerciseCSVRow(
            name: name, bodyPart: bodyPart, equipmentType: equipmentType,
            setupDefaults: setupDefaults, isTimeBased: isTimeBased, notes: notes
        )
    }

    // MARK: - Inserts new exercises

    func testImportsNewExercises() throws {
        let report = ExerciseCSVImporter.importRows(
            [row("Bench"), row("Squat"), row("Deadlift")], into: context
        )
        XCTAssertEqual(report.insertedCount, 3)
        XCTAssertEqual(Set(report.insertedNames), ["Bench", "Squat", "Deadlift"])
        XCTAssertEqual(try allExercises().count, 3)
    }

    func testImportedRowsAreCustomUserData() throws {
        ExerciseCSVImporter.importRows([row("Bench")], into: context)
        let ex = try XCTUnwrap(try allExercises().first)
        XCTAssertTrue(ex.isCustom)
    }

    // MARK: - Order

    func testOrderAppendsAfterExistingMax() throws {
        let pre = Exercise(name: "Existing"); pre.order = 7
        context.insert(pre)
        try context.save()

        ExerciseCSVImporter.importRows([row("Bench"), row("Squat")], into: context)

        let inserted = try allExercises().filter { $0.name != "Existing" }
        XCTAssertEqual(Set(inserted.map(\.order)), [8, 9])
        // No collision with the existing row's order.
        XCTAssertEqual(Set(try allExercises().map(\.order)).count, 3)
    }

    func testOrderStartsAtZeroOnEmptyStore() throws {
        ExerciseCSVImporter.importRows([row("Bench"), row("Squat")], into: context)
        XCTAssertEqual(Set(try allExercises().map(\.order)), [0, 1])
    }

    // MARK: - Duplicate handling

    func testDuplicateNameSkippedCaseInsensitively() throws {
        let pre = Exercise(name: "bench press", isCustom: true)
        context.insert(pre)
        try context.save()

        let report = ExerciseCSVImporter.importRows(
            [row("Bench Press", bodyPart: "Chest"), row("Squat")], into: context
        )
        XCTAssertEqual(report.insertedNames, ["Squat"])
        XCTAssertEqual(report.skippedDuplicateNames, ["Bench Press"])
        // Only one row with that name still exists.
        XCTAssertEqual(
            try allExercises().filter { $0.name.lowercased() == "bench press" }.count, 1
        )
    }

    func testInBatchDuplicateInsertsOnlyOnce() throws {
        let report = ExerciseCSVImporter.importRows(
            [row("Bench"), row("BENCH"), row("bench")], into: context
        )
        XCTAssertEqual(report.insertedNames, ["Bench"])
        XCTAssertEqual(report.skippedDuplicateNames, ["BENCH", "bench"])
        XCTAssertEqual(try allExercises().count, 1)
    }

    func testExistingExerciseNotMutated() throws {
        let pre = Exercise(
            name: "Bench", bodyPart: "Pecs", notes: "mine",
            equipmentType: nil, setupDefaults: "custom", isCustom: true
        )
        pre.order = 3
        context.insert(pre)
        try context.save()

        ExerciseCSVImporter.importRows(
            [row("bench", bodyPart: "Chest", equipmentType: "Barbell", notes: "csv")],
            into: context
        )

        let matches = try allExercises().filter { $0.name.lowercased() == "bench" }
        XCTAssertEqual(matches.count, 1)
        let preserved = try XCTUnwrap(matches.first)
        XCTAssertEqual(preserved.name, "Bench")
        XCTAssertEqual(preserved.bodyPart, "Pecs")
        XCTAssertEqual(preserved.notes, "mine")
        XCTAssertNil(preserved.equipmentType)
        XCTAssertEqual(preserved.setupDefaults, "custom")
        XCTAssertEqual(preserved.order, 3)
        XCTAssertTrue(preserved.isCustom)
    }

    // MARK: - Field fidelity

    func testOptionalFieldsImportedCorrectly() throws {
        ExerciseCSVImporter.importRows([
            row("Plank", bodyPart: "Core", equipmentType: "Bodyweight",
                setupDefaults: "elbows under shoulders", isTimeBased: true,
                notes: "neutral spine"),
        ], into: context)

        let ex = try XCTUnwrap(try allExercises().first)
        XCTAssertEqual(ex.bodyPart, "Core")
        XCTAssertEqual(ex.equipmentType, "Bodyweight")
        XCTAssertEqual(ex.setupDefaults, "elbows under shoulders")
        XCTAssertEqual(ex.notes, "neutral spine")
        XCTAssertTrue(ex.isTimeBased)
    }

    func testEmptyOptionalFieldsRemainNil() throws {
        ExerciseCSVImporter.importRows([row("Bench")], into: context)
        let ex = try XCTUnwrap(try allExercises().first)
        XCTAssertNil(ex.bodyPart)
        XCTAssertNil(ex.equipmentType)
        XCTAssertNil(ex.setupDefaults)
        XCTAssertNil(ex.notes)
        XCTAssertFalse(ex.isTimeBased)
    }

    func testNonCanonicalBodyPartAndEquipmentAccepted() throws {
        ExerciseCSVImporter.importRows(
            [row("Wrist Curl", bodyPart: "Forearms", equipmentType: "Anvil")],
            into: context
        )
        let ex = try XCTUnwrap(try allExercises().first)
        XCTAssertEqual(ex.bodyPart, "Forearms")
        XCTAssertEqual(ex.equipmentType, "Anvil")
    }

    // MARK: - ParseReport entry point

    func testImportFromParseReportInsertsOnlyValidAndCarriesRejectedSkipped() throws {
        let csv = """
        name,bodyPart,equipmentType,setupDefaults,isTimeBased,notes
        Bench,Chest,Barbell,,false,
        ,Chest,,,false,
        Squat,Quads,bad
        Bench,Back,,,true,
        Plank,Core,,,true,
        """
        guard case let .success(parsed) = ExerciseCSV.parse(csv) else {
            return XCTFail("expected parse success")
        }

        let report = ExerciseCSVImporter.import(parsed, into: context)

        XCTAssertEqual(Set(report.insertedNames), ["Bench", "Plank"])
        XCTAssertEqual(report.parseRejected.count, 2)   // missing name + wrong column count
        XCTAssertEqual(report.parseSkipped.count, 1)    // in-file duplicate Bench
        XCTAssertEqual(try allExercises().count, 2)
    }

    // MARK: - No-op cases

    func testAllDuplicateImportCreatesNoRows() throws {
        let pre = Exercise(name: "Bench", isCustom: true)
        context.insert(pre)
        try context.save()

        let report = ExerciseCSVImporter.importRows([row("bench"), row("BENCH")], into: context)
        XCTAssertEqual(report.insertedCount, 0)
        XCTAssertEqual(try allExercises().count, 1)
    }

    func testEmptyInputCreatesNoRows() throws {
        let report = ExerciseCSVImporter.importRows([], into: context)
        XCTAssertEqual(report.insertedCount, 0)
        XCTAssertEqual(try allExercises().count, 0)
    }

    func testBlankNameRowsAreSkippedDefensively() throws {
        let report = ExerciseCSVImporter.importRows(
            [row("   "), row("Bench")], into: context
        )
        XCTAssertEqual(report.insertedNames, ["Bench"])
        XCTAssertEqual(try allExercises().count, 1)
    }

    // MARK: - Atomic batch / mixed

    func testMixedBatchInsertsOnlyNewRows() throws {
        let pre = Exercise(name: "Squat", isCustom: true)
        context.insert(pre)
        try context.save()

        let report = ExerciseCSVImporter.importRows(
            [row("Bench"), row("squat"), row("Deadlift")], into: context
        )
        XCTAssertEqual(Set(report.insertedNames), ["Bench", "Deadlift"])
        XCTAssertEqual(report.skippedDuplicateNames, ["squat"])
        XCTAssertEqual(try allExercises().count, 3)  // Squat + Bench + Deadlift
    }

    // MARK: - Data safety: other entities untouched

    func testRoutinesWorkoutsAndHistoryUntouched() throws {
        // Seed one routine and one completed workout with a set log.
        let ex = Exercise(name: "Bench", isCustom: true)
        context.insert(ex)
        let routine = Routine(name: "Push A", blocks: [])
        context.insert(routine)
        let log = SetLog(indexInExercise: 0, reps: 5, weight: 100)
        let item = WorkoutItem(exercise: ex, setLogs: [log])
        let workout = Workout(items: [item])
        context.insert(workout)
        try context.save()

        let routinesBefore = try context.fetch(FetchDescriptor<Routine>()).count
        let workoutsBefore = try context.fetch(FetchDescriptor<Workout>()).count
        let itemsBefore = try context.fetch(FetchDescriptor<WorkoutItem>()).count
        let logsBefore = try context.fetch(FetchDescriptor<SetLog>()).count

        ExerciseCSVImporter.importRows(
            [row("Squat"), row("bench")], into: context
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<Routine>()).count, routinesBefore)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, workoutsBefore)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutItem>()).count, itemsBefore)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SetLog>()).count, logsBefore)
        // The collided "Bench" was not duplicated; only "Squat" added.
        XCTAssertEqual(try allExercises().count, 2)
    }
}
