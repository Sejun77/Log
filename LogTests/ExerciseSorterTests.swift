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

    private func titles(_ sections: [ExerciseSection]) -> [String] {
        sections.map(\.title)
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

    // MARK: - sections(_:mode:) — grouped output

    func testSectionsBodyPartOrderAndContents() {
        let a = makeExercise(name: "Bench Press", bodyPart: "Chest")
        let b = makeExercise(name: "Squat", bodyPart: "Quads")
        let c = makeExercise(name: "Deadlift", bodyPart: "Back")
        let d = makeExercise(name: "Row", bodyPart: "Back")

        let sections = ExerciseSorter.sections([a, b, c, d], mode: .bodyPart)
        let unwrapped = try! XCTUnwrap(sections)
        // Sections in localized order: Back, Chest, Quads
        XCTAssertEqual(titles(unwrapped), ["Back", "Chest", "Quads"])
        // Rows inside each section keep the name-tiebreaker order
        XCTAssertEqual(names(unwrapped[0].items), ["Deadlift", "Row"])
        XCTAssertEqual(names(unwrapped[1].items), ["Bench Press"])
        XCTAssertEqual(names(unwrapped[2].items), ["Squat"])
    }

    func testSectionsEquipmentOrderAndContents() {
        let a = makeExercise(name: "Bench Press", equipmentType: "Barbell")
        let b = makeExercise(name: "Curl", equipmentType: "Dumbbell")
        let c = makeExercise(name: "Press", equipmentType: "Barbell")

        let sections = ExerciseSorter.sections([a, b, c], mode: .equipment)
        let unwrapped = try! XCTUnwrap(sections)
        XCTAssertEqual(titles(unwrapped), ["Barbell", "Dumbbell"])
        XCTAssertEqual(names(unwrapped[0].items), ["Bench Press", "Press"])
        XCTAssertEqual(names(unwrapped[1].items), ["Curl"])
    }

    func testSectionsNilEmptyWhitespaceCollapseIntoTrailingUnspecified() {
        let chest = makeExercise(name: "Bench Press", bodyPart: "Chest")
        let blank = makeExercise(name: "Blank A", bodyPart: "   ")
        let nilOne = makeExercise(name: "Blank B", bodyPart: nil)
        let emptyStr = makeExercise(name: "Blank C", bodyPart: "")

        let sections = ExerciseSorter.sections(
            [chest, blank, nilOne, emptyStr], mode: .bodyPart
        )
        let unwrapped = try! XCTUnwrap(sections)
        // One named section, then a single trailing "Unspecified" bucket
        XCTAssertEqual(
            titles(unwrapped),
            ["Chest", ExerciseSorter.unspecifiedSectionTitle]
        )
        XCTAssertEqual(unwrapped.last?.title, "Unspecified")
        XCTAssertEqual(
            names(unwrapped[1].items), ["Blank A", "Blank B", "Blank C"]
        )
    }

    func testSectionsLegacyCustomValueGetsOwnOrderedSection() {
        // "Legs" and "Arms" are no longer canonical but remain valid stored
        // values; each should form its own section ordered with everything
        // else (the sorter is canonical-agnostic — it groups any string).
        let chest = makeExercise(name: "Bench Press", bodyPart: "Chest")
        let legs = makeExercise(name: "Squat", bodyPart: "Legs")
        let arms = makeExercise(name: "Curl", bodyPart: "Arms")

        let sections = ExerciseSorter.sections(
            [chest, legs, arms], mode: .bodyPart
        )
        let unwrapped = try! XCTUnwrap(sections)
        XCTAssertEqual(titles(unwrapped), ["Arms", "Chest", "Legs"])
        XCTAssertEqual(names(unwrapped[2].items), ["Squat"])
    }

    func testSectionsEmptyInputReturnsNoSections() {
        // Grouped modes return a non-nil but empty section list for empty
        // input (distinct from the `nil` "render flat" signal of manual /
        // alphabetical).
        XCTAssertEqual(try! XCTUnwrap(ExerciseSorter.sections([], mode: .bodyPart)).count, 0)
        XCTAssertEqual(try! XCTUnwrap(ExerciseSorter.sections([], mode: .equipment)).count, 0)
    }

    func testSectionsSingleItemProducesOneSection() {
        let core = makeExercise(name: "Plank", bodyPart: "Core")
        let sections = ExerciseSorter.sections([core], mode: .bodyPart)
        let unwrapped = try! XCTUnwrap(sections)
        XCTAssertEqual(titles(unwrapped), ["Core"])
        XCTAssertEqual(names(unwrapped[0].items), ["Plank"])

        // A single unspecified item still produces one (Unspecified) section.
        let blank = makeExercise(name: "Mystery", bodyPart: nil)
        let blankSections = ExerciseSorter.sections([blank], mode: .bodyPart)
        XCTAssertEqual(
            titles(try! XCTUnwrap(blankSections)),
            [ExerciseSorter.unspecifiedSectionTitle]
        )
    }

    func testSectionsOnFilteredInputDropEmptyGroups() {
        // Simulate the search path: the view filters by name *before* calling
        // the grouping helper, so a section with no surviving rows must not
        // appear at all.
        let chest = makeExercise(name: "Bench Press", bodyPart: "Chest")
        let back = makeExercise(name: "Deadlift", bodyPart: "Back")
        let backRow = makeExercise(name: "Row", bodyPart: "Back")

        // Pretend the user searched "Bench" — only the Chest row survives.
        let filtered = [chest, back, backRow].filter {
            $0.name.localizedCaseInsensitiveContains("Bench")
        }
        let sections = ExerciseSorter.sections(filtered, mode: .bodyPart)
        let unwrapped = try! XCTUnwrap(sections)
        XCTAssertEqual(titles(unwrapped), ["Chest"])
        XCTAssertEqual(names(unwrapped[0].items), ["Bench Press"])
    }

    func testSectionsReturnNilForManualAndAlphabetical() {
        let a = makeExercise(name: "Bench Press", bodyPart: "Chest", equipmentType: "Barbell")
        let b = makeExercise(name: "Squat", bodyPart: "Quads", equipmentType: "Barbell")
        XCTAssertNil(ExerciseSorter.sections([a, b], mode: .manual))
        XCTAssertNil(ExerciseSorter.sections([a, b], mode: .alphabetical))
    }

    func testSectionsOrderIsStableRegardlessOfInputOrder() {
        // Same set, two different input orderings → identical section order.
        let chest = makeExercise(name: "Bench Press", bodyPart: "Chest")
        let back = makeExercise(name: "Deadlift", bodyPart: "Back")
        let quads = makeExercise(name: "Squat", bodyPart: "Quads")
        let blank = makeExercise(name: "Mystery", bodyPart: nil)

        let order1 = ExerciseSorter.sections(
            [chest, back, quads, blank], mode: .bodyPart
        )
        let order2 = ExerciseSorter.sections(
            [blank, quads, chest, back], mode: .bodyPart
        )
        let expected = ["Back", "Chest", "Quads", ExerciseSorter.unspecifiedSectionTitle]
        XCTAssertEqual(titles(try! XCTUnwrap(order1)), expected)
        XCTAssertEqual(titles(try! XCTUnwrap(order2)), expected)
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
