import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class CanvasDocumentTests: XCTestCase {
    func testCanvasChangesReplaceBothGraphAndExecutablePrompt() throws {
        let original = Workflow(id: "a", name: "Example", prompt: ["1": .object(["class_type": .string("Source"), "inputs": .object([:])])], pinned: ["1.deleted"])
        let text = #"{"prompt":{"2":{"class_type":"Target","inputs":{"image":["3",0]}}},"workflow":{"nodes":[{"id":2,"pos":[-50,200]},{"id":3}],"links":[[1,3,0,2,0,"IMAGE"]],"definitions":{"subgraphs":[]}}}"#
        let document = try JSONDecoder().decode(CanvasDocument.self, from: Data(text.utf8))
        let edited = try document.applying(to: original)
        XCTAssertNil(edited.prompt["1"])
        XCTAssertEqual(edited.prompt["2"]?["inputs"]["image"], .array([.string("3"), .integer(0)]))
        XCTAssertEqual(edited.canvas?["nodes"].array.first?["pos"], .array([.integer(-50), .integer(200)]))
        XCTAssertTrue(edited.pinned.isEmpty)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(try Workflow.load(JSONEncoder().encode(edited), name: "Exported"), edited)
    }
    func testAnEmptyCanvasCanBeSavedAndReopened() throws {
        let document = CanvasDocument(prompt: [:], workflow: .object(["nodes": .array([]), "links": .array([])]))
        let edited = try document.applying(to: Workflow(id: "empty", name: "Empty", prompt: [:]))
        XCTAssertEqual(try Workflow.load(JSONEncoder().encode(edited), name: "Empty"), edited)
    }
    func testMalformedSnapshotDoesNotReplaceTheWorkflow() {
        let bad = CanvasDocument(prompt: ["1": .string("bad")], workflow: .object(["nodes": .array([])]))
        XCTAssertThrowsError(try bad.applying(to: Workflow(id: "a", name: "Original", prompt: [:])))
    }
    func testUnchanged64BitSeedSurvivesJavaScriptRounding() throws {
        let node: JSONValue = .object(["class_type": .string("Seed"), "inputs": .object(["seed": .unsigned(UInt64.max)])])
        let original = Workflow(id: "a", name: "Seed", prompt: ["1": node])
        let rounded: JSONValue = .object(["class_type": .string("Seed"), "inputs": .object(["seed": .number(Double(UInt64.max))])])
        let edited = try CanvasDocument(prompt: ["1": rounded], workflow: .object(["nodes": .array([])])).applying(to: original)
        XCTAssertEqual(edited.prompt["1"]?["inputs"]["seed"], .unsigned(UInt64.max))
    }
}
