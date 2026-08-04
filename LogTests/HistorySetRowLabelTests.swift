import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 4 polish — the History set-row label.
///
/// Review found cardio sets rendering as "1. Working". "Working" is strength
/// vocabulary: a cardio bout may be a warm-up jog, the main effort, or a
/// cooldown, and the log does not know which. Cardio rows now read "1. Set".
///
/// Every other label in the app is in scope here only to be pinned *unchanged*:
/// strength rows, timed-hold rows, warm-up rows, and the active-workout row
/// labels (`SetKind.activeRowLabel`), which this patch deliberately does not
/// touch.
@MainActor
final class HistorySetRowLabelTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func makeExercise(
        name: String, timeBased: Bool = false, cardio: Bool = false
    ) -> Exercise {
        let exercise = Exercise(name: name)
        context.insert(exercise)
        exercise.setTimeBased(timeBased)
        exercise.setCardio(cardio)
        return exercise
    }

    @discardableResult
    private func makeLog(
        into item: WorkoutItem,
        index: Int,
        kind: SetKind = .working,
        reps: Int = 0,
        weight: Double? = nil,
        durationSeconds: Int? = nil,
        metrics: CardioMetrics? = nil
    ) -> SetLog {
        let log = SetLog(
            indexInExercise: index, kind: kind, reps: reps, weight: weight,
            durationSeconds: durationSeconds)
        context.insert(log)
        if let metrics { log.applyCardioMetrics(metrics) }
        item.setLogs.append(log)
        return log
    }

    private func makeItem(_ exercise: Exercise) -> WorkoutItem {
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        context.insert(item)
        return item
    }

    private func labels(_ item: WorkoutItem) -> [String] {
        let isCardio = HistorySetRowLabel.isCardioItem(item)
        return item.setLogs
            .sorted { $0.indexInExercise < $1.indexInExercise }
            .map { HistorySetRowLabel.text(for: $0, isCardio: isCardio) }
    }

    // MARK: - 1. Cardio rows use the neutral label

    func testCardioRowsUseNeutralSetLabel() {
        let item = makeItem(makeExercise(
            name: "Treadmill Run", timeBased: true, cardio: true))
        makeLog(into: item, index: 0, durationSeconds: 1_800,
                metrics: CardioMetrics(distanceMeters: 5_000))
        makeLog(into: item, index: 1, durationSeconds: 600)

        XCTAssertEqual(labels(item), ["1. Set", "2. Set"])
    }

    func testCardioRowsNeverSayWorking() {
        let item = makeItem(makeExercise(
            name: "Rowing Machine", timeBased: true, cardio: true))
        for index in 0..<4 {
            makeLog(into: item, index: index, durationSeconds: 300)
        }

        for label in labels(item) {
            XCTAssertFalse(
                label.localizedCaseInsensitiveContains("working"),
                "cardio History row still uses strength vocabulary: \(label)")
        }
    }

    /// A cardio bout logged with only a duration carries no metrics at all, and
    /// must still be labelled from its exercise rather than from its contents —
    /// otherwise two sets of the same run would disagree.
    func testDurationOnlyCardioSetStillUsesNeutralLabel() {
        let item = makeItem(makeExercise(
            name: "Walking", timeBased: true, cardio: true))
        let log = makeLog(into: item, index: 0, durationSeconds: 1_200)

        XCTAssertFalse(log.hasCardioMetrics)
        XCTAssertEqual(labels(item), ["1. Set"])
    }

    /// Mixed rows within one cardio item are labelled identically whether or
    /// not the individual set happens to carry metrics.
    func testCardioLabelIsConsistentAcrossSetsOfTheSameItem() {
        let item = makeItem(makeExercise(
            name: "Stationary Bike", timeBased: true, cardio: true))
        makeLog(into: item, index: 0, durationSeconds: 900,
                metrics: CardioMetrics(distanceMeters: 4_000, calories: 210))
        makeLog(into: item, index: 1, durationSeconds: 900)

        XCTAssertEqual(labels(item), ["1. Set", "2. Set"])
    }

    /// The neutral label is a localized string, not a hardcoded literal, and
    /// renders as "Set" in the app's development language.
    func testNeutralLabelIsTheLocalizedSetString() {
        XCTAssertEqual(HistorySetRowLabel.neutralCardioLabel, "Set")
    }

    // MARK: - 2. Strength rows are unchanged

    func testStrengthRowsStillSayWorking() {
        let item = makeItem(makeExercise(name: "Bench Press"))
        makeLog(into: item, index: 0, reps: 8, weight: 60)
        makeLog(into: item, index: 1, reps: 8, weight: 60)

        XCTAssertEqual(labels(item), ["1. Working", "2. Working"])
    }

    func testStrengthDropsetRowIsUnchanged() {
        let item = makeItem(makeExercise(name: "Lateral Raise"))
        let log = makeLog(
            into: item, index: 0, kind: .dropset, reps: 12, weight: 8)

        XCTAssertEqual(
            HistorySetRowLabel.text(for: log, isCardio: false), "1. Dropset")
    }

    func testWarmupRowIsUnchangedForEveryTrackingMode() {
        // Warmups carry a negative `indexInExercise` (`-(order + 1)`).
        let strength = makeItem(makeExercise(name: "Squat"))
        let warmup = makeLog(
            into: strength, index: -1, kind: .warmup, reps: 5, weight: 40)
        XCTAssertEqual(
            HistorySetRowLabel.text(for: warmup, isCardio: false), "Warmup 1")
        XCTAssertEqual(
            HistorySetRowLabel.text(for: warmup, isCardio: true), "Warmup 1")
    }

    // MARK: - 3. Timed holds are unchanged

    func testTimedHoldRowsAreUnchanged() {
        let item = makeItem(makeExercise(name: "Plank", timeBased: true))
        makeLog(into: item, index: 0, durationSeconds: 60)
        makeLog(into: item, index: 1, durationSeconds: 45)

        XCTAssertFalse(HistorySetRowLabel.isCardioItem(item))
        XCTAssertEqual(labels(item), ["1. Working", "2. Working"])
    }

    // MARK: - Cardio detection

    func testCardioDetectionFollowsTheExerciseNotTheMetrics() {
        let cardio = makeItem(makeExercise(
            name: "Elliptical", timeBased: true, cardio: true))
        let hold = makeItem(makeExercise(name: "Wall Sit", timeBased: true))
        let strength = makeItem(makeExercise(name: "Deadlift"))

        XCTAssertTrue(HistorySetRowLabel.isCardioItem(cardio))
        XCTAssertFalse(HistorySetRowLabel.isCardioItem(hold))
        XCTAssertFalse(HistorySetRowLabel.isCardioItem(strength))
    }

    /// History survives exercise deletion (`exerciseNameSnapshot`), so the
    /// label has to survive it too. With no live `Exercise`, recorded metrics
    /// are the only remaining evidence — read across all of the item's sets.
    func testDeletedCardioExerciseFallsBackToRecordedMetrics() {
        let exercise = makeExercise(
            name: "Stair Climber", timeBased: true, cardio: true)
        let item = makeItem(exercise)
        makeLog(into: item, index: 0, durationSeconds: 600,
                metrics: CardioMetrics(distanceMeters: 1_200))
        makeLog(into: item, index: 1, durationSeconds: 600)

        item.exercise = nil

        XCTAssertTrue(HistorySetRowLabel.isCardioItem(item))
        XCTAssertEqual(labels(item), ["1. Set", "2. Set"])
    }

    /// A deleted *strength* exercise has no metrics to find and keeps its
    /// existing rendering rather than being reclassified.
    func testDeletedStrengthExerciseKeepsWorkingLabel() {
        let item = makeItem(makeExercise(name: "Row"))
        makeLog(into: item, index: 0, reps: 10, weight: 50)

        item.exercise = nil

        XCTAssertFalse(HistorySetRowLabel.isCardioItem(item))
        XCTAssertEqual(labels(item), ["1. Working"])
    }

    // MARK: - 4. Active-workout labels are untouched

    /// The active workout has never shown "Working": `.working` returns nil so
    /// the row draws no kind label at all. This patch is History-only, and this
    /// test is what fails if a future edit tries to "fix" the active row too.
    func testActiveWorkoutRowLabelsAreUnchanged() {
        XCTAssertNil(SetKind.working.activeRowLabel)
        XCTAssertEqual(SetKind.warmup.activeRowLabel, "Warmup")
        XCTAssertEqual(SetKind.dropset.activeRowLabel, "Drop Set")
    }

    /// The neutral History label must not have leaked into the active row.
    func testActiveWorkoutRowLabelsNeverUseTheHistoryNeutralLabel() {
        for kind in SetKind.allCases {
            XCTAssertNotEqual(
                kind.activeRowLabel, HistorySetRowLabel.neutralCardioLabel)
        }
    }
}
