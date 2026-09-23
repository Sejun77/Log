import SwiftData
import XCTest

@testable import Log

/// Covers the Saved Routines row's trailing Start button gate
/// (`RoutineQuickStart`). The button itself is SwiftUI wiring and is verified
/// manually; what is pinned here is that it can never offer a start the
/// routine editor's own Start would refuse, and never shows while a workout is
/// already active.
@MainActor
final class RoutineQuickStartTests: SwiftDataTestHarness {

    // MARK: - Fixtures

    private func makeExercise(_ name: String) -> Exercise {
        let ex = Exercise(name: name, isCustom: true)
        context.insert(ex)
        return ex
    }

    private func makeBlock(
        _ exercises: [Exercise],
        isSuperset: Bool = false,
        supersetRoundRestSeconds: Int? = nil,
        order: Int = 0
    ) -> RoutineBlock {
        let slots = exercises.enumerated().map { i, ex in
            let re = RoutineExercise(exercise: ex, order: i, setTemplates: [])
            context.insert(re)
            return re
        }
        let b = RoutineBlock(isSuperset: isSuperset, order: order, exercises: slots)
        b.supersetRoundRestSeconds = supersetRoundRestSeconds
        context.insert(b)
        return b
    }

    private func makeRoutine(_ name: String, blocks: [RoutineBlock]) -> Routine {
        let r = Routine(name: name, blocks: blocks)
        context.insert(r)
        return r
    }

    /// One routine of every startability shape the editor distinguishes.
    private func makeMixedRoutines() -> [Routine] {
        let bench = makeExercise("Bench Press")
        let row = makeExercise("Row")
        let curl = makeExercise("Curl")
        let routines = [
            makeRoutine("Normal", blocks: [makeBlock([bench])]),
            makeRoutine("Empty", blocks: []),
            makeRoutine(
                "Superset no rest",
                blocks: [makeBlock([bench, row], isSuperset: true)]
            ),
            makeRoutine(
                "Superset with rest",
                blocks: [
                    makeBlock(
                        [row, curl], isSuperset: true,
                        supersetRoundRestSeconds: 90)
                ]
            ),
        ]
        try? context.save()
        return routines
    }

    // MARK: - Startability parity with the editor

    func testStartableIDsMatchTheEditorRulePerRoutine() {
        let routines = makeMixedRoutines()

        let startable = RoutineQuickStart.startableRoutineIDs(
            for: routines, in: context)

        for r in routines {
            XCTAssertEqual(
                startable.contains(r.id), r.isStartable(in: context),
                "row gate disagrees with the editor's Start for \(r.name)")
        }
        XCTAssertEqual(
            Set(routines.filter { ["Normal", "Superset with rest"].contains($0.name) }
                .map(\.id)),
            startable)
    }

    func testRoutineWithDeletedExerciseIsNotOfferedStart() {
        let ex = makeExercise("Gone")
        let r = makeRoutine("Orphaned", blocks: [makeBlock([ex])])
        try? context.save()
        context.delete(ex)
        try? context.save()

        XCTAssertFalse(r.isStartable(in: context))
        XCTAssertTrue(
            RoutineQuickStart.startableRoutineIDs(for: [r], in: context).isEmpty)
    }

    func testNoRoutinesMeansNoStartableIDs() {
        XCTAssertTrue(
            RoutineQuickStart.startableRoutineIDs(for: [], in: context).isEmpty)
    }

    // MARK: - Visibility

    func testStartButtonShowsOnlyForStartableRoutinesWithNoActiveWorkout() {
        let startable = UUID()
        let blocked = UUID()
        let ids: Set<UUID> = [startable]

        XCTAssertTrue(
            RoutineQuickStart.showsStartButton(
                routineID: startable, startableIDs: ids, hasActiveWorkout: false))
        XCTAssertFalse(
            RoutineQuickStart.showsStartButton(
                routineID: blocked, startableIDs: ids, hasActiveWorkout: false))
    }

    /// While a workout is active, no row offers Start — not even for the
    /// active routine itself or an otherwise-startable one. Resume and the
    /// editor's "Start New" confirmation remain the only paths.
    func testStartButtonHiddenOnEveryRowWhileAWorkoutIsActive() {
        let a = UUID()
        let b = UUID()
        for id in [a, b] {
            XCTAssertFalse(
                RoutineQuickStart.showsStartButton(
                    routineID: id, startableIDs: [a, b], hasActiveWorkout: true))
        }
    }

    // MARK: - Same start path

    /// The row button pushes `StartWorkoutFromRoutineView` for the tapped
    /// routine; that view builds its plan with the same `makePlan`, so the
    /// session is tied to the tapped routine's identity.
    func testRowStartBuildsPlanForTheTappedRoutine() {
        let routines = makeMixedRoutines()
        let tapped = routines[0]

        let plan = StartWorkoutFromRoutineView.makePlan(from: tapped)

        XCTAssertEqual(plan.routineID, tapped.id)
        XCTAssertEqual(plan.routineName, tapped.name)
        XCTAssertFalse(plan.blocks.isEmpty)
    }

    // MARK: - Reused copy

    /// The row button and the Routines toolbar Help button add no catalog keys;
    /// they reuse these existing ones, which must stay translated.
    func testReusedKeysLocalizeToKorean() throws {
        let path = try XCTUnwrap(
            Bundle(for: Exercise.self).path(forResource: "ko", ofType: "lproj"))
        let ko = try XCTUnwrap(Bundle(path: path))
        let expected = [
            "Start": "시작",
            "Start Workout": "운동 시작",
            "User Guide": "사용자 가이드",
        ]
        for (key, korean) in expected {
            XCTAssertEqual(
                ko.localizedString(forKey: key, value: key, table: nil), korean)
        }
    }
}
