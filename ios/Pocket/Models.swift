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
    var tailscale = false
    var controlURL = ""
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
        return Workflow(id: root["id"]?.text.nonEmpty ?? UUID().uuidString,
                        name: root["name"]?.text.nonEmpty ?? name, prompt: prompt,
                        pinned: root["pinned"]?.array.map(\.text) ?? [])
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

struct OutputImage: Identifiable {
    let promptID: String
    let filename: String
    let subfolder: String
    let type: String
    var id: String { "\(promptID)/\(type)/\(subfolder)/\(filename)" }
    var isVideo: Bool { ["mp4", "mov", "webm", "m4v"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) }
}
extension String { var nonEmpty: String? { isEmpty ? nil : self } }
