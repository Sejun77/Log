import SwiftData
import XCTest

@testable import Log

/// Cardio Phase 1, Slice 4 — the entry → storage → History pipeline.
///
/// `ActiveWorkoutView` is a 3900-line SwiftUI view with no view model, so it
/// cannot be instantiated in a unit test. What *is* testable is the exact
/// sequence it performs when the Log button is tapped, which these tests
/// reproduce step for step:
///
///   draft → `CardioEntryDraft.metrics` → `SetLog.applyCardioMetrics`
///         → `CardioHistorySummary.primaryText` / `.secondaryLines`
///
/// If the view's wiring is ever changed to skip a step, the compile-time types
/// here still match but the behavioral assertions below are the specification
/// that step must satisfy.
@MainActor
final class ActiveWorkoutCardioEntryTests: SwiftDataTestHarness {

    private let km = DistanceUnit.kilometers

    /// Mirrors `appendTimeSetLog(slotID:setIndex:durationSeconds:kind:cardio:)`:
    /// a time-based log always writes reps 0 / nil weight, then applies the
    /// metrics — which is also what clears them when the draft is empty.
    @discardableResult
    private func logTimeSet(
        into item: WorkoutItem,
        setIndex: Int = 0,
        durationSeconds: Int,
        cardio: CardioMetrics = CardioMetrics()
    ) -> SetLog {
        let log = SetLog(
            indexInExercise: setIndex, kind: .working, reps: 0, weight: nil,
            restSeconds: nil, timestamp: .now, durationSeconds: durationSeconds)
        log.applyCardioMetrics(cardio)
        context.insert(log)
        item.setLogs.append(log)
        return log
    }

    private func makeItem(_ exercise: Exercise) -> WorkoutItem {
        context.insert(exercise)
        let item = WorkoutItem(exercise: exercise, setLogs: [])
        context.insert(item)
        return item
    }

    private func cardioExercise(_ name: String = "Treadmill Run") -> Exercise {
        let ex = Exercise(name: name, bodyPart: "Cardio", isCustom: false)
        ex.setTimeBased(true)
        ex.setCardio(true)
        return ex
    }

    private func timedHoldExercise(_ name: String = "Plank") -> Exercise {
        let ex = Exercise(name: name, isCustom: false)
        ex.setTimeBased(true)
        return ex
    }

    // MARK: - 1. Entered metrics reach the store

