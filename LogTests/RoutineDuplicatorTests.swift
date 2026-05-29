import XCTest

@testable import Log

/// Pure tests for `RoutineDuplicator.copiedName(for:existingNames:)` — the
/// copied-routine-name generator (Slice A). Value-in / value-out, no SwiftData
/// model or `ModelContext` needed, mirroring `RoutineNameValidatorTests`.
final class RoutineDuplicatorTests: XCTestCase {

    func testNoCollisionUsesBaseCopyName() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "Upper A", existingNames: ["Lower A"]
            ),
            "Upper A copy"
        )
    }

    func testFirstCopyCollisionAppendsTwo() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "Upper A", existingNames: ["Upper A", "Upper A copy"]
            ),
            "Upper A copy 2"
        )
    }

    func testMultipleCollisionsIncrementSuffix() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "Upper A",
                existingNames: ["Upper A copy", "Upper A copy 2"]
            ),
            "Upper A copy 3"
        )
    }

    func testCaseInsensitiveCollision() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "Upper A", existingNames: ["upper a copy"]
            ),
            "Upper A copy 2"
        )
    }

    func testOriginalNameTrimmed() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "  Upper A  ", existingNames: []
            ),
            "Upper A copy"
        )
    }

    func testExistingNamesTrimmedForCollision() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: "Upper A", existingNames: [" Upper A copy "]
            ),
            "Upper A copy 2"
        )
    }

    func testEmptyOriginalFallsBackToRoutine() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(for: "", existingNames: []),
            "Routine copy"
        )
    }

    func testWhitespaceOnlyOriginalFallsBackToRoutine() {
        XCTAssertEqual(
            RoutineDuplicator.copiedName(for: "   ", existingNames: []),
            "Routine copy"
        )
        // And the fallback still de-dupes against existing "Routine copy".
        XCTAssertEqual(
            RoutineDuplicator.copiedName(
                for: " ", existingNames: ["Routine copy"]
            ),
            "Routine copy 2"
        )
    }
}
