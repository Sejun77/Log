import XCTest

/// Launch smoke coverage for archive / TestFlight builds.
///
/// Replaces the pre-architecture-v2 `HappyPathTests`, which drove a full
/// create-exercise → create-routine → log-set → finish workflow through a dozen
/// accessibility identifiers that no longer exist. That end-to-end shape was
/// the reason it rotted: every UI change broke it, and it asserted on visible
/// copy that localization can move (the app ships `ko` alongside `en`).
///
/// What this covers instead is the part worth gating an archive on — the app
/// comes up, the SwiftData container opens, the launch-time backfills and the
/// built-in exercise seed run without crashing, and all four top-level screens
/// construct and render. Nothing here depends on user-created data or on any
/// user-visible string.
final class LaunchSmokeTests: XCTestCase {

    // MARK: - Fixtures

    /// Tab-bar button positions, in `RootTabView`'s declaration order.
    ///
    /// SwiftUI drops `.accessibilityIdentifier` applied inside `.tabItem`, so
    /// the tab buttons carry no identifier of their own and matching their
    /// labels would tie this test to localized copy. Index is the stable
    /// handle; every tap is then verified against the destination's `screen_*`
    /// identifier, so a reordered tab bar fails loudly here instead of quietly
    /// passing against the wrong screen.
    private enum TabIndex {
        static let routines = 0
        static let exercises = 1
        static let history = 2
        static let settings = 3
    }

    /// Lower bound on the cells the Exercises list shows once the built-in
    /// catalogue is seeded. An iPhone 17 renders 9 (two chrome rows plus the
    /// visible slice of the ~30 seeded exercises); a store that came up without
    /// the seed can only produce the chrome, so this threshold separates the
    /// two while leaving room for smaller screens and layout tweaks — and
    /// without naming a single exercise.
    private let minimumSeededExerciseCells = 5

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Reuses the app's existing UI-testing path (`BootstrapRoot`): it wipes
        // the store and clears the seed-version flag, so each launch starts
        // from a fresh install with the exercise catalogue re-seeded and no
        // routines. It also skips the 1.5s splash floor and suppresses the
        // cardio migration alert, both of which would otherwise race the first
        // assertion.
        app.launchArguments.append("--ui-testing")
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// The app launches under UI-testing mode and reaches its main UI.
    ///
    /// Reaching the tab bar means the model container opened and every
    /// launch-time backfill in `BootstrapRoot.task` completed — the failures
    /// most worth catching before an archive, because they are unrecoverable
    /// on a user's device.
    func testAppLaunchesAndShowsMainTabBar() {
        XCTAssertTrue(
            mainTabBar.waitForExistence(timeout: 60),
            """
            Main tab bar never appeared. The app either crashed on launch, \
            failed to open the SwiftData container, or the splash overlay \
            never cleared.
            """
        )

        XCTAssertTrue(
            app.otherElements["screen_routines"].waitForExistence(timeout: 15),
            "Routines is the default tab but its screen did not render."
        )
    }

    /// Every top-level tab opens and renders its own screen, and the Exercises
    /// tab is populated by the built-in catalogue seed.
    func testEveryMainTabRendersItsScreen() {
        XCTAssertTrue(
            mainTabBar.waitForExistence(timeout: 60),
            "Main tab bar never appeared."
        )

        let exercises = selectTab(
            at: TabIndex.exercises, expecting: "screen_exercises"
        )
        // Proves the seed pass actually populated the store, not just that the
        // screen drew. Scoped to the Exercises screen so unrelated chrome
        // elsewhere in the hierarchy cannot inflate the count.
        XCTAssertGreaterThanOrEqual(
            exercises.cells.count,
            minimumSeededExerciseCells,
            """
            Exercises list looks empty — the built-in catalogue seed did not \
            run or did not persist.
            """
        )

        selectTab(at: TabIndex.history, expecting: "screen_history")
        selectTab(at: TabIndex.settings, expecting: "screen_settings")

        // Return to the default tab so the run ends where it started.
        selectTab(at: TabIndex.routines, expecting: "screen_routines")
    }

    // MARK: - Helpers

    private var mainTabBar: XCUIElement {
        app.tabBars.firstMatch
    }

    /// Taps the tab-bar button at `index` and asserts the screen identified by
    /// `screenID` renders. Returns that screen so callers can scope further
    /// queries to it.
    @discardableResult
    private func selectTab(
        at index: Int,
        expecting screenID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let button = mainTabBar.buttons.element(boundBy: index)
        XCTAssertTrue(
            button.waitForExistence(timeout: 15),
            "No tab-bar button at index \(index).",
            file: file,
            line: line
        )
        button.tap()

        let screen = app.otherElements[screenID]
        XCTAssertTrue(
            screen.waitForExistence(timeout: 15),
            """
            Tapping tab index \(index) did not show '\(screenID)'. The tab \
            order may have changed, or the screen failed to render.
            """,
            file: file,
            line: line
        )
        return screen
    }
}
