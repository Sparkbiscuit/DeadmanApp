//
//  LoomUITestsLaunchTests.swift
//  LoomUITests
//
//  Created by Nicholas Christoforakis on 8/14/24.
//

import XCTest

final class LoomUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-skip-onboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Your Tasks"].waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
