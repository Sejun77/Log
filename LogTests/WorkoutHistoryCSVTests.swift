import XCTest

@testable import Log

/// Tests for the denormalized `workout_history.csv` exporter (CSV Slice 3).
/// Pure: `Workout` / `WorkoutItem` / `SetLog` are constructed directly (no
/// `ModelContext`) and only stored properties are read. Exported text is parsed
/// back through `CSVCodec` so cell assertions are escaping-robust.
final class WorkoutHistoryCSVTests: XCTestCase {

    // MARK: - Fixtures

    /// epoch 0 → ISO-8601 "1970-01-01T00:00:00Z" (GMT, deterministic).
    private let epoch0 = Date(timeIntervalSince1970: 0)
    private let iso0 = "1970-01-01T00:00:00Z"

    private func makeLog(
        index: Int, kind: SetKind = .working, reps: Int = 8,
        weight: Double? = nil, rest: Int? = nil, duration: Int? = nil,
        sub: Int? = nil, at ts: Date = Date(timeIntervalSince1970: 0)
    ) -> SetLog {
        SetLog(
            indexInExercise: index, kind: kind, reps: reps, weight: weight,
            restSeconds: rest, timestamp: ts, durationSeconds: duration, subIndex: sub
        )
    }

    private func makeItem(
        name: String, blockOrder: Int? = nil, logs: [SetLog]
    ) -> WorkoutItem {
        let item = WorkoutItem(exercise: Exercise(name: name), setLogs: logs)
        item.sourceBlockOrder = blockOrder
        return item
    }

    private func makeWorkout(
        date: Date = Date(timeIntervalSince1970: 0), completedAt: Date? = nil,
        routineName: String? = nil, notes: String? = nil, items: [WorkoutItem]
    ) -> Workout {
        // `Workout.init` has no `completedAt` parameter (it's set post-completion),
        // so apply it after construction.
        let w = Workout(
            date: date, routineName: routineName, items: items, notes: notes
        )
        w.completedAt = completedAt
        return w
    }

    /// Parse the export back into a grid for cell-level assertions.
    private func grid(_ workouts: [Workout]) -> [[String]] {
        CSVCodec.parse(WorkoutHistoryCSV.export(workouts: workouts))
    }

    // MARK: - Header / empty

    func testHeaderOrderIsStable() {
        XCTAssertEqual(
            WorkoutHistoryCSV.header,
            ["workoutDate", "completedAt", "routineName", "exerciseName",
             "blockOrder", "setIndex", "subIndex", "kind", "reps", "weight",
             "durationSeconds", "restSeconds", "timestamp", "workoutNotes"]
        )
    }

    func testEmptyHistoryExportsHeaderOnly() {
        XCTAssertEqual(
            WorkoutHistoryCSV.export(workouts: []),
            WorkoutHistoryCSV.header.joined(separator: ",")
        )
    }

    // MARK: - Row fan-out

    func testSingleWorkoutItemSetExportsOneRow() {
        let w = makeWorkout(items: [makeItem(name: "Bench", logs: [makeLog(index: 0)])])
        let g = grid([w])
        XCTAssertEqual(g.count, 2)  // header + 1 data row
        XCTAssertEqual(g[0], WorkoutHistoryCSV.header)
    }

    func testMultipleSetLogsExportMultipleRows() {
        let item = makeItem(name: "Bench", logs: [
            makeLog(index: 0), makeLog(index: 1), makeLog(index: 2),
        ])
        let g = grid([makeWorkout(items: [item])])
        XCTAssertEqual(g.count, 4)  // header + 3
        XCTAssertEqual(g.dropFirst().map { $0[5] }, ["0", "1", "2"])  // setIndex column
    }

    func testRowOrderPreservedAcrossWorkoutsItemsAndLogs() {
        let w1 = makeWorkout(items: [
            makeItem(name: "A", logs: [makeLog(index: 0), makeLog(index: 1)]),
            makeItem(name: "B", logs: [makeLog(index: 0)]),
        ])
        let w2 = makeWorkout(items: [makeItem(name: "C", logs: [makeLog(index: 0)])])
        let names = grid([w1, w2]).dropFirst().map { $0[3] }  // exerciseName column
        XCTAssertEqual(names, ["A", "A", "B", "C"])
    }

    // MARK: - Kind / subIndex

    func testWarmupWorkingDropsetKindsExportCorrectly() {
        let item = makeItem(name: "Bench", logs: [
            makeLog(index: 0, kind: .warmup),
            makeLog(index: 1, kind: .working),
            makeLog(index: 2, kind: .dropset),
        ])
        let kinds = grid([makeWorkout(items: [item])]).dropFirst().map { $0[7] }
        XCTAssertEqual(kinds, ["warmup", "working", "dropset"])
    }

    func testDropsetSubIndexExportsCorrectly() {
        let item = makeItem(name: "Bench", logs: [
            makeLog(index: 2, kind: .working, sub: nil),
            makeLog(index: 2, kind: .dropset, sub: 1),
            makeLog(index: 2, kind: .dropset, sub: 2),
        ])
        let subs = grid([makeWorkout(items: [item])]).dropFirst().map { $0[6] }
        XCTAssertEqual(subs, ["", "1", "2"])
    }

    // MARK: - Snapshot / fallback

