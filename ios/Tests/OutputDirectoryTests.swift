import Foundation
import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class OutputDirectoryTests: XCTestCase {
    func testOutputPageRetainsFoldersUnicodeAndPagination() throws {
        let data = Data(#"{"folder":"相册","total":63,"nextOffset":60,"entries":[{"name":"子目录","path":"相册/子目录","kind":"folder","subfolder":"相册","size":0,"modified":1000},{"name":"图 1.png","path":"相册/图 1.png","kind":"file","subfolder":"相册","size":4096,"modified":2000}]}"#.utf8)
        let page = try JSONDecoder().decode(OutputDirectoryPage.self, from: data)
        XCTAssertEqual(page.folder, "相册")
        XCTAssertEqual(page.nextOffset, 60)
        XCTAssertTrue(page.entries[0].isFolder)
        XCTAssertFalse(page.entries[1].isFolder)
        XCTAssertEqual(page.entries[1].output.filename, "图 1.png")
        XCTAssertEqual(page.entries[1].output.assetID, "output/相册/图 1.png")
    }

    func testOverwrittenFilesHaveNewPreviewRevisionWithoutChangingAssetIdentity() throws {
        let original = OutputDirectoryEntry(name: "a.mp4", path: "a.mp4", kind: "file", subfolder: "", size: 100, modified: 1000)
        let overwritten = OutputDirectoryEntry(name: "a.mp4", path: "a.mp4", kind: "file", subfolder: "", size: 200, modified: 2000)
        XCTAssertTrue(original.output.isVideo)
        XCTAssertEqual(original.output.assetID, overwritten.output.assetID)
        XCTAssertNotEqual(original.output.promptID, overwritten.output.promptID)
        XCTAssertNotEqual(original.output.id, overwritten.output.id)
    }
}
