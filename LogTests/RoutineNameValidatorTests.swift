import XCTest

@testable import Log

/// Pure tests for the routine-rename validation rules used by
/// `RoutineEditor.commitRename()`. No SwiftData harness needed — the validator
/// is value-in / value-out.
final class RoutineNameValidatorTests: XCTestCase {

    // MARK: - sanitized

    func testSanitizedTrimsWhitespaceAndNewlines() {
        XCTAssertEqual(RoutineNameValidator.sanitized("  Push  "), "Push")
        XCTAssertEqual(RoutineNameValidator.sanitized("\nPull\n"), "Pull")
        XCTAssertEqual(RoutineNameValidator.sanitized("\tUpper A "), "Upper A")
    }

    func testSanitizedReturnsNilForEmptyOrWhitespace() {
        XCTAssertNil(RoutineNameValidator.sanitized(""))
        XCTAssertNil(RoutineNameValidator.sanitized("   "))
        XCTAssertNil(RoutineNameValidator.sanitized("\n \t"))
    }

    // MARK: - validateRename

    func testValidateRenameEmptyReturnsEmpty() {
        XCTAssertEqual(
            RoutineNameValidator.validateRename(
                raw: "   ", previous: "Push", otherNames: ["Pull"]
            ),
            .empty
        )
    }

    func testValidateRenameUnchangedWhenTrimmedEqualsPrevious() {
        XCTAssertEqual(
            RoutineNameValidator.validateRename(
                raw: "  Push  ", previous: "Push", otherNames: ["Pull"]
            ),
            .unchanged
        )
    }

    func testValidateRenameRejectsCaseInsensitiveDuplicate() {
        XCTAssertEqual(
            RoutineNameValidator.validateRename(
                raw: "pull", previous: "Push", otherNames: ["Pull", "Legs"]
            ),
            .duplicate("pull")
        )
    }

    func testValidateRenameAcceptsNewUniqueName() {
        XCTAssertEqual(
            RoutineNameValidator.validateRename(
                raw: "  Upper A ", previous: "Push", otherNames: ["Pull"]
            ),
            .ok("Upper A")
        )
    }

    func testValidateRenameAllowsCaseChangeOfSelf() {
        // "push" differs from "Push" and self is excluded from `otherNames`,
        // so changing only the casing of the routine's own name is accepted.
        XCTAssertEqual(
            RoutineNameValidator.validateRename(
                raw: "push", previous: "Push", otherNames: ["Pull"]
            ),
            .ok("push")
        )
    }

    func testValidateRenameDuplicateCheckExcludesSelfViaCaller() {
        // Caller passes only OTHER routine names; an identical re-save of the
        // current name is reported as `.unchanged`, never `.duplicate`.
        XCTAssertEqual(
            RoutineNameValidator.validateRename(
                raw: "Push", previous: "Push", otherNames: []
            ),
            .unchanged
        )
    }
}
