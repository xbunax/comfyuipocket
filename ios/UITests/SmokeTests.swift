import XCTest

final class SmokeTests: XCTestCase {
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
