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
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let assetsTab = app.tabBars.buttons["资产"]
        XCTAssertTrue(assetsTab.waitForExistence(timeout: 5))
        assetsTab.tap()

        let settingsButton = app.buttons["我的"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

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
    func test资产页展示总览与分组并支持隐藏金额() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        app.tabBars.buttons["资产"].tap()
        XCTAssertTrue(app.staticTexts["净资产"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["总借入"].exists)
        XCTAssertTrue(app.staticTexts["总借出"].exists)
        attachScreenshot(app, name: "assets-overview")

        // 隐藏金额
        app.buttons["隐藏金额"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "¥ ****")).firstMatch.waitForExistence(timeout: 2))
        attachScreenshot(app, name: "assets-hidden")
        app.buttons["显示金额"].tap()
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
