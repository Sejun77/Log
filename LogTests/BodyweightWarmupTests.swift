import XCTest

@testable import Log

/// Slice 1 — bodyweight consistency for warm-up step editing. Covers the pure
/// rules behind the `WarmupStepEditSheet` kind picker and weight persistence:
/// `warmupKinds(isBodyweight:currentKind:)` and
/// `warmupSavedWeight(kind:isBodyweight:weightText:)`.
final class BodyweightWarmupTests: XCTestCase {

    // MARK: - Kind availability

    func testNonBodyweightOffersAllKinds() {
        let kinds = warmupKinds(isBodyweight: false)
        XCTAssertEqual(kinds, [.fixedReps, .percentage, .noteOnly])
    }

    func testBodyweightAddExcludesPercentage() {
        let kinds = warmupKinds(isBodyweight: true)
        XCTAssertFalse(kinds.contains(.percentage))
    }

    func testBodyweightAddIncludesFixedRepsAndNoteOnly() {
        let kinds = warmupKinds(isBodyweight: true)
        XCTAssertEqual(kinds, [.fixedReps, .noteOnly])
    }

    func testBodyweightEditWithLegacyPercentageKeepsPercentage() {
        let kinds = warmupKinds(isBodyweight: true, currentKind: .percentage)
        XCTAssertTrue(kinds.contains(.percentage))
        XCTAssertTrue(kinds.contains(.fixedReps))
        XCTAssertTrue(kinds.contains(.noteOnly))
    }

    func testBodyweightEditWithFixedRepsDoesNotDuplicate() {
        let kinds = warmupKinds(isBodyweight: true, currentKind: .fixedReps)
        XCTAssertEqual(kinds, [.fixedReps, .noteOnly])
    }

    func testNoDuplicateKinds() {
        for current: WarmupStepKind? in [nil, .fixedReps, .percentage, .noteOnly] {
            for bw in [true, false] {
                let kinds = warmupKinds(isBodyweight: bw, currentKind: current)
                XCTAssertEqual(kinds.count, Set(kinds).count,
                               "duplicate kinds for isBodyweight=\(bw) current=\(String(describing: current))")
            }
        }
    }

    // MARK: - Saved weight

    func testNonBodyweightFixedRepsSavesEnteredWeight() {
        XCTAssertEqual(
            warmupSavedWeight(kind: .fixedReps, isBodyweight: false, weightText: "60.5"),
            60.5
        )
    }

    func testBodyweightFixedRepsSavesNilWeight() {
        XCTAssertNil(
            warmupSavedWeight(kind: .fixedReps, isBodyweight: true, weightText: "60.5")
        )
    }

    func testPercentageSavesNilWeight() {
        XCTAssertNil(
            warmupSavedWeight(kind: .percentage, isBodyweight: false, weightText: "60")
        )
    }

    func testNoteOnlySavesNilWeight() {
        XCTAssertNil(
            warmupSavedWeight(kind: .noteOnly, isBodyweight: false, weightText: "60")
        )
    }
}