    func testSnapshotNameWinsOverLiveExerciseName() {
        let item = WorkoutItem(exercise: Exercise(name: "Live Name"), setLogs: [makeLog(index: 0)])
        item.exerciseNameSnapshot = "Snapshot Name"
        XCTAssertEqual(grid([makeWorkout(items: [item])])[1][3], "Snapshot Name")
    }

    func testDeletedNilExerciseStillExportsSnapshotName() {
        let item = WorkoutItem(exercise: Exercise(name: "Bench"), setLogs: [makeLog(index: 0)])
        item.exercise = nil  // simulate deleted live Exercise
        // exerciseNameSnapshot was set to "Bench" at init and survives deletion.
        XCTAssertEqual(grid([makeWorkout(items: [item])])[1][3], "Bench")
    }

    func testFallsBackToLiveNameWhenSnapshotNil() {
        let item = WorkoutItem(exercise: Exercise(name: "Bench"), setLogs: [makeLog(index: 0)])
        item.exerciseNameSnapshot = nil
        XCTAssertEqual(grid([makeWorkout(items: [item])])[1][3], "Bench")
    }

    func testEmptyExerciseNameWhenNoSnapshotAndNoExercise() {
        let item = WorkoutItem(exercise: Exercise(name: "Bench"), setLogs: [makeLog(index: 0)])
        item.exerciseNameSnapshot = nil
        item.exercise = nil
        XCTAssertEqual(grid([makeWorkout(items: [item])])[1][3], "")
    }

    // MARK: - Optionals / formatting

    func testOptionalFieldsBecomeEmptyStrings() {
        // No completedAt / routineName / blockOrder / subIndex / weight /
        // duration / rest / notes.
        let item = makeItem(name: "Bench", logs: [makeLog(index: 0)])
        let row = grid([makeWorkout(items: [item])])[1]
        XCTAssertEqual(row[1], "")   // completedAt
        XCTAssertEqual(row[2], "")   // routineName
        XCTAssertEqual(row[4], "")   // blockOrder
        XCTAssertEqual(row[6], "")   // subIndex
        XCTAssertEqual(row[9], "")   // weight
        XCTAssertEqual(row[10], "")  // durationSeconds
        XCTAssertEqual(row[11], "")  // restSeconds
        XCTAssertEqual(row[13], "")  // workoutNotes
    }

    func testPopulatedFieldsExport() {
        let item = makeItem(name: "Bench", blockOrder: 2, logs: [
            makeLog(index: 0, reps: 5, weight: 100.0, rest: 90, duration: nil),
        ])
        let w = makeWorkout(
            completedAt: epoch0, routineName: "Push A", notes: "felt strong",
            items: [item]
        )
        let row = grid([w])[1]
        XCTAssertEqual(row[0], iso0)          // workoutDate
        XCTAssertEqual(row[1], iso0)          // completedAt
        XCTAssertEqual(row[2], "Push A")      // routineName
        XCTAssertEqual(row[4], "2")           // blockOrder
        XCTAssertEqual(row[8], "5")           // reps
        XCTAssertEqual(row[9], "100")         // weight (integral → no decimal)
        XCTAssertEqual(row[11], "90")         // restSeconds
        XCTAssertEqual(row[12], iso0)         // timestamp
        XCTAssertEqual(row[13], "felt strong")
    }

    func testFractionalWeightKeepsDecimal() {
        let item = makeItem(name: "Bench", logs: [makeLog(index: 0, weight: 82.5)])
        XCTAssertEqual(grid([makeWorkout(items: [item])])[1][9], "82.5")
    }

    func testTimeBasedDurationExports() {
        let item = makeItem(name: "Plank", logs: [
            makeLog(index: 0, reps: 0, duration: 60),
        ])
        XCTAssertEqual(grid([makeWorkout(items: [item])])[1][10], "60")
    }

    // MARK: - Escaping & dates

    func testCommasQuotesNewlinesEscapedThroughCodec() {
        let item = makeItem(name: "Row, Bent", logs: [makeLog(index: 0)])
        let w = makeWorkout(
            routineName: "Pull \"A\"", notes: "line1\nline2", items: [item]
        )
        // Round-trips through CSVCodec back to the original cell values.
        let row = grid([w])[1]
        XCTAssertEqual(row[2], "Pull \"A\"")
        XCTAssertEqual(row[3], "Row, Bent")
        XCTAssertEqual(row[13], "line1\nline2")
    }

    func testISODateFieldsAreStable() {
        let item = makeItem(name: "Bench", logs: [makeLog(index: 0, at: epoch0)])
        let w = makeWorkout(date: epoch0, completedAt: epoch0, items: [item])
        let row = grid([w])[1]
        XCTAssertEqual(row[0], iso0)
        XCTAssertEqual(row[1], iso0)
        XCTAssertEqual(row[12], iso0)
    }

    // MARK: - No identifiers

    func testNoSwiftDataIdentifiersExported() {
        let exercise = Exercise(name: "Bench")
        let item = WorkoutItem(exercise: exercise, setLogs: [makeLog(index: 0)])
        let w = makeWorkout(items: [item])
        let csv = WorkoutHistoryCSV.export(workouts: [w])
        XCTAssertFalse(csv.contains(w.id.uuidString))
        XCTAssertFalse(csv.contains(exercise.id.uuidString))
    }
}
