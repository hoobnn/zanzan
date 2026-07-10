//
//  zanzanUITests.swift
//  zanzanUITests
//
//  Created by hoobnn on 2026/7/6.
//

import XCTest

final class zanzanUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppIconOptionsFromSettings() throws {
        let app = XCUIApplication()
        app.launch()

        let settingsTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let appIconLink = app.staticTexts["应用图标"]
        XCTAssertTrue(appIconLink.waitForExistence(timeout: 5))
        appIconLink.tap()

        XCTAssertTrue(app.navigationBars["应用图标"].waitForExistence(timeout: 5))

        let emeraldButton = app.buttons["翡翠"]
        let ivoryButton = app.buttons["象牙白"]
        let midnightButton = app.buttons["深墨"]
        XCTAssertTrue(emeraldButton.exists)
        XCTAssertTrue(ivoryButton.exists)
        XCTAssertTrue(midnightButton.exists)

        let selectionValues = [emeraldButton, ivoryButton, midnightButton]
            .compactMap { $0.value as? String }
        XCTAssertEqual(selectionValues.count(where: { $0 == "已选择" }), 1)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
