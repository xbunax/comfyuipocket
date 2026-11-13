import XCTest
@testable import ComfyUIPocket

final class ModelTests: XCTestCase {
    func testIPv4AndIPv6Pairing() throws {
        var profile = ServerProfile(); profile.host = "192.168.1.20"
        XCTAssertEqual(try profile.baseURL().absoluteString, "http://192.168.1.20:8188")
        profile.host = "fd7a:115c:a1e0::1"; profile.https = true
        XCTAssertEqual(try profile.baseURL().absoluteString, "https://[fd7a:115c:a1e0::1]:8188")
        profile.port = "65536"; XCTAssertThrowsError(try profile.baseURL())
        profile.port = "8188"; profile.host = "http://example.com/"; XCTAssertThrowsError(try profile.baseURL())
    }
    func testLargeSeedsAndConnectionsSurviveEditing() throws {
        let json = #"{"1":{"class_type":"KSampler","inputs":{"seed":9007199254740993,"model":["2",0],"cfg":7.5}},"2":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"example.safetensors"}}}"#
        var workflow = try Workflow.load(Data(json.utf8), name: "Example")
        XCTAssertEqual(workflow.prompt["1"]?["inputs"]["seed"], .integer(9007199254740993))
        XCTAssertFalse(workflow.fields.contains { $0.key == "model" })
        let field = try XCTUnwrap(workflow.fields.first { $0.key == "cfg" })
        workflow.set(field, value: .number(8.5))
        let saved = try JSONEncoder().encode(workflow)
        let loaded = try Workflow.load(saved, name: "Restored")
        XCTAssertEqual(loaded.prompt["1"]?["inputs"]["model"], .array([.string("2"), .integer(0)]))
        XCTAssertEqual(loaded.prompt["1"]?["inputs"]["seed"], .integer(9007199254740993))
        XCTAssertEqual(loaded.prompt["1"]?["inputs"]["cfg"], .number(8.5))
    }
    func testRejectsCanvasFormatInsteadOfGuessingWidgetMapping() {
        XCTAssertThrowsError(try Workflow.load(Data(#"{"nodes":[],"links":[]}"#.utf8), name: "Canvas"))
    }
    func testPinnedOrderAndStructuredValues() throws {
        let json = #"{"1":{"class_type":"CustomNode","inputs":{"text":"hello","enabled":true,"config":{"x":3},"strength":0.5}}}"#
        var workflow = try Workflow.load(Data(json.utf8), name: "Custom")
        workflow.pinned = ["1.strength", "1.enabled"]
        XCTAssertEqual(workflow.fields.map(\.key), ["strength", "enabled", "text"])
        XCTAssertEqual(workflow.prompt["1"]?["inputs"]["config"], .object(["x": .integer(3)]))
    }
}
