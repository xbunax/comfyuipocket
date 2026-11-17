import Foundation
import Observation
import IrohLib
import Network
import Security
import WebKit

@MainActor @Observable
final class IrohTransport {
    private(set) var peer: IrohPeerProfile
    private(set) var status = "准备直连…"
    private(set) var authenticated = false
    private(set) var baseURL: URL?
    private(set) var access: LoopbackAccess?
    @ObservationIgnored private var enrollmentToken: String?
    @ObservationIgnored private var endpoint: Endpoint?
    @ObservationIgnored private var connection: IrohLib.Connection?
    @ObservationIgnored private var connecting: Task<IrohLib.Connection, Error>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var listenerReady: CheckedContinuation<URL, Error>?
    @ObservationIgnored private var channels: [UUID: (NWConnection, Task<Void, Never>)] = [:]
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var cookie: HTTPCookie?
    private static let alpn = Data("comfyuipocket/tcp/1".utf8)

    init(peer: IrohPeerProfile, token: String? = nil) { self.peer = peer; enrollmentToken = token }

    func start() async throws {
        status = "建立仅直连通道…"
        endpoint = try await timed(15) {
            try await Endpoint.bind(options: EndpointOptions(preset: presetN0DisableRelay(),
                secretKey: Self.identity(), relayMode: RelayMode.disabled()))
        }
        _ = try await ensureConnection()
        let url = try await startListener()
        guard let access else { throw PocketError.message("本地通道未就绪。") }
        let cookie = HTTPCookie(properties: [.name: access.cookieName, .value: access.token,
            .domain: "127.0.0.1", .path: "/", .init("HttpOnly"): "TRUE", .init("SameSite"): "Strict"])!
        self.cookie = cookie
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        baseURL = url
        status = "已直连 · 已禁用中继"
    }

    func stop() {
        stopped = true; monitor?.cancel(); monitor = nil; connecting?.cancel(); connecting = nil
        listenerReady?.resume(throwing: CancellationError()); listenerReady = nil
        listener?.cancel(); listener = nil
        for (_, (socket, task)) in channels { task.cancel(); socket.cancel() }; channels.removeAll()
        try? connection?.close(errorCode: 0, reason: Data("disconnected".utf8)); connection = nil
        if let endpoint { Task { try? await endpoint.close() } }; endpoint = nil
        if let cookie { Task { await WKWebsiteDataStore.default().httpCookieStore.delete(cookie) } }; cookie = nil
        status = "已断开"
    }

    private func ensureConnection() async throws -> IrohLib.Connection {
        guard !stopped, let endpoint else { throw PocketError.message("P2P 通道已关闭。") }
        if let connection, connection.closeReason() == nil { return connection }
        if let connecting { return try await connecting.value }
        let task = Task<IrohLib.Connection, Error> { @MainActor in
            self.status = "正在建立直连…"
            return try await self.timed(15) {
                let ticket = try EndpointTicket.fromString(str: self.peer.ticket)
                let address = ticket.endpointAddr()
                guard address.id().description == self.peer.endpointId, address.relayUrl() == nil else {
                    throw PocketError.message("配对设备身份不符，或配对信息包含中继地址。")
                }
                let connection = try await endpoint.connect(addr: address, alpn: Self.alpn)
                do {
                    guard connection.remoteId().description == self.peer.endpointId,
                          connection.paths().contains(where: { $0.isIp && $0.isSelected }),
                          !connection.paths().contains(where: \.isRelay) else {
                        throw PocketError.message("未建立 IP 直连；已拒绝中继连接。")
                    }
                    let stream = try await connection.openBi()
                    let hello: JSONValue = .object(["v": .integer(1), "token": self.enrollmentToken.map(JSONValue.string) ?? .null])
                    try await Self.writeFrame(stream.send(), value: hello)
                    try await stream.send().finish()
                    let response = try await Self.readFrame(stream.recv())
                    guard response["ok"] == .bool(true), response["v"] == .integer(1), response["directOnly"] == .bool(true),
                          response["endpointId"].text == self.peer.endpointId else {
                        throw PocketError.message("电脑拒绝了配对，请重新生成配对码。")
                    }
                    let fresh = try EndpointTicket.fromString(str: response["ticket"].text).endpointAddr()
                    guard fresh.id().description == self.peer.endpointId, fresh.relayUrl() == nil else {
                        throw PocketError.message("电脑返回了无效的直连地址。")
                    }
                    self.peer.ticket = response["ticket"].text
                    self.authenticated = true; self.enrollmentToken = nil
                    return connection
                } catch {
                    try? connection.close(errorCode: 1, reason: Data("pairing rejected".utf8)); throw error
                }
            }
        }
        connecting = task
        defer { connecting = nil }
        do {
            let connection = try await task.value
            guard !stopped else { try? connection.close(errorCode: 0, reason: Data()); throw CancellationError() }
            self.connection = connection; status = "已直连 · 已禁用中继"
            monitor?.cancel()
            monitor = Task { @MainActor [weak self] in
                var missingSince: Date?
                while !Task.isCancelled, let self, self.connection === connection {
                    let paths = connection.paths()
                    if paths.contains(where: \.isRelay) { try? connection.close(errorCode: 1, reason: Data("relay forbidden".utf8)) }
                    if paths.contains(where: { $0.isIp && $0.isSelected }) { missingSince = nil }
                    else { if missingSince == nil { missingSince = Date() } }
                    if connection.closeReason() != nil || missingSince.map({ Date().timeIntervalSince($0) > 15 }) == true {
                        try? connection.close(errorCode: 1, reason: Data("direct path lost".utf8))
                        self.connection = nil; self.status = "直连已断开，等待重连"; return
                    }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
            return connection
        } catch {
            status = "无法建立直连；未使用中继"
            if error is CancellationError { throw error }
            throw PocketError.message("无法与电脑建立直连。请确认电脑已启用 Pocket P2P、配对仍有效且网络允许 UDP 直连；也可改用 IP 连接。")
        }
    }

    private func startListener() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] socket in
            Task { @MainActor in
                guard let self, !self.stopped, self.channels.count < 64 else { socket.cancel(); return }
                let id = UUID()
                socket.start(queue: .main)
                let task = Task { @MainActor in await self.serve(socket); self.channels[id] = nil }
                self.channels[id] = (socket, task)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, let continuation = self.listenerReady else { return }
                    self.listenerReady = nil
                    do {
                        self.access = LoopbackAccess(token: try Self.randomToken(), port: port)
                        continuation.resume(returning: URL(string: "http://127.0.0.1:\(port)")!)
                    } catch { continuation.resume(throwing: error) }
                case .failed(let error):
                    self.listenerReady?.resume(throwing: error); self.listenerReady = nil
                    self.status = "本地通道异常，请重新连接"
                default: break
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listenerReady = continuation; listener.start(queue: .main)
        }
    }

