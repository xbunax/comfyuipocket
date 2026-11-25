import Foundation

struct ArtworkSelection {
    private(set) var files: [String: OutputImage] = [:]

    func containsAll(_ outputs: [OutputImage]) -> Bool {
        !outputs.isEmpty && outputs.allSatisfy { files[$0.fileID] != nil }
    }

    mutating func toggle(_ outputs: [OutputImage]) {
        if containsAll(outputs) {
            remove(Set(outputs.map(\.fileID)))
        } else {
            for output in outputs { files[output.fileID] = output }
        }
    }

    mutating func remove(_ ids: Set<String>) {
        for id in ids { files.removeValue(forKey: id) }
    }
}

struct MediaArchive: Codable, Equatable {
    var outputs: [OutputImage] = []
    var removedOutputIDs: Set<String> = []
    var deletedTaskIDs: Set<String> = []
    var deletedPromptIDs: Set<String> = []
    var generationOrder: [String: Double] = [:]
    // Optional for archives written before task grouping was introduced.
    var taskMetadata: [String: MediaTaskMetadata]? = nil
    var provenance: [String: MediaProvenance]? = nil

    mutating func ingest(_ history: JSONValue) {
        for (id, entry) in history.object {
            let prompt = entry["prompt"].array
            let created = prompt.count > 3 ? prompt[3]["create_time"].double : 0
            generationOrder[id] = created > 0 ? created : (prompt.first?.double ?? 0)
            if var record = MediaProvenance.historyEntry(entry, id: id) {
                if let saved = provenance?[id], saved.prompt == record.prompt {
                    record.outputNodes = record.outputNodes ?? saved.outputNodes
                    record.displayedText = record.displayedText ?? saved.displayedText
                }
                if provenance == nil { provenance = [:] }
                provenance?[id] = record
            }
            if prompt.count > 3 {
                let meta = prompt[3]["pocket_task"]
                if !meta["id"].text.isEmpty {
                    if taskMetadata == nil { taskMetadata = [:] }
                    taskMetadata?[id] = MediaTaskMetadata(id: meta["id"].text, name: meta["name"].text,
                                                         createdAt: meta["created_at"].double)
                }
            }
        }
        let incoming = OutputImage.fromHistory(history).filter { !removedOutputIDs.contains($0.id) }
        let incomingIDs = Set(incoming.map(\.id))
        outputs = incoming + outputs.filter { !incomingIDs.contains($0.id) && !removedOutputIDs.contains($0.id) }
        let order = Dictionary(uniqueKeysWithValues: outputs.enumerated().map { ($0.element.id, $0.offset) })
        let generations = generationOrder
        outputs.sort {
            let a = generations[$0.promptID] ?? 0, b = generations[$1.promptID] ?? 0
            return a == b ? (order[$0.id] ?? 0) < (order[$1.id] ?? 0) : a > b
        }
    }
    mutating func remove(_ output: OutputImage) { remove([output]) }

