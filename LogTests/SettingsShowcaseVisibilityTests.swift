import XCTest

@testable import Log

/// Build 10 / audit M9 — the Calculus showcase is Debug-only.
///
/// The gate itself is `#if DEBUG`, which no test can observe from the other
/// side: a test bundle is built in the same configuration as the app it hosts,
/// so a Debug run can never see what a Release build renders. That is exactly
/// why the rule is factored into a pure function — `isVisible(isDebug:)` takes
/// the configuration as an argument, so **both** answers are assertable here,
/// and the `#if DEBUG` in `SettingsView` is a one-line application of a rule
/// that is tested rather than a rule that lives only in a preprocessor branch.
final class SettingsShowcaseVisibilityTests: XCTestCase {

    /// A development build keeps the showcase: it is still a useful demo, and
    /// nothing about this slice removes it from the app.
    func testTheShowcaseIsVisibleInADebugBuild() {
        XCTAssertTrue(SettingsShowcaseVisibility.isVisible(isDebug: true))
    }

    /// **The finding.** A Release build — which is what TestFlight ships — must
    /// not offer an AP Calculus AB demo inside a gym app.
    func testTheShowcaseIsHiddenInAReleaseBuild() {
        XCTAssertFalse(SettingsShowcaseVisibility.isVisible(isDebug: false))
    }

    /// The rule is the configuration and nothing else: no `UserDefaults`, no
    /// feature flag, no way for a shipped build to be talked into showing it.
    func testVisibilityIsPurelyTheBuildConfiguration() {
        for isDebug in [true, false] {
            XCTAssertEqual(
                SettingsShowcaseVisibility.isVisible(isDebug: isDebug), isDebug)
            XCTAssertEqual(
                SettingsShowcaseVisibility.isVisible(isDebug: isDebug),
                SettingsShowcaseVisibility.isVisible(isDebug: isDebug),
                "the answer must not depend on anything but its argument")
        }
    }

    /// This suite runs in Debug, so the compiled constant must agree with the
    /// Debug answer. If someone replaces the `#if DEBUG` around the constant
    /// with something that resolves the wrong way, this fails here rather than
    /// surfacing as a showcase row in a TestFlight build.
    func testTheCompiledConstantMatchesThisBuildsConfiguration() {
        #if DEBUG
            XCTAssertTrue(
                SettingsShowcaseVisibility.isVisibleInThisBuild,
                "a Debug build must keep the showcase")
            XCTAssertEqual(
                SettingsShowcaseVisibility.isVisibleInThisBuild,
                SettingsShowcaseVisibility.isVisible(isDebug: true))
        #else
            XCTAssertFalse(
                SettingsShowcaseVisibility.isVisibleInThisBuild,
                "a Release build must not offer the showcase")
            XCTAssertEqual(
                SettingsShowcaseVisibility.isVisibleInThisBuild,
                SettingsShowcaseVisibility.isVisible(isDebug: false))
        #endif
    }
}
