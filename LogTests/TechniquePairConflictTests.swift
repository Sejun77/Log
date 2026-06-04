import XCTest

@testable import Log

/// Technique overlap cleanup — covers the pure pairwise conflict helper
/// `techniquePairConflict(_:_:)` that both the technique picker
/// (`TechniqueTypePickerSheet.conflictMessage(for:)`) and the per-set-index
/// toggle (`TechniqueParamEditView.conflictForAdding(idx:)`) now share.
///
/// Type-level bodyweight/duration gating lives in `BodyweightTechniqueTests`
/// and is intentionally not re-covered here.
final class TechniquePairConflictTests: XCTestCase {

    private func assertAllowed(
        _ a: TechniqueType, _ b: TechniqueType,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNil(
            techniquePairConflict(a, b),
            "\(a)+\(b) should be allowed", file: file, line: line
        )
        XCTAssertNil(
            techniquePairConflict(b, a),
            "\(b)+\(a) should be allowed (order-independent)", file: file, line: line
        )
    }

    private func assertBlocked(
        _ a: TechniqueType, _ b: TechniqueType,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNotNil(
            techniquePairConflict(a, b),
            "\(a)+\(b) should be blocked", file: file, line: line
        )
        XCTAssertNotNil(
            techniquePairConflict(b, a),
            "\(b)+\(a) should be blocked (order-independent)", file: file, line: line
        )
    }

    // MARK: - Newly allowed / confirmed allowed

    func testDropSetPlusRestPauseAllowed() {
        assertAllowed(.dropset, .restPause)
    }

    func testRestPausePlusAmrapAllowed() {
        assertAllowed(.restPause, .amrap)
    }

    func testAmrapPlusToFailureAllowed() {
        assertAllowed(.amrap, .toFailure)
    }

    func testDropSetEffortAndExecutionCombos() {
        assertAllowed(.dropset, .toFailure)
        assertAllowed(.dropset, .partialReps)
        assertAllowed(.dropset, .tempoOverride)
        assertAllowed(.restPause, .tempoOverride)
        assertAllowed(.partialReps, .tempoOverride)
    }

    // MARK: - Still blocked

    func testDropSetPlusAmrapBlocked() {
        assertBlocked(.dropset, .amrap)
    }

    func testDropSetPlusClusterBlocked() {
        assertBlocked(.dropset, .cluster)
    }

    func testRestPausePlusClusterBlocked() {
        assertBlocked(.restPause, .cluster)
    }

    func testClusterPlusAmrapBlocked() {
        assertBlocked(.cluster, .amrap)
    }

    // MARK: - Duplicate handling (folded into helper)

    func testDuplicateSameTypeBlocked() {
        for type in TechniqueType.allCases {
            XCTAssertNotNil(
                techniquePairConflict(type, type),
                "duplicate \(type) on the same set should be blocked"
            )
        }
    }
}
