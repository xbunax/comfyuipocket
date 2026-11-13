import Foundation

struct CanvasDocument: Codable {
    var prompt: [String: JSONValue]
    var workflow: JSONValue

    func applying(to original: Workflow) throws -> Workflow {
        guard case .object = workflow, case .array = workflow["nodes"],
              prompt.values.allSatisfy({ node in
                  guard case .string(let type) = node["class_type"], !type.isEmpty,
                        case .object = node["inputs"] else { return false }
                  return true
              }) else { throw PocketError.message("画布返回了无效的工作流，原有内容已保留。") }
        var result = original
        result.prompt = prompt
        // JavaScript cannot represent every 64-bit seed. Preserve unchanged integer
        // values when the frontend's numeric representation has not changed.
        for (id, node) in prompt {
            var next = node.object
            var inputs = node["inputs"].object
            for (key, value) in inputs {
                guard let previous = original.prompt[id]?["inputs"][key], previous.double == value.double else { continue }
                switch (previous, value) {
                case (.integer, .integer), (.integer, .number), (.unsigned, .integer), (.unsigned, .unsigned), (.unsigned, .number): inputs[key] = previous
                default: break
                }
            }
            next["inputs"] = .object(inputs); result.prompt[id] = .object(next)
        }
        result.canvas = workflow
        let valid = Set(result.fields.map(\.id))
        result.pinned.removeAll { !valid.contains($0) }
        return result
    }
}
