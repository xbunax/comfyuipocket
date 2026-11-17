import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class MediaOrderingTests: XCTestCase {
    private func output(_ name: String, prompt: String = "p") -> OutputImage {
        OutputImage(promptID: prompt, filename: name, subfolder: "", type: "output")
    }
    func testTaskTotalsDeduplicateFilesAndKeepUnknownAfterZero() {
        let a = output("a.png"), reused = output("a.png", prompt: "q"), b = output("b.mp4")
        XCTAssertEqual(MediaOrdering.totalSize([a, reused, b], sizes: [a.assetID: 0, b.assetID: 25]), 25)
        XCTAssertNil(MediaOrdering.totalSize([a, b], sizes: [a.assetID: 0]))
        XCTAssertNil(MediaOrdering.totalSize([a, b], sizes: [a.assetID: .max, b.assetID: 1]))
        let unknown = MediaTaskGroup(id: "unknown", taskID: "u", name: "Unknown", createdAt: 1, outputs: [b])
        let zero = MediaTaskGroup(id: "zero", taskID: "z", name: "Zero", createdAt: 2, outputs: [a])
        for ascending in [true, false] {
            XCTAssertEqual(MediaOrdering.groups([unknown, zero], key: .size, ascending: ascending, sizes: [a.assetID: 0]).map(\.id), ["zero", "unknown"])
        }
    }
    func testNameTimeAndSizeOrdersAreStableAndReversible() {
        let a = output("image2.png"), b = output("image10.png")
        XCTAssertEqual(MediaOrdering.outputs([b, a], key: .name, ascending: true, sizes: [:]).map(\.filename), [a.filename, b.filename])
        XCTAssertEqual(MediaOrdering.outputs([a, b], key: .size, ascending: false, sizes: [a.assetID: 1, b.assetID: 50]).map(\.filename), [b.filename, a.filename])
        let old = MediaTaskGroup(id: "old", taskID: "o", name: "Z", createdAt: 1, outputs: [a])
        let new = MediaTaskGroup(id: "new", taskID: "n", name: "A", createdAt: 2, outputs: [b])
        XCTAssertEqual(MediaOrdering.groups([old, new], key: .time, ascending: false, sizes: [:]).map(\.id), ["new", "old"])
        XCTAssertEqual(MediaOrdering.groups([old, new], key: .name, ascending: true, sizes: [:]).map(\.id), ["new", "old"])
    }
}
