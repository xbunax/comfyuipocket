import Foundation

@MainActor
final class ComfyClient {
    let baseURL: URL
    let serverID: String
    let loopbackAccess: LoopbackAccess?
    let displayAddress: String
    let clientID = UUID().uuidString
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var sizeCache: [String: (bytes: Int64?, expires: Date)] = [:]
    private var pendingSizes: [String: Task<Int64?, Never>] = [:]
    init(baseURL: URL, serverID: String? = nil, loopbackAccess: LoopbackAccess? = nil, displayAddress: String? = nil) {
        self.baseURL = baseURL
        self.serverID = serverID ?? baseURL.absoluteString
        self.loopbackAccess = loopbackAccess
        self.displayAddress = displayAddress ?? baseURL.host ?? baseURL.absoluteString
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
    private func mediaData(_ url: URL, revision: String, lifetime: TimeInterval = 7 * 86400) async throws -> Data {
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
        let (temporary, response) = try await session.download(for: r)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw PocketError.message("作品下载失败。")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(URL(fileURLWithPath: image.filename).lastPathComponent)")
        try FileManager.default.moveItem(at: temporary, to: file)
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
            do {
                var r = try request("ws", query: [.init(name: "clientId", value: clientID)])
                var c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
                c.scheme = c.scheme == "https" ? "wss" : "ws"; r.url = c.url
                let ws = session.webSocketTask(with: r); socket = ws; ws.resume()
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    state(true); delay = 1
                    switch message {
                    case .string(let text): if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) { event(v) }
                    case .data(let data):
                        // ComfyUI binary preview: uint32 event type, uint32 image format, encoded image.
                        if data.count > 8, Array(data.prefix(4)) == [0, 0, 0, 1] { preview(Data(data.dropFirst(8))) }
                    @unknown default: break
                    }
                }
            } catch { state(false) }
            socket?.cancel(with: .goingAway, reason: nil); socket = nil
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 15)
        }
    }
    func disconnect() { socket?.cancel(with: .goingAway, reason: nil); socket = nil }
}
