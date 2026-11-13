import SwiftUI

enum TaskRemovalTarget: Identifiable {
    case task(GenerationTask), prompt(String)
    var id: String {
        switch self { case .task(let task): return task.id; case .prompt(let id): return id }
    }
}

extension PocketStore {
    func deleteTask(_ target: TaskRemovalTarget) async -> Bool {
        guard let api = client else { error = "请先连接服务器。"; return false }
        let server = api.baseURL.absoluteString
        let task: GenerationTask
        switch target {
        case .task(let value): task = value
        case .prompt(let id):
            task = GenerationTask(id: "external:\(id)", server: server, workflowID: "", name: "任务", createdAt: 0,
                                  requestedCount: 1, items: [GenerationItem(id: id, prompt: [:])])
        }
        guard !task.submitting, task.server == server, !deletingTasks.contains(task.id) else { return false }
        deletingTasks.insert(task.id); defer { deletingTasks.remove(task.id) }
        let ids = Set(task.items.map(\.id))
        do {
            let freshQueue = try await api.json("queue")
            func running(_ queue: JSONValue) -> Bool {
                queue["queue_running"].array.contains { $0.array.count > 1 && ids.contains($0.array[1].text) }
            }
            guard !running(freshQueue) else { throw PocketError.message("任务正在生成，请先停止后再删除记录。") }
            if !ids.isEmpty {
                _ = try await api.json("queue", method: "POST", body: .object(["delete": .array(ids.sorted().map(JSONValue.string))]))
                let checkedQueue = try await api.json("queue")
                guard !running(checkedQueue) else { throw PocketError.message("任务已开始生成，请先停止后再删除记录。") }
            }
            let freshHistory = try await api.json("history", query: [.init(name: "max_items", value: "200")])
            try mergeMedia(freshHistory, server: server) // Keep generated works before deleting their task records.
            if !ids.isEmpty {
                _ = try await api.json("history", method: "POST", body: .object(["delete": .array(ids.sorted().map(JSONValue.string))]))
            }
            var archive = mediaArchives[server] ?? MediaArchive()
            archive.deletedTaskIDs.insert(task.id); archive.deletedPromptIDs.formUnion(ids)
            mediaArchives[server] = archive; try persistMediaArchives()
            generationTasks.removeAll { $0.server == server && $0.id == task.id }
            saveGenerationTasks()
            if client === api {
                history = archive.visibleHistory(history); forgetPromptIDs(ids)
                notice = "已删除任务记录，生成作品已保留。"
                await refresh()
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func removeOutput(_ output: OutputImage, deleteFile: Bool) async -> Bool {
        guard let api = client else { error = "请先选择服务器。"; return false }
        let server = api.baseURL.absoluteString
        guard !deletingOutputs.contains(output.id) else { return false }
        deletingOutputs.insert(output.id); defer { deletingOutputs.remove(output.id) }
        do {
            if deleteFile {
                guard pluginCapabilities.contains("media-delete") else {
                    throw PocketError.message("请更新电脑端 Pocket 插件至 v0.5.0 并重启 ComfyUI，才能删除服务器文件。")
                }
                _ = try await api.json("pocket/v1/media/delete", method: "POST", body: .object([
                    "filename": .string(output.filename), "subfolder": .string(output.subfolder), "type": .string(output.type)
                ]))
            }
            var archive = mediaArchives[server] ?? MediaArchive()
            archive.remove(output)
            mediaArchives[server] = archive; try persistMediaArchives()
            await MediaCache.shared.invalidate(resource: MediaCacheKey.resource(api.mediaURL(output)))
            if client === api { notice = deleteFile ? "已删除服务器文件并清理缓存。" : "已从本机作品中移除。" }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

private struct TaskDeletionDialog: ViewModifier {
    @Environment(PocketStore.self) private var store
    @Binding var target: TaskRemovalTarget?
    var onDeleted: () -> Void
    func body(content: Content) -> some View {
        content.confirmationDialog("删除任务记录？", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), presenting: target) { target in
            Button("删除记录并取消待执行项", role: .destructive) {
                Task { if await store.deleteTask(target) { onDeleted() } }
            }
        } message: { _ in Text("生成作品会保留。正在生成的任务需要先停止，再删除记录。") }
    }
}

private struct WorkDeletionDialog: ViewModifier {
    @Environment(PocketStore.self) private var store
    @Binding var output: OutputImage?
    var onDeleted: () -> Void
    func body(content: Content) -> some View {
        content.confirmationDialog("删除作品？", isPresented: Binding(get: { output != nil }, set: { if !$0 { output = nil } }), presenting: output) { output in
            Button("仅从本机作品移除", role: .destructive) {
                Task { if await store.removeOutput(output, deleteFile: false) { onDeleted() } }
            }
            if store.pluginCapabilities.contains("media-delete") {
                Button("永久删除服务器文件", role: .destructive) {
                    Task { if await store.removeOutput(output, deleteFile: true) { onDeleted() } }
                }
            }
        } message: { _ in
            Text(store.pluginCapabilities.contains("media-delete")
                 ? "仅移除会保留电脑文件；永久删除会清理电脑上的对应文件，无法恢复。"
                 : "当前可从本机作品中移除。删除电脑文件需更新 Pocket 插件至 v0.5.0 并重启 ComfyUI。")
        }
    }
}

extension View {
    func taskDeletionDialog(_ target: Binding<TaskRemovalTarget?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(TaskDeletionDialog(target: target, onDeleted: onDeleted))
    }
    func workDeletionDialog(_ output: Binding<OutputImage?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(WorkDeletionDialog(output: output, onDeleted: onDeleted))
    }
}
