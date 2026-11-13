import Foundation

@MainActor
final class ComfyClient {
    let baseURL: URL
    let clientID = UUID().uuidString
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
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
    func image(_ image: OutputImage) async throws -> Data {
        try await checked(request("view", query: [.init(name: "filename", value: image.filename), .init(name: "subfolder", value: image.subfolder), .init(name: "type", value: image.type)]))
    }
    func inputMedia(_ value: String) async throws -> Data {
        let (data, response) = try await session.data(from: inputMediaURL(value))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw PocketError.message("文件预览不可用。") }
        return data
    }
    func inputMediaURL(_ value: String) -> URL {
        let parts = MediaFile.split(value)
        var query = [URLQueryItem(name: "filename", value: parts.filename), .init(name: "type", value: parts.type)]
        if !parts.subfolder.isEmpty { query.append(.init(name: "subfolder", value: parts.subfolder)) }
        return url("view", query: query)
    }
    func download(_ image: OutputImage) async throws -> URL {
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
        return folder.isEmpty ? name : "\(folder)/\(name)"
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
