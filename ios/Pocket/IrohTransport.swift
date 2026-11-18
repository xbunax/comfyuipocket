import Foundation
import Observation
import IrohLib
import Network
import OSLog
import Security
import WebKit

@MainActor @Observable
final class IrohTransport {
    private(set) var peer: IrohPeerProfile
    struct Event: Identifiable {
        let id = UUID()
        let time = Date()
        let message: String
    }
    private(set) var events: [Event] = []
    private(set) var status = "准备直连…" {
        didSet {
            guard status != oldValue else { return }
            events.append(Event(message: status))
            if events.count > 32 { events.removeFirst() }
        }
    }
    let speedTest = DirectSpeedTest()
    private(set) var supportsSpeedTest = false
    var directReady: Bool {
        guard let connection, !stopped, connection.closeReason() == nil else { return false }
        return connection.paths().contains { $0.isIp && $0.isSelected }
    }
    var canRetryNow: Bool { !stopped && connection == nil && retryAfter != nil }
    func retryNow() async {
        guard canRetryNow else { return }
        retryAfter = nil
        _ = try? await ensureConnection()
    }
    func testSpeed() {
        guard directReady, supportsSpeedTest, let connection else { return }
        speedTest.start(on: connection)
    }
    private(set) var authenticated = false
    private(set) var baseURL: URL?
    private(set) var access: LoopbackAccess?
    @ObservationIgnored private var enrollmentToken: String?
    @ObservationIgnored private var endpoint: Endpoint?
    private var connection: IrohLib.Connection?
    @ObservationIgnored private var connecting: Task<IrohLib.Connection, Error>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var listenerReady: CheckedContinuation<URL, Error>?
    @ObservationIgnored private var channels: [UUID: (NWConnection, Task<Void, Never>)] = [:]
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var cookie: HTTPCookie?
    private var retryAfter: ContinuousClock.Instant?
    @ObservationIgnored private var retryDelay = 1
    @ObservationIgnored var onReconnect: ((IrohPeerProfile) -> Void)?
    private static let alpn = Data("comfyuipocket/tcp/1".utf8)
    private static let log = Logger(subsystem: "com.xbunax.comfyuipocket", category: "P2P")

    init(peer: IrohPeerProfile, token: String? = nil) { self.peer = peer; enrollmentToken = token }

    func start() async throws {
        status = "建立仅直连通道…"
        endpoint = try await bindEndpoint()
        _ = try await ensureConnection()
        let url = try await startListener()
        guard let access else { throw PocketError.message("本地通道未就绪。") }
        let cookie = HTTPCookie(properties: [.name: access.cookieName, .value: access.token,
            .domain: "127.0.0.1", .path: "/", .init("HttpOnly"): "TRUE", .init("SameSite"): "Strict"])!
        self.cookie = cookie
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        baseURL = url
        status = "已直连 · 已禁用中继"
        Self.log.info("phase=loopback result=ready")
        resumeMonitoring()
    }

    func stop(status finalStatus: String = "已断开") {
        speedTest.clear()
        enrollmentToken = nil
        stopped = true; monitor?.cancel(); monitor = nil; connecting?.cancel(); connecting = nil
        listenerReady?.resume(throwing: CancellationError()); listenerReady = nil
        listener?.cancel(); listener = nil
        for (_, (socket, task)) in channels { task.cancel(); socket.cancel() }; channels.removeAll()
        try? connection?.close(errorCode: 0, reason: Data("disconnected".utf8)); connection = nil
        if let endpoint { Task { try? await endpoint.close() } }; endpoint = nil
        if let cookie { Task { await WKWebsiteDataStore.default().httpCookieStore.delete(cookie) } }; cookie = nil
        status = finalStatus
    }

    func suspendMonitoring() {
        speedTest.cancel()
        monitor?.cancel()
        monitor = nil
    }

