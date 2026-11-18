import Foundation

/// FFI futures do not observe Swift task cancellation. A structured task group
/// would wait for the losing FFI task and defeat the timeout. Return immediately;
/// the owner closes its endpoint/socket to release any outstanding native work.
@MainActor final class PairingDeadline<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var result: Result<Value, Error>?
    private func finish(_ value: Result<Value, Error>) {
        guard result == nil else { return }
        result = value
        continuation?.resume(with: value); continuation = nil
        work?.cancel(); timer?.cancel(); work = nil; timer = nil
    }
    static func run(_ seconds: Double, timeoutMessage: String = "建立直连超时，未使用中继。",
                    body: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        let race = PairingDeadline<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result = race.result { continuation.resume(with: result); return }
                race.continuation = continuation
                race.work = Task { @MainActor in
                    do { race.finish(.success(try await body())) } catch { race.finish(.failure(error)) }
                }
                race.timer = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    race.finish(.failure(PocketError.message(timeoutMessage)))
                }
            }
        } onCancel: { Task { @MainActor in race.finish(.failure(CancellationError())) } }
    }
}

struct IrohPeerProfile: Codable, Equatable, Sendable {
    var endpointId: String
    var ticket: String
    var name: String
    var serverID: String { "iroh://" + endpointId }
}

struct PairingInvitation: Codable, Equatable, Sendable {
    let v: Int
    let ticket: String
    let endpointId: String
    let name: String
    let token: String
    let expiresAt: Int64
    let directOnly: Bool
    var peer: IrohPeerProfile { IrohPeerProfile(endpointId: endpointId, ticket: ticket, name: name) }

    static func parse(_ text: String, now: Date = Date()) throws -> PairingInvitation {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 16384, let url = URLComponents(string: text),
              url.scheme == "comfypocket", url.host == "iroh", url.path == "/1",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              let items = url.queryItems, items.count == 1, items[0].name == "d",
              let encoded = items[0].value, encoded.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw PocketError.message("这不是 ComfyUI Pocket 配对码，请从电脑的 Pocket 面板重新获取。")
        }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count <= 8192,
              let invite = try? JSONDecoder().decode(PairingInvitation.self, from: data),
              invite.v == 1, invite.directOnly,
              invite.endpointId.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              invite.token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              !invite.ticket.isEmpty, invite.ticket.utf8.count <= 4096, invite.name.utf8.count <= 256 else {
            throw PocketError.message("配对码内容无效或不支持仅直连模式。")
        }
        guard Double(invite.expiresAt) >= now.timeIntervalSince1970 else {
            throw PocketError.message("配对码已过期，请在电脑上生成新的配对码。")
        }
        return invite
    }
}

/// Validate the first request on a loopback socket, then keep streaming that socket.
/// The private media prefix allows AVFoundation to load videos without custom headers.
struct LoopbackAccess: Sendable {
    let token: String
    let port: UInt16
    var cookieName: String { "PocketP2P\(port)" }
    var mediaPrefix: String { "/_pocket/\(token)" }
    var origin: String { "http://127.0.0.1:\(port)" }
    func authorize(_ header: Data) throws -> Data {
        guard header.count <= 65536, let text = String(data: header, encoding: .isoLatin1), text.hasSuffix("\r\n\r\n") else {
            throw PocketError.message("无效的本地请求。")
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard request.count == 3, ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(request[0]),
              request[1].hasPrefix("/"), !request[1].hasPrefix("//"), ["HTTP/1.0", "HTTP/1.1"].contains(request[2]) else {
            throw PocketError.message("无效的本地请求。")
        }
        var target = request[1], allowed = false, hosts: [String] = [], origins: [String] = [], kept: [String] = []
        let upgrade = lines.contains { $0.lowercased().hasPrefix("upgrade: websocket") }
        if target.hasPrefix(mediaPrefix + "/") { allowed = true; target = String(target.dropFirst(mediaPrefix.count)) }
        for line in lines.dropFirst().dropLast(2) {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
                throw PocketError.message("无效的本地请求头。")
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !upgrade && (name == "connection" || name == "keep-alive") { continue }
            if name == "host" { hosts.append(value.lowercased()) }
            if name == "origin" { origins.append(value) }
            if name == "x-pocket-local-token" { allowed = allowed || equal(value, token); continue }
            if name == "cookie" {
                let cookies = value.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                var remaining: [String] = []
                for cookie in cookies {
                    if cookie.hasPrefix(cookieName + "=") { allowed = allowed || equal(String(cookie.dropFirst(cookieName.count + 1)), token) }
                    else { remaining.append(cookie) }
                }
                if !remaining.isEmpty { kept.append("Cookie: " + remaining.joined(separator: "; ")) }
            } else { kept.append(line) }
        }
        guard allowed, hosts == ["127.0.0.1:\(port)"], origins.isEmpty || origins == [origin] else {
            throw PocketError.message("本地 P2P 通道未授权。")
        }
        // One HTTP request per TCP socket ensures every media prefix and local
        // credential is validated/stripped. QUIC itself remains persistent.
        if !upgrade { kept.append("Connection: close") }
        let result = (["\(request[0]) \(target) \(request[2])"] + kept).joined(separator: "\r\n") + "\r\n\r\n"
        return result.data(using: .isoLatin1)!
    }
    private func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    func mediaURL(_ url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath = mediaPrefix + parts.percentEncodedPath
        return parts.url!
    }
    func resource(_ url: URL, serverID: String) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if parts.percentEncodedPath.hasPrefix(mediaPrefix + "/") {
            parts.percentEncodedPath.removeFirst(mediaPrefix.count)
        }
        let query = parts.queryItems?.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        parts.scheme = "http"; parts.host = "cache.invalid"; parts.port = nil; parts.queryItems = query
        return serverID + "|" + parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
}