    mutating func remove(_ items: [OutputImage]) {
        let files = Set(items.map(\.fileID))
        removedOutputIDs.formUnion(items.map(\.id))
        var historyIDs: [String] = []
        outputs.removeAll {
            guard files.contains($0.fileID) else { return false }
            historyIDs.append($0.id)
            return true
        }
        removedOutputIDs.formUnion(historyIDs)
    }
    var gallery: [OutputImage] {
        var seen = Set<String>()
        return outputs.filter { !removedOutputIDs.contains($0.id) && seen.insert($0.assetID).inserted }
    }
    mutating func rememberTasks(_ tasks: [GenerationTask]) {
        for task in tasks {
            for item in task.items {
                if taskMetadata == nil { taskMetadata = [:] }
                taskMetadata?[item.id] = MediaTaskMetadata(id: task.id, name: task.name, createdAt: task.createdAt)
                if !item.prompt.isEmpty {
                    if provenance == nil { provenance = [:] }
                    var record = provenance?[item.id] ?? MediaProvenance(prompt: item.prompt, workflowID: "", workflowName: "", taskID: "", createdAt: 0)
                    record.workflowID = task.workflowID
                    record.workflowName = task.name
                    record.taskID = task.id
                    record.createdAt = task.createdAt
                    provenance?[item.id] = record
                }
            }
        }
    }
    var galleryGroups: [MediaTaskGroup] {
        var groups: [MediaTaskGroup] = []
        var indices: [String: Int] = [:]
        var seen: [String: Set<String>] = [:]
        for output in outputs where !removedOutputIDs.contains(output.id) {
            let meta = taskMetadata?[output.promptID]
            let key = meta.map { "task:\($0.id)" } ?? "prompt:\(output.promptID)"
            // Cached output files can be reused by separate tasks. Deduplicate within each task only.
            guard seen[key, default: []].insert(output.assetID).inserted else { continue }
            if let index = indices[key] { groups[index].outputs.append(output) }
            else {
                indices[key] = groups.count
                let timestamp = generationOrder[output.promptID] ?? 0
                groups.append(MediaTaskGroup(id: key, taskID: meta?.id ?? output.promptID,
                    name: meta?.name.isEmpty == false ? meta!.name : "生成任务",
                    createdAt: meta?.createdAt ?? (timestamp > 100_000_000_000 ? timestamp / 1000 : timestamp), outputs: [output]))
            }
        }
        return groups
    }
    func visible(_ items: [OutputImage]) -> [OutputImage] {
        items.filter { !removedOutputIDs.contains($0.id) }
    }
    func record(for output: OutputImage, embedded: MediaProvenance?) -> MediaProvenance? {
        let direct = provenance?[output.promptID]
        let matching = outputs.lazy.filter { $0.assetID == output.assetID }.compactMap { provenance?[$0.promptID] }
        guard let embedded else { return direct ?? matching.first }
        // An output path can be reused. A file's embedded execution graph takes
        // precedence over history entries for another revision of the same path.
        if direct?.prompt == embedded.prompt { return direct }
        return matching.first { $0.prompt == embedded.prompt } ?? embedded
    }
    func visibleHistory(_ history: JSONValue) -> JSONValue {
        .object(history.object.filter { !deletedPromptIDs.contains($0.key) })
    }

    func canvasDisplayText(workflowID: String, tasks: [GenerationTask], live: CanvasDisplayRun) -> [String: String] {
        var displays: [String: String] = [:]
        for task in tasks where task.workflowID == workflowID && !deletedTaskIDs.contains(task.id) {
            for item in task.items.reversed() where !deletedPromptIDs.contains(item.id) {
                var texts = provenance?[item.id]?.displayedText ?? [:]
                if item.id == live.promptID { texts.merge(live.texts) { _, latest in latest } }
                for (nodeID, text) in texts where displays[nodeID] == nil
                    && item.prompt[nodeID]?["class_type"] == .string("GoohaiDisplayAny") {
                    displays[nodeID] = text
                }
            }
        }
        return displays
    }
}

struct CanvasDisplayRun {
    private(set) var promptID: String?
    private(set) var texts: [String: String] = [:]

    static func text(from output: JSONValue) -> String? {
        let payloads = output["gh_display"].array
        guard !payloads.isEmpty else { return nil }
        var texts: [String] = []
        var size = 0
        for payload in payloads {
            guard ["STRING", "TEXT"].contains(payload["type"].text.uppercased()),
                  case .string(let text) = payload["text"] else { return nil }
            size += text.utf8.count + 2
            guard size <= 256 * 1024 else { return nil }
            texts.append(text)
        }
        return texts.joined(separator: "\n\n")
    }

    mutating func receive(_ event: JSONValue) -> Bool {
        guard let promptID = event["prompt_id"].text.nonEmpty,
              let nodeID = event["node"].text.nonEmpty,
              let text = Self.text(from: event["output"]) else { return false }
        if self.promptID != promptID {
            self.promptID = promptID
            texts.removeAll()
        }
        guard texts[nodeID] != text, texts[nodeID] != nil || texts.count < 64 else { return false }
        texts[nodeID] = text
        return true
    }
}

