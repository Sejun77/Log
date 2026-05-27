import XCTest

@testable import Log

/// Pure tests for the ordered, duplicate-capable selection model behind the
/// multi-select exercise picker. No SwiftData harness — value-in / value-out.
final class ExerciseMultiSelectionTests: XCTestCase {

    func testStartsEmpty() {
        let s = ExerciseMultiSelection()
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.count, 0)
    }

    func testAppendPreservesTapOrder() {
        let a = UUID()
        let b = UUID()
        var s = ExerciseMultiSelection()
        s.append(a)
        s.append(b)
        s.append(a)
        XCTAssertEqual(s.orderedIDs, [a, b, a])
        XCTAssertEqual(s.count, 3)
        XCTAssertFalse(s.isEmpty)
    }

    func testDuplicateAllowedAndCounted() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        var s = ExerciseMultiSelection()
        s.append(a)
        s.append(b)
        s.append(a)
        XCTAssertEqual(s.count(of: a), 2)
        XCTAssertEqual(s.count(of: b), 1)
        XCTAssertEqual(s.count(of: c), 0)
    }

    func testRemoveAtIndex() {
        let a = UUID()
        let b = UUID()
        var s = ExerciseMultiSelection()
        s.append(a)
        s.append(b)
        s.append(a)
        s.remove(at: 1)  // removes b
        XCTAssertEqual(s.orderedIDs, [a, a])
    }

    func testRemoveAtIndexOutOfRangeIsNoop() {
        let a = UUID()
        var s = ExerciseMultiSelection()
        s.append(a)
        s.remove(at: 5)
        s.remove(at: -1)
        XCTAssertEqual(s.orderedIDs, [a])
    }

    func testRemoveAtOffsets() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        var s = ExerciseMultiSelection()
        s.append(a)
        s.append(b)
        s.append(c)
        s.remove(atOffsets: IndexSet([0, 2]))
        XCTAssertEqual(s.orderedIDs, [b])
    }

    func testRemoveAllClears() {
        let a = UUID()
        var s = ExerciseMultiSelection()
        s.append(a)
        s.append(a)
        s.removeAll()
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.count, 0)
    }

    func testResolvedPreservesOrderAndDuplicates() {
        let a = UUID()
        let b = UUID()
        var s = ExerciseMultiSelection()
        s.append(a)
        s.append(b)
        s.append(a)
        let byID: [UUID: String] = [a: "A", b: "B"]
        XCTAssertEqual(s.resolved(using: byID), ["A", "B", "A"])
    }

    func testResolvedDropsUnknownIDs() {
        let a = UUID()
        let unknown = UUID()
        var s = ExerciseMultiSelection()
        s.append(a)
        s.append(unknown)
        let byID: [UUID: String] = [a: "A"]
        XCTAssertEqual(s.resolved(using: byID), ["A"])
    }

    /// Filtering the visible library (search) must not clear or reorder the
    /// stored selection. The model holds ids independently of any filtered view.
    func testSelectionIndependentOfLibraryFiltering() {
        let a = UUID()
        let b = UUID()
        var s = ExerciseMultiSelection()
        s.append(a)
        s.append(b)

        // Resolving against the full library yields both, in order.
        let fullByID: [UUID: String] = [a: "A", b: "B"]
        XCTAssertEqual(s.resolved(using: fullByID), ["A", "B"])

        // Resolving against a search-narrowed subset drops the hidden one for
        // display purposes but does NOT mutate the stored selection.
        let filteredByID: [UUID: String] = [b: "B"]
        XCTAssertEqual(s.resolved(using: filteredByID), ["B"])
        XCTAssertEqual(s.orderedIDs, [a, b])
    }
}
