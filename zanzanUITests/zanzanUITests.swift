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
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-zanzan.appLanguage", "zh-Hans",
            "-zanzan.brandTheme", "ivory",
        ]
        app.launch()

        let assetsTab = app.tabBars.buttons["资产"]
        XCTAssertTrue(assetsTab.waitForExistence(timeout: 5))
        assetsTab.tap()

        let settingsButton = app.buttons["我的"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        let appIconLink = app.staticTexts["应用图标"]
        scrollToElement(appIconLink, in: app)
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
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-zanzan.appLanguage", "zh-Hans",
            "-zanzan.brandTheme", "ivory",
        ]
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
    func testSketchGlassSettingsScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-zanzan.uiTesting",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-zanzan.appLanguage", "zh-Hans",
            "-zanzan.brandTheme", "ivory",
            "-zanzan.backdropStyle", "sketch",
            "-zanzan.transactionRowFrame", "NO",
        ]
        app.launch()

        app.tabBars.buttons["资产"].tap()
        XCTAssertTrue(app.buttons["我的"].waitForExistence(timeout: 5))
        app.buttons["我的"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.waitForNonExistence(timeout: 3))
        attachScreenshot(app, name: "sketch-settings-home-top")

        let destinations = [
            ("settings.link.ledgers", "账本", "screen.ledgers", "sketch-settings-ledgers"),
            ("settings.link.accounts", "账户管理", "screen.accounts", "sketch-settings-accounts"),
            ("settings.link.categories", "分类管理", "screen.categories", "sketch-settings-categories"),
            ("settings.link.tags", "标签管理", "screen.tags", "sketch-settings-tags"),
            ("settings.link.budgets", "预算", "screen.budgets", "sketch-settings-budgets"),
            ("settings.link.reimbursements", "报销与退款", "screen.reimbursements", "sketch-settings-reimbursements"),
            ("settings.link.recurring", "周期记账", "screen.recurring", "sketch-settings-recurring"),
            ("settings.link.installments", "分期与贷款", "screen.installments", "sketch-settings-installments"),
            ("settings.link.creditPools", "授信池", "screen.creditPools", "sketch-settings-credit-pools"),
            ("settings.link.dataTransfer", "数据导入导出", "screen.dataTransfer", "sketch-settings-data-transfer"),
            ("settings.link.maintenance", "数据维护", "screen.maintenance", "sketch-settings-maintenance"),
            ("settings.link.recentlyDeleted", "最近删除", "screen.recentlyDeleted", "sketch-settings-recently-deleted"),
            ("settings.link.appearance", "外观与语言", "screen.appearance", "sketch-settings-appearance"),
            ("settings.link.appIcon", "应用图标", "screen.appIcon", "sketch-settings-app-icon"),
        ]

        let settingsScrollView = app.scrollViews["screen.settings"]
        XCTAssertTrue(settingsScrollView.exists)

        for (linkIdentifier, title, screenIdentifier, screenshotName) in destinations {
            let link = app.buttons[linkIdentifier]
            scrollToElement(link, in: settingsScrollView)
            XCTAssertTrue(link.isHittable, "\(title) 入口不可点击")
            link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), "\(title) 页面未打开")
            XCTAssertTrue(
                app.descendants(matching: .any)[screenIdentifier].waitForExistence(timeout: 3),
                "\(title) 页面根标识不存在"
            )
            if screenIdentifier == "screen.appearance" {
                XCTAssertTrue(app.segmentedControls["appearance.backdrop"].exists)
                XCTAssertEqual(
                    app.switches["appearance.transactionRowFrame"].value as? String,
                    "0"
                )
            }
            attachScreenshot(app, name: screenshotName)
            app.navigationBars[title].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        }
        attachScreenshot(app, name: "sketch-settings-home-bottom")
    }

    @MainActor
    func test统计页与账本筛选器可用() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-zanzan.appLanguage", "zh-Hans",
            "-zanzan.brandTheme", "ivory",
        ]
        app.launch()

        app.tabBars.buttons["统计"].tap()
        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["本月结余"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["上一月"].exists)
        XCTAssertTrue(app.buttons["下一月"].exists)
        attachScreenshot(app, name: "stats-overview")

        app.tabBars.buttons["账本"].tap()
        XCTAssertTrue(app.buttons["筛选"].waitForExistence(timeout: 5))
        app.buttons["筛选"].tap()
        XCTAssertTrue(app.buttons["全部类型"].waitForExistence(timeout: 3))
    }

    @MainActor
    func test记账页支持选择二级分类并保留特殊设计() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-zanzan.appLanguage", "zh-Hans",
            "-zanzan.brandTheme", "ivory",
        ]
        app.launch()

        app.tabBars.buttons["记账"].tap()
        XCTAssertTrue(app.buttons["餐饮"].waitForExistence(timeout: 5))
        app.buttons["餐饮"].tap()
        XCTAssertTrue(app.staticTexts["二级分类"].waitForExistence(timeout: 3))

        let breakfast = app.buttons["早餐"]
        XCTAssertTrue(breakfast.waitForExistence(timeout: 3))
        breakfast.tap()
        XCTAssertEqual(breakfast.value as? String, "已选择")
        attachScreenshot(app, name: "record-subcategory")
    }

    @MainActor
    func testEnglishRecordPageFitsLandscape() throws {
        let device = XCUIDevice.shared
        device.orientation = .landscapeLeft
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "en_US",
            "-zanzan.appLanguage", "en",
            "-zanzan.brandTheme", "ivory",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM",
        ]
        app.launch()

        let recordTab = app.tabBars.buttons["Add Entry"]
        XCTAssertTrue(recordTab.waitForExistence(timeout: 5))
        recordTab.tap()

        XCTAssertTrue(app.buttons["Save & Continue"].waitForExistence(timeout: 5))

        // 默认分类属于用户数据，切换应用语言后名称不会被改写。
        let dining = app.buttons["餐饮"]
        XCTAssertTrue(dining.waitForExistence(timeout: 5))
        XCTAssertTrue(dining.isHittable)
        dining.tap()
        XCTAssertTrue(app.staticTexts["Subcategory"].waitForExistence(timeout: 3))

        let finish = app.buttons["recordFinishButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 3))
        XCTAssertTrue(finish.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(
            CGPoint(x: finish.frame.midX, y: finish.frame.midY)
        ))
        attachScreenshot(app, name: "record-english-landscape")
    }

    @MainActor
    func testEnglishAppearanceAndLanguageEntryIsReachable() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-zanzan.appLanguage", "en",
            "-zanzan.brandTheme", "ivory",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM",
        ]
        app.launch()

        app.tabBars.buttons["Assets"].tap()
        XCTAssertTrue(app.buttons["Me"].waitForExistence(timeout: 5))
        app.buttons["Me"].tap()

        let appearanceLink = app.staticTexts["Appearance & Language"]
        scrollToElement(appearanceLink, in: app)
        XCTAssertTrue(appearanceLink.waitForExistence(timeout: 5))
        appearanceLink.tap()

        XCTAssertTrue(app.navigationBars["Appearance & Language"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Interface Theme"].exists)
        XCTAssertFalse(app.staticTexts["Accent Color"].exists)
        let languageHeader = app.staticTexts["Language"]
        scrollToElement(languageHeader, in: app)
        XCTAssertTrue(languageHeader.waitForExistence(timeout: 3))
    }

    @MainActor
    func test白色默认主题与收支语义重点色() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-zanzan.appLanguage", "zh-Hans",
            "-zanzan.brandTheme", "ivory",
        ]
        app.launch()

        app.tabBars.buttons["资产"].tap()
        XCTAssertTrue(app.buttons["我的"].waitForExistence(timeout: 5))
        app.buttons["我的"].tap()

        let settingsScrollView = app.scrollViews["screen.settings"]
        let appearanceLink = app.buttons["settings.link.appearance"]
        scrollToElement(appearanceLink, in: settingsScrollView)
        appearanceLink.tap()

        let ivory = app.buttons["appearance.theme.ivory"]
        XCTAssertTrue(ivory.waitForExistence(timeout: 5))
        XCTAssertEqual(ivory.value as? String, "已选择")
        XCTAssertFalse(app.staticTexts["重点色"].exists)
        XCTAssertFalse(app.buttons["appearance.accent.green"].exists)
        XCTAssertFalse(app.buttons["appearance.accent.red"].exists)
        attachScreenshot(app, name: "appearance-white-theme-iphone17")

        app.navigationBars["外观与语言"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.navigationBars["设置"].buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))

        app.tabBars.buttons["记账"].tap()
        XCTAssertTrue(app.buttons["recordFinishButton"].waitForExistence(timeout: 5))
        let expense = app.buttons["record.kind.expense"]
        let income = app.buttons["record.kind.income"]
        XCTAssertTrue(expense.waitForExistence(timeout: 5))
        XCTAssertEqual(expense.value as? String, "已选择")
        XCTAssertEqual(income.value as? String, "未选择")
        attachScreenshot(app, name: "record-expense-red-iphone17")

        income.tap()
        XCTAssertEqual(income.value as? String, "已选择")
        XCTAssertEqual(expense.value as? String, "未选择")
        XCTAssertTrue(app.buttons["工资"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(app, name: "record-income-green-iphone17")
    }

    @MainActor
    func testSketchGlassRootTabsScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-zanzan.uiTesting",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-zanzan.appLanguage", "zh-Hans",
            "-zanzan.brandTheme", "ivory",
            "-zanzan.backdropStyle", "sketch",
            "-zanzan.transactionRowFrame", "NO",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["账本"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "示例 ·"))
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        attachScreenshot(app, name: "sketch-ledger-sample-iphone17")

        app.tabBars.buttons["资产"].tap()
        XCTAssertTrue(app.staticTexts["净资产"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["现金"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "sketch-assets-sample-iphone17")

        app.tabBars.buttons["统计"].tap()
        XCTAssertTrue(app.staticTexts["本月结余"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["支出构成"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "sketch-stats-sample-iphone17")

        app.tabBars.buttons["记账"].tap()
        let expenseKind = app.buttons["record.kind.expense"]
        XCTAssertTrue(expenseKind.waitForExistence(timeout: 5))
        XCTAssertTrue(expenseKind.isHittable)
        let finishButton = app.buttons["recordFinishButton"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 5))
        XCTAssertTrue(finishButton.isHittable)
        XCTAssertTrue(
            app.descendants(matching: .any)["record.amountSection"].exists
        )
        attachScreenshot(app, name: "sketch-record-iphone17")
    }

    @MainActor
    func testSketchGlassDetailsAndFormsScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-zanzan.uiTesting",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-zanzan.appLanguage", "zh-Hans",
            "-zanzan.brandTheme", "ivory",
        ]
        app.launch()

        app.tabBars.buttons["资产"].tap()
        let cashAccount = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "现金"))
            .firstMatch
        XCTAssertTrue(cashAccount.waitForExistence(timeout: 5))
        cashAccount.tap()
        XCTAssertTrue(app.navigationBars["现金"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.waitForNonExistence(timeout: 3))
        attachScreenshot(app, name: "sketch-detail-account")

        app.buttons["编辑"].tap()
        XCTAssertTrue(app.navigationBars["编辑账户"].waitForExistence(timeout: 3))
        attachScreenshot(app, name: "sketch-form-account")
        let accountNameField = app.textFields["账户名"]
        XCTAssertTrue(accountNameField.waitForExistence(timeout: 3))
        accountNameField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        attachScreenshot(app, name: "sketch-form-account-focused")
        app.navigationBars["编辑账户"].buttons["取消"].tap()

        XCTAssertTrue(app.buttons["校准到实际余额"].waitForExistence(timeout: 3))
        app.buttons["校准到实际余额"].tap()
        XCTAssertTrue(app.navigationBars["校准余额"].waitForExistence(timeout: 3))
        attachScreenshot(app, name: "sketch-form-balance-calibration")
        app.navigationBars["校准余额"].buttons["取消"].tap()

        XCTAssertTrue(app.navigationBars["现金"].waitForExistence(timeout: 3))
        app.navigationBars["现金"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["资产"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        app.buttons["我的"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))

        let forms = [
            ("settings.link.ledgers", "账本", "新建账本", "新建账本", "sketch-form-ledger"),
            ("settings.link.categories", "分类管理", "新建分类", "新建分类", "sketch-form-category"),
            ("settings.link.tags", "标签管理", "新建标签", "新建标签", "sketch-form-tag"),
            ("settings.link.budgets", "预算", "添加预算", "添加预算", "sketch-form-budget"),
            ("settings.link.reimbursements", "报销与退款", "登记到账", "登记到账", "sketch-form-settlement"),
            ("settings.link.recurring", "周期记账", "新建计划", "新建周期计划", "sketch-form-recurring"),
            ("settings.link.installments", "分期与贷款", "新建计划", "新建分期计划", "sketch-form-installment"),
            ("settings.link.creditPools", "授信池", "新建授信池", "新建授信池", "sketch-form-credit-pool"),
        ]

        let settingsScrollView = app.scrollViews["screen.settings"]
        XCTAssertTrue(settingsScrollView.exists)

        for (linkIdentifier, destinationTitle, actionTitle, formTitle, screenshotName) in forms {
            let link = app.buttons[linkIdentifier]
            scrollToElement(link, in: settingsScrollView)
            XCTAssertTrue(link.isHittable, "\(destinationTitle) 入口不可点击")
            link.tap()
            XCTAssertTrue(app.navigationBars[destinationTitle].waitForExistence(timeout: 3))

            let action = app.buttons[actionTitle]
            XCTAssertTrue(action.waitForExistence(timeout: 3), "\(actionTitle) 操作不可用")
            action.tap()
            XCTAssertTrue(app.navigationBars[formTitle].waitForExistence(timeout: 3))
            attachScreenshot(app, name: screenshotName)
            app.navigationBars[formTitle].buttons["取消"].tap()

            XCTAssertTrue(app.navigationBars[destinationTitle].waitForExistence(timeout: 3))
            app.navigationBars[destinationTitle].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable, attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
    }

    @MainActor
    private func scrollToElement(_ element: XCUIElement, in scrollView: XCUIElement) {
        var attempts = 0
        while !element.isHittable, attempts < 8 {
            scrollView.swipeUp()
            attempts += 1
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments += ["-zanzan.appLanguage", "zh-Hans"]
            app.launch()
        }
    }
}
