import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class MobileWorkflowTests: XCTestCase {
    func testArtworkDetailsKeepSubmittedPromptAfterHistoryAndTaskRemoval() throws {
        let history = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"p":{"prompt":[1,"p",{"3":{"class_type":"LazyMergeWorkbench","inputs":{"提示词文本":"original prompt"}},"4":{"class_type":"Size","inputs":{"width":1024,"height":768,"seed":18446744073709551615}}},{"pocket_task":{"id":"batch","name":"K2 Workbench","workflow_id":"workflow-a","created_at":1700000000}}],"outputs":{"1":{"images":[{"filename":"a.png","type":"output"}]}}}}"#.utf8))
        var archive = MediaArchive(); archive.ingest(history)
        archive.deletedTaskIDs.insert("batch"); archive.deletedPromptIDs.insert("p")
        archive.ingest(.object([:]))
        let saved = try JSONDecoder().decode(MediaArchive.self, from: JSONEncoder().encode(archive))
        let record = try XCTUnwrap(saved.provenance?["p"])
        XCTAssertEqual(record.workflowID, "workflow-a")
        XCTAssertEqual(record.workflowName, "K2 Workbench")
        XCTAssertEqual(record.promptFields.first?.value, .string("original prompt"))
        XCTAssertEqual(record.prompt["4"]?["inputs"]["seed"], .unsigned(UInt64.max))
        XCTAssertEqual(saved.galleryGroups.first?.outputs.count, 1)
    }
    func testPNGFallbackReadsOnlyStructuredPromptAndRejectsTruncatedMetadata() throws {
        let prompt = #"{"1":{"class_type":"CLIPTextEncode","inputs":{"text":"saved image prompt"}}}"#
        let payload = Data(("prompt\0" + prompt).utf8)
        let n = UInt32(payload.count)
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10, UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        data.append(Data("tEXt".utf8)); data.append(payload); data.append(Data(repeating: 0, count: 4))
        let record = try XCTUnwrap(MediaProvenance.embeddedPNG(data))
        XCTAssertEqual(record.promptFields.first?.value, .string("saved image prompt"))
        XCTAssertTrue(record.workflowName.isEmpty)
        XCTAssertNil(MediaProvenance.embeddedPNG(Data(data.dropLast(5))))
        XCTAssertNil(MediaProvenance.embeddedPNG(Data("not a PNG".utf8)))
    }
    func testGalleryGroupsBatchImagesAndVideosAndSurvivesTaskDeletion() throws {
        var archive = MediaArchive()
        archive.outputs = [
            OutputImage(promptID: "p2", filename: "b.mp4", subfolder: "", type: "output"),
            OutputImage(promptID: "p1", filename: "a.png", subfolder: "", type: "output"),
            OutputImage(promptID: "external", filename: "a.png", subfolder: "", type: "output")
        ]
        let task = GenerationTask(id: "batch", server: "server", workflowID: "w", name: "Video", createdAt: 100,
            requestedCount: 2, items: [GenerationItem(id: "p1", prompt: [:]), GenerationItem(id: "p2", prompt: [:])])
        archive.rememberTasks([task])
        archive.deletedTaskIDs.insert("batch")
        archive.deletedPromptIDs.formUnion(["p1", "p2"])
        let restored = try JSONDecoder().decode(MediaArchive.self, from: JSONEncoder().encode(archive))
        let groups = restored.galleryGroups
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].taskID, "batch")
        XCTAssertEqual(groups[0].outputs.count, 2)
        XCTAssertEqual(groups[0].videoCount, 1)
        XCTAssertEqual(groups[1].taskID, "external")
        archive.remove(archive.outputs[0])
        XCTAssertEqual(archive.galleryGroups[0].outputs.count, 1)
    }
    func testGalleryLegacyArchiveAndServerBatchMetadata() throws {
        let legacy = #"{"outputs":[],"removedOutputIDs":[],"deletedTaskIDs":[],"deletedPromptIDs":[],"generationOrder":{}}"#
        var archive = try JSONDecoder().decode(MediaArchive.self, from: Data(legacy.utf8))
        XCTAssertNil(archive.taskMetadata)
        let history = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"p":{"prompt":[1,"p",{}, {"pocket_task":{"id":"batch","name":"Example","created_at":100}}],"outputs":{"1":{"images":[{"filename":"a.png","type":"output"}]}}}}"#.utf8))
        archive.ingest(history)
        XCTAssertEqual(archive.galleryGroups.first?.taskID, "batch")
        XCTAssertEqual(archive.galleryGroups.first?.name, "Example")
    }
    func testChineseFieldsPreserveLinksAndRandomizeActualSeedsOnly() throws {
        var workflow = try Workflow.load(Data(#"{"1":{"class_type":"LazyMergeGenerate","inputs":{"种子":12,"随机种子":true,"宽度":1024,"高度":768,"model":["2",0]}},"2":{"class_type":"LazyMergeWorkbench","inputs":{"提示词文本":"hello","图片数据":"[]"}}}"#.utf8), name: "Custom")
        let linked = workflow.prompt["1"]?["inputs"]["model"]
        workflow.randomizeSeeds()
        XCTAssertEqual(workflow.prompt["1"]?["inputs"]["model"], linked)
        XCTAssertEqual(workflow.prompt["1"]?["inputs"]["随机种子"], .bool(true))
        XCTAssertTrue(MobileField.isSeed("种子")); XCTAssertFalse(MobileField.isSeed("每段递增种子"))
        XCTAssertNotNil(WorkflowResolution(fields: workflow.fields.filter { $0.nodeID == "1" }))
        XCTAssertTrue(MobileField.isPrompt(try XCTUnwrap(workflow.fields.first { $0.key == "提示词文本" })))
    }
    func testImagesKeepMasksAndUnknownMetadataWhenReordered() throws {
        var images = try WorkbenchImages(#"[{"image":"a.png","mask":"mask.png","custom":{"x":1},"subfolder":"ref","type":"input"},{"image":"b.png","type":"output"}]"#)
        let first = images.items[0]
        images.items.swapAt(0, 1)
        let decoded = try WorkbenchImages(images.encoded())
        XCTAssertEqual(decoded.items[1], first)
        XCTAssertEqual(WorkbenchImages.reference(first), "ref/a.png [input]")
        XCTAssertEqual(WorkbenchImages.reference(WorkbenchImages.item("ref/new.png")), "ref/new.png [input]")
        XCTAssertThrowsError(try WorkbenchImages("{\"unknown\":1}"))
    }
    func testStoryboardUpdatesTimingBankAndDerivedInputsTogether() throws {
        var board = try H3Storyboard(#"{"segments":[{"id":"a","start":0,"length":24,"type":"text","prompt":"first","custom":1},{"id":"b","start":24,"length":48,"type":"text","prompt":"second"}],"workspace_mode":"分镜","h3Tracks":{"多参":{"segments":[{"keep":true}]}},"h3MultiRef":{"images":[{"fileName":"a.png"}]}}"#)
        XCTAssertTrue(board.editable)
        board.update(index: 0, key: "length", value: .integer(48))
        board.update(index: 1, key: "prompt", value: .string("changed"))
        let inputs = try board.inputs(fps: 24)
        XCTAssertEqual(inputs["local_prompts"], .string("first | changed"))
        XCTAssertEqual(inputs["segment_lengths"], .string("48,48"))
        XCTAssertEqual(inputs["duration_seconds"], .number(4))
        XCTAssertEqual(board.segments[1]["start"], .number(48))
        XCTAssertEqual(board.segments[0]["custom"], .integer(1))
        XCTAssertEqual(board.root["h3MultiRef"]?["images"].array.count, 1)
        XCTAssertEqual(board.root["h3Tracks"]?["多参"]["segments"].array.first?["keep"], .bool(true))
        XCTAssertEqual(board.root["h3Tracks"]?["分镜"]["segments"].array, board.segments)
    }
    func testComplexStoryboardsNeverUseSimplifiedSerializer() throws {
        for timeline in [
            #"{"segments":[{"start":12,"length":24,"type":"text"}]}"#,
            #"{"segments":[{"start":0,"length":24,"type":"image"}]}"#,
            #"{"retakeMode":true,"segments":[{"start":0,"length":24,"type":"text"}]}"#,
            #"{"audioSegments":[{"fileName":"a.wav"}],"segments":[{"start":0,"length":24,"type":"text"}]}"#
        ] {
            var board = try H3Storyboard(timeline)
            let before = board.root
            XCTAssertFalse(board.editable)
            board.update(index: 0, key: "length", value: .integer(48))
            XCTAssertEqual(board.root, before)
            XCTAssertThrowsError(try board.inputs(fps: 24))
        }
    }
}
