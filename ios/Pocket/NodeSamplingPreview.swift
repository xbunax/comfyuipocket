import Foundation

struct NodeSamplingFrame {
    let id = UUID()
    let nodeID: String
    let includesSchedule: Bool
    let payload: Data

    init?(_ data: JSONValue) {
        let nodeID = data["node_id"].text
        guard nodeID.utf8.count <= 128, !nodeID.isEmpty,
              nodeID.split(separator: ":", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
              }),
              let step = Int(data["step"].text), step >= 0,
              let total = Int(data["total"].text), total >= step else { return nil }
        let schedule = data["sigmas"].array
        let includesSchedule = schedule.count > 1
        guard schedule.count <= 4096 else { return nil }
        if case .string(let image) = data["image"] {
            let mime = data["mime"].text
            guard !image.isEmpty, image.utf8.count <= 8 * 1024 * 1024,
                  ["", "image/jpeg", "image/png", "image/webp", "video/mp4"].contains(mime) else { return nil }
        } else if !includesSchedule {
            return nil
        }
        guard let payload = try? JSONEncoder().encode(data), payload.count <= 9 * 1024 * 1024 else { return nil }
        self.nodeID = nodeID
        self.includesSchedule = includesSchedule
        self.payload = payload
    }

    var slot: String { nodeID + (includesSchedule ? "/schedule" : "/frame") }
}

/// Keep the current schedule plus the newest picture for each preview node.
/// Bursty senders cannot grow the native queue without bound.
struct NodeSamplingBuffer {
    private(set) var frames: [NodeSamplingFrame] = []

    mutating func append(_ frame: NodeSamplingFrame) {
        frames.removeAll { $0.slot == frame.slot || (frame.includesSchedule && $0.nodeID == frame.nodeID) }
        frames.append(frame)
        while frames.count > 16 || frames.reduce(0, { $0 + $1.payload.count }) > 20 * 1024 * 1024 {
            frames.removeFirst()
        }
    }
}

struct NodeSamplingRun {
    private(set) var promptID: String?
    private(set) var accepting = false
    private(set) var buffer = NodeSamplingBuffer()

    mutating func begin(_ id: String) {
        guard !id.isEmpty, promptID != id else { return }
        promptID = id
        accepting = true
        buffer = NodeSamplingBuffer()
    }

    mutating func end(_ id: String) {
        if id == promptID { accepting = false }
    }

    mutating func receive(_ data: JSONValue) -> NodeSamplingFrame? {
        guard accepting, let promptID,
              data["prompt_id"].text.isEmpty || data["prompt_id"].text == promptID,
              let frame = NodeSamplingFrame(data) else { return nil }
        buffer.append(frame)
        return frame
    }
}
