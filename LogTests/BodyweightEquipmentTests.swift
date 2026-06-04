import XCTest

@testable import Log

/// Covers `isBodyweightEquipment(_:)` — the pure classifier that drives hiding
/// the weight input for bodyweight exercises during an active workout. Trimmed
/// + case-insensitive so imported/legacy casings still match; nil/empty/other
/// equipment types are not bodyweight.
final class BodyweightEquipmentTests: XCTestCase {

    func testCanonicalValueIsBodyweight() {
        XCTAssertTrue(isBodyweightEquipment("Bodyweight"))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertTrue(isBodyweightEquipment(" bodyweight "))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(isBodyweightEquipment("BODYWEIGHT"))
    }

    func testNilIsNotBodyweight() {
        XCTAssertFalse(isBodyweightEquipment(nil))
    }

    func testEmptyStringIsNotBodyweight() {
        XCTAssertFalse(isBodyweightEquipment(""))
    }

    func testBarbellIsNotBodyweight() {
        XCTAssertFalse(isBodyweightEquipment("Barbell"))
    }

    func testDumbbellIsNotBodyweight() {
        XCTAssertFalse(isBodyweightEquipment("Dumbbell"))
    }
}
