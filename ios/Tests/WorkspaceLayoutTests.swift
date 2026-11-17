import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class WorkspaceLayoutTests: XCTestCase {
    func testWindowResizeAndUserPreferenceUseAvailableSpace() {
        var layout = WorkspaceLayout(width: 393, height: 740)
        XCTAssertFalse(layout.usesColumns)
        layout.width = 1024
        XCTAssertTrue(layout.usesColumns)
        XCTAssertTrue(layout.showsCanvasInspector)
        layout.width = 700
        XCTAssertFalse(layout.usesColumns)
        layout.mode = .expanded
        XCTAssertTrue(layout.usesColumns)
        XCTAssertFalse(layout.showsCanvasInspector)
        layout.width = 393
        XCTAssertFalse(layout.usesColumns, "Manual wide layout must not squeeze columns into a phone window")
        layout.width = 1366; layout.mode = .compact
        XCTAssertFalse(layout.usesColumns)
    }

    func testShortWindowsAndInvalidDimensionsRemainUsable() {
        XCTAssertFalse(WorkspaceLayout(width: 1200, height: 250).usesColumns)
        XCTAssertFalse(WorkspaceLayout(width: .infinity, height: 800).usesColumns)
        let split = WorkspaceLayout(width: 820, height: 600)
        XCTAssertTrue(split.usesColumns)
        XCTAssertFalse(split.showsCanvasInspector)
        XCTAssertGreaterThanOrEqual(split.navigationWidth, 240)
        XCTAssertLessThanOrEqual(WorkspaceLayout(width: 3000, height: 1200).navigationWidth, 320)
    }
}
