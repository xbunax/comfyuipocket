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

struct ResolutionPreset: Identifiable, Sendable {
    let width: Int
    let height: Int
    let name: String?
    init(width: Int, height: Int, name: String? = nil) {
        self.width = width; self.height = height; self.name = name
    }
    var id: String { "\(width)×\(height)" }
    var title: String { name.map { "\($0) · \(id)" } ?? id }
    static let common = [
        ResolutionPreset(width: 512, height: 512),
        ResolutionPreset(width: 768, height: 768),
        ResolutionPreset(width: 1024, height: 1024),
        ResolutionPreset(width: 832, height: 1216),
        ResolutionPreset(width: 1216, height: 832),
        ResolutionPreset(width: 1280, height: 720, name: "720p 横屏"),
        ResolutionPreset(width: 720, height: 1280, name: "720p 竖屏"),
        ResolutionPreset(width: 1920, height: 1080, name: "1080p 横屏"),
        ResolutionPreset(width: 1080, height: 1920, name: "1080p 竖屏"),
        ResolutionPreset(width: 2560, height: 1440, name: "2K QHD 横屏"),
        ResolutionPreset(width: 1440, height: 2560, name: "2K QHD 竖屏"),
        ResolutionPreset(width: 2048, height: 1080, name: "2K DCI 横屏"),
        ResolutionPreset(width: 1080, height: 2048, name: "2K DCI 竖屏"),
        ResolutionPreset(width: 3840, height: 2160, name: "4K UHD 横屏"),
        ResolutionPreset(width: 2160, height: 3840, name: "4K UHD 竖屏"),
        ResolutionPreset(width: 4096, height: 2160, name: "4K DCI 横屏"),
        ResolutionPreset(width: 2160, height: 4096, name: "4K DCI 竖屏"),
        ResolutionPreset(width: 1536, height: 1536),
        ResolutionPreset(width: 2048, height: 2048)
    ]
    static let quick = common.filter {
        ($0.width == $0.height && $0.width <= 1024)
            || ($0.width, $0.height) == (1920, 1080)
            || ($0.width, $0.height) == (2560, 1440)
            || ($0.width, $0.height) == (3840, 2160)
    }
}

/// Only pair editable numeric dimensions on the same node. Never replace links.
struct WorkflowResolution {
    let width: WorkflowField
    let height: WorkflowField
    init?(fields: [WorkflowField]) {
        guard let width = fields.first(where: { $0.key == "width" }),
              let height = fields.first(where: { $0.key == "height" }),
              width.nodeID == height.nodeID,
              Self.isNumeric(width.value), Self.isNumeric(height.value) else { return nil }
        self.width = width; self.height = height
    }
    func values(for preset: ResolutionPreset, schema: JSONValue) -> (width: JSONValue, height: JSONValue)? {
        guard let w = Self.value(preset.width, field: width, schema: schema),
              let h = Self.value(preset.height, field: height, schema: schema) else { return nil }
        return (w, h)
    }
    private static func isNumeric(_ value: JSONValue) -> Bool {
        switch value { case .integer, .unsigned, .number: return true; default: return false }
    }
    private static func value(_ size: Int, field: WorkflowField, schema: JSONValue) -> JSONValue? {
        guard size > 0 else { return nil }
        let descriptor = (schema["input"]["required"].object[field.key] ?? schema["input"]["optional"].object[field.key] ?? .null).array
        let choices = InputSchema.choices(descriptor)
        if !choices.isEmpty && !choices.contains(where: { isNumeric($0) && $0.double == Double(size) }) { return nil }
        let config = descriptor.count > 1 ? descriptor[1] : .null
        let number = Double(size)
        if config.object["min"] != nil && number < config["min"].double { return nil }
        if config.object["max"] != nil && number > config["max"].double { return nil }
        let step = config["step"].double
        if step.isFinite && step > 0 {
            let units = (number - (config.object["min"] == nil ? 0 : config["min"].double)) / step
            if abs(units - units.rounded()) > 0.000001 { return nil }
        }
        switch field.value {
        case .integer: return .integer(Int64(size))
        case .unsigned: return .unsigned(UInt64(size))
        case .number: return .number(number)
        default: return nil
        }
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

enum WorkflowNodePurpose: String, CaseIterable, Identifiable {
    case prompts, media, models, sampling, dimensions, outputs, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .prompts: return "提示词"
        case .media: return "图片与媒体"
        case .models: return "模型与加载"
        case .sampling: return "采样与生成"
        case .dimensions: return "尺寸与潜空间"
        case .outputs: return "输出与保存"
        case .other: return "其他节点"
        }
    }
    static func classify(_ fields: [WorkflowField]) -> Self {
        let type = fields.first?.classType.lowercased() ?? ""
        if type.contains("save") || type.contains("preview") || type.contains("output") { return .outputs }
        if fields.contains(where: { $0.key == "text" || $0.key.lowercased().contains("prompt") })
            || type.contains("textencode") || type.contains("conditioning") { return .prompts }
        if fields.contains(where: { MediaFile.kind(for: $0) != nil }) { return .media }
        if ["sampler", "scheduler", "sampling", "noise", "guider"].contains(where: { type.contains($0) }) { return .sampling }
        if ["loader", "checkpoint", "lora", "clip", "model"].contains(where: { type.contains($0) }) { return .models }
        if ["latent", "resize", "scale", "resolution", "vae"].contains(where: { type.contains($0) })
            || fields.contains(where: { ["width", "height"].contains($0.key) }) { return .dimensions }
        return .other
    }
}

struct WorkflowNodeSection: Identifiable {
    let id: String
    let fields: [WorkflowField]
    var title: String { fields.first?.nodeTitle ?? id }
    var purpose: WorkflowNodePurpose { WorkflowNodePurpose.classify(fields) }
}

extension Workflow {
    var nodeSections: [WorkflowNodeSection] {
        let fields = self.fields
        return Dictionary(grouping: fields, by: \.nodeID).map { WorkflowNodeSection(id: $0.key, fields: $0.value) }
            .sorted { a, b in
                let ai = fields.firstIndex(where: { $0.nodeID == a.id }) ?? 0
                let bi = fields.firstIndex(where: { $0.nodeID == b.id }) ?? 0
                return ai < bi
            }
    }
}

struct OutputImage: Codable, Equatable, Identifiable {
    let promptID: String
    let filename: String
    let subfolder: String
    let type: String
    var id: String { "\(promptID)/\(type)/\(subfolder)/\(filename)" }
    var assetID: String { "\(type)/\(subfolder)/\(filename)" }
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
