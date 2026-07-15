//
//  LoomUITests.swift
//  LoomUITests
//
//  Created by Nicholas Christoforakis on 8/14/24.
//

import XCTest

final class LoomUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testFreshLaunchCompletesOnboarding() throws {
        let app = launchApp()

        assertVisible(app.staticTexts["Capture in seconds"])
        assertVisible(element(labeled: "Step 1 of 4", in: app))

        app.buttons["Continue"].tap()
        assertVisible(app.staticTexts["Your day"])
        assertVisible(element(labeled: "Step 2 of 4", in: app))

        app.buttons["Continue"].tap()
        assertVisible(app.staticTexts["Manageable blocks"])
        assertVisible(element(labeled: "Step 3 of 4", in: app))

        app.buttons["Continue"].tap()
        assertVisible(app.staticTexts["Stay on pace"])
        assertVisible(element(labeled: "Step 4 of 4", in: app))

        app.buttons["Start weaving"].tap()
        assertVisible(app.staticTexts["Your Tasks"])
        XCTAssertTrue(app.buttons["Tasks"].isSelected)
    }

    func testSkipOnboardingNavigatesTabsAndInspectsCaptureOptions() throws {
        let app = launchApp(skipOnboarding: true)

        assertVisible(app.staticTexts["Your Tasks"])
        visitTab("Schedule", showing: "Schedule", in: app)
        visitTab("Weave", showing: "Your Weave", in: app)
        visitTab("Settings", showing: "Settings", in: app)
        visitTab("Tasks", showing: "Your Tasks", in: app)

        let captureButton = app.buttons["Capture a task"]
        assertVisible(captureButton)
        captureButton.tap()

        let titleField = app.textFields["capture.taskTitleField"]
        assertVisible(titleField)
        dismissKeyboardIfNeeded(in: app)

        let schedulingOptions = app.buttons["capture.moreSchedulingOptions"]
        scrollToHittable(schedulingOptions, in: app)
        schedulingOptions.tap()

        assertVisible(app.staticTexts["Repeats"])
        assertVisible(app.buttons["One-off"])
        assertVisible(app.buttons["Weekly"])
        assertVisible(app.staticTexts["Earliest start"])
        assertVisible(app.buttons["Soon"])
        assertVisible(app.buttons["Pick a time"])

        app.buttons["Cancel"].tap()
        XCTAssertTrue(titleField.waitForNonExistence(timeout: 3))
        assertVisible(app.staticTexts["Your Tasks"])
    }

    private func launchApp(skipOnboarding: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        if skipOnboarding {
            app.launchArguments.append("-ui-testing-skip-onboarding")
        }
        app.launch()
        return app
    }

    private func element(labeled label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    private func visitTab(_ tab: String, showing title: String, in app: XCUIApplication) {
        let button = app.buttons[tab]
        assertVisible(button)
        button.tap()
        assertVisible(app.staticTexts[title])
        XCTAssertTrue(button.isSelected, "Expected \(tab) to be selected")
    }

    private func dismissKeyboardIfNeeded(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 1) else { return }
        let done = keyboard.buttons["Done"]
        if done.exists {
            done.tap()
        }
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<5 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Expected \(element) to become hittable", file: file, line: line)
    }

    private func assertVisible(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), file: file, line: line)
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
