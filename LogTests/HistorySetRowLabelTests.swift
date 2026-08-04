import SwiftData
import XCTest

@testable import Log

/// The History set-row label.
///
/// One rule, no exceptions: **number, then the stored set kind's name.** A row
/// reads "1. Working Set", "1. Warm-up Set" or "1. Drop Set", and which one it
/// is depends on `SetLog.kind` alone.
///
/// The exercise is deliberately not consulted. An earlier patch gave cardio its
/// own neutral "Set" label; that special case is gone — the app stores set kind
/// on the set, and cardio has no cardio-specific kinds to distinguish, so a
/// cardio working set is a working set. Most of this file exists to keep it
/// that way: the same assertions run across strength, timed-hold and cardio
/// exercises and expect identical output.
///
/// The active-workout row labels (`SetKind.activeRowLabel`) are a separate,
/// intentionally different vocabulary and are pinned here as *unchanged*.
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

    private func strengthExercise() -> Exercise {
        makeExercise(name: "Bench Press")
    }

    private func timedHoldExercise() -> Exercise {
        makeExercise(name: "Plank", timeBased: true)
    }

    private func cardioExercise() -> Exercise {
        makeExercise(name: "Treadmill Run", timeBased: true, cardio: true)
    }

    /// One item per tracking mode, so a single assertion can prove the label
    /// does not vary with the exercise.
    private func allTrackingModeItems() -> [(TrackingMode, WorkoutItem)] {
        [strengthExercise(), timedHoldExercise(), cardioExercise()].map {
            ($0.trackingMode, makeItem($0))
        }
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
        item.setLogs
            .sorted { $0.indexInExercise < $1.indexInExercise }
            .map { HistorySetRowLabel.text(for: $0) }
    }

    // MARK: - 1–3. Working sets, whatever the exercise

    func testStrengthWorkingRowsUseWorkingSet() {
        let item = makeItem(strengthExercise())
        makeLog(into: item, index: 0, reps: 8, weight: 60)
        makeLog(into: item, index: 1, reps: 8, weight: 60)

        XCTAssertEqual(labels(item), ["1. Working Set", "2. Working Set"])
    }

    func testTimedHoldWorkingRowsUseWorkingSet() {
        let item = makeItem(timedHoldExercise())
        makeLog(into: item, index: 0, durationSeconds: 60)
        makeLog(into: item, index: 1, durationSeconds: 45)

        XCTAssertEqual(labels(item), ["1. Working Set", "2. Working Set"])
    }

    func testCardioWorkingRowsUseWorkingSet() {
        let item = makeItem(cardioExercise())
        makeLog(into: item, index: 0, durationSeconds: 1_800,
                metrics: CardioMetrics(distanceMeters: 5_000))
        makeLog(into: item, index: 1, durationSeconds: 600)

        XCTAssertEqual(labels(item), ["1. Working Set", "2. Working Set"])
    }

    // MARK: - 4. Warm-up sets

    /// Warmups carry a negative `indexInExercise` (`-(order + 1)`), which is
    /// negated back into a 1-based warm-up number.
    func testWarmupRowsUseWarmupSet() {
        let item = makeItem(strengthExercise())
        makeLog(into: item, index: -1, kind: .warmup, reps: 5, weight: 40)
        makeLog(into: item, index: -2, kind: .warmup, reps: 3, weight: 60)

        XCTAssertEqual(labels(item), ["2. Warm-up Set", "1. Warm-up Set"])
    }

    func testWarmupNumberingCountsFromOne() {
        let item = makeItem(strengthExercise())
        let first = makeLog(
            into: item, index: -1, kind: .warmup, reps: 5, weight: 40)
        let fourth = makeLog(
            into: item, index: -4, kind: .warmup, reps: 2, weight: 80)

        XCTAssertEqual(HistorySetRowLabel.number(for: first), 1)
        XCTAssertEqual(HistorySetRowLabel.number(for: fourth), 4)
        XCTAssertEqual(HistorySetRowLabel.text(for: first), "1. Warm-up Set")
        XCTAssertEqual(HistorySetRowLabel.text(for: fourth), "4. Warm-up Set")
    }

    // MARK: - 5. Drop sets

    func testDropsetRowsUseDropSet() {
        let item = makeItem(makeExercise(name: "Lateral Raise"))
        let log = makeLog(
            into: item, index: 0, kind: .dropset, reps: 12, weight: 8)

        XCTAssertEqual(HistorySetRowLabel.text(for: log), "1. Drop Set")
    }

    /// The dropset row reuses the same key the active workout already uses, so
    /// the two surfaces cannot drift apart on this one word.
    func testDropsetSharesItsLabelWithTheActiveRow() {
        XCTAssertEqual(
            SetKind.dropset.historyRowLabel, SetKind.dropset.activeRowLabel)
    }

    // MARK: - 6. Cardio is not special-cased

    /// The whole point of this patch: identical set logs produce identical
    /// labels under a strength, a timed-hold and a cardio exercise.
    func testLabelDoesNotDependOnTrackingMode() {
        for kind in SetKind.allCases {
            var rendered: [TrackingMode: String] = [:]
            for (mode, item) in allTrackingModeItems() {
                let index = kind == .warmup ? -1 : 0
                let log = makeLog(into: item, index: index, kind: kind)
                rendered[mode] = HistorySetRowLabel.text(for: log)
            }
            XCTAssertEqual(
                Set(rendered.values).count, 1,
                "\(kind) label varies by tracking mode: \(rendered)")
        }
    }

    /// Recorded cardio metrics must not change the label either — an earlier
    /// design inferred cardio-ness from them.
    func testRecordedMetricsDoNotChangeTheLabel() {
        let item = makeItem(cardioExercise())
        let withMetrics = makeLog(
            into: item, index: 0, durationSeconds: 900,
            metrics: CardioMetrics(distanceMeters: 4_000, calories: 210))
        let withoutMetrics = makeLog(
            into: item, index: 1, durationSeconds: 900)

        XCTAssertTrue(withMetrics.hasCardioMetrics)
        XCTAssertFalse(withoutMetrics.hasCardioMetrics)
        XCTAssertEqual(
            HistorySetRowLabel.text(for: withMetrics), "1. Working Set")
        XCTAssertEqual(
            HistorySetRowLabel.text(for: withoutMetrics), "2. Working Set")
    }

    /// History survives exercise deletion (`exerciseNameSnapshot`). With no
    /// live `Exercise` at all the label is unchanged, because it never read one.
    func testLabelSurvivesExerciseDeletion() {
        let item = makeItem(cardioExercise())
        makeLog(into: item, index: 0, durationSeconds: 600,
                metrics: CardioMetrics(distanceMeters: 1_200))

        item.exercise = nil

        XCTAssertEqual(labels(item), ["1. Working Set"])
    }

    /// The neutral cardio label the previous patch introduced is gone; nothing
    /// in History renders a bare "Set" any more.
    func testNoRowRendersTheBareNeutralLabel() {
        for kind in SetKind.allCases {
            XCTAssertNotEqual(kind.historyRowLabel, "Set")
        }
    }

    // MARK: - Every kind names itself

    func testEveryKindHasADistinctNonEmptyHistoryLabel() {
        let labels = SetKind.allCases.map(\.historyRowLabel)
        XCTAssertEqual(labels.count, Set(labels).count)
        for label in labels { XCTAssertFalse(label.isEmpty) }
    }

    func testHistoryLabelsAreTheExpectedEnglishStrings() {
        XCTAssertEqual(SetKind.working.historyRowLabel, "Working Set")
        XCTAssertEqual(SetKind.warmup.historyRowLabel, "Warm-up Set")
        XCTAssertEqual(SetKind.dropset.historyRowLabel, "Drop Set")
    }

    /// An unparseable `kindRaw` resolves to `.working` (`SetLog.kind`'s
    /// fallback), so a corrupt row still renders a sensible label instead of
    /// echoing raw storage back at the user.
    func testUnknownStoredKindFallsBackToWorkingSet() {
        let item = makeItem(strengthExercise())
        let log = makeLog(into: item, index: 0, reps: 5, weight: 50)
        log.kindRaw = "not-a-kind"

        XCTAssertEqual(HistorySetRowLabel.text(for: log), "1. Working Set")
    }

    // MARK: - 7. Active-workout labels are untouched

    /// The active workout has never shown "Working": `.working` returns nil so
    /// the row draws no kind label at all. This is History-only, and this test
    /// is what fails if a future edit tries to unify the two vocabularies.
    func testActiveWorkoutRowLabelsAreUnchanged() {
        XCTAssertNil(SetKind.working.activeRowLabel)
        XCTAssertEqual(SetKind.warmup.activeRowLabel, "Warmup")
        XCTAssertEqual(SetKind.dropset.activeRowLabel, "Drop Set")
    }

    /// The two vocabularies stay separate where they are meant to differ.
    func testActiveAndHistoryLabelsDifferForWorkingAndWarmup() {
        XCTAssertNotEqual(
            SetKind.working.activeRowLabel, SetKind.working.historyRowLabel)
        XCTAssertNotEqual(
            SetKind.warmup.activeRowLabel, SetKind.warmup.historyRowLabel)
    }
}
