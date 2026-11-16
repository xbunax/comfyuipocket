import Foundation

/// Field semantics are independent of a custom node's display language.
enum MobileField {
    static func isSeed(_ key: String) -> Bool {
        let k = key.lowercased()
        return k == "seed" || k.hasSuffix("_seed") || k == "种子" || k == "超分种子"
    }
    static func isPrompt(_ field: WorkflowField) -> Bool {
        let k = field.key.lowercased()
        return k == "text" || k == "prompt" || k == "positive" || k == "negative" || k == "global_prompt" || k == "negative_prompt"
            || k == "system_prompt" || k == "提示词文本" || k == "提示词" || k == "负面提示词"
            || (field.classType == "PrimitiveStringMultiline" && k == "value")
    }
    static func isInternal(_ field: WorkflowField) -> Bool {
        guard field.classType.hasPrefix("Lazy") else { return false }
        // The director's mode button swaps track banks, not just this scalar value.
        if field.classType == "LazyH3Director", field.key == "workspace_mode" { return true }
        return ["timeline_ui", "local_prompts", "segment_lengths", "guide_strength", "transition_smoothness"].contains(field.key)
    }
    static func isCommon(_ field: WorkflowField) -> Bool {
        if isInternal(field) { return false }
        if isPrompt(field) || isSeed(field.key) || MediaFile.kind(for: field) != nil { return true }
        if ["图片数据", "timeline_data"].contains(field.key) { return true }
        let key = field.key.lowercased()
        return ["width", "height", "custom_width", "custom_height", "宽度", "高度", "aspect_ratio", "megapixels", "multiple",
                "steps", "cfg", "denoise", "步数", "krea步数", "qwen步数", "kreacfg", "qwencfg", "frame_rate", "workspace_mode",
                "启用", "启用超分", "启用补帧", "放大倍数", "超分倍率", "补帧倍率", "风格库", "风格", "batch_size"].contains(key)
            || field.classType.contains("LoraStack") || field.classType.contains("LoraLoader")
    }
    static func slot(_ key: String) -> Int? {
        guard let tail = key.split(separator: "_").last, let value = Int(tail), value > 0 else { return nil }
        return value
    }
}

/// Workbench JSON entries retain extension-specific masks and metadata on reorder.
struct WorkbenchImages {
    var items: [JSONValue]
    init(_ text: String) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data((text.isEmpty ? "[]" : text).utf8))
        guard case .array(let items) = value, items.allSatisfy({ if case .object = $0 { return true }; return false }) else {
            throw PocketError.message("图片数据格式不受支持，请在专用控件中编辑。")
        }
        self.items = items
    }
    func encoded() throws -> String { String(decoding: try JSONEncoder().encode(items), as: UTF8.self) }
    static func reference(_ item: JSONValue) -> String {
        let raw = item["image"].text
        let path = raw.contains("/") || item["subfolder"].text.isEmpty ? raw : item["subfolder"].text + "/" + raw
        return path + " [\(item["type"].text.isEmpty ? "input" : item["type"].text)]"
    }
    static func item(_ uploaded: String) -> JSONValue {
        let file = MediaFile.split(uploaded)
        return .object(["image": .string(file.filename), "subfolder": .string(file.subfolder), "type": .string(file.type), "mask": .string("")])
    }
}

/// Only the untrimmed, contiguous text storyboard has a direct mobile serializer.
/// Audio, retakes, overlaps and media clips continue through the node's own editor.
struct H3Storyboard {
    var root: [String: JSONValue]
    var segments: [JSONValue] { root["segments"]?.array ?? [] }
    init(_ text: String) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard case .object(let root) = value, case .array = root["segments"] else { throw PocketError.message("无法识别导演台数据。") }
        self.root = root
    }
    var editable: Bool {
        guard root["retakeMode"] != .bool(true), root["manualOutputRange"] != .bool(true), root["mainTrackEnabled"] != .bool(false),
              (root["audioSegments"]?.array ?? []).isEmpty, (root["motionSegments"]?.array ?? []).isEmpty else { return false }
        var end = 0.0
        for s in segments {
            guard s["type"].text == "text", s["start"].double == end,
                  s["length"].double >= 1, s["length"].double <= 100000,
                  s["length"].double.rounded() == s["length"].double else { return false }
            end += s["length"].double
        }
        return !segments.isEmpty
    }
    mutating func update(index: Int, key: String, value: JSONValue) {
        guard editable, segments.indices.contains(index), ["prompt", "length"].contains(key) else { return }
        var list = segments
        var segment = list[index].object
        if key == "length", value.double < 1 { return }
        segment[key] = value; list[index] = .object(segment)
        var start: Double = 0
        for i in list.indices {
            var item = list[i].object; item["start"] = .number(start)
            start += item["length"]?.double ?? 0; list[i] = .object(item)
        }
        replaceSegments(list)
    }
    mutating func replaceSegments(_ segments: [JSONValue]) {
        var list = segments
        var start: Double = 0
        for i in list.indices {
            var item = list[i].object; item["start"] = .number(start)
            start += item["length"]?.double ?? 0; list[i] = .object(item)
        }
        root["segments"] = .array(list); root["normalDurationFrames"] = .number(start)
        var banks = root["h3Tracks"]?.object ?? [:]
        let mode = root["workspace_mode"]?.text == "多参" ? "多参" : "分镜"
        var bank = banks[mode]?.object ?? [:]; bank["segments"] = .array(list)
        banks[mode] = .object(bank); root["h3Tracks"] = .object(banks)
    }
    func inputs(fps: Double) throws -> [String: JSONValue] {
        guard editable, fps > 0 else { throw PocketError.message("此时间轴需要使用专用控件编辑。") }
        guard !segments.contains(where: { $0["prompt"].text.contains("|") }) else { throw PocketError.message("分镜提示词不能包含 |，导演台会将它作为分镜分隔符。") }
        let duration = segments.reduce(0) { $0 + $1["length"].double }
        let text = String(decoding: try JSONEncoder().encode(JSONValue.object(root)), as: UTF8.self)
        return ["timeline_data": .string(text), "local_prompts": .string(segments.map { $0["prompt"].text }.joined(separator: " | ")),
                "segment_lengths": .string(segments.map { String(Int($0["length"].double)) }.joined(separator: ",")),
                "start_frame": .integer(0), "end_frame": .number(duration), "duration_frames": .number(duration),
                "start_second": .number(0), "end_second": .number(duration / fps), "duration_seconds": .number(duration / fps)]
    }
}