    private func serve(_ socket: NWConnection) async {
        defer { socket.cancel() }
        do {
            let first = try await timed(8) {
                try await withTaskCancellationHandler { try await Self.readHeader(socket) }
                onCancel: { socket.cancel() }
            }
            guard let access else { return }
            let header: Data
            do { header = try access.authorize(first.header) }
            catch { try? await Self.send(socket, Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return }
            let connection = try await ensureConnection()
            let stream = try await connection.openBi()
            try await stream.send().writeAll(buf: header + first.body)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await Self.pipeUp(socket, stream.send()) }
                group.addTask { try await Self.pipeDown(stream.recv(), socket) }
                do { while try await group.next() != nil {} }
                catch { socket.cancel(); group.cancelAll(); throw error }
            }
        } catch {
            try? await Self.send(socket, Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        }
    }

    private static func readHeader(_ socket: NWConnection) async throws -> (header: Data, body: Data) {
        var data = Data()
        while data.count <= 65536 {
            let (chunk, ended) = try await receive(socket)
            data.append(chunk)
            if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                guard range.upperBound <= 65536 else { break }
                return (Data(data[..<range.upperBound]), Data(data[range.upperBound...]))
            }
            if ended { break }
        }
        throw PocketError.message("本地请求头无效或过大。")
    }
    private static func receive(_ socket: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), complete)) }
            }
        }
    }
    private static func send(_ socket: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private static func pipeUp(_ socket: NWConnection, _ stream: SendStream) async throws {
        while true {
            let (data, complete) = try await receive(socket)
            if !data.isEmpty { try await stream.writeAll(buf: data) }
            if complete { try await stream.finish(); return }
        }
    }
    private static func pipeDown(_ stream: RecvStream, _ socket: NWConnection) async throws {
        while true {
            let data = try await stream.read(sizeLimit: 65536)
            if data.isEmpty {
                socket.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                return
            }
            try await send(socket, data)
        }
    }
    private static func writeFrame(_ stream: SendStream, value: JSONValue) async throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8192 else { throw PocketError.message("配对消息过大。") }
        var size = UInt32(data.count).bigEndian
        try await stream.writeAll(buf: withUnsafeBytes(of: &size) { Data($0) } + data)
    }
    private static func readFrame(_ stream: RecvStream) async throws -> JSONValue {
        let prefix = try await stream.readExact(size: 4)
        let size = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= 8192 else { throw PocketError.message("电脑返回了无效配对消息。") }
        return try JSONDecoder().decode(JSONValue.self, from: await stream.readExact(size: size))
    }
    private func timed<T: Sendable>(_ seconds: Double, body: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw PocketError.message("建立直连超时，未使用中继。") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private static func randomData() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PocketError.message("无法创建配对身份。") }; return data
    }
    private static func randomToken() throws -> String {
        try randomData().base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func identity() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.xbunax.comfyuipocket.iroh.identity", kSecAttrAccount as String: "phone"]
        var match = query; match[kSecReturnData as String] = true; match[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(match as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw PocketError.message("无法读取已保存的配对身份。") }
        let secret = try randomData()
        var item = query; item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PocketError.message("无法保存配对身份。") }
        return secret
    }
}
