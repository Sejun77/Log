import XCTest

@testable import Log

/// The strip's visibility is the only logic it has: it sits in a safe-area inset
/// and takes its height from there, so these pin when that inset exists.
final class KeyboardDismissStripPolicyTests: XCTestCase {

    func testShownOnlyWhileTheKeyboardIsUpOnAnEnabledScreen() {
        XCTAssertTrue(
            KeyboardDismissStripPolicy(isEnabled: true, keyboardVisible: true).isShown)
        XCTAssertFalse(
            KeyboardDismissStripPolicy(isEnabled: true, keyboardVisible: false).isShown)
    }

    func testNeverShownForAKeyboardThatDismissesThroughItsOwnReturnKey() {
        XCTAssertFalse(
            KeyboardDismissStripPolicy(isEnabled: false, keyboardVisible: true).isShown)
        XCTAssertFalse(
            KeyboardDismissStripPolicy(isEnabled: false, keyboardVisible: false).isShown)
    }
}
