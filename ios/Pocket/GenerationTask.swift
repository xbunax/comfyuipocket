import Foundation

struct GenerationSubmission {
    var taskID: String? = nil
    var promptIDs: [String] = []
    var error: String? = nil
}

struct GenerationItem: Codable, Identifiable, Equatable {
    var id: String
    var prompt: [String: JSONValue]
    var cancelled = false
    var sequence: Int? = nil
}

struct GenerationTask: Codable, Identifiable, Equatable {
    var id: String
    var server: String
    var workflowID: String
    var name: String
    var createdAt: Double
    var requestedCount: Int
    var items: [GenerationItem] = []
    var submissionError: String? = nil
    var submitting = false

    var title: String { requestedCount > 1 ? "\(name) ×\(requestedCount)" : name }
    func summary(queue: JSONValue, history: JSONValue) -> GenerationSummary {
        let running = Set(queue["queue_running"].array.compactMap { $0.array.count > 1 ? $0.array[1].text : nil })
        let pending = Set(queue["queue_pending"].array.compactMap { $0.array.count > 1 ? $0.array[1].text : nil })
        var result = GenerationSummary()
        for item in items {
            if running.contains(item.id) { result.running += 1 }
            else if pending.contains(item.id) { result.pending += 1 }
            else if history[item.id]["status"]["status_str"].text == "success" { result.completed += 1 }
            else if history[item.id]["status"]["status_str"].text == "error" { result.failed += 1 }
            else if item.cancelled { result.cancelled += 1 }
            else { result.unavailable += 1 }
        }
        return result
    }
}

struct GenerationSummary {
    var running = 0
    var pending = 0
    var completed = 0
    var failed = 0
    var cancelled = 0
    var unavailable = 0
    var active: Bool { running > 0 || pending > 0 }
    var finished: Int { completed + failed + cancelled }
    var label: String {
        if running > 0 { return "正在生成" }
        if pending > 0 { return "等待执行" }
        if failed > 0 { return "包含失败" }
        if unavailable > 0 { return "记录暂不可用" }
        if cancelled > 0 { return completed > 0 ? "部分取消" : "已取消" }
        return "已完成"
    }
}

struct GenerationActivityState {
    let units: Int64
    let terminal: Bool
    let succeeded: Bool
    let subtitle: String

    init(task: GenerationTask, summary: GenerationSummary, activePrompt: String, progress: Double) {
        terminal = !task.submitting && !summary.active && summary.finished == task.items.count
        succeeded = terminal && summary.completed == task.requestedCount && task.submissionError == nil
        let sampling = !terminal && progress.isFinite && task.items.contains { $0.id == activePrompt }
        let nodePercent = sampling ? Int(min(0.99, max(0, progress)) * 100) : 0
        units = Int64(summary.finished * 100 + nodePercent)
        let count = "\(summary.completed)/\(task.requestedCount)"
        if terminal {
            subtitle = succeeded ? "已完成 \(count)" : "已结束 · 成功 \(count)"
        } else if task.submitting {
            subtitle = "已提交 \(task.items.count)/\(task.requestedCount)"
        } else if sampling {
            subtitle = "已完成 \(count) · 当前节点 \(nodePercent)%"
        } else {
            subtitle = "\(summary.label) · 已完成 \(count)"
        }
    }
}
