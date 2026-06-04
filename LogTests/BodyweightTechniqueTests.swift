import XCTest

@testable import Log

/// Slice 2 — bodyweight consistency for the routine technique picker. Covers
/// the pure type-level availability gate behind
/// `TechniqueTypePickerSheet.conflictMessage(for:)`:
/// `techniqueConflictMessage(for:isBodyweight:usesDuration:)` and its boolean
/// wrapper `isTechniqueAllowed(_:isBodyweight:usesDuration:)`.
final class BodyweightTechniqueTests: XCTestCase {

    // MARK: - Dropset gating

    func testDropsetBlockedForBodyweight() {
        XCTAssertFalse(
            isTechniqueAllowed(.dropset, isBodyweight: true, usesDuration: false)
        )
        XCTAssertEqual(
            techniqueConflictMessage(for: .dropset, isBodyweight: true, usesDuration: false),
            "Not available for bodyweight exercises."
        )
    }

    func testDropsetAllowedForNonBodyweight() {
        XCTAssertTrue(
            isTechniqueAllowed(.dropset, isBodyweight: false, usesDuration: false)
        )
        XCTAssertNil(
            techniqueConflictMessage(for: .dropset, isBodyweight: false, usesDuration: false)
        )
    }

    // MARK: - Other techniques remain allowed for bodyweight

    func testNonWeightTechniquesAllowedForBodyweight() {
        let stillAllowed: [TechniqueType] = [
            .amrap, .restPause, .cluster, .partialReps, .toFailure, .tempoOverride,
        ]
        for type in stillAllowed {
            XCTAssertTrue(
                isTechniqueAllowed(type, isBodyweight: true, usesDuration: false),
                "\(type) should remain allowed for bodyweight"
            )
        }
    }

    // MARK: - Existing duration rules unchanged

    func testDurationRulesUnchangedForNonBodyweight() {
        // Rep-count-dependent techniques are still blocked for duration sets.
        for type in techniquesIncompatibleWithDuration {
            XCTAssertEqual(
                techniqueConflictMessage(for: type, isBodyweight: false, usesDuration: true),
                "Not available for duration-based exercises."
            )
        }
        // Tempo override is not rep-count dependent, so duration does not block it.
        XCTAssertTrue(
            isTechniqueAllowed(.tempoOverride, isBodyweight: false, usesDuration: true)
        )
    }

    // MARK: - Bodyweight precedence

    func testBodyweightDropsetMessageWinsOverDuration() {
        // When both flags apply to dropset, the bodyweight message is returned first.
        XCTAssertEqual(
            techniqueConflictMessage(for: .dropset, isBodyweight: true, usesDuration: true),
            "Not available for bodyweight exercises."
        )
    }
}
