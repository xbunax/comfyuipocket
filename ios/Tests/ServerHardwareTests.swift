import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class ServerHardwareTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    func testStandardStatsReportMemoryAndKeepUnsupportedUtilizationUnknown() throws {
        let stats = try json(#"{"system":{"ram_total":1000,"ram_free":400},"devices":[{"name":"GPU A","vram_total":2000,"vram_free":500}]}"#)
        let result = ServerHardware(stats: stats)
        XCTAssertEqual(result.ram, 60); XCTAssertEqual(result.vram, 75)
        XCTAssertNil(result.cpu); XCTAssertNil(result.gpu); XCTAssertEqual(result.gpuName, "GPU A")
        XCTAssertNil(ServerHardware().ram)
    }
    func testResourceMetricsRespectZeroAndRejectInvalidOrMissingValues() throws {
        let resources = try json(#"{"cpuPercent":null,"gpu":{"name":"GPU B","utilizationPercent":0,"memory":{"usedBytes":80,"totalBytes":100}},"ram":{"usedBytes":25,"totalBytes":100}}"#)
        let result = ServerHardware(resources: resources)
        XCTAssertNil(result.cpu); XCTAssertEqual(result.gpu, 0); XCTAssertEqual(result.vram, 80); XCTAssertEqual(result.ram, 25)
        let invalid = try json(#"{"cpuPercent":-1,"gpu":{"utilizationPercent":101,"memory":{"usedBytes":500,"totalBytes":100}},"ram":{"usedBytes":50,"totalBytes":0}}"#)
        let unavailable = ServerHardware(resources: invalid)
        XCTAssertNil(unavailable.cpu); XCTAssertNil(unavailable.gpu); XCTAssertNil(unavailable.vram); XCTAssertNil(unavailable.ram)
        XCTAssertNil(ServerHardware.percent(.bool(false))); XCTAssertNil(ServerHardware.percent(.string("0")))
    }
}
