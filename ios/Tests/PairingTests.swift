import XCTest
#if canImport(ComfyUIPocketCore)
@testable import ComfyUIPocketCore
#else
@testable import ComfyUIPocket
#endif

final class PairingTests: XCTestCase {
    @MainActor func testDeadlineReturnsWhileNativeWorkIgnoresCancellation() async throws {
        let start = Date()
        do {
            _ = try await PairingDeadline<Int>.run(0.03) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { continuation.resume(returning: 1) }
                }
            }
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
        // Let the deliberately uncooperative work complete without leaking it.
        try await Task.sleep(for: .seconds(0.45))
    }
    private func code(_ overrides: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = ["v": 1, "ticket": "endpoint-test", "endpointId": String(repeating: "a", count: 64),
            "name": "电脑", "token": String(repeating: "t", count: 43), "expiresAt": 2000, "directOnly": true]
        value.merge(overrides) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: value)
        return "comfypocket://iroh/1?d=" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func testInvitationValidatesExpiryVersionPolicyAndIdentity() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let invite = try PairingInvitation.parse(code(), now: now)
        XCTAssertEqual(invite.peer.serverID, "iroh://" + String(repeating: "a", count: 64))
        for invalid: [String: Any] in [["v": 2], ["directOnly": false], ["expiresAt": 999], ["endpointId": "other"], ["token": "short"]] {
            XCTAssertThrowsError(try PairingInvitation.parse(code(invalid), now: now))
        }
        XCTAssertThrowsError(try PairingInvitation.parse(code() + "&d=duplicate", now: now))
        XCTAssertThrowsError(try PairingInvitation.parse(code() + "#fragment", now: now))
        XCTAssertThrowsError(try PairingInvitation.parse("https://example.com/1?d=abc", now: now))
    }
    func testOldIPProfileStillDecodes() throws {
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(#"{"host":"192.168.1.2","port":"8188","https":false}"#.utf8))
        XCTAssertNil(profile.irohPeer)
        XCTAssertNil(profile.connectionMethod)
        XCTAssertEqual(try profile.baseURL().absoluteString, "http://192.168.1.2:8188")
    }
    func testLoopbackRequiresTokenAndRejectsForeignOriginAndHost() throws {
        let access = LoopbackAccess(token: "private-token", port: 12345)
        func header(_ extras: String, host: String = "127.0.0.1:12345") -> Data {
            Data("GET /system_stats HTTP/1.1\r\nHost: \(host)\r\n\(extras)\r\n".utf8)
        }
        XCTAssertThrowsError(try access.authorize(header("")))
        XCTAssertThrowsError(try access.authorize(header("X-Pocket-Local-Token: wrong\r\n")))
        XCTAssertThrowsError(try access.authorize(header("X-Pocket-Local-Token: private-token\r\nOrigin: https://evil.example\r\n")))
        XCTAssertThrowsError(try access.authorize(header("X-Pocket-Local-Token: private-token\r\n", host: "evil.example:12345")))
        let accepted = try access.authorize(header("X-Pocket-Local-Token: private-token\r\nOrigin: \(access.origin)\r\n"))
        XCTAssertFalse(String(decoding: accepted, as: UTF8.self).contains("private-token"))
        XCTAssertTrue(String(decoding: accepted, as: UTF8.self).contains("Connection: close"))
        let cookie = try access.authorize(header("Cookie: \(access.cookieName)=private-token; other=value\r\n"))
        XCTAssertTrue(String(decoding: cookie, as: UTF8.self).contains("Cookie: other=value"))
        XCTAssertFalse(String(decoding: cookie, as: UTF8.self).contains(access.cookieName))
        let upgrade = Data("GET /ws HTTP/1.1\r\nHost: 127.0.0.1:12345\r\nX-Pocket-Local-Token: private-token\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8)
        let socket = String(decoding: try access.authorize(upgrade), as: UTF8.self)
        XCTAssertTrue(socket.contains("Connection: Upgrade"))
        XCTAssertFalse(socket.contains("Connection: close"))
    }
    func testMediaPrefixIsRemovedAndCacheSurvivesPortAndTokenChanges() throws {
        let a = LoopbackAccess(token: "one", port: 12345), b = LoopbackAccess(token: "two", port: 23456)
        let first = a.mediaURL(URL(string: a.origin + "/view?filename=a.png&type=output")!)
        let second = b.mediaURL(URL(string: b.origin + "/view?type=output&filename=a.png")!)
        XCTAssertEqual(a.resource(first, serverID: "iroh://peer1"), b.resource(second, serverID: "iroh://peer1"))
        XCTAssertNotEqual(a.resource(first, serverID: "iroh://peer1"), a.resource(first, serverID: "iroh://peer2"))
        let header = Data("GET \(first.path)?filename=a.png HTTP/1.1\r\nHost: 127.0.0.1:12345\r\nRange: bytes=0-9\r\n\r\n".utf8)
        let forwarded = String(decoding: try a.authorize(header), as: UTF8.self)
        XCTAssertTrue(forwarded.hasPrefix("GET /view?filename=a.png HTTP/1.1"))
        XCTAssertTrue(forwarded.contains("Range: bytes=0-9"))
    }
}
