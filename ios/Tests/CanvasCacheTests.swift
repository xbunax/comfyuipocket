import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class CanvasCacheTests: XCTestCase {
    private func key(_ id: String, server: String = "http://host:8188") -> CanvasCacheKey {
        CanvasCacheKey(baseURL: URL(string: server)!, workflowID: id)
    }
    private func workflow() throws -> Workflow {
        try Workflow.load(Data(#"{"1":{"class_type":"Text","inputs":{"text":"original","seed":18446744073709551615}}}"#.utf8), name: "Test")
    }
    func testReopenReusesOnlyMatchingGraphDataAndUpdatesExistingRuntimeOtherwise() throws {
        let original = try workflow(), revision = CanvasRevision(original)
        var reordered = original
        reordered.name = "Renamed"; reordered.pinned = ["1.text"]
        XCTAssertEqual(CanvasRevision(reordered), revision)
        XCTAssertEqual(CanvasOpenPlan.resolve(sameServer: true, runtimeReady: true, available: true,
            current: revision, incoming: CanvasRevision(reordered), force: false), .reuse)
        var edited = original
        var node = edited.prompt["1"]!.object, inputs = node["inputs"]!.object
        inputs["text"] = .string("changed on phone or server"); node["inputs"] = .object(inputs); edited.prompt["1"] = .object(node)
        XCTAssertEqual(CanvasOpenPlan.resolve(sameServer: true, runtimeReady: true, available: true,
            current: revision, incoming: CanvasRevision(edited), force: false), .updateGraph)
        edited = original; edited.canvas = .object(["nodes": .array([])])
        XCTAssertNotEqual(CanvasRevision(edited), revision)
        XCTAssertEqual(CanvasRevision(original).prompt["1"]?["inputs"]["seed"], .unsigned(UInt64.max))
    }
    func testServerChangesForcedRefreshAndTerminatedPagesAlwaysReloadRuntime() throws {
        let revision = CanvasRevision(try workflow())
        for (sameServer, ready, force) in [(false,true,false), (true,false,false), (true,true,true)] {
            XCTAssertEqual(CanvasOpenPlan.resolve(sameServer: sameServer, runtimeReady: ready, available: true,
                current: revision, incoming: revision, force: force), .reloadPage)
        }
        XCTAssertEqual(CanvasOpenPlan.resolve(sameServer: true, runtimeReady: true, available: false,
            current: revision, incoming: revision, force: false), .updateGraph)
    }
    func testCacheSeparatesServersUsesLRUAndRecreatesEvictedPages() {
        var evicted: [Int] = [], created = 0
        var cache = CanvasMemoryCache<Int>(capacity: 2, onEvict: { evicted.append($0) })
        let a = key("same"), b = key("same", server: "http://other:8188"), c = key("third")
        XCTAssertEqual(cache.acquire(a) { created += 1; return 1 }, 1)
        XCTAssertEqual(cache.acquire(b) { created += 1; return 2 }, 2)
        XCTAssertEqual(cache.acquire(a) { XCTFail("Reopening must reuse the existing page"); return 99 }, 1)
        _ = cache.acquire(c) { created += 1; return 3 }
        XCTAssertEqual(cache.keys, [a,c]); XCTAssertEqual(evicted, [2])
        XCTAssertEqual(cache.acquire(b) { created += 1; return 4 }, 4)
        XCTAssertEqual(created, 4); XCTAssertEqual(evicted, [2,1])
    }
    func testMemoryWarningAndEvictionKeepAttachedEditorUntilReleased() {
        var evicted: [String] = []
        var cache = CanvasMemoryCache<String>(capacity: 1, onEvict: { evicted.append($0) })
        let a = key("a"), b = key("b")
        _ = cache.acquire(a) { "a" }; cache.attach(a)
        _ = cache.acquire(b) { "b" }; cache.attach(b)
        XCTAssertEqual(cache.keys.count, 2)
        cache.discardInactive(); XCTAssertTrue(evicted.isEmpty)
        cache.detach(a); XCTAssertEqual(evicted, ["a"]); XCTAssertEqual(cache.keys, [b])
        cache.detach(b); cache.discardInactive(); XCTAssertEqual(evicted, ["a","b"])
        XCTAssertTrue(cache.keys.isEmpty)
    }
}
