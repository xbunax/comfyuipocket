import XCTest

final class SmokeTests: XCTestCase {
    @MainActor func testWorkbenchCanvasAndPromptStudio() {
        let app = XCUIApplication()
        app.launchEnvironment["POCKET_UI_FIXTURES"] = "1"
        app.launch()
        let id = String(repeating: "a", count: 32)
        let pin = app.buttons["pin.\(id)"]
        XCTAssertTrue(pin.waitForExistence(timeout: 15))
        if pin.label.hasPrefix("取消") { pin.tap() }
        pin.tap()
        XCTAssertTrue(app.staticTexts["置顶"].exists)
        app.buttons["workflow.\(id)"].tap()
        let canvas = app.buttons["workflowCanvasButton"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.tap()
        XCTAssertTrue(app.navigationBars["工作流画布"].waitForExistence(timeout: 5))
        let layout = XCTAttachment(screenshot: app.screenshot()); layout.name = "03-Canvas"; layout.lifetime = .keepAlways; add(layout)
        app.buttons["完成"].tap()
        let visual = app.buttons["promptVisualEditor"]
        XCTAssertTrue(visual.waitForExistence(timeout: 5))
        visual.tap()
        XCTAssertTrue(app.navigationBars["编辑提示词"].waitForExistence(timeout: 5))
        let toggle = app.switches["promptBlockEditing"]
        XCTAssertTrue(toggle.exists)
        if toggle.value as? String == "0" { toggle.tap() }
        let word = app.buttons["promptChip.soft light"]
        XCTAssertTrue(word.exists)
        word.tap()
        XCTAssertTrue(app.navigationBars["词块详细设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["翻译"].exists)
        app.buttons["取消"].tap()
        let studio = XCTAttachment(screenshot: app.screenshot()); studio.name = "04-PromptStudio"; studio.lifetime = .keepAlways; add(studio)
        toggle.tap()
        XCTAssertTrue(app.textViews["promptTextEditor"].exists)
        app.buttons["取消"].tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["inputMediaPreview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["本地文件"].exists)
        XCTAssertTrue(app.buttons["服务器文件"].exists)
    }
    @MainActor func testBatchAppearsOnceAndRetainsEachGenerationParameters() {
        let app = XCUIApplication()
        app.launchEnvironment["POCKET_UI_FIXTURES"] = "1"
        app.launch()
        app.tabBars.buttons["任务"].tap()
        let task = app.staticTexts["UI Canvas Workflow ×2"]
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "UI Canvas Workflow ×2").count, 1)
        task.tap()
        XCTAssertTrue(app.navigationBars["批量任务详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第 1 次生成"].exists)
        XCTAssertTrue(app.staticTexts["第 2 次生成"].exists)
        app.staticTexts["第 1 次生成"].tap()
        XCTAssertTrue(app.staticTexts["portrait, (soft light:1.20), <lora:example:0.8>"].waitForExistence(timeout: 5))
    }
    @MainActor func testLaunchAndConnectionForm() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["工作台"].waitForExistence(timeout: 15))
        let library = XCTAttachment(screenshot: app.screenshot()); library.name = "01-Library"; library.lifetime = .keepAlways; add(library)
        app.tabBars.buttons["连接"].tap()
        XCTAssertTrue(app.textFields["IP 地址，例如 192.168.1.20"].waitForExistence(timeout: 5))
        let connection = XCTAttachment(screenshot: app.screenshot()); connection.name = "02-Connection"; connection.lifetime = .keepAlways; add(connection)
    }
}
