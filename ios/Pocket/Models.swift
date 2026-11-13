import Foundation
import Darwin

enum PocketError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum JSONValue: Codable, Equatable {
    case string(String), integer(Int64), unsigned(UInt64), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var object: [String: JSONValue] { if case .object(let v) = self { return v }; return [:] }
    var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    var text: String {
        switch self {
        case .string(let v): return v
        case .integer(let v): return String(v)
        case .unsigned(let v): return String(v)
        case .number(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        default: return ""
        }
    }
    var double: Double { Double(text) ?? 0 }
    subscript(_ key: String) -> JSONValue { object[key] ?? .null }
}

struct ServerProfile: Codable, Equatable {
    var host = ""
    var port = "8188"
    var https = false
    func baseURL() throws -> URL {
        let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw
        var v4 = in_addr(); var v6 = in6_addr()
        guard inet_pton(AF_INET, ip, &v4) == 1 || inet_pton(AF_INET6, ip, &v6) == 1,
              let p = Int(port), (1...65535).contains(p) else {
            throw PocketError.message("请输入有效的 IPv4 / IPv6 地址和 1–65535 之间的端口。")
        }
        let address = ip.contains(":") ? "[\(ip)]" : ip
        guard let url = URL(string: "\(https ? "https" : "http")://\(address):\(p)") else {
            throw PocketError.message("服务器地址无效。")
        }
        return url
    }
}

struct Workflow: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: [String: JSONValue]
    var pinned: [String] = []
    var canvas: JSONValue? = nil
    enum CodingKeys: String, CodingKey {
        case id, name, prompt, pinned
        case canvas = "workflow"
    }
    static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    static func load(_ data: Data, name: String) throws -> Workflow {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let root = json.object
        let prompt = root["prompt"]?.object ?? root
        guard !prompt.isEmpty, prompt.values.allSatisfy({ node in
            guard case .string(let name) = node["class_type"], !name.isEmpty,
                  case .object = node["inputs"] else { return false }
            return true
        }) else {
            throw PocketError.message("需要 ComfyUI 的 API 格式工作流。普通画布 JSON 请在桌面端使用 Pocket 插件导出。")
        }
        return Workflow(id: root["id"]?.text.nonEmpty ?? newID(),
                        name: root["name"]?.text.nonEmpty ?? name, prompt: prompt,
                        pinned: root["pinned"]?.array.map(\.text) ?? [],
                        canvas: root["workflow"].flatMap { $0 == .null ? nil : $0 })
    }
    var fields: [WorkflowField] {
        prompt.flatMap { nodeID, node in
            node["inputs"].object.compactMap { key, value -> WorkflowField? in
                // API-format links and structured custom inputs are never flattened or rewritten.
                switch value { case .string, .integer, .unsigned, .number, .bool: break; default: return nil }
                return WorkflowField(nodeID: nodeID, key: key, nodeTitle: node["_meta"]["title"].text.nonEmpty ?? node["class_type"].text,
                                     classType: node["class_type"].text, value: value)
            }
        }.sorted {
            let a = pinned.firstIndex(of: $0.id) ?? 10000 + $0.priority
            let b = pinned.firstIndex(of: $1.id) ?? 10000 + $1.priority
            if a != b { return a < b }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }
    mutating func set(_ field: WorkflowField, value: JSONValue) {
        var node = prompt[field.nodeID]!.object
        var inputs = node["inputs"]!.object
        inputs[field.key] = value; node["inputs"] = .object(inputs); prompt[field.nodeID] = .object(node)
    }
    mutating func randomizeSeeds() {
        for nodeID in Array(prompt.keys) {
            guard var node = prompt[nodeID]?.object, var inputs = node["inputs"]?.object else { continue }
            var changed = false
            for key in Array(inputs.keys) where key.lowercased().contains("seed") {
                guard let value = inputs[key] else { continue }
                switch value {
                case .integer:
                    inputs[key] = .integer(Int64.random(in: 0...Int64(UInt32.max)))
                    changed = true
                case .unsigned:
                    inputs[key] = .unsigned(UInt64.random(in: 0...UInt64(UInt32.max)))
                    changed = true
                default:
                    break
                }
            }
            if changed {
                node["inputs"] = .object(inputs)
                prompt[nodeID] = .object(node)
            }
        }
    }
    var groupName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = trimmed.firstIndex(where: { $0 == "_" || $0 == "-" }) else { return "其他" }
        let prefix = String(trimmed[..<index]).trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? "其他" : prefix
    }
}

