import Foundation
import CryptoKit

@MainActor
final class ComfyClient {
    let baseURL: URL
    let serverID: String
    let loopbackAccess: LoopbackAccess?
    let displayAddress: String
    let clientID: String
    private var session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var nodeDefinitionFetch: Task<Data, Error>?
    private var sizeCache: [String: (bytes: Int64?, expires: Date)] = [:]
    private var pendingSizes: [String: Task<Int64?, Never>] = [:]
    init(baseURL: URL, serverID: String? = nil, loopbackAccess: LoopbackAccess? = nil, displayAddress: String? = nil,
         clientID: String = UUID().uuidString) {
        self.baseURL = baseURL
        self.serverID = serverID ?? baseURL.absoluteString
        self.loopbackAccess = loopbackAccess
        self.displayAddress = displayAddress ?? baseURL.host ?? baseURL.absoluteString
        self.clientID = clientID
        let config = URLSessionConfiguration.ephemeral
        if let loopbackAccess { config.httpAdditionalHeaders = ["X-Pocket-Local-Token": loopbackAccess.token] }
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }
    func cacheResource(_ url: URL) -> String {
        loopbackAccess?.resource(url, serverID: serverID) ?? MediaCacheKey.resource(url)
    }
    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }
    func request(_ path: String, method: String = "GET", body: JSONValue? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
        var r = URLRequest(url: url(path, query: query)); r.httpMethod = method
        if let body { r.httpBody = try JSONEncoder().encode(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }
    func remove(_ path: String) async throws {
        let (data, response) = try await session.data(for: request(path, method: "DELETE"))
        guard let http = response as? HTTPURLResponse else { throw PocketError.message("服务器没有返回响应。") }
        if http.statusCode == 404 { return }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data.prefix(2000), encoding: .utf8) ?? "无响应内容"
            throw PocketError.message("服务器返回 HTTP \(http.statusCode)：\(message)")
        }
    }
    private func checked(_ r: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: r)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if loopbackAccess != nil && status == 503 {
                throw PocketError.message("P2P 直连已断开或无法建立；未使用中继。请检查电脑和网络后重连。")
            }
            let message = String(data: data.prefix(2000), encoding: .utf8) ?? "无响应内容"
            throw PocketError.message("服务器返回 HTTP \(status)：\(message)")
        }
        return data
    }
    func json(_ path: String, method: String = "GET", body: JSONValue? = nil, query: [URLQueryItem] = []) async throws -> JSONValue {
        let data = try await checked(request(path, method: method, body: body, query: query))
        return data.isEmpty ? .object([:]) : try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func hardwareJSON(_ path: String) async throws -> JSONValue {
        var r = try request(path); r.timeoutInterval = 3; r.cachePolicy = .reloadIgnoringLocalCacheData
        return try JSONDecoder().decode(JSONValue.self, from: await checked(r))
    }
    func nodeDefinitions() async throws -> Data {
        if let nodeDefinitionFetch { return try await nodeDefinitionFetch.value }
        let fetch = Task { try await fetchNodeDefinitions() }
        nodeDefinitionFetch = fetch
        defer { nodeDefinitionFetch = nil }
        return try await fetch.value
    }
    private func fetchNodeDefinitions() async throws -> Data {
        let cache = NodeDefinitionsCache.shared
        let previous = await cache.read(serverID)
        let header = "X-Pocket-Node-Revision"
        var request = try request("object_info")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(previous?.revision ?? "none", forHTTPHeaderField: header)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PocketError.message("服务器没有返回节点定义。")
        }
        if http.statusCode == 304, let previous, http.value(forHTTPHeaderField: header) == previous.revision {
            return previous.data
        }
        guard http.statusCode == 200 else {
            throw PocketError.message("获取节点定义失败（HTTP \(http.statusCode)）。")
        }
        guard let revision = http.value(forHTTPHeaderField: header) else { return data }
        return try await cache.store(data, revision: revision, base: previous,
            delta: http.value(forHTTPHeaderField: "X-Pocket-Node-Delta") == "1", server: serverID)
    }
    func releaseMemory() async throws {
        let body: JSONValue = .object(["unload_models": .bool(true), "free_memory": .bool(true)])
        _ = try await checked(request("free", method: "POST", body: body))
    }
    func probeServer() async throws {
        var request = try request("queue")
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let queue = try JSONDecoder().decode(JSONValue.self, from: await checked(request))
        guard case .array = queue["queue_running"], case .array = queue["queue_pending"] else {
            throw PocketError.message("ComfyUI 未返回有效的队列状态。")
        }
    }
    func renewSession() {
        disconnect()
        let old = session
        session = URLSession(configuration: old.configuration)
        old.invalidateAndCancel()
        for task in pendingSizes.values { task.cancel() }
        pendingSizes.removeAll()
    }
    func outputDirectory(folder: String, offset: Int, sort: String, ascending: Bool, input: Bool = false) async throws -> OutputDirectoryPage {
        let data = try await checked(request(input ? "pocket/v1/inputs" : "pocket/v1/outputs", query: [
            .init(name: "folder", value: folder), .init(name: "offset", value: String(offset)),
            .init(name: "limit", value: "60"), .init(name: "sort", value: sort),
            .init(name: "direction", value: ascending ? "ascending" : "descending")
        ]))
        return try JSONDecoder().decode(OutputDirectoryPage.self, from: data)
    }
    func importAsset(_ asset: OutputImage) async throws -> String {
        let result = try await json("pocket/v1/media/import", method: "POST", body: .object([
            "type": .string(asset.type), "subfolder": .string(asset.portableSubfolder), "filename": .string(asset.filename)
        ]))
        guard let value = result["value"].text.nonEmpty else { throw PocketError.message("服务器没有返回输入文件路径。") }
        return value
    }
    func image(_ image: OutputImage) async throws -> Data {
        try await mediaData(mediaURL(image), revision: image.promptID)
    }
    /// HEAD reads file length without downloading images or large videos.
    private func mediaSize(_ output: OutputImage) async -> Int64? {
        let key = output.assetID + "|" + output.promptID
        if let cached = sizeCache[key], cached.expires > Date() { return cached.bytes }
        if let pending = pendingSizes[key] { return await pending.value }
        var request = URLRequest(url: mediaURL(output)); request.httpMethod = "HEAD"
        request.timeoutInterval = 5; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let session = session
        let task = Task<Int64?, Never> {
            guard let (_, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let text = http.value(forHTTPHeaderField: "Content-Length"), let size = Int64(text), size >= 0 else { return nil }
            return size
        }
        pendingSizes[key] = task
        let result = await task.value; pendingSizes[key] = nil
        if sizeCache.count >= 2048 { sizeCache = sizeCache.filter { $0.value.expires > Date() }; if sizeCache.count >= 2048 { sizeCache.removeAll() } }
        sizeCache[key] = (result, Date().addingTimeInterval(result == nil ? 30 : 300))
        return result
    }
    func mediaSizes(_ outputs: [OutputImage]) async -> [String: Int64] {
        var seen = Set<String>(), result: [String: Int64] = [:]
        let unique = outputs.filter { seen.insert($0.assetID).inserted }
        for start in stride(from: 0, to: unique.count, by: 4) {
            guard !Task.isCancelled else { return result }
            let batch = unique[start..<min(start + 4, unique.count)]
            await withTaskGroup(of: (String, Int64?).self) { group in
                for output in batch { group.addTask { (output.assetID, await self.mediaSize(output)) } }
                for await (id, size) in group { if let size { result[id] = size } }
            }
        }
        return result
    }
    func mediaURL(_ image: OutputImage) -> URL {
        let url = url("view", query: [.init(name: "filename", value: image.filename), .init(name: "subfolder", value: image.subfolder), .init(name: "type", value: image.type)])
        return loopbackAccess?.mediaURL(url) ?? url
    }
    private func mediaData(_ url: URL, revision: String, lifetime: TimeInterval = .infinity) async throws -> Data {
        let session = session
        return try await MediaCache.shared.data(for: MediaCacheKey(resource: cacheResource(url), variant: "original:\(revision)"), lifetime: lifetime) {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw PocketError.message("文件预览不可用。")
            }
            return data
        }
    }
    func inputMedia(_ value: String) async throws -> Data {
        try await mediaData(inputMediaURL(value), revision: "input", lifetime: 60)
    }
    func inputMediaURL(_ value: String) -> URL {
        let parts = MediaFile.split(value)
        var query = [URLQueryItem(name: "filename", value: parts.filename), .init(name: "type", value: parts.type)]
        if !parts.subfolder.isEmpty { query.append(.init(name: "subfolder", value: parts.subfolder)) }
        let url = url("view", query: query)
        return loopbackAccess?.mediaURL(url) ?? url
    }
    func download(_ image: OutputImage) async throws -> URL {
        if !image.isVideo {
            let data = try await self.image(image)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(URL(fileURLWithPath: image.filename).lastPathComponent)")
            try data.write(to: file); return file
        }
        let r = try request("view", query: [.init(name: "filename", value: image.filename), .init(name: "subfolder", value: image.subfolder), .init(name: "type", value: image.type)])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(URL(fileURLWithPath: image.filename).lastPathComponent)")
        let key = MediaCacheKey(resource: cacheResource(mediaURL(image)), variant: "video-file:\(image.promptID)")
        let session = session
        try await MediaCache.shared.materializeFile(for: key, destination: file) {
            let (temporary, response) = try await session.download(for: r)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                throw PocketError.message("作品下载失败。")
            }
            return temporary
        }
        return file
    }
    func upload(_ data: Data, filename: String, mime: String) async throws -> String {
        let boundary = UUID().uuidString
        var r = try request("upload/image", method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"type\"\r\n\r\ninput\r\n--\(boundary)--\r\n".utf8))
        r.httpBody = body
        let json = try JSONDecoder().decode(JSONValue.self, from: await checked(r))
        guard let name = json["name"].text.nonEmpty else { throw PocketError.message("图片上传没有返回文件名。") }
        let folder = json["subfolder"].text
        let value = folder.isEmpty ? name : "\(folder)/\(name)"
        await MediaCache.shared.invalidate(resource: cacheResource(inputMediaURL(value)))
        return value
    }
    func listen(event: @escaping @MainActor (JSONValue) -> Void, preview: @escaping @MainActor (Data) -> Void, state: @escaping @MainActor (Bool) -> Void) async {
        var delay: UInt64 = 1
        while !Task.isCancelled {
            var attempt: URLSessionWebSocketTask?
            do {
                var r = try request("ws", query: [.init(name: "clientId", value: clientID)])
                var c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
                c.scheme = c.scheme == "https" ? "wss" : "ws"; r.url = c.url
                let ws = session.webSocketTask(with: r)
                attempt = ws; socket = ws; ws.resume()
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard !Task.isCancelled, socket === ws else { break }
                    state(true); delay = 1
                    switch message {
                    case .string(let text): if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) { event(v) }
                    case .data(let data):
                        // ComfyUI binary preview: uint32 event type, uint32 image format, encoded image.
                        if data.count > 8, Array(data.prefix(4)) == [0, 0, 0, 1] { preview(Data(data.dropFirst(8))) }
                    @unknown default: break
                    }
                }
            } catch {
                if !Task.isCancelled, socket === attempt { state(false) }
            }
            attempt?.cancel(with: .goingAway, reason: nil)
            if socket === attempt { socket = nil }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 15)
        }
    }
    func disconnect() { socket?.cancel(with: .goingAway, reason: nil); socket = nil }
}

