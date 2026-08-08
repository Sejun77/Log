import SwiftData
import XCTest

@testable import Log

/// The History set-row label.
///
/// The rule: **number, then the name of what was logged.** A strength or
/// timed-hold row reads "1. Working Set", "1. Warm-up Set" or "1. Drop Set",
/// and which one it is depends on `SetLog.kind` alone. A cardio row reads
/// **"1. Cardio Set"**.
///
/// ### Why cardio is the one exception
///
/// A cardio bout is one aggregate entry for the whole effort, not a set in the
/// strength sense — and the Cardio Plan block rendered directly above these
/// rows already spends the words *Warm-up*, *Work*, *Recovery* and *Cool-down*
/// on planned segments. "Working Set" beside that plan read as the plan's
/// *Work* segment, implying the other segments were logged somewhere too. They
/// are not.
///
/// This is a naming decision about a rendered row and nothing more: the stored
/// `SetKind` is untouched, cardio still persists `.working`, and there are no
/// cardio-specific set kinds. `SetKind.historyRowLabel` therefore stays the
/// pure kind vocabulary and the exception lives in `HistorySetRowLabel`.
///
/// > An earlier patch gave cardio a neutral "1. Set" and was reverted for
/// > saying *less* than the app knew. "Cardio Set" is the opposite move: it
/// > names the thing precisely rather than declining to name it.
///
/// The active-workout row labels (`SetKind.activeRowLabel`) are a separate,
/// intentionally different vocabulary and are pinned here as *unchanged* — a
/// `.working` set draws no label mid-workout, cardio included.
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

    /// One item per tracking mode, so a single assertion can prove which part
    /// of the label varies with the exercise and which part does not.
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

    /// Renders an item's rows the way `HistoryView` does — cardio-ness resolved
    /// from the item, not passed in by the test — so these assertions cover the
    /// production path rather than a convenient parameterization of it.
    private func labels(_ item: WorkoutItem) -> [String] {
        let isCardio = HistorySetRowLabel.isCardio(item)
        return item.setLogs
            .sorted { $0.indexInExercise < $1.indexInExercise }
            .map { HistorySetRowLabel.text(for: $0, isCardio: isCardio) }
    }

    // MARK: - 1–3. Working sets

    func testStrengthWorkingRowsUseWorkingSet() {
        let item = makeItem(strengthExercise())
        makeLog(into: item, index: 0, reps: 8, weight: 60)
        makeLog(into: item, index: 1, reps: 8, weight: 60)

        XCTAssertEqual(labels(item), ["1. Working Set", "2. Working Set"])
    }

    /// A timed hold is not cardio. "Working Set" is the right word for a plank:
    /// it is a set, performed for time instead of reps, and it carries no plan
    /// whose vocabulary it could collide with.
    func testTimedHoldWorkingRowsUseWorkingSet() {
        let item = makeItem(timedHoldExercise())
        makeLog(into: item, index: 0, durationSeconds: 60)
        makeLog(into: item, index: 1, durationSeconds: 45)

        XCTAssertEqual(labels(item), ["1. Working Set", "2. Working Set"])
    }

    func testCardioRowsUseCardioSet() {
        let item = makeItem(cardioExercise())
        makeLog(into: item, index: 0, durationSeconds: 1_800,
                metrics: CardioMetrics(distanceMeters: 5_000))
        makeLog(into: item, index: 1, durationSeconds: 600)

        XCTAssertEqual(labels(item), ["1. Cardio Set", "2. Cardio Set"])
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
        XCTAssertEqual(
            HistorySetRowLabel.text(for: first, isCardio: false),
            "1. Warm-up Set")
        XCTAssertEqual(
            HistorySetRowLabel.text(for: fourth, isCardio: false),
            "4. Warm-up Set")
    }

    // MARK: - 5. Drop sets

    func testDropsetRowsUseDropSet() {
        let item = makeItem(makeExercise(name: "Lateral Raise"))
        let log = makeLog(
            into: item, index: 0, kind: .dropset, reps: 12, weight: 8)

        XCTAssertEqual(
            HistorySetRowLabel.text(for: log, isCardio: false), "1. Drop Set")
    }

    /// The dropset row reuses the same key the active workout already uses, so
    /// the two surfaces cannot drift apart on this one word.
    func testDropsetSharesItsLabelWithTheActiveRow() {
        XCTAssertEqual(
            SetKind.dropset.historyRowLabel, SetKind.dropset.activeRowLabel)
    }

    // MARK: - 6. Cardio names its aggregate row, and only that row

    /// The exception is scoped to `.working`. Cardio has no warm-up or drop
    /// `SetLog`s — structured warm-up, recovery and cool-down are *planned
    /// segments*, never logged rows — but if one ever reached History it would
    /// still name its stored kind rather than being relabelled.
    func testCardioDoesNotRenameOtherSetKinds() {
        let item = makeItem(cardioExercise())
        let warmup = makeLog(into: item, index: -1, kind: .warmup)
        let drop = makeLog(into: item, index: 0, kind: .dropset)

        XCTAssertEqual(
            HistorySetRowLabel.text(for: warmup, isCardio: true),
            "1. Warm-up Set")
        XCTAssertEqual(
            HistorySetRowLabel.text(for: drop, isCardio: true), "1. Drop Set")
    }

    /// Only the *name* varies with the exercise. The number is computed from
    /// the set alone, so identical logs number identically under every mode.
    func testNumberingDoesNotDependOnTrackingMode() {
        for kind in SetKind.allCases {
            var numbers: Set<Int> = []
            for (_, item) in allTrackingModeItems() {
                let index = kind == .warmup ? -1 : 0
                let log = makeLog(into: item, index: index, kind: kind)
                numbers.insert(HistorySetRowLabel.number(for: log))
            }
            XCTAssertEqual(
                numbers.count, 1,
                "\(kind) numbering varies by tracking mode: \(numbers)")
        }
    }

    /// Strength and timed hold share one label; cardio is the only mode that
    /// differs. Pins the blast radius of the exception.
    func testOnlyCardioChangesTheWorkingRowName() {
        var rendered: [TrackingMode: String] = [:]
        for (mode, item) in allTrackingModeItems() {
            let log = makeLog(into: item, index: 0)
            rendered[mode] = HistorySetRowLabel.text(
                for: log, isCardio: HistorySetRowLabel.isCardio(item))
        }

        XCTAssertEqual(rendered[.strength], "1. Working Set")
        XCTAssertEqual(rendered[.timedHold], "1. Working Set")
        XCTAssertEqual(rendered[.cardio], "1. Cardio Set")
    }

    /// Recorded metrics must not decide the label — an earlier design inferred
    /// cardio-ness from them, so a duration-only bout read differently from the
    /// one beside it. The exercise decides; a bout logged with nothing but a
    /// duration is still a Cardio Set.
    func testRecordedMetricsDoNotDecideTheLabel() {
        let item = makeItem(cardioExercise())
        let withMetrics = makeLog(
            into: item, index: 0, durationSeconds: 900,
            metrics: CardioMetrics(distanceMeters: 4_000, calories: 210))
        let withoutMetrics = makeLog(
            into: item, index: 1, durationSeconds: 900)

        XCTAssertTrue(withMetrics.hasCardioMetrics)
        XCTAssertFalse(withoutMetrics.hasCardioMetrics)
        XCTAssertEqual(labels(item), ["1. Cardio Set", "2. Cardio Set"])
    }

    /// The mirror image: metrics on a *strength* item cannot promote its rows
    /// to Cardio Sets.
    func testStrengthItemWithStrayMetricsStillReadsAsWorkingSet() {
        let item = makeItem(strengthExercise())
        makeLog(into: item, index: 0, reps: 8, weight: 60,
                metrics: CardioMetrics(distanceMeters: 100))

        XCTAssertEqual(labels(item), ["1. Working Set"])
    }

    // MARK: - 6b. Resolving cardio-ness when the exercise is gone

    func testCardioIsResolvedFromTheLiveExercise() {
        XCTAssertTrue(HistorySetRowLabel.isCardio(makeItem(cardioExercise())))
        XCTAssertFalse(HistorySetRowLabel.isCardio(makeItem(strengthExercise())))
        XCTAssertFalse(
            HistorySetRowLabel.isCardio(makeItem(timedHoldExercise())))
    }

    /// History outlives the exercises it records. With the exercise deleted the
    /// frozen prescription snapshot answers instead: a target distance is
    /// authorable on a cardio slot and nowhere else.
    func testDeletedExerciseFallsBackToTheTargetDistanceSnapshot() {
        let item = makeItem(cardioExercise())
        makeLog(into: item, index: 0, durationSeconds: 600,
                metrics: CardioMetrics(distanceMeters: 1_200))
        let snapshot = PlannedPrescriptionSnapshot()
        context.insert(snapshot)
        snapshot.targetDistanceMeters = 5_000
        item.plannedPrescriptionSnapshot = snapshot

        item.exercise = nil

        XCTAssertEqual(labels(item), ["1. Cardio Set"])
    }

    /// A structured plan is the other cardio-only trace on the snapshot.
    func testDeletedExerciseFallsBackToTheStructuredPlanSnapshot() throws {
        let item = makeItem(cardioExercise())
        makeLog(into: item, index: 0, durationSeconds: 1_500)
        let snapshot = PlannedPrescriptionSnapshot()
        context.insert(snapshot)
        snapshot.cardioSegmentsData = try JSONEncoder().encode(
            CardioSegmentPlan(groups: [
                CardioSegmentGroup(segments: [
                    CardioSegment(kind: .work, durationSeconds: 1_500)
                ])
            ]))
        item.plannedPrescriptionSnapshot = snapshot

        item.exercise = nil

        XCTAssertEqual(labels(item), ["1. Cardio Set"])
    }

    /// With no exercise and no cardio trace on the snapshot there is nothing to
    /// read, and the row falls back to the kind it stored. Guessing from the
    /// metrics is what the previous design did, and it is why two rows holding
    /// the same data could read differently.
    func testDeletedExerciseWithNoSnapshotEvidenceReadsAsWorkingSet() {
        let item = makeItem(cardioExercise())
        makeLog(into: item, index: 0, durationSeconds: 600,
                metrics: CardioMetrics(distanceMeters: 1_200))

        item.exercise = nil

        XCTAssertEqual(labels(item), ["1. Working Set"])
    }

    /// The neutral label the reverted patch introduced stays gone: no row
    /// renders a bare "Set".
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

    /// The cardio name is not a `SetKind` and must not become one — the model
    /// stores `.working` for a cardio bout and nothing about that changed.
    func testCardioSetIsNotASetKind() {
        XCTAssertFalse(
            SetKind.allCases.map(\.historyRowLabel).contains("Cardio Set"))
        XCTAssertNil(SetKind(rawValue: "cardio"))
    }

    /// An unparseable `kindRaw` resolves to `.working` (`SetLog.kind`'s
    /// fallback), so a corrupt row still renders a sensible label instead of
    /// echoing raw storage back at the user.
    func testUnknownStoredKindFallsBackToWorkingSet() {
        let item = makeItem(strengthExercise())
        let log = makeLog(into: item, index: 0, reps: 5, weight: 50)
        log.kindRaw = "not-a-kind"

        XCTAssertEqual(
            HistorySetRowLabel.text(for: log, isCardio: false),
            "1. Working Set")
    }

    // MARK: - 7. Active-workout labels are untouched

    /// The active workout has never shown "Working": `.working` returns nil so
    /// the row draws no kind label at all. This is History-only, and this test
    /// is what fails if a future edit tries to unify the two vocabularies — or
    /// tries to stamp "Cardio Set" onto the active row, where the surrounding
    /// context already says what the exercise is.
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
