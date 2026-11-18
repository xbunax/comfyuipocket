import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class GenerationActivityTests: XCTestCase {
    func testBatchSeedModeCanRandomizeTheFirstRun() {
        let indices = Array(0..<3)
        XCTAssertEqual(indices.filter { BatchSeedMode.preserve.randomizes(index: $0) }, [])
        XCTAssertEqual(indices.filter { BatchSeedMode.afterFirst.randomizes(index: $0) }, [1, 2])
        XCTAssertEqual(indices.filter { BatchSeedMode.everyRun.randomizes(index: $0) }, [0, 1, 2])
    }
    private func batch() -> GenerationTask {
        GenerationTask(id: "one", server: "server", workflowID: "workflow", name: "Workflow",
                       createdAt: 0, requestedCount: 2, items: [
                        GenerationItem(id: "a", prompt: [:]),
                        GenerationItem(id: "b", prompt: [:])
                       ])
    }

    func testSamplerCompletionDoesNotCompleteTheBatch() {
        let state = GenerationActivityState(task: batch(), summary: GenerationSummary(running: 1, completed: 1),
                                            activePrompt: "b", progress: 1)
        XCTAssertFalse(state.terminal)
        XCTAssertEqual(state.units, 199)
        XCTAssertTrue(state.subtitle.contains("1/2"))
    }

    func testOnlyConfirmedTerminalResultsTriggerCompletion() {
        let unavailable = GenerationActivityState(task: batch(), summary: GenerationSummary(completed: 1, unavailable: 1),
                                                  activePrompt: "", progress: 0)
        XCTAssertFalse(unavailable.terminal)
        let done = GenerationActivityState(task: batch(), summary: GenerationSummary(completed: 2), activePrompt: "", progress: 0)
        XCTAssertTrue(done.terminal)
        XCTAssertTrue(done.succeeded)
        let failed = GenerationActivityState(task: batch(), summary: GenerationSummary(completed: 1, failed: 1),
                                             activePrompt: "unrelated", progress: 0.9)
        XCTAssertTrue(failed.terminal)
        XCTAssertFalse(failed.succeeded)
    }
}
