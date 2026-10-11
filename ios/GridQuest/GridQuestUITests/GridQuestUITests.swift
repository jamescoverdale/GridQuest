import XCTest

final class GridQuestUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSampleGridAndReturnToOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["SAMPLE GRID"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["6 × 6"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "GridQuest sample grid"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["connectHealth"].waitForExistence(timeout: 5))
        app.buttons["sampleGrid"].tap()
        XCTAssertTrue(app.staticTexts["SAMPLE GRID"].waitForExistence(timeout: 5))
    }

    @MainActor func testAboutAndGridControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["Hide grid lines"].waitForExistence(timeout: 10))
        app.buttons["Hide grid lines"].tap()
        XCTAssertTrue(app.buttons["Show grid lines"].exists)
        app.buttons["GridQuest options"].tap()
        XCTAssertFalse(app.buttons["Fit collected squares"].exists)
        app.buttons["About GridQuest"].tap()
        XCTAssertTrue(app.navigationBars["About GridQuest"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["GridQuest is a modern clone of Squadra by Bert Temme, bringing its square-collecting adventure to Apple Health workouts."].exists)
        XCTAssertTrue(app.buttons["Visit the Squadra website"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["SAMPLE GRID"].exists)
    }

    @MainActor func testLargestSquareChangesMapCamera() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["jumpLargestSquare"].waitForExistence(timeout: 10))
        app.buttons["jumpLargestSquare"].tap()
        let map = app.descendants(matching: .any).matching(identifier: "explorationMap").firstMatch
        let focused = NSPredicate(format: "value == %@", "Showing largest square")
        expectation(for: focused, evaluatedWith: map)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["Jump home"].exists)
        XCTAssertFalse(app.buttons["Sync Apple Health"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Focused largest square"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testCollectedSquareSelectionShowsDateAndClears() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["jumpLargestSquare"].waitForExistence(timeout: 10))
        app.buttons["jumpLargestSquare"].tap()
        let map = app.descendants(matching: .any).matching(identifier: "explorationMap").firstMatch
        expectation(for: NSPredicate(format: "value == %@", "Showing largest square"), evaluatedWith: map)
        waitForExpectations(timeout: 5)
        // Tap inside the filled sample square, away from the floating controls.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.staticTexts["firstCollectedDate"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "Selected collected square"), evaluatedWith: map)
        waitForExpectations(timeout: 5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Selected square and first collected date"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Close square details"].tap()
        XCTAssertFalse(app.staticTexts["firstCollectedDate"].exists)
        // This point lies outside the sample block and its narrow extensions.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.70)).tap()
        XCTAssertTrue(app.staticTexts["A new square to explore"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["firstCollectedDate"].exists)
        expectation(for: NSPredicate(format: "value == %@", "Selected uncollected square"), evaluatedWith: map)
        waitForExpectations(timeout: 5)
    }
}
