import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class ModelTests: XCTestCase {
    func testPromptBoardDragOrderAndMovingAcrossCategories() {
        var board = PromptBoardDocument(text: "one, two, (three:1.20)")
        let one = board.blocks[0].id; let two = board.blocks[1].id; let three = board.blocks[2].id
        board.move(one, to: "uncategorized", over: three)
        XCTAssertEqual(board.rendered, "two, (three:1.20), one")
        board.move(one, to: "uncategorized", over: two)
        XCTAssertEqual(board.rendered, "one, two, (three:1.20)")
        board.categories.append(PromptCategory(id: "style", name: "风格"))
        board.move(two, to: "style")
        XCTAssertEqual(board.rendered, "one, (three:1.20), two")
        XCTAssertEqual(board.blocks.first(where: { $0.id == two })?.categoryID, "style")
        board.removeCategory("style")
        XCTAssertEqual(board.blocks.count, 3)
        XCTAssertTrue(board.blocks.allSatisfy { $0.categoryID == "uncategorized" })
    }
    func testPromptBoardRoundTripKeepsDisabledWordsAndOriginalWeights() throws {
        var board = PromptBoardDocument(text: "portrait, (soft light:1.200), <lora:style:0.8>")
        board.blocks[0].enabled = false
        board.categories[0].collapsed = true
        let restored = try JSONDecoder().decode(PromptBoardDocument.self, from: JSONEncoder().encode(board))
        XCTAssertEqual(restored, board)
        XCTAssertEqual(restored.rendered, "(soft light:1.200), <lora:style:0.8>")
        XCTAssertEqual(restored.blocks[1].weight, 1.2)
    }
    func testPromptBoardExternalEditsKeepMatchingWordsAndRespectNewOrder() {
        var board = PromptBoardDocument(text: "one, two, three")
        board.categories.append(PromptCategory(id: "style", name: "风格"))
        let two = board.blocks[1].id
        board.move(two, to: "style")
        board.blocks[0].enabled = false
        board.synchronize("three, two, four")
        XCTAssertEqual(board.rendered, "three, two, four")
        XCTAssertEqual(board.blocks.first(where: { $0.id == two })?.categoryID, "uncategorized")
        XCTAssertEqual(board.blocks.filter { !$0.enabled }.map(\.text), ["one"])
    }
    func testCanvasSurvivesImportEditingAndExport() throws {
        let json = #"{"id":"canvas","name":"Layout","prompt":{"1":{"class_type":"Text","inputs":{"text":"hello"}}},"workflow":{"nodes":[{"id":1,"pos":[-200,300],"size":[320,140]}],"links":[],"definitions":{"subgraphs":[]}}}"#
        var workflow = try Workflow.load(Data(json.utf8), name: "Canvas")
        let canvas = try XCTUnwrap(workflow.canvas)
        workflow.set(try XCTUnwrap(workflow.fields.first), value: .string("updated"))
        let restored = try Workflow.load(JSONEncoder().encode(workflow), name: "Restored")
        XCTAssertEqual(restored.canvas, canvas)
        XCTAssertEqual(restored.prompt["1"]?["inputs"]["text"], .string("updated"))
        let legacy = try Workflow.load(Data(#"{"1":{"class_type":"X","inputs":{}}}"#.utf8), name: "Legacy")
        XCTAssertNil(legacy.canvas)
    }
    func testFileOptionsSupportLegacyListsAndModernComboSchemas() throws {
        let legacy = try JSONDecoder().decode(JSONValue.self, from: Data(#"[["a.png","b.png"],{"image_upload":true}]"#.utf8))
        let modern = try JSONDecoder().decode(JSONValue.self, from: Data(#"["COMBO",{"options":["a.mp4","b.mp4"],"video_upload":true}]"#.utf8))
        XCTAssertEqual(InputSchema.choices(legacy.array).map(\.text), ["a.png", "b.png"])
        XCTAssertEqual(InputSchema.choices(modern.array).map(\.text), ["a.mp4", "b.mp4"])
        XCTAssertTrue(InputSchema.choices([.string("STRING")]).isEmpty)
    }
    func testPromptBlocksRespectNestedSyntaxEscapesAndLora() {
        let text = #"portrait, (red dress, silk:1.25), <lora:style:0.8>, [day:night:0.5], escaped\,comma, ((soft light))"#
        let blocks = PromptBlocks.parse(text)
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[1].text, "red dress, silk")
        XCTAssertEqual(blocks[1].weight, 1.25)
        XCTAssertEqual(blocks[2].text, "<lora:style:0.8>")
        XCTAssertEqual(blocks[3].text, "[day:night:0.5]")
        XCTAssertEqual(blocks[4].text, #"escaped\,comma"#)
        XCTAssertEqual(PromptBlocks.render(blocks), text)
    }
    func testPromptBlockWeightEnableOrderingAndUnicode() {
        var blocks = PromptBlocks.parse("人物，夜景\n柔光")
        XCTAssertEqual(blocks.count, 3)
        blocks[0].weight = 1.35
        blocks[1].enabled = false
        blocks.swapAt(0, 2)
        XCTAssertEqual(PromptBlocks.render(blocks), "柔光, (人物:1.35)")
        blocks[1].enabled = true
        XCTAssertEqual(PromptBlocks.parse(PromptBlocks.render(blocks))[2].weight, 1.35)
    }
    func testWeightParserDoesNotUnwrapMultipleExpressionsOrEscapedParens() {
        let blocks = PromptBlocks.parse(#"(cat) (dog:1.2), \(literal\), (outer (inner:1.1):1.40), (test:NaN)"#)
        XCTAssertEqual(blocks[0].text, "(cat) (dog:1.2)")
        XCTAssertEqual(blocks[0].weight, 1)
        XCTAssertEqual(blocks[2].weight, 1.4)
        XCTAssertEqual(blocks[2].rendered, "(outer (inner:1.1):1.40)")
        XCTAssertEqual(blocks[3].text, "(test:NaN)")
    }
    func testBatchSummaryCountsMixedStatesWithoutTreatingMissingAsSuccess() throws {
        let task = GenerationTask(id: "batch", server: "s", workflowID: "w", name: "Test", createdAt: 1, requestedCount: 6,
            items: ["running", "pending", "ok", "bad", "cancelled", "missing"].map { GenerationItem(id: $0, prompt: [:], cancelled: $0 == "cancelled") })
        let queue = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"queue_running":[[1,"running"]],"queue_pending":[[2,"pending"]]}"#.utf8))
        let history = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"ok":{"status":{"status_str":"success"}},"bad":{"status":{"status_str":"error"}}}"#.utf8))
        let summary = task.summary(queue: queue, history: history)
        XCTAssertEqual(summary.running, 1); XCTAssertEqual(summary.pending, 1)
        XCTAssertEqual(summary.completed, 1); XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.cancelled, 1); XCTAssertEqual(summary.unavailable, 1)
        XCTAssertEqual(summary.finished, 3); XCTAssertTrue(summary.active)
        XCTAssertEqual(try JSONDecoder().decode(GenerationTask.self, from: JSONEncoder().encode(task)), task)
    }
    func testMediaDetectionHandlesAnnotatedFilesWithoutMisclassifyingOtherFields() {
        func field(_ key: String, _ type: String, _ value: String) -> WorkflowField {
            WorkflowField(nodeID: "1", key: key, nodeTitle: "Load", classType: type, value: .string(value))
        }
        XCTAssertEqual(MediaFile.kind(for: field("file", "CustomInput", "pic.png [output]")), .image)
        XCTAssertEqual(MediaFile.kind(for: field("audio", "LoadAudio", "speech.wav")), .file)
        XCTAssertNil(MediaFile.kind(for: field("upload", "LoadImage", "image")))
        XCTAssertNil(MediaFile.kind(for: field("ckpt_name", "CheckpointLoader", "model.safetensors")))
    }
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
        let json = #"{"1":{"class_type":"KSampler","inputs":{"seed":1,"steps":20,"noise_seed":18446744073709551615,"text":"seed"}}}"#
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