struct WorkflowField: Identifiable {
    let nodeID: String
    let key: String
    let nodeTitle: String
    let classType: String
    let value: JSONValue
    var id: String { "\(nodeID).\(key)" }
    var priority: Int {
        if key == "text" || key.contains("prompt") { return 0 }
        if key == "image" { return 1 }
        if key.contains("seed") { return 2 }
        if ["steps", "cfg", "width", "height"].contains(key) { return 3 }
        return 4
    }
}

enum InputSchema {
    static func choices(_ descriptor: [JSONValue]) -> [JSONValue] {
        guard let first = descriptor.first else { return [] }
        if case .array(let values) = first { return values }
        if first.text == "COMBO", descriptor.count > 1 { return descriptor[1]["options"].array }
        return []
    }
}

struct OutputImage: Identifiable {
    let promptID: String
    let filename: String
    let subfolder: String
    let type: String
    var id: String { "\(promptID)/\(type)/\(subfolder)/\(filename)" }
    var isVideo: Bool { ["mp4", "mov", "webm", "m4v", "avi", "mkv"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) }
    var mimeType: String {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
    static func fromHistoryEntry(_ entry: JSONValue, promptID: String) -> [OutputImage] {
        var result: [OutputImage] = []
        var seen = Set<String>()
        for (_, output) in entry["outputs"].object.sorted(by: { $0.key < $1.key }) {
            let files = output["images"].array + output["gifs"].array + output["videos"].array
            for file in files {
                guard !file["filename"].text.isEmpty else { continue }
                let item = OutputImage(promptID: promptID, filename: file["filename"].text, subfolder: file["subfolder"].text,
                                       type: file["type"].text.nonEmpty ?? "output")
                if seen.insert(item.id).inserted { result.append(item) }
            }
        }
        return result
    }
    static func fromHistory(_ history: JSONValue) -> [OutputImage] {
        let entries = history.object.sorted { ($0.value["prompt"].array.first?.double ?? 0) > ($1.value["prompt"].array.first?.double ?? 0) }
        var result: [OutputImage] = []
        var seen = Set<String>()
        for (id, entry) in entries {
            for item in fromHistoryEntry(entry, promptID: id) where seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        return result
    }
}

enum MediaKind: Equatable { case image, video, file }

enum MediaFile {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "avi", "mkv"]

    static func kind(for field: WorkflowField) -> MediaKind? {
        guard case .string(let raw) = field.value else { return nil }
        let key = field.key.lowercased()
        let nodeClass = field.classType.lowercased()
        let ext = URL(fileURLWithPath: split(raw).filename).pathExtension.lowercased()
        let pathKeys = ["image", "video", "audio", "file", "filename", "file_path", "image_path", "video_path", "path"]
        if nodeClass.contains("loadvideo") && pathKeys.contains(key) { return .video }
        if nodeClass.contains("loadimage") && pathKeys.contains(key) { return .image }
        if pathKeys.contains(key) && videoExtensions.contains(ext) { return .video }
        if pathKeys.contains(key) && imageExtensions.contains(ext) { return .image }
        if key.contains("image") && imageExtensions.contains(ext) { return .image }
        if key.contains("video") && videoExtensions.contains(ext) { return .video }
        if pathKeys.contains(key) && (["wav", "mp3", "flac", "ogg", "m4a", "pdf", "txt", "json", "csv", "obj", "glb"].contains(ext) || nodeClass.contains("loadaudio")) { return .file }
        return nil
    }

    static func split(_ raw: String) -> (filename: String, subfolder: String, type: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var type = "input"
        let annotations = [(" [output]", "output"), (" [input]", "input"), (" [temp]", "temp")]
        for (suffix, annotation) in annotations where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            type = annotation
            break
        }
        value = value.replacingOccurrences(of: "\\", with: "/")
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        let filename = parts.last.map(String.init) ?? value
        let subfolder = parts.dropLast().joined(separator: "/")
        return (filename, subfolder, type)
    }
}

struct SavedPrompt: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var text: String
    var updatedAt: Double
}
extension String { var nonEmpty: String? { isEmpty ? nil : self } }

struct SyncRecord: Codable, Equatable {
    var serverUpdatedAt: Double = 0
    var dirty: Bool = false
}

enum WorkflowSync {
    // A server deletion removes a local copy only when it was synced and has no unsent edits.
    static func idsToRemove(records: [String: SyncRecord], serverIDs: Set<String>,
                            pendingDeletes: Set<String>) -> [String] {
        records.compactMap { id, record in
            record.serverUpdatedAt > 0 && !record.dirty
                && !serverIDs.contains(id) && !pendingDeletes.contains(id) ? id : nil
        }.sorted()
    }
}
