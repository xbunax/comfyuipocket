import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

private actor LoadCounter {
    var value = 0
    func increment() { value += 1 }
}
private actor CacheGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func untilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func open() { waiter?.resume(); waiter = nil }
}

final class MediaCacheTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    func testConcurrentRequestsShareOneLoadAndSurviveCacheRecreation() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let cache = MediaCache(directory: folder)
        let counter = LoadCounter(); let key = MediaCacheKey(resource: "server-a/image", variant: "raw")
        let expected = Data("image-bytes".utf8)
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await cache.data(for: key) {
                        await counter.increment(); try await Task.sleep(for: .milliseconds(30)); return expected
                    }
                }
            }
            var values: [Data] = []; for try await value in group { values.append(value) }; return values
        }
        XCTAssertEqual(results.count, 8); XCTAssertTrue(results.allSatisfy { $0 == expected })
        let requests = await counter.value; XCTAssertEqual(requests, 1)
        let recreated = MediaCache(directory: folder)
        let disk = try await recreated.data(for: key) { await counter.increment(); return Data() }
        XCTAssertEqual(disk, expected)
        let finalRequests = await counter.value; XCTAssertEqual(finalRequests, 1)
    }
    func testInvalidationPreventsInFlightDataFromRepopulatingCache() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let cache = MediaCache(directory: folder); let gate = CacheGate()
        let key = MediaCacheKey(resource: "image", variant: "raw")
        let pending = Task { try await cache.data(for: key) { await gate.wait(); return Data("old".utf8) } }
        await gate.untilStarted(); await cache.invalidate(resource: key.resource); await gate.open()
        do { _ = try await pending.value; XCTFail("Invalidated data must not be returned") } catch is CancellationError { }
        let latest = try await cache.data(for: key) { Data("new".utf8) }
        XCTAssertEqual(latest, Data("new".utf8))
    }
    func testCacheKeysSeparateServersRevisionsAndIgnoreQueryOrder() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let cache = MediaCache(directory: folder); let counter = LoadCounter()
        let urlA = URL(string: "http://127.0.0.1:8188/view?type=output&filename=a.png")!
        let urlB = URL(string: "http://127.0.0.1:8188/view?filename=a.png&type=output")!
        XCTAssertEqual(MediaCacheKey.resource(urlA), MediaCacheKey.resource(urlB))
        for key in [MediaCacheKey(resource: MediaCacheKey.resource(urlA), variant: "p1"),
                    MediaCacheKey(resource: MediaCacheKey.resource(urlA), variant: "p2"),
                    MediaCacheKey(resource: "http://127.0.0.2:8188/view?filename=a.png&type=output", variant: "p1")] {
            _ = try await cache.data(for: key) { await counter.increment(); return Data([1]) }
        }
        let requests = await counter.value; XCTAssertEqual(requests, 3)
    }
    func testExpiredDataReloadsAndDiskBudgetIsBounded() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let cache = MediaCache(directory: folder, memoryLimit: 0, diskLimit: 64)
        let key = MediaCacheKey(resource: "image", variant: "raw")
        _ = try await cache.data(for: key) { Data([1]) }
        let value = try await cache.data(for: key, lifetime: 0) { Data([2]) }
        XCTAssertEqual(value, Data([2]))
        for index in 0..<4 {
            _ = try await cache.data(for: MediaCacheKey(resource: "image-\(index)", variant: "raw")) { Data(repeating: 7, count: 24) }
        }
        XCTAssertLessThanOrEqual(try diskUsage(folder), 64)
    }
    private func diskUsage(_ folder: URL) throws -> Int {
        var size = 0
        if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == true { size += values.fileSize ?? 0 }
            }
        }
        return size
    }
}
