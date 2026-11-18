import Foundation

struct GenerationDetails {
    var prompts: [GenerationPrompt] = []
    var parameters: [WorkflowField] = []
}

struct GenerationPrompt: Identifiable {
    enum Role: String, Hashable {
        case prompt, positive, negative, segments
        var title: String {
            switch self {
            case .prompt: "提示词"
            case .positive: "正向"
            case .negative: "负向"
            case .segments: "分镜提示词"
            }
        }
    }
    let nodeID: String
    let port: String
    let nodeTitle: String
    let role: Role
    let text: String
    let submittedInput: Bool
    var id: String { "\(nodeID).\(port)" }
}

/// Inspect the API-format graph saved at submission, including subgraph node IDs.
/// Text qualifies through a generation input or a link feeding that input.
struct ExecutionPrompts {
    private struct Wire: Hashable {
        let node: String
        let slot: Int
    }
    private struct Trace: Hashable {
        let wire: Wire
        let role: GenerationPrompt.Role
        let submittedInput: Bool
    }
    let record: MediaProvenance
    private var nodes: [String: JSONValue] { record.prompt }

    func details(for output: OutputImage? = nil) -> GenerationDetails {
        let scope = upstreamNodes(from: outputRoots(for: output))
        let fields = record.workflow.fields.filter { scope.contains($0.nodeID) }
        var prompts: [GenerationPrompt] = []
        var described = Set<String>()
        var traced = Set<Trace>()
        let recordedText = textFromRun()

        func add(_ id: String, _ port: String, _ role: GenerationPrompt.Role, _ text: String, _ submitted: Bool) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  described.insert("\(id).\(port)").inserted else { return }
            let node = nodes[id] ?? .null
            prompts.append(GenerationPrompt(nodeID: id, port: port, nodeTitle: node["_meta"]["title"].text.nonEmpty ?? node["class_type"].text,
                                            role: role, text: text, submittedInput: submitted))
        }
        func follow(_ value: JSONValue, node: String, port: String, role: GenerationPrompt.Role, submitted: Bool) {
            if case .string(let text) = value {
                add(node, port, role, text, submitted)
                return
            }
            guard let source = wire(value), scope.contains(source.node),
                  traced.insert(Trace(wire: source, role: role, submittedInput: submitted)).inserted,
                  let sourceNode = nodes[source.node] else { return }
            let type = sourceNode["class_type"].text.lowercased()
            if type == "conditioningzeroout" { return }
            if let text = recordedText[source] {
                add(source.node, "output:\(source.slot)", role, text, submitted)
                return
            }
            let submitted = submitted || Self.rewritesText(type) && sourceNode["inputs"]["goohai_bypass"] != .bool(true)
            let inputs = promptInputs(sourceNode)
            let semantic = inputs.keys.sorted().filter { Self.role($0, type: type) != nil }
            let hasSeparateNegative = semantic.contains { Self.role($0, type: type) == .negative }
            for key in inputs.keys.sorted() {
                let keyRole = Self.role(key, type: type)
                if keyRole == nil && !Self.passesText(key, type: type) { continue }
                if hasSeparateNegative && keyRole != nil && (keyRole == .negative) != (role == .negative) { continue }
                if let next = inputs[key] {
                    follow(next, node: source.node, port: key, role: keyRole == .segments ? .segments : role, submitted: submitted)
                }
            }
        }

        // Sampler and guider ports identify the role of an upstream encoder.
        // Inspect them first so a shared encoder is not reported twice.
        let candidates = scope.sorted().flatMap { id -> [(String, String, GenerationPrompt.Role, JSONValue)] in
            guard let node = nodes[id] else { return [] }
            let type = node["class_type"].text.lowercased()
            guard !Self.rewritesText(type) else { return [] }
            return promptInputs(node).sorted { $0.key < $1.key }.compactMap { key, value in
                Self.role(key, type: type).map { (id, key, $0, value) }
            }
        }
        let samplerPorts = candidates.filter {
            ["positive", "negative", "conditioning"].contains($0.1.lowercased())
                && !Self.isEncoder(nodes[$0.0]?["class_type"].text.lowercased() ?? "")
        }
        for (id, key, role, value) in samplerPorts + candidates {
            follow(value, node: id, port: key, role: role, submitted: false)
        }