    func testEnteredMetricsAreStoredOnTheSetLog() throws {
        let item = makeItem(cardioExercise())
        let draft = CardioEntryDraft(
            unit: km, distance: "6.2", avgHeartRate: "142", calories: "410",
            incline: "3", resistance: "8", hrZone: .z3)

        let log = logTimeSet(into: item, durationSeconds: 2_700, cardio: draft.metrics)
        try context.save()

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SetLog>()).first)
        XCTAssertEqual(stored.durationSeconds, 2_700)
        XCTAssertEqual(stored.distanceMeters ?? 0, 6_200, accuracy: 0.0001)
        XCTAssertEqual(stored.distanceUnitRaw, "km")
        XCTAssertEqual(stored.avgHeartRate, 142)
        XCTAssertEqual(stored.calories, 410)
        XCTAssertEqual(stored.inclinePercent, 3)
        XCTAssertEqual(stored.resistanceLevel, 8)
        XCTAssertEqual(stored.hrZoneRaw, "z3")
        XCTAssertEqual(stored.id, log.id)
    }

    func testDistanceEnteredInKilometersStoresMetersAndKm() {
        let item = makeItem(cardioExercise())
        let draft = CardioEntryDraft(unit: .kilometers, distance: "5")

        let log = logTimeSet(into: item, durationSeconds: 1_800, cardio: draft.metrics)

        XCTAssertEqual(log.distanceMeters ?? 0, 5_000, accuracy: 0.0001)
        XCTAssertEqual(log.distanceUnitRaw, "km")
    }

    func testDistanceEnteredInMilesStoresMetersAndMi() {
        let item = makeItem(cardioExercise())
        let draft = CardioEntryDraft(unit: .miles, distance: "3")

        let log = logTimeSet(into: item, durationSeconds: 1_500, cardio: draft.metrics)

        XCTAssertEqual(log.distanceMeters ?? 0, 4_828.032, accuracy: 0.0001)
        XCTAssertEqual(log.distanceUnitRaw, "mi")
    }

    // MARK: - 2. Duration-only logging is unchanged

    /// The core compatibility requirement: a cardio set logged without ever
    /// opening Details is byte-identical to a pre-Slice-4 cardio set.
    func testDurationOnlyCardioSetStoresNoMetrics() {
        let item = makeItem(cardioExercise())
        let untouched = CardioEntryDraft(unit: km)

        let log = logTimeSet(
            into: item, durationSeconds: 1_800, cardio: untouched.metrics)

        XCTAssertEqual(log.durationSeconds, 1_800)
        XCTAssertEqual(log.reps, 0)
        XCTAssertNil(log.weight)
        XCTAssertFalse(log.hasCardioMetrics)
        XCTAssertNil(log.distanceMeters)
        XCTAssertNil(log.distanceUnitRaw)
        XCTAssertNil(log.avgHeartRate)
        XCTAssertNil(log.calories)
        XCTAssertNil(log.inclinePercent)
        XCTAssertNil(log.resistanceLevel)
        XCTAssertNil(log.hrZoneRaw)
    }

    /// Invalid entries are dropped rather than blocking the log — a typo in an
    /// optional field must never cost the user their set.
    func testInvalidMetricsDoNotBlockLoggingAndStoreNil() {
        let item = makeItem(cardioExercise())
        let typos = CardioEntryDraft(
            unit: km, distance: "abc", avgHeartRate: "999", calories: "-5",
            incline: "500", resistance: "0")

        let log = logTimeSet(into: item, durationSeconds: 1_800, cardio: typos.metrics)

        XCTAssertEqual(log.durationSeconds, 1_800)
        XCTAssertFalse(log.hasCardioMetrics)
    }

    /// A timed hold passes no draft at all (the row's `cardioDraft` is nil), so
    /// its log takes the default empty metrics.
    func testTimedHoldLoggingIsUnchanged() {
        let item = makeItem(timedHoldExercise())

        let log = logTimeSet(into: item, durationSeconds: 60)

        XCTAssertEqual(log.durationSeconds, 60)
        XCTAssertEqual(log.reps, 0)
        XCTAssertNil(log.weight)
        XCTAssertFalse(log.hasCardioMetrics)
    }

    /// Strength sets never touch this path; asserting it here keeps the
    /// guarantee visible next to the cardio cases.
    func testStrengthLoggingIsUnchanged() {
        let ex = Exercise(name: "Bench Press", isCustom: false)
        let item = makeItem(ex)
        let log = SetLog(indexInExercise: 0, kind: .working, reps: 8, weight: 60)
        context.insert(log)
        item.setLogs.append(log)

        XCTAssertEqual(log.reps, 8)
        XCTAssertEqual(log.weight, 60)
        XCTAssertNil(log.durationSeconds)
        XCTAssertFalse(log.hasCardioMetrics)
        XCTAssertNil(
            CardioHistorySummary.primaryText(for: log),
            "A strength set must fall through to the weight/reps rendering")
        XCTAssertTrue(
            CardioHistorySummary.secondaryLines(for: log, fallbackUnit: km).isEmpty)
    }

    // MARK: - 3. Re-logging clears a previous attempt

    /// Undo then re-log with an empty draft must not leave the first attempt's
    /// distance attached — the reason `appendTimeSetLog` applies metrics
    /// unconditionally rather than only when non-empty.
    func testRelogWithEmptyDraftClearsPreviousMetrics() {
        let item = makeItem(cardioExercise())
        let first = CardioEntryDraft(unit: km, distance: "6.2", avgHeartRate: "142")
        let log = logTimeSet(into: item, durationSeconds: 2_700, cardio: first.metrics)
        XCTAssertTrue(log.hasCardioMetrics)

        // Re-log the same set index with nothing entered.
        log.durationSeconds = 1_800
        log.applyCardioMetrics(CardioEntryDraft(unit: km).metrics)

        XCTAssertEqual(log.durationSeconds, 1_800)
        XCTAssertFalse(log.hasCardioMetrics)
        XCTAssertNil(log.distanceMeters)
        XCTAssertNil(log.avgHeartRate)
    }

    // MARK: - 4. History integration

    func testLoggedCardioSetRendersItsHistorySummary() {
        let item = makeItem(cardioExercise())
        let draft = CardioEntryDraft(
            unit: km, distance: "6.2", avgHeartRate: "142", calories: "410")

        let log = logTimeSet(into: item, durationSeconds: 2_700, cardio: draft.metrics)

        XCTAssertEqual(CardioHistorySummary.primaryText(for: log), "2700s")
        XCTAssertEqual(
            CardioHistorySummary.secondaryLines(for: log, fallbackUnit: km),
            ["6.2 km · 7:15 /km", "142 bpm · 410 kcal"])
    }

    func testDurationOnlyCardioSetRendersLikeBefore() {
        let item = makeItem(cardioExercise())

        let log = logTimeSet(
            into: item, durationSeconds: 1_800,
            cardio: CardioEntryDraft(unit: km).metrics)

        XCTAssertEqual(CardioHistorySummary.primaryText(for: log), "1800s")
        XCTAssertTrue(
            CardioHistorySummary.secondaryLines(for: log, fallbackUnit: km).isEmpty)
    }

    func testTimedHoldRendersLikeBefore() {
        let item = makeItem(timedHoldExercise())

        let log = logTimeSet(into: item, durationSeconds: 60)

        XCTAssertEqual(CardioHistorySummary.primaryText(for: log), "60s")
        XCTAssertTrue(
            CardioHistorySummary.secondaryLines(for: log, fallbackUnit: km).isEmpty)
    }

    /// A workout finished with a mix of set types renders each row correctly —
    /// the closest a unit test gets to the manual smoke checklist.
    func testFinishedWorkoutRendersMixedRowsCorrectly() throws {
        let workout = Workout(date: .now, items: [])
        context.insert(workout)

        let cardioItem = makeItem(cardioExercise())
        logTimeSet(
            into: cardioItem, setIndex: 0, durationSeconds: 1_800,
            cardio: CardioEntryDraft(unit: km).metrics)
        logTimeSet(
            into: cardioItem, setIndex: 1, durationSeconds: 2_700,
            cardio: CardioEntryDraft(
                unit: km, distance: "6.2", avgHeartRate: "142", calories: "410",
                incline: "-3", resistance: "8"
            ).metrics)
        workout.items.append(cardioItem)

        let plankItem = makeItem(timedHoldExercise())
        logTimeSet(into: plankItem, durationSeconds: 60)
        workout.items.append(plankItem)

        workout.completedAt = .now
        try context.save()

        let cardioLogs = cardioItem.setLogs.sorted { $0.indexInExercise < $1.indexInExercise }
        // Duration-only cardio: one line, unchanged.
        XCTAssertEqual(CardioHistorySummary.primaryText(for: cardioLogs[0]), "1800s")
        XCTAssertTrue(
            CardioHistorySummary.secondaryLines(
                for: cardioLogs[0], fallbackUnit: km).isEmpty)

        // Fully recorded cardio: duration stays primary, metrics grouped below.
        XCTAssertEqual(CardioHistorySummary.primaryText(for: cardioLogs[1]), "2700s")
        XCTAssertEqual(
            CardioHistorySummary.secondaryLines(
                for: cardioLogs[1], fallbackUnit: km),
            [
                "6.2 km · 7:15 /km",
                "-3% incline · level 8",
                "142 bpm · 410 kcal",
            ])

        // Plank: untouched.
        XCTAssertEqual(
            CardioHistorySummary.primaryText(for: plankItem.setLogs[0]), "60s")
        XCTAssertTrue(
            CardioHistorySummary.secondaryLines(
                for: plankItem.setLogs[0], fallbackUnit: km).isEmpty)
    }

    // MARK: - 5. Cardio slot gating

    /// The row only builds a Details section when the *live* exercise is
    /// `.cardio`, which is what `refreshCardioSlots` derives. Asserting the
    /// three tracking modes here pins the gate itself.
    func testOnlyCardioExercisesQualifyForMetricEntry() {
        let cardio = cardioExercise()
        let plank = timedHoldExercise()
        let bench = Exercise(name: "Bench Press", isCustom: false)
        for ex in [cardio, plank, bench] { context.insert(ex) }

        XCTAssertEqual(cardio.trackingMode, .cardio)
        XCTAssertEqual(plank.trackingMode, .timedHold)
        XCTAssertEqual(bench.trackingMode, .strength)

        let qualifying = [cardio, plank, bench].filter { $0.trackingMode == .cardio }
        XCTAssertEqual(qualifying.map(\.name), ["Treadmill Run"])
    }

    /// Turning the Cardio toggle off removes the slot's entry affordance on the
    /// next refresh — no orphaned Details section pointing at a timed hold.
    func testUncheckingCardioRemovesTheSlotFromEntry() {
        let ex = cardioExercise()
        context.insert(ex)
        XCTAssertEqual(ex.trackingMode, .cardio)

        ex.setCardio(false)

        XCTAssertEqual(ex.trackingMode, .timedHold)
    }
}
