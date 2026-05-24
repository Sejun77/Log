import SwiftData
import XCTest

@testable import Log

/// Phase 10 polish (Exercises list sorting) — pure tests for the
/// `ExerciseSorter` namespace. `Exercise` is a SwiftData `@Model`, so
/// instances are inserted into the harness's in-memory store before
/// being passed to the sorter; the sorter itself never touches the
/// context. Pins the four sort modes against name/body-part/equipment
/// tiebreakers, nil/whitespace-only field handling, and the input
/// edge cases (empty, single item).
@MainActor
final class ExerciseSorterTests: SwiftDataTestHarness {

    // MARK: - Helpers

    @discardableResult
    private func makeExercise(
        name: String,
        order: Int = 0,
        bodyPart: String? = nil,
        equipmentType: String? = nil
    ) -> Exercise {
        let ex = Exercise(
            name: name,
            bodyPart: bodyPart,
            equipmentType: equipmentType
        )
        ex.order = order
        context.insert(ex)
        return ex
    }

    private func names(_ items: [Exercise]) -> [String] {
        items.map(\.name)
    }

    // MARK: - .manual

    func testManualSortsByOrderThenName() {
        let a = makeExercise(name: "Bench Press", order: 2)
        let b = makeExercise(name: "Deadlift", order: 0)
        let c = makeExercise(name: "Squat", order: 1)
        let d = makeExercise(name: "Curl", order: 2)  // collides with a

        let sorted = ExerciseSorter.sort([a, b, c, d], mode: .manual)
        // order 0 → b, order 1 → c, order 2 → [Bench Press, Curl] by name
        XCTAssertEqual(names(sorted), ["Deadlift", "Squat", "Bench Press", "Curl"])
    }

    // MARK: - .alphabetical

    func testAlphabeticalUsesLocalizedNaturalOrder() {
        // localizedStandardCompare folds case and orders numerics naturally
        let a = makeExercise(name: "bench press")
        let b = makeExercise(name: "Bench Press 2")
        let c = makeExercise(name: "Bench Press 10")
        let d = makeExercise(name: "Áb Wheel")

        let sorted = ExerciseSorter.sort([c, a, d, b], mode: .alphabetical)
        // Á sorts with A; case-insensitive; "2" before "10" under natural order
        XCTAssertEqual(
            names(sorted),
            ["Áb Wheel", "bench press", "Bench Press 2", "Bench Press 10"]
        )
    }

    // MARK: - .bodyPart

    func testBodyPartSortsByBodyPartThenName() {
        let a = makeExercise(name: "Bench Press", bodyPart: "Chest")
        let b = makeExercise(name: "Squat", bodyPart: "Legs")
        let c = makeExercise(name: "Deadlift", bodyPart: "Back")
        let d = makeExercise(name: "Row", bodyPart: "Back")

        let sorted = ExerciseSorter.sort([a, b, c, d], mode: .bodyPart)
        // Back: Deadlift, Row → then Chest: Bench Press → then Legs: Squat
        XCTAssertEqual(names(sorted), ["Deadlift", "Row", "Bench Press", "Squat"])
    }

    func testNilBodyPartSortsAfterNamedRows() {
        let a = makeExercise(name: "Bench Press", bodyPart: "Chest")
        let b = makeExercise(name: "Mystery A", bodyPart: nil)
        let c = makeExercise(name: "Deadlift", bodyPart: "Back")
        let d = makeExercise(name: "Mystery B", bodyPart: nil)

        let sorted = ExerciseSorter.sort([a, b, c, d], mode: .bodyPart)
        XCTAssertEqual(
            names(sorted),
            ["Deadlift", "Bench Press", "Mystery A", "Mystery B"]
        )
    }

    func testWhitespaceOnlyBodyPartTreatedAsNil() {
        let blank = makeExercise(name: "Blank A", bodyPart: "   ")
        let nilOne = makeExercise(name: "Blank B", bodyPart: nil)
        let chest = makeExercise(name: "Bench Press", bodyPart: "Chest")
        let emptyString = makeExercise(name: "Blank C", bodyPart: "")

        let sorted = ExerciseSorter.sort(
            [blank, nilOne, chest, emptyString], mode: .bodyPart
        )
        // All three blanks sort after the named row, ordered by name among themselves
        XCTAssertEqual(
            names(sorted),
            ["Bench Press", "Blank A", "Blank B", "Blank C"]
        )
    }

    // MARK: - .equipment

    func testEquipmentSortMirrorsBodyPartShape() {
        let a = makeExercise(name: "Bench Press", equipmentType: "Barbell")
        let b = makeExercise(name: "Curl", equipmentType: "Dumbbell")
        let c = makeExercise(name: "Press", equipmentType: "Barbell")
        let d = makeExercise(name: "Mystery", equipmentType: nil)

        let sorted = ExerciseSorter.sort([a, b, c, d], mode: .equipment)
        // Barbell: Bench Press, Press → Dumbbell: Curl → nil: Mystery
        XCTAssertEqual(
            names(sorted),
            ["Bench Press", "Press", "Curl", "Mystery"]
        )
    }

    // MARK: - Edge cases

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(ExerciseSorter.sort([], mode: .manual).isEmpty)
        XCTAssertTrue(ExerciseSorter.sort([], mode: .alphabetical).isEmpty)
        XCTAssertTrue(ExerciseSorter.sort([], mode: .bodyPart).isEmpty)
        XCTAssertTrue(ExerciseSorter.sort([], mode: .equipment).isEmpty)
    }

    func testSingleItemPassthroughForEveryMode() {
        let ex = makeExercise(name: "Solo", bodyPart: "Core", equipmentType: "Bodyweight")
        for mode in ExerciseSortMode.allCases {
            let sorted = ExerciseSorter.sort([ex], mode: mode)
            XCTAssertEqual(names(sorted), ["Solo"], "mode=\(mode)")
        }
    }

    // MARK: - SortMode enum

    func testSortModeRawValuesAreStable() {
        // These raw values are the persisted `@AppStorage` strings — never
        // rename without a migration. Pinned so a stray rename trips the
        // build before users see their preference reset to default.
        XCTAssertEqual(ExerciseSortMode.manual.rawValue, "manual")
        XCTAssertEqual(ExerciseSortMode.alphabetical.rawValue, "alphabetical")
        XCTAssertEqual(ExerciseSortMode.bodyPart.rawValue, "bodyPart")
        XCTAssertEqual(ExerciseSortMode.equipment.rawValue, "equipment")
    }

    func testSortModeAllCasesCount() {
        XCTAssertEqual(ExerciseSortMode.allCases.count, 4)
    }
}
