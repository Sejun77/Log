import XCTest

final class HappyPathTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
    }

    private func waitAndTap(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Element not found: \(element)",
            file: file,
            line: line
        )
        element.tap()
    }

    private func attachDebugTree(name: String = "UIHierarchy") {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCreateLogAndSeeHistory() {
        // Wait for tab bar
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        // 1) Add an exercise
        waitAndTap(tabBar.buttons["Exercises"])
        let nameField = app.textFields["exerciseNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Bench Press\n")  // dismiss keyboard
        waitAndTap(app.buttons["addExerciseButton"])
        XCTAssertTrue(
            app.staticTexts["Bench Press"].waitForExistence(timeout: 5)
        )

        // 2) Create a routine
        waitAndTap(tabBar.buttons["Routines"])
        let routineField = app.textFields["routineNameField"]
        XCTAssertTrue(routineField.waitForExistence(timeout: 5))
        routineField.tap()
        routineField.typeText("Upper A\n")
        waitAndTap(app.buttons["addRoutineButton"])

        // Tap the specific row by its StaticText identifier on the label
        let routineRow = app.staticTexts["routineRow_Upper A"]
        if !routineRow.waitForExistence(timeout: 5) {
            attachDebugTree(name: "MissingRoutineRow")
        }
        waitAndTap(routineRow)

        // 3) Open the picker sheet
        let chooseExercises = app.buttons["chooseExercisesButton"]
        if !chooseExercises.waitForExistence(timeout: 5) {
            attachDebugTree(name: "BeforeChooseExercises")
        }
        waitAndTap(chooseExercises)

        // Wait for the sheet, then choose "Bench Press"
        let pickerSheet = app.otherElements["exercisePickerSheet"]
        XCTAssertTrue(
            pickerSheet.waitForExistence(timeout: 5),
            "Exercise picker sheet didn’t appear."
        )
        let benchOption = app.buttons["exerciseOption_Bench Press"]
        if !benchOption.waitForExistence(timeout: 3) {
            // menu rows can be StaticText depending on OS
            let benchText = app.staticTexts["exerciseOption_Bench Press"]
            XCTAssertTrue(
                benchText.waitForExistence(timeout: 3),
                "Missing exercise option ‘Bench Press’."
            )
            benchText.tap()
        } else {
            benchOption.tap()
        }
        waitAndTap(app.buttons["exercisePickerDone"])

        // Add block
        waitAndTap(app.buttons["addBlockButton"])

        // 4) Start workout overview
        waitAndTap(app.buttons["startWorkoutLink"])

        // 5) Begin workout (toolbar button inside StartWorkoutFromRoutineView)
        waitAndTap(app.buttons["beginWorkoutButton"])

        // Prove we are on ActiveWorkoutView
        XCTAssertTrue(
            app.navigationBars["Workout"].waitForExistence(timeout: 5)
        )

        // 6) Log the first set (index 0)
        let firstLog = app.buttons["logSetButton_0"]
        if !firstLog.waitForExistence(timeout: 5) { app.swipeUp() }
        waitAndTap(firstLog)

        // 7) Finish workout
        let finish = app.buttons["Finish Workout"]
        if !finish.waitForExistence(timeout: 5) {
            attachDebugTree(name: "BeforeFinish")
        }
        waitAndTap(finish)

        // 8) Verify it appears in History
        waitAndTap(tabBar.buttons["History"])
        XCTAssertTrue(
            app.staticTexts.element(boundBy: 0).waitForExistence(timeout: 5)
        )
    }
}