    private func bindEndpoint() async throws -> Endpoint {
        Self.log.info("phase=bind result=starting")
        do {
            let endpoint = try await timed(8) {
                let endpoint = try await Endpoint.bind(options: EndpointOptions(preset: presetN0DisableRelay(),
                    secretKey: Self.identity(), relayMode: RelayMode.disabled()))
                guard !self.stopped, !Task.isCancelled else {
                    try? await endpoint.close()
                    throw CancellationError()
                }
                return endpoint
            }
            Self.log.info("phase=bind result=ready")
            return endpoint
        } catch {
            Self.log.error("phase=bind result=failed error=\(String(reflecting: type(of: error)), privacy: .public)")
            throw error
        }
    }

    func resumeMonitoring() {
        guard !stopped, monitor == nil else { return }
        retryAfter = nil
        monitor = Task { @MainActor [weak self] in
            var missingSince: ContinuousClock.Instant?
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.stopped else { return }
                let now = ContinuousClock.now
                if let connection = self.connection {
                    let paths = connection.paths()
                    if paths.contains(where: { $0.isIp && $0.isSelected }) {
                        missingSince = nil
                    } else if missingSince == nil {
                        missingSince = now
                    }
                    let expired = missingSince.map { $0.duration(to: now) >= .seconds(15) } ?? false
                    if connection.closeReason() != nil || paths.contains(where: \.isRelay) || expired {
                        self.speedTest.clear()
                        try? connection.close(errorCode: 1, reason: Data("direct path lost".utf8))
                        self.connection = nil
                        self.status = "直连已断开，正在重连…"
                        Self.log.info("phase=session result=lost")
                    }
                }
                if self.connection == nil, self.retryAfter.map({ now >= $0 }) ?? true {
                    missingSince = nil
                    _ = try? await self.ensureConnection()
                }
            }
        }
    }

    private func ensureConnection() async throws -> IrohLib.Connection {
        guard !stopped else { throw PocketError.message("P2P 通道已关闭。") }
        if let connection, connection.closeReason() == nil { return connection }
        if let connecting { return try await connecting.value }
        if let retryAfter, ContinuousClock.now < retryAfter {
            throw PocketError.message("正等待下一次 P2P 重连。")
        }
        let task = Task<IrohLib.Connection, Error> { @MainActor in
            do {
                if self.endpoint == nil { self.endpoint = try await self.bindEndpoint() }
                guard let endpoint = self.endpoint else { throw CancellationError() }
                let connection = try await self.openDirectConnection(endpoint)
                self.status = "正在验证配对身份…"
                let (freshTicket, probeSupported) = try await self.authorize(connection)
                guard !self.stopped, !Task.isCancelled else {
                    try? connection.close(errorCode: 0, reason: Data())
                    throw CancellationError()
                }
                let reconnecting = self.authenticated
                self.peer.ticket = freshTicket
                self.speedTest.clear()
                self.supportsSpeedTest = probeSupported
                self.authenticated = true
                self.enrollmentToken = nil
                self.connection = connection
                self.retryAfter = nil
                self.retryDelay = 1
                self.status = "已直连 · 已禁用中继"
                Self.log.info("phase=authorize result=accepted reconnect=\(reconnecting)")
                if reconnecting { self.onReconnect?(self.peer) }
                return connection
            } catch {
                guard !self.stopped, !Task.isCancelled, !(error is CancellationError) else {
                    throw CancellationError()
                }
                if self.authenticated {
                    self.retryAfter = ContinuousClock.now.advanced(by: .seconds(self.retryDelay))
                    self.retryDelay = min(self.retryDelay * 2, 30)
                    self.status = "直连未恢复，正在自动重试"
                } else {
                    self.status = "无法建立直连"
                }
                throw error
            }
        }
        connecting = task
        defer { connecting = nil }
        return try await task.value
    }

    private func openDirectConnection(_ endpoint: Endpoint) async throws -> IrohLib.Connection {
        let address = try EndpointTicket.fromString(str: peer.ticket).endpointAddr()
        guard address.id().description == peer.endpointId, address.relayUrl() == nil else {
            Self.log.error("phase=ticket result=invalid_identity_or_relay")
            throw PocketError.message("保存的 P2P 地址与设备身份不符，请从电脑刷新配对码。")
        }
        status = "正在尝试保存的直连地址…"
        do {
            let connection = try await dial(endpoint, address: address, seconds: 6)
            Self.log.info("phase=cached_address result=connected")
            return connection
        } catch {
            try Task.checkCancellation()
            Self.log.notice("phase=cached_address result=failed error=\(String(reflecting: type(of: error)), privacy: .public)")
        }
        status = "正在查找电脑的最新地址…"
        let discovered = EndpointAddr(id: address.id(), relayUrl: nil, addresses: [])
        do {
            // A fresh endpoint clears the old remote address and its pending dial.
            // Keep the phone's identity and the local HTTP/WebSocket listener.
            try await endpoint.close()
            self.endpoint = nil
            try Task.checkCancellation()
            let rediscoveryEndpoint = try await bindEndpoint()
            self.endpoint = rediscoveryEndpoint
            let connection = try await dial(rediscoveryEndpoint, address: discovered, seconds: 12)
            Self.log.info("phase=address_lookup result=connected")
            return connection
        } catch {
            try Task.checkCancellation()
            Self.log.error("phase=address_lookup result=failed error=\(String(reflecting: type(of: error)), privacy: .public)")
            throw PocketError.message("保存的地址连不上，也未能通过地址发现直连。请确认电脑已启用 Pocket P2P。若电脑地址已变，可扫描同一台电脑的新二维码来刷新地址。")
        }
    }

    private func dial(_ endpoint: Endpoint, address: EndpointAddr, seconds: Double) async throws -> IrohLib.Connection {
        let expectedID = peer.endpointId
        return try await timed(seconds) {
            let connection = try await endpoint.connect(addr: address, alpn: Self.alpn)
            do {
                try Task.checkCancellation()
                let paths = connection.paths()
                guard connection.remoteId().description == expectedID,
                      paths.contains(where: { $0.isIp && $0.isSelected }),
                      !paths.contains(where: \.isRelay) else {
                    throw PocketError.message("未建立可信的 IP 直连。")
                }
                return connection
            } catch {
                try? connection.close(errorCode: 1, reason: Data("direct path unavailable".utf8))
                throw error
            }
        }
    }

    private func authorize(_ connection: IrohLib.Connection) async throws -> (String, Bool) {
        let expectedID = peer.endpointId
        let token = enrollmentToken
        do {
            return try await timed(8) {
                let stream = try await connection.openBi()
                let hello: JSONValue = .object(["v": .integer(1), "token": token.map(JSONValue.string) ?? .null])
                try await Self.writeFrame(stream.send(), value: hello)
                try await stream.send().finish()
                let response = try await Self.readFrame(stream.recv())
                guard response["ok"] == .bool(true), response["v"] == .integer(1),
                      response["directOnly"] == .bool(true), response["endpointId"].text == expectedID else {
                    throw PocketError.message("配对确认无效。")
                }
                let ticket = response["ticket"].text
                let fresh = try EndpointTicket.fromString(str: ticket).endpointAddr()
                guard fresh.id().description == expectedID, fresh.relayUrl() == nil else {
                    throw PocketError.message("电脑返回了无效的直连地址。")
                }
                return (ticket, response["speedTest"] == .integer(1))
            }
        } catch {
            try? connection.close(errorCode: 1, reason: Data("authorization incomplete".utf8))
            try Task.checkCancellation()
            Self.log.error("phase=authorize result=failed error=\(String(reflecting: type(of: error)), privacy: .public)")
            throw PocketError.message("已连到电脑，但未完成配对验证。请检查电脑 Pocket 面板的已配对设备和连接日志。")
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
        try await PairingDeadline<T>.run(seconds, body: body)
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