private actor NodeDefinitionsCache {
    static let shared = NodeDefinitionsCache()
    struct Entry: Codable, Sendable {
        let revision: String
        let data: Data
    }

    private let directory = URL.cachesDirectory.appending(path: "PocketNodeDefinitions", directoryHint: .isDirectory)

    private func file(_ server: String) -> URL {
        let digest = SHA256.hash(data: Data(server.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined())
    }

    func read(_ server: String) -> Entry? {
        guard let value = try? Data(contentsOf: file(server)) else { return nil }
        return try? PropertyListDecoder().decode(Entry.self, from: value)
    }

    func store(_ data: Data, revision: String, base: Entry?, delta: Bool, server: String) throws -> Data {
        let merged: Data
        if delta {
            guard let base,
                  var definitions = try JSONSerialization.jsonObject(with: base.data) as? [String: Any],
                  let patch = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let changed = patch["changed"] as? [String: Any],
                  let removed = patch["removed"] as? [String] else {
                throw PocketError.message("服务器返回的节点更新无效。")
            }
            for name in removed { definitions.removeValue(forKey: name) }
            definitions.merge(changed) { _, latest in latest }
            merged = try JSONSerialization.data(withJSONObject: definitions)
        } else {
            merged = data
        }
        if revision.utf8.count == 64, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let bytes = try? encoder.encode(Entry(revision: revision, data: merged)) {
                try? bytes.write(to: file(server), options: .atomic)
            }
        }
        return merged
    }
}
