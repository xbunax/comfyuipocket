import Foundation

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
            if prompt.count > 2, !prompt[2].object.isEmpty {
                let meta = prompt.count > 3 ? prompt[3]["pocket_task"] : .null
                let record = MediaProvenance(prompt: prompt[2].object, workflowID: meta["workflow_id"].text,
                    workflowName: meta["name"].text, taskID: meta["id"].text.nonEmpty ?? id,
                    createdAt: meta["created_at"].double > 0 ? meta["created_at"].double : (created > 100_000_000_000 ? created / 1000 : created))
                if provenance == nil { provenance = [:] }; provenance?[id] = record
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
    mutating func remove(_ output: OutputImage) {
        removedOutputIDs.insert(output.id)
        for item in outputs where item.assetID == output.assetID { removedOutputIDs.insert(item.id) }
        outputs.removeAll { $0.assetID == output.assetID }
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
                    provenance?[item.id] = MediaProvenance(prompt: item.prompt, workflowID: task.workflowID,
                        workflowName: task.name, taskID: task.id, createdAt: task.createdAt)
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
    func visibleHistory(_ history: JSONValue) -> JSONValue {
        .object(history.object.filter { !deletedPromptIDs.contains($0.key) })
    }
}

struct MediaProvenance: Codable, Equatable {
    var prompt: [String: JSONValue]
    var workflowID: String
    var workflowName: String
    var taskID: String
    var createdAt: Double
    var workflow: Workflow { Workflow(id: workflowID, name: workflowName, prompt: prompt) }
    var promptFields: [WorkflowField] {
        workflow.fields.filter { MobileField.isPrompt($0) || $0.key == "local_prompts" }
    }
    var parameterFields: [WorkflowField] {
        workflow.fields.filter { !MobileField.isPrompt($0) && $0.key != "local_prompts" && !["timeline_data", "图片数据", "history_json", "timeline_ui"].contains($0.key) }
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
                   case .object(let prompt) = value, !prompt.isEmpty,
                   prompt.values.allSatisfy({ node in
                       guard !node["class_type"].text.isEmpty, case .object = node["inputs"] else { return false }
                       return true
                   }) {
                    return MediaProvenance(prompt: prompt, workflowID: "", workflowName: "", taskID: "", createdAt: 0)
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
