import Foundation

struct MediaArchive: Codable, Equatable {
    var outputs: [OutputImage] = []
    var removedOutputIDs: Set<String> = []
    var deletedTaskIDs: Set<String> = []
    var deletedPromptIDs: Set<String> = []
    var generationOrder: [String: Double] = [:]

    mutating func ingest(_ history: JSONValue) {
        for (id, entry) in history.object {
            let prompt = entry["prompt"].array
            let created = prompt.count > 3 ? prompt[3]["create_time"].double : 0
            generationOrder[id] = created > 0 ? created : (prompt.first?.double ?? 0)
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
    func visible(_ items: [OutputImage]) -> [OutputImage] {
        items.filter { !removedOutputIDs.contains($0.id) }
    }
    func visibleHistory(_ history: JSONValue) -> JSONValue {
        .object(history.object.filter { !deletedPromptIDs.contains($0.key) })
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