struct MediaProvenance: Codable, Equatable {
    var prompt: [String: JSONValue]
    var workflowID: String
    var workflowName: String
    var taskID: String
    var createdAt: Double
    var outputNodes: [String: [String]]? = nil
    var requestedOutputs: [String]? = nil
    var displayedText: [String: String]? = nil
    var workflow: Workflow { Workflow(id: workflowID, name: workflowName, prompt: prompt) }

    static func historyEntry(_ entry: JSONValue, id: String) -> MediaProvenance? {
        let submission = entry["prompt"].array
        guard submission.count > 2, !submission[2].object.isEmpty else { return nil }
        let meta = submission.count > 3 ? submission[3]["pocket_task"] : .null
        let created = submission.count > 3 ? submission[3]["create_time"].double : 0
        var record = MediaProvenance(prompt: submission[2].object, workflowID: meta["workflow_id"].text,
            workflowName: meta["name"].text, taskID: meta["id"].text.nonEmpty ?? id,
            createdAt: meta["created_at"].double > 0 ? meta["created_at"].double : (created > 100_000_000_000 ? created / 1000 : created))
        if submission.count > 4, !submission[4].array.isEmpty { record.requestedOutputs = submission[4].array.map(\.text) }
        var producers: [String: [String]] = [:]
        var displayed: [String: String] = [:]
        for (nodeID, result) in entry["outputs"].object.sorted(by: { $0.key < $1.key }) {
            for file in OutputImage.fromNodeOutput(result, promptID: id) {
                producers[file.assetID, default: []].append(nodeID)
            }
            if record.prompt[nodeID]?["class_type"].text == "GoohaiDisplayAny",
               let text = CanvasDisplayRun.text(from: result) {
                displayed[nodeID] = text
            }
        }
        record.outputNodes = producers.isEmpty ? nil : producers
        record.displayedText = displayed.isEmpty ? nil : displayed
        return record
    }

    static func embeddedPrompt(_ value: JSONValue) -> MediaProvenance? {
        guard case .object(let prompt) = value, !prompt.isEmpty,
              prompt.values.allSatisfy({ node in
                  guard !node["class_type"].text.isEmpty, case .object = node["inputs"] else { return false }
                  return true
              }) else { return nil }
        return MediaProvenance(prompt: prompt, workflowID: "", workflowName: "", taskID: "", createdAt: 0)
    }
    /// ComfyUI's standard SaveImage writes the executed prompt into a PNG tEXt chunk.
    /// Read it only when task history is unavailable; never infer prompts from the current workflow.
    static func embeddedPNG(_ data: Data) -> MediaProvenance? {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        var offset = 8
        while offset <= data.count - 12 {
            let length = (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
            guard length <= data.count - offset - 12 else { return nil }
            if data[offset + 4..<offset + 8].elementsEqual([116, 69, 88, 116]), length <= 20 * 1024 * 1024 {
                let payload = data.subdata(in: offset + 8..<offset + 8 + length)
                if let separator = payload.firstIndex(of: 0), String(data: payload.prefix(upTo: separator), encoding: .utf8) == "prompt",
                   let value = try? JSONDecoder().decode(JSONValue.self, from: payload.suffix(from: separator + 1)),
                   let record = embeddedPrompt(value) {
                    return record
                }
            }
            offset += length + 12
        }
        return nil
    }
}

struct MediaTaskMetadata: Codable, Equatable {
    var id: String
    var name: String
    var createdAt: Double
}

struct MediaTaskGroup: Identifiable {
    var id: String
    var taskID: String
    var name: String
    var createdAt: Double
    var outputs: [OutputImage]
    var videoCount: Int { outputs.filter(\.isVideo).count }
    var summary: String {
        let images = outputs.count - videoCount
        return [images > 0 ? "\(images) 张图片" : nil, videoCount > 0 ? "\(videoCount) 个视频" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

enum WorkflowResults {
    // An unfinished or failed newest submission must never fall back to old images.
    static func latestPromptIDs(workflowID: String, tasks: [GenerationTask], legacyIDs: [String]) -> [String] {
        if let latest = tasks.filter({ $0.workflowID == workflowID }).max(by: { $0.createdAt < $1.createdAt }) {
            return latest.items.map(\.id)
        }
        return Array(legacyIDs.prefix(1))
    }
}
