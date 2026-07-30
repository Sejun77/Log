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
        // Entry #12 P1: Tempo Override is now blocked for duration too. A
        // tempo describes eccentric/concentric rep phases, and a duration
        // exercise has no reps to phase — this matches the prescription-level
        // rule that hides and clears the tempo field for duration slots.
        XCTAssertTrue(
            techniquesIncompatibleWithDuration.contains(.tempoOverride))
        XCTAssertFalse(
            isTechniqueAllowed(.tempoOverride, isBodyweight: false, usesDuration: true)
        )
        XCTAssertEqual(
            techniqueConflictMessage(
                for: .tempoOverride, isBodyweight: false, usesDuration: true),
            "Not available for duration-based exercises."
        )
        // Unchanged for non-duration exercises.
        XCTAssertTrue(
            isTechniqueAllowed(.tempoOverride, isBodyweight: false, usesDuration: false)
        )
        XCTAssertTrue(
            isTechniqueAllowed(.tempoOverride, isBodyweight: true, usesDuration: false)
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
