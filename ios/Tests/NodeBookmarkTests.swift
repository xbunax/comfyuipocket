import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class NodeBookmarkTests: XCTestCase {
    func testBookmarksPersistAndStayIsolatedAcrossServersWorkflowsAndSubgraphs() throws {
        let node = CanvasNodeLocation(path: [], nodeID: "7", type: "Text", title: "提示词")
        let nested = CanvasNodeLocation(path: ["2", "3"], nodeID: "7", type: "Text", title: "子图提示词")
        var library = NodeBookmarkLibrary()
        library.toggle(server: "A", workflowID: "one", location: node)
        library.toggle(server: "A", workflowID: "one", location: nested)
        library.toggle(server: "B", workflowID: "one", location: node)
        library.toggle(server: "A", workflowID: "two", location: node)
        let decoded = try JSONDecoder().decode(NodeBookmarkLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(library, decoded)
        XCTAssertEqual(library.bookmarks(server: "A", workflowID: "one").map(\.location), [node, nested])
        library.toggle(server: "A", workflowID: "one", location: node)
        XCTAssertEqual(library.entries.count, 3)
        XCTAssertTrue(library.contains(server: "B", workflowID: "one", location: node))
    }
    func testRenamedNodeResolvesButMissingOrReusedIDDoesNotJumpElsewhere() throws {
        let old = CanvasNodeLocation(path: ["2"], nodeID: "7", type: "Text", title: "Old")
        var library = NodeBookmarkLibrary(); library.toggle(server: "A", workflowID: "one", location: old)
        let saved = try XCTUnwrap(library.entries.first)
        var renamed = old; renamed.title = "New"
        XCTAssertEqual(library.resolved(saved, in: [renamed])?.title, "New")
        var wrongType = old; wrongType.type = "Image"
        var wrongPath = old; wrongPath.path = ["3"]
        XCTAssertNil(library.resolved(saved, in: [wrongType, wrongPath]))
        XCTAssertNil(library.resolved(saved, in: []))
        XCTAssertEqual(library.entries, [saved])
        XCTAssertNotEqual(CanvasNodeLocation.key(["a/b", "c"]), CanvasNodeLocation.key(["a", "b/c"]))
    }
}
