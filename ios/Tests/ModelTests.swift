import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

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
    func testUnsignedSeedKeepsAll64Bits() throws {
        let data = Data(#"{"1":{"class_type":"Seed","inputs":{"seed":18446744073709551615}}}"#.utf8)
        let workflow = try Workflow.load(data, name: "Seed")
        XCTAssertEqual(workflow.prompt["1"]?["inputs"]["seed"], .unsigned(UInt64.max))
        let restored = try Workflow.load(JSONEncoder().encode(workflow), name: "Seed")
        XCTAssertEqual(restored.prompt, workflow.prompt)
    }
    func testGalleryCollectsImagesAndVideosWithoutDuplicates() throws {
        let json = #"{"new":{"prompt":[2],"outputs":{"1":{"images":[{"filename":"a.png","type":"output"}],"videos":[{"filename":"clip.mp4","subfolder":"v","type":"output"}]},"2":{"gifs":[{"filename":"clip.mp4","subfolder":"v","type":"output"}]}}},"old":{"prompt":[1],"outputs":{"1":{"images":[{"filename":"old.png"}]}}}}"#
        let history = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let files = OutputImage.fromHistory(history)
        XCTAssertEqual(files.map(\.filename), ["a.png", "clip.mp4", "old.png"])
        XCTAssertTrue(files[1].isVideo)
        XCTAssertEqual(files[1].subfolder, "v")
        XCTAssertEqual(files[2].type, "output")
    }
    func testPinnedOrderAndStructuredValues() throws {
        let json = #"{"1":{"class_type":"CustomNode","inputs":{"text":"hello","enabled":true,"config":{"x":3},"strength":0.5}}}"#
        var workflow = try Workflow.load(Data(json.utf8), name: "Custom")
        workflow.pinned = ["1.strength", "1.enabled"]
        XCTAssertEqual(workflow.fields.map(\.key), ["strength", "enabled", "text"])
        XCTAssertEqual(workflow.prompt["1"]?["inputs"]["config"], .object(["x": .integer(3)]))
    }
    func testWorkflowIDsAreServerCompatible() {
        let id = Workflow.newID()
        XCTAssertEqual(id.count, 32)
        XCTAssertNotNil(id.range(of: "^[a-f0-9]{32}$", options: .regularExpression))
        XCTAssertNotEqual(id, Workflow.newID())
    }
    func testSyncRemovalOnlyCleansSyncedUneditedWorkflows() {
        let records = [
            "aaaa": SyncRecord(serverUpdatedAt: 100, dirty: false),
            "bbbb": SyncRecord(serverUpdatedAt: 0, dirty: false),
            "cccc": SyncRecord(serverUpdatedAt: 100, dirty: true),
            "dddd": SyncRecord(serverUpdatedAt: 100, dirty: false)
        ]
        let removed = WorkflowSync.idsToRemove(records: records,
                                               serverIDs: ["dddd"],
                                               pendingDeletes: ["cccc"])
        XCTAssertEqual(removed, ["aaaa"])
    }
    func testLegacyProfileWithTailscaleFieldsStillDecodes() throws {
        let data = Data(#"{"host":"10.0.0.5","port":"8188","https":false,"tailscale":true,"controlURL":""}"#.utf8)
        let profile = try JSONDecoder().decode(ServerProfile.self, from: data)
        XCTAssertEqual(profile.host, "10.0.0.5")
        XCTAssertFalse(profile.https)
    }
    func testBatchSeedRandomizationPreservesOtherValuesAndTypes() throws {
        let json = #"{"1":{"class_type":"KSampler","inputs":{"seed":1,"steps":20,"noise_seed":9007199254740993,"text":"seed"}}}"#
        var workflow = try Workflow.load(Data(json.utf8), name: "Seeds")
        workflow.randomizeSeeds()
        if case .integer(let seed) = workflow.prompt["1"]?["inputs"]["seed"] ?? .null {
            XCTAssertNotEqual(seed, 1)
        } else { XCTFail("seed should stay integer") }
        if case .unsigned(let seed) = workflow.prompt["1"]?["inputs"]["noise_seed"] ?? .null {
            XCTAssertLessThanOrEqual(seed, UInt64(UInt32.max))
        } else { XCTFail("noise_seed should stay unsigned") }
        XCTAssertEqual(workflow.prompt["1"]?["inputs"]["steps"], .integer(20))
        XCTAssertEqual(workflow.prompt["1"]?["inputs"]["text"], .string("seed"))
    }
    func testMediaFieldDetectionAndAnnotationParsing() {
        let image = WorkflowField(nodeID: "1", key: "image", nodeTitle: "Load", classType: "LoadImage",
                                  value: .string("folder/pic.png"))
        XCTAssertEqual(MediaFile.kind(for: image), .image)
        let video = WorkflowField(nodeID: "2", key: "file", nodeTitle: "LoadVideo", classType: "LoadVideo",
                                  value: .string("clip.mp4"))
        XCTAssertEqual(MediaFile.kind(for: video), .video)
        let model = WorkflowField(nodeID: "3", key: "ckpt_name", nodeTitle: "Model", classType: "CheckpointLoader",
                                  value: .string("model.safetensors"))
        XCTAssertNil(MediaFile.kind(for: model))
        let parts = MediaFile.split("MOSS_Image_Setup/pic.png [output]")
        XCTAssertEqual(parts.filename, "pic.png")
        XCTAssertEqual(parts.subfolder, "MOSS_Image_Setup")
        XCTAssertEqual(parts.type, "output")
    }
    func testHistoryEntryOutputsAndGroupNames() throws {
        let json = #"{"outputs":{"9":{"images":[{"filename":"a.png","subfolder":"","type":"output"},{"filename":"a.png","subfolder":"","type":"output"}],"videos":[{"filename":"clip.mp4","type":"output"}]}}}"#
        let entry = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let files = OutputImage.fromHistoryEntry(entry, promptID: "p1")
        XCTAssertEqual(files.map(\.filename), ["a.png", "clip.mp4"])
        XCTAssertEqual(files[0].id, "p1/output//a.png")
        XCTAssertEqual(files[1].mimeType, "video/mp4")
        let workflow = try Workflow.load(Data(#"{"1":{"class_type":"X","inputs":{}}}"#.utf8), name: "MiniMax_H3_T2V")
        XCTAssertEqual(workflow.groupName, "MiniMax")
        let other = try Workflow.load(Data(#"{"1":{"class_type":"X","inputs":{}}}"#.utf8), name: "Unsaved Workflow")
        XCTAssertEqual(other.groupName, "其他")
    }
}
