import SwiftData
import XCTest

@testable import Log

/// Tests for the real-history extractor. `Workout`/`WorkoutItem`/`SetLog` are
/// `@Model` reference types, so these run on `SwiftDataTestHarness` (in-memory
/// container) — same approach as `WorkoutItemGroupingTests`. The extractor
/// itself performs no inserts/saves; the harness just lets us build fixtures.
@MainActor
final class WorkoutHistoryAnalyticsTests: SwiftDataTestHarness {

    private let referenceDate = Date(timeIntervalSinceReferenceDate: 0)
    private func day(_ d: Double) -> Date {
        referenceDate.addingTimeInterval(d * 86_400)
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeWorkout(date: Date, completed: Bool = true) -> Workout {
        let w = Workout(date: date, items: [])
        if completed { w.completedAt = date.addingTimeInterval(3600) }
        context.insert(w)
        return w
    }

    /// Adds an item to `w`. Pass `exercise: nil` to simulate a deleted exercise
    /// (the `.nullify` rule): the item is built from a throwaway `Exercise` so
    /// `exerciseNameSnapshot` is populated, then its `exercise` link is cleared.
    @discardableResult
    private func addItem(
        to w: Workout,
        exercise: Exercise?,
        snapshotName: String? = nil,
        sets: [(kind: SetKind, reps: Int, weight: Double?)]
    ) -> WorkoutItem {
        let backing = exercise ?? Exercise(name: snapshotName ?? "Deleted", isCustom: true)
        context.insert(backing)

        let item = WorkoutItem(exercise: backing, setLogs: [])
        if let snapshotName { item.exerciseNameSnapshot = snapshotName }

        var logs: [SetLog] = []
        for (i, s) in sets.enumerated() {
            let log = SetLog(indexInExercise: i, kind: s.kind, reps: s.reps, weight: s.weight)
            context.insert(log)
            logs.append(log)
        }
        item.setLogs = logs

        if exercise == nil { item.exercise = nil }  // simulate deletion
        context.insert(item)
        w.items.append(item)
        return item
    }

    private func makeExercise(_ name: String) -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        return ex
    }

    private func ref(_ exercises: [Workout]) -> WorkoutHistoryAnalytics.ExerciseRef {
        WorkoutHistoryAnalytics.availableExercises(in: exercises).first!
    }

    // MARK: - 1. Completed workouts only

    func test_completedWorkoutsOnly() {
        let bench = makeExercise("Bench Press")
        let done = makeWorkout(date: day(0), completed: true)
        addItem(to: done, exercise: bench, sets: [(.working, 5, 100)])

        let active = makeWorkout(date: day(3), completed: false)  // in-progress
        addItem(to: active, exercise: bench, sets: [(.working, 5, 200)])

        let workouts = [done, active]
        let r = ref(workouts)
        let strength = WorkoutHistoryAnalytics.strengthSeries(for: r, in: workouts)

        XCTAssertEqual(strength.count, 1, "only the completed workout contributes")
        XCTAssertEqual(strength.first!.date, day(0))
        XCTAssertEqual(strength.first!.value, 100 * (1 + 5.0 / 30.0), accuracy: 1e-6)
    }

    // MARK: - 2. e1RM = max per workout, with rep cap

    func test_e1RM_maxPerWorkout_andRepCap() {
        let bench = makeExercise("Bench Press")
        let w = makeWorkout(date: day(0))
        addItem(to: w, exercise: bench, sets: [
            (.warmup, 10, 50),    // ignored (warmup)
            (.working, 5, 100),   // e1RM 116.67
            (.working, 2, 120),   // e1RM 128.0  ← max
            (.working, 20, 60),   // excluded from e1RM (reps > 12)
        ])

        let workouts = [w]
        let strength = WorkoutHistoryAnalytics.strengthSeries(for: ref(workouts), in: workouts)

        XCTAssertEqual(strength.count, 1)
        XCTAssertEqual(strength.first!.value, 120 * (1 + 2.0 / 30.0), accuracy: 1e-6)  // 128.0
    }

    // MARK: - 3. Volume aggregation (working only, no rep cap)

    func test_volume_workingOnly_noRepCap() {
        let bench = makeExercise("Bench Press")
        let w = makeWorkout(date: day(0))
        addItem(to: w, exercise: bench, sets: [
            (.working, 5, 100),   // 500
            (.working, 20, 60),   // 1200 (counted — no rep cap on volume)
            (.warmup, 10, 50),    // ignored (warmup)
            (.working, 5, 0),     // ignored (no load)
            (.working, 0, 80),    // ignored (no reps)
        ])

        let workouts = [w]
        let volume = WorkoutHistoryAnalytics.volumeSeries(for: ref(workouts), in: workouts)

        XCTAssertEqual(volume.count, 1)
        XCTAssertEqual(volume.first!.volume, 1700, accuracy: 1e-6)  // 500 + 1200
    }