        let parameters = fields.filter { field in
            let key = field.key.lowercased()
            return !described.contains(field.id) && Self.role(key, type: field.classType.lowercased()) == nil
                && !MobileField.isPrompt(field)
                && !["system_prompt", "timeline_data", "图片数据", "history_json", "timeline_ui"].contains(key)
        }
        return GenerationDetails(prompts: prompts, parameters: parameters)
    }

    private func outputRoots(for output: OutputImage?) -> [String]? {
        let media = nodes.keys.filter { id in
            let type = nodes[id]?["class_type"].text.lowercased() ?? ""
            return type.contains("saveimage") || type.contains("savevideo") || type.contains("videocombine")
                || type == "lazyvideosave" || type == "previewimage"
        }.sorted()
        if let output {
            if let recorded = record.outputNodes?[output.assetID], !recorded.isEmpty { return recorded }
            let matching = media.filter { id in
                let inputs = nodes[id]?["inputs"] ?? .null
                let prefix = (inputs["filename_prefix"].text.nonEmpty ?? inputs["文件名"].text).replacingOccurrences(of: "\\", with: "/")
                guard !prefix.isEmpty, !prefix.contains("%") else { return false }
                let path = output.subfolder.isEmpty ? output.filename : "\(output.subfolder)/\(output.filename)"
                if path.hasPrefix(prefix + ".") { return true }
                guard path.hasPrefix(prefix + "_") else { return false }
                return path.dropFirst(prefix.count + 1).first?.isNumber == true
            }
            if matching.count == 1 { return matching }
            if media.count > 1 { return [] }
            return media.isEmpty ? record.requestedOutputs : media
        }
        let recorded = Set(record.outputNodes?.values.flatMap { $0 } ?? [])
        if !recorded.isEmpty { return recorded.sorted() }
        if let requested = record.requestedOutputs, !requested.isEmpty {
            let outputs = requested.filter { media.contains($0) }
            return outputs.isEmpty ? requested : outputs
        }
        return media.isEmpty ? nil : media
    }

    private func upstreamNodes(from roots: [String]?) -> Set<String> {
        var pending = roots ?? Array(nodes.keys)
        var visited = Set<String>()
        while let id = pending.popLast() {
            guard let node = nodes[id], !Self.isNote(node["class_type"].text.lowercased()),
                  visited.insert(id).inserted else { continue }
            if node["class_type"].text == "ConditioningZeroOut" { continue }
            for (key, value) in activeInputs(node) where !Self.metadataPorts.contains(key.lowercased()) {
                if let source = wire(value) { pending.append(source.node) }
            }
        }
        return visited
    }

    private func wire(_ value: JSONValue) -> Wire? {
        let pair = value.array
        guard pair.count == 2, let slot = Int(pair[1].text), slot >= 0, nodes[pair[0].text] != nil else { return nil }
        return Wire(node: pair[0].text, slot: slot)
    }

    private func activeInputs(_ node: JSONValue) -> [String: JSONValue] {
        let inputs = node["inputs"].object
        guard node["class_type"].text == "ComfySwitchNode" else { return inputs }
        var choice = inputs["switch"] ?? .null
        if let source = wire(choice), nodes[source.node]?["class_type"].text == "PrimitiveBoolean" {
            choice = nodes[source.node]?["inputs"]["value"] ?? .null
        }
        guard case .bool(let on) = choice else { return [:] }
        let key = on ? "on_true" : "on_false"
        if let value = inputs[key] { return [key: value] }
        return [:]
    }

    private func promptInputs(_ node: JSONValue) -> [String: JSONValue] {
        var inputs = activeInputs(node)
        guard ["LazyH3Director", "WanRemixDirector"].contains(node["class_type"].text),
              let data = inputs["timeline_data"], case .string(let json) = data,
              let timeline = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
              !timeline["segments"].array.isEmpty else { return inputs }
        let start = inputs["start_frame"]?.double ?? 0
        let duration = inputs["duration_frames"]?.double ?? 0
        let end = duration > 0 ? start + duration : Double.infinity
        let segments = timeline["segments"].array.enumerated().filter { _, segment in
            let position = segment["start"].double
            return segment["type"].text != "ghost" && !segment.object.isEmpty
                && position < end && position + max(1, segment["length"].double) > start
        }.sorted { ($0.element["start"].double, $0.offset) < ($1.element["start"].double, $1.offset) }
        let fallback = (inputs["local_prompts"]?.text ?? "").split(separator: "|", omittingEmptySubsequences: false)
        let text: [String] = segments.enumerated().compactMap { index, segment in
            let original = segment.element["prompt"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !original.isEmpty { return original }
            if fallback.indices.contains(index) { return String(fallback[index]).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            return nil
        }
        inputs["local_prompts"] = .string(text.joined(separator: "\n\n"))
        return inputs
    }

    private func textFromRun() -> [Wire: String] {
        var result: [Wire: String] = [:]
        for (id, text) in record.displayedText ?? [:] {
            guard let node = nodes[id], node["class_type"].text == "GoohaiDisplayAny",
                  let source = wire(node["inputs"]["Any"]) else { continue }
            result[source] = text
        }
        return result
    }

    private static let metadataPorts: Set<String> = ["filename", "filename_prefix", "文件名", "metadata", "extra_pnginfo",
                                                     "note", "notes", "markdown", "system_prompt", "caption"]
    private static func isNote(_ type: String) -> Bool {
        type == "note" || type.hasPrefix("markdown") || type.hasSuffix("note") || type.hasSuffix("notes")
    }
    private static func isEncoder(_ type: String) -> Bool { type.contains("textencode") || type.contains("encodetext") }
    private static func rewritesText(_ type: String) -> Bool {
        type.contains("promptoptimizer") || type.contains("promptchat") || type.contains("promptgenerator") || type.contains("llm")
    }
    private static func role(_ key: String, type: String) -> GenerationPrompt.Role? {
        switch key.lowercased() {
        case "positive", "positive_prompt", "正向提示词": return .positive
        case "negative", "negative_prompt", "负面提示词", "负向提示词": return .negative
        case "local_prompts": return .segments
        case "prompt", "global_prompt", "提示词文本", "提示词", "用户提示词": return .prompt
        case "conditioning": return type.contains("guider") || type.contains("sampler") ? .positive : nil
        case "text", "text_g", "text_l", "clip_l", "t5xxl":
            return isEncoder(type) ? .prompt : nil
        default: return nil
        }
    }
    private static func passesText(_ key: String, type: String) -> Bool {
        let key = key.lowercased()
        if type == "comfyswitchnode" { return key == "on_true" || key == "on_false" }
        if type == "goohaidisplayany" || type.contains("reroute") { return key == "any" || key == "input" }
        if type.hasPrefix("conditioning") { return key.hasPrefix("conditioning") }
        return ["text", "string", "value"].contains(key) && !type.hasPrefix("showtext")
    }
}
