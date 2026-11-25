import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class NodeSamplingPreviewTests: XCTestCase {
    private func frame(step: Int64, for promptID: String? = nil) -> JSONValue {
        .object([
            "prompt_id": promptID.map(JSONValue.string) ?? .null,
            "node_id": .string("2:329"),
            "step": .integer(step),
            "total": .integer(20),
            "image": step > 0 ? .string("AAEC") : .null,
            "mime": step > 0 ? .string("video/mp4") : .null,
            "sigmas": step == 0 ? .array([.integer(1), .integer(0)]) : .null
        ])
    }

    func testSamplingRunKeepsScheduleAndLatestFrameAndRejectsCrossPromptFrames() throws {
        var run = NodeSamplingRun()
        XCTAssertNil(run.receive(frame(step: 0)))
        run.begin("first")
        let schedule = try XCTUnwrap(run.receive(frame(step: 0)))
        XCTAssertTrue(schedule.includesSchedule)
        XCTAssertNotNil(run.receive(frame(step: 1)))
        run.begin("first") // Successive progress events must keep the schedule.
        XCTAssertNil(run.receive(frame(step: 2, for: "different")))
        let newest = try XCTUnwrap(run.receive(frame(step: 3)))
        XCTAssertEqual(run.buffer.frames.map(\.id), [schedule.id, newest.id])
        let nativePayload = try JSONDecoder().decode(JSONValue.self, from: newest.payload)
        XCTAssertEqual(nativePayload["mime"], .string("video/mp4"))
        XCTAssertEqual(nativePayload["node_id"], .string("2:329"))

        run.end("different")
        XCTAssertTrue(run.accepting)
        run.end("first")
        XCTAssertNil(run.receive(frame(step: 4)))
        XCTAssertEqual(run.buffer.frames.map(\.id), [schedule.id, newest.id])
        run.begin("second")
        XCTAssertTrue(run.buffer.frames.isEmpty)
        XCTAssertNil(run.receive(frame(step: 5, for: "first")))
    }
}
