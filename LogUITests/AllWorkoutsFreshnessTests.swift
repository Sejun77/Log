import XCTest

/// All Workouts must keep the user's place and show correct data when they switch
/// tabs while it is pushed, log sets elsewhere, and come back.
///
/// Its rows compute their summaries lazily, so these tests read what is on screen
/// after each kind of change rather than trusting a cached value.
///
/// Launches with `--ui-testing`, which WIPES THE STORE, so every test skips itself
/// anywhere but a Simulator. The workouts come from `UITestFixtures`.
///
/// Known issue, unresolved (2026-11-05): one full-suite run failed two assertions
/// that passed in the other full-suite runs. In `test_tabSwitch…`, the first
/// `assertAllWorkoutsTopRowShows` did not find the All Workouts bar after the tab
/// switch. In `test_back…`, `openAllWorkouts` did not find it after tapping View All
/// Workouts. That run kept no screenshots and the cause is not established, so treat
/// a recurrence as a possible app bug. Do not relax these assertions to get past it.
final class AllWorkoutsFreshnessTests: XCTestCase {

    private enum TabIndex {
        static let routines = 0
        static let history = 2
    }

    /// `UITestFixtures` gives every history workout this subtitle.
    private let seededSubtitle = "2 exercises · 4 sets"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        #if !targetEnvironment(simulator)
        throw XCTSkip("--ui-testing wipes the store: Simulator only.")
        #else
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing", "--ui-test-workout-history",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 180))
        discardSessionLeftByPreviousTest()
        XCTAssertTrue(startWorkoutRow.waitForExistence(timeout: 120))
        #endif
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// Log, Undo and Save & Exit made in another tab all reach the kept-open list,
    /// and a delete made from that list removes only the chosen workout.
    func test_tabSwitchKeepsAllWorkoutsOpenWithFreshData() {
        selectTab(TabIndex.history)
        openAllWorkouts()
        XCTAssertTrue(topRow.staticTexts[seededSubtitle].waitForExistence(timeout: 15))

        selectTab(TabIndex.routines)
        enterWorkout()
        logSet()
        assertAllWorkoutsTopRowShows("1 exercise · 1 set", inProgress: true)

        returnToWorkout()
        logSet()
        assertAllWorkoutsTopRowShows("1 exercise · 2 sets", inProgress: true)

        returnToWorkout()
        app.buttons["Undo"].firstMatch.tap()
        assertAllWorkoutsTopRowShows("1 exercise · 1 set", inProgress: true)

        returnToWorkout()
        endButton.tap()
        let saveAndExit = app.buttons["Save & Exit"].firstMatch
        XCTAssertTrue(saveAndExit.waitForExistence(timeout: 15))
        saveAndExit.tap()
        // Save & Exit keeps the workout resumable.
        XCTAssertTrue(app.staticTexts["Resume workout"].firstMatch.waitForExistence(timeout: 30))
        assertAllWorkoutsTopRowShows("1 exercise · 1 set", inProgress: true)

        // A neighbor of the row deleted below keeps its own data.
        let victim = app.cells.element(boundBy: 2)
        XCTAssertTrue(victim.staticTexts[seededSubtitle].waitForExistence(timeout: 15))
        let victimLabels = labels(of: victim)
        let neighborLabels = labels(of: app.cells.element(boundBy: 3))

        victim.swipeLeft()
        let deleteAction = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 10))
        deleteAction.tap()
        let confirm = app.alerts.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        let deadline = Date().addingTimeInterval(15)
        while visibleRowLabels().contains(victimLabels) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(visibleRowLabels().contains(victimLabels), "Deleted workout is still listed.")
        XCTAssertTrue(visibleRowLabels().contains(neighborLabels), "A workout other than the chosen one changed.")
        XCTAssertTrue(topRow.staticTexts["1 exercise · 1 set"].exists)
    }

    /// Rows built only once they scroll into view still show their own data.
    func test_rowsBuiltByScrollingShowTheirData() {
        selectTab(TabIndex.history)
        openAllWorkouts()

        var seenRows = Set(visibleRowLabels())
        for _ in 0..<6 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
            let rows = visibleRowLabels()
            XCTAssertFalse(rows.isEmpty)
            for row in rows {
                XCTAssertTrue(row.hasSuffix(seededSubtitle), "Wrong summary on row: \(row)")
            }
            seenRows.formUnion(rows)
        }
        XCTAssertGreaterThan(seenRows.count, 20, "The list did not scroll to new rows.")
    }

    /// Back leaves All Workouts, and it does not come back on a later tab switch.
    /// Reopening it still shows the data logged in the meantime.
    func test_backReturnsToHistoryAndReopenShowsFreshData() {
        selectTab(TabIndex.history)
        openAllWorkouts()

        app.navigationBars["All Workouts"].buttons.firstMatch.tap()
        XCTAssertTrue(viewAllWorkoutsRow.waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars["All Workouts"].exists)

        selectTab(TabIndex.routines)
        enterWorkout()
        logSet()

        selectTab(TabIndex.history)
        XCTAssertFalse(app.navigationBars["All Workouts"].waitForExistence(timeout: 3))

        openAllWorkouts()
        XCTAssertTrue(topRow.staticTexts["1 exercise · 1 set"].waitForExistence(timeout: 15))
    }

    // MARK: - Helpers

    private var startWorkoutRow: XCUIElement { app.buttons["startWorkoutFromRoutineRow"].firstMatch }
    private var topRow: XCUIElement { app.cells.element(boundBy: 0) }
    private var endButton: XCUIElement { app.navigationBars.buttons["End"].firstMatch }
    private var viewAllWorkoutsRow: XCUIElement { app.buttons["View All Workouts"].firstMatch }

    /// A session left active by an earlier test can survive the store wipe, leaving
    /// Routines offering to resume it instead of to start a workout.
    private func discardSessionLeftByPreviousTest() {
        guard !startWorkoutRow.waitForExistence(timeout: 30) else { return }
        let resume = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Resume workout'")).firstMatch
        guard resume.waitForExistence(timeout: 30) else { return }
        resume.tap()
        closeRestTimerIfShown()
        XCTAssertTrue(endButton.waitForExistence(timeout: 30))
        endButton.tap()
        let discard = app.buttons["Discard Workout"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 15))
        discard.tap()
    }

    private func selectTab(_ index: Int) {
        app.tabBars.firstMatch.buttons.element(boundBy: index).tap()
    }

    private func openAllWorkouts() {
        XCTAssertTrue(viewAllWorkoutsRow.waitForExistence(timeout: 30))
        for _ in 0..<8 where !viewAllWorkoutsRow.isHittable { app.swipeDown() }
        viewAllWorkoutsRow.tap()
        XCTAssertTrue(app.navigationBars["All Workouts"].waitForExistence(timeout: 30))
    }

    private func enterWorkout() {
        startWorkoutRow.tap()
        // The row tap lands on the editor under XCUITest; both routes lead to the
        // same Start Workout screen.
        let viaEditor = app.buttons["startWorkoutFromEditor"].firstMatch
        if viaEditor.waitForExistence(timeout: 5) { viaEditor.tap() }
        let begin = app.navigationBars.buttons["Start Workout"].firstMatch
        XCTAssertTrue(begin.waitForExistence(timeout: 30))
        let enabled = NSPredicate(format: "isEnabled == true")
        wait(for: [expectation(for: enabled, evaluatedWith: begin)], timeout: 30)
        begin.tap()

        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(endButton.waitForExistence(timeout: 60))
    }

    private func logSet() {
        closeRestTimerIfShown()
        let log = app.buttons["Log"].firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 30))
        log.tap()
        closeRestTimerIfShown()
    }

    /// The full-screen rest timer covers the workout's own controls.
    private func closeRestTimerIfShown() {
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }
    }

    private func returnToWorkout() {
        selectTab(TabIndex.routines)
        closeRestTimerIfShown()
        XCTAssertTrue(endButton.waitForExistence(timeout: 30))
    }

    private func assertAllWorkoutsTopRowShows(
        _ subtitle: String,
        inProgress: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        selectTab(TabIndex.history)
        XCTAssertTrue(
            app.navigationBars["All Workouts"].waitForExistence(timeout: 15),
            "The tab switch lost the user's place in All Workouts.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            topRow.staticTexts[subtitle].waitForExistence(timeout: 15),
            "Top row shows \(labels(of: topRow)), expected \(subtitle).",
            file: file,
            line: line
        )
        XCTAssertEqual(topRow.staticTexts["In Progress"].exists, inProgress, file: file, line: line)
    }

    private func labels(of cell: XCUIElement) -> String {
        cell.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
    }

    private func visibleRowLabels() -> [String] {
        app.cells.allElementsBoundByIndex.map(labels(of:)).filter { !$0.isEmpty }
    }
}