    // MARK: - 4. Deleted exercise label fallback

    func test_deletedExercise_labelFallback() {
        let w = makeWorkout(date: day(0))
        addItem(to: w, exercise: nil, snapshotName: "Squat", sets: [(.working, 5, 140)])

        let workouts = [w]
        let refs = WorkoutHistoryAnalytics.availableExercises(in: workouts)

        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first!.displayName, "Squat")
        XCTAssertTrue(refs.first!.isDeleted)
        if case .deletedName(let n) = refs.first!.key {
            XCTAssertEqual(n, "squat")
        } else {
            XCTFail("expected .deletedName key for a deleted exercise")
        }

        let strength = WorkoutHistoryAnalytics.strengthSeries(for: refs.first!, in: workouts)
        XCTAssertEqual(strength.first!.value, 140 * (1 + 5.0 / 30.0), accuracy: 1e-6)
    }

    // MARK: - 5. Multiple items, same exercise, one workout

    func test_multipleItemsSameExercise_aggregateInOneWorkout() {
        let bench = makeExercise("Bench Press")
        let w = makeWorkout(date: day(0))
        addItem(to: w, exercise: bench, sets: [(.working, 5, 100)])  // e1RM 116.67, vol 500
        addItem(to: w, exercise: bench, sets: [(.working, 5, 110)])  // e1RM 128.33, vol 550

        let workouts = [w]
        let r = ref(workouts)
        let strength = WorkoutHistoryAnalytics.strengthSeries(for: r, in: workouts)
        let volume = WorkoutHistoryAnalytics.volumeSeries(for: r, in: workouts)

        XCTAssertEqual(strength.count, 1, "one session ⇒ one strength point")
        XCTAssertEqual(strength.first!.value, 110 * (1 + 5.0 / 30.0), accuracy: 1e-6)  // max of the two items
        XCTAssertEqual(volume.count, 1)
        XCTAssertEqual(volume.first!.volume, 1050, accuracy: 1e-6)  // 500 + 550 across items
    }

    // MARK: - 6. Invalid sets filtered → exercise unavailable

    func test_invalidSetsOnly_exerciseNotAvailable() {
        let bench = makeExercise("Bench Press")
        let w = makeWorkout(date: day(0))
        addItem(to: w, exercise: bench, sets: [
            (.warmup, 10, 50),   // warmup
            (.working, 5, 0),    // no load
            (.working, 0, 80),   // no reps
        ])

        let workouts = [w]
        let refs = WorkoutHistoryAnalytics.availableExercises(in: workouts)
        XCTAssertTrue(refs.isEmpty, "no valid working set ⇒ exercise is not selectable")
    }

    // MARK: - Identity + sorting

    func test_availableExercises_identityByIDAndSorted() {
        let squat = makeExercise("Squat")
        let bench = makeExercise("Bench Press")
        let w = makeWorkout(date: day(0))
        addItem(to: w, exercise: squat, sets: [(.working, 5, 140)])
        addItem(to: w, exercise: bench, sets: [(.working, 5, 100)])

        let workouts = [w]
        let refs = WorkoutHistoryAnalytics.availableExercises(in: workouts)

        XCTAssertEqual(refs.map(\.displayName), ["Bench Press", "Squat"], "sorted by name")
        XCTAssertEqual(refs[0].key, .id(bench.id))
        XCTAssertEqual(refs[1].key, .id(squat.id))
    }

    // MARK: - Multi-session series ordering across workouts

    func test_strengthSeries_onesPerCompletedSession() {
        let bench = makeExercise("Bench Press")
        let w1 = makeWorkout(date: day(0))
        addItem(to: w1, exercise: bench, sets: [(.working, 8, 60)])
        let w2 = makeWorkout(date: day(7))
        addItem(to: w2, exercise: bench, sets: [(.working, 5, 70)])

        let workouts = [w1, w2]
        let r = ref(workouts)
        let strength = WorkoutHistoryAnalytics.strengthSeries(for: r, in: workouts)
        let volume = WorkoutHistoryAnalytics.volumeSeries(for: r, in: workouts)

        XCTAssertEqual(strength.count, 2)
        XCTAssertEqual(volume.count, 2)
        // Both series are analyzable by the pure layer.
        let summary = StrengthAnalytics.analyze(strength: strength, volume: volume)
        XCTAssertEqual(summary.pointCount, 2)
        XCTAssertGreaterThan(summary.totalAccumulatedVolume, 0)
    }
}
