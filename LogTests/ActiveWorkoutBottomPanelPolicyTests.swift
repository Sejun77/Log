import XCTest

@testable import Log

/// The Back / Next panel stays in the active workout's bottom safe-area inset
/// whether or not the keyboard is up, so hiding it must not touch its layout.
/// These pin what "hidden" has to mean for a control that is still there.
final class ActiveWorkoutBottomPanelPolicyTests: XCTestCase {

    func testPanelIsFullyPresentWithoutKeyboard() {
        let policy = ActiveWorkoutBottomPanelPolicy(keyboardVisible: false)

        XCTAssertEqual(policy.opacity, 1)
        XCTAssertTrue(policy.isHitTestable)
        XCTAssertFalse(policy.isAccessibilityHidden)
    }

    /// Invisible alone is not enough: the buttons are still in the layout, so
    /// a stray tap or VoiceOver could otherwise navigate away mid-edit.
    func testPanelCannotBeSeenTappedOrReadWhileKeyboardIsUp() {
        let policy = ActiveWorkoutBottomPanelPolicy(keyboardVisible: true)

        XCTAssertEqual(policy.opacity, 0)
        XCTAssertFalse(policy.isHitTestable)
        XCTAssertTrue(policy.isAccessibilityHidden)
    }
}
