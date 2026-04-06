//
//  MaqkrsTutorUITests.swift
//  MaqkrsTutorUITests
//

import XCTest

final class MaqkrsTutorUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testModelPickerPersistsPerSessionAndSeedsNewSessionsFromGlobalDefault() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MAQKRS_UI_TEST_IN_MEMORY"] = "1"
        app.launchEnvironment["MAQKRS_TEST_INSTALLED_MODELS"] =
            "gemma4:e2b-it-q4_K_M,gemma4:e4b-it-q4_K_M"
        app.launch()

        let newSessionButton = app.buttons["new-session-button"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 5))

        let modelPicker = app.popUpButtons["model-picker"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 5))

        newSessionButton.click()
        XCTAssertTrue(modelPicker.currentValueContains("Gemma 4 E2B"))

        modelPicker.click()
        let e4bItem = app.menuItems["Gemma 4 E4B"]
        XCTAssertTrue(e4bItem.waitForExistence(timeout: 2))
        e4bItem.click()
        XCTAssertTrue(modelPicker.currentValueContains("Gemma 4 E4B"))

        newSessionButton.click()
        XCTAssertTrue(modelPicker.currentValueContains("Gemma 4 E4B"))

        modelPicker.click()
        let e2bItem = app.menuItems["Gemma 4 E2B"]
        XCTAssertTrue(e2bItem.waitForExistence(timeout: 2))
        e2bItem.click()
        XCTAssertTrue(modelPicker.currentValueContains("Gemma 4 E2B"))

        let sessionLinks = app.descendants(matching: .any).matching(identifier: "session-link")
        let olderSession = sessionLinks.element(boundBy: 1)
        XCTAssertTrue(olderSession.waitForExistence(timeout: 2))
        olderSession.click()

        XCTAssertTrue(modelPicker.currentValueContains("Gemma 4 E4B"))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchEnvironment["MAQKRS_UI_TEST_IN_MEMORY"] = "1"
            app.launchEnvironment["MAQKRS_TEST_INSTALLED_MODELS"] =
                "gemma4:e2b-it-q4_K_M,gemma4:e4b-it-q4_K_M"
            app.launch()
        }
    }
}

private extension XCUIElement {
    func currentValueContains(_ expected: String) -> Bool {
        let valueText = value as? String ?? ""
        return label.contains(expected) || valueText.contains(expected)
    }
}
