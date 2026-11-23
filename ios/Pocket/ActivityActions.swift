import SwiftUI

enum ArtworkDeletion: Equatable {
    case work, serverFile
}

struct ArtworkRemovalResult {
    var completed: Set<String> = []
    var unconfirmed: [String] = []
    var archiveWarning: String?
}

enum TaskRemovalTarget: Identifiable {
    case task(GenerationTask), prompt(String)
    var id: String {
        switch self { case .task(let task): return task.id; case .prompt(let id): return id }
    }
}

extension PocketStore {
    func deleteTask(_ target: TaskRemovalTarget) async -> Bool {
        guard let api = client else { error = "请先连接服务器。"; return false }
        let server = api.serverID
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
    func removeOutput(_ output: OutputImage, deleteFile: Bool) async throws -> Bool {
        guard let api = client else { throw PocketError.message("请先选择服务器。") }
        guard !deletingOutputs.contains(output.fileID) else { return false }
        let result = try await removeOutputs([output], from: api, deleteFiles: deleteFile)
        if let reason = result.unconfirmed.first { throw PocketError.message(reason) }
        if client === api {
            notice = result.archiveWarning ?? (deleteFile ? "已删除服务器文件。" : "已从本机作品中移除。")
        }
        return result.completed.contains(output.fileID)
    }

    func removeOutputs(_ outputs: [OutputImage], from api: ComfyClient, deleteFiles: Bool,
                       progress: (Int) -> Void = { _ in }) async throws -> ArtworkRemovalResult {
        guard client === api else { throw PocketError.message("服务器连接已改变，请重新选择文件。") }
        if deleteFiles {
            guard pluginCapabilities.contains("media-delete") else {
                throw PocketError.message("请更新电脑端 Pocket 插件并重启 ComfyUI。")
            }
            guard outputs.allSatisfy(\.canDeleteServerFile) else {
                throw PocketError.message("选中的文件包含不能从服务器删除的项目。")
            }
        }

        var seen = Set<String>()
        let unique = outputs.filter { seen.insert($0.fileID).inserted }
        let pending = Set(unique.map(\.fileID)).subtracting(deletingOutputs)
        deletingOutputs.formUnion(pending)
        defer { deletingOutputs.subtract(pending) }

        var result = ArtworkRemovalResult()
        var removed: [OutputImage] = []
        for (index, output) in unique.enumerated() {
            if client !== api || Task.isCancelled {
                result.unconfirmed.append("连接已改变或操作中断。")
                break
            }
            if !pending.contains(output.fileID) {
                result.unconfirmed.append("\(output.filename)：文件正在删除。")
            } else {
                do {
                    if deleteFiles {
                        let response = try await api.json("pocket/v1/media/delete", method: "POST", body: .object([
                            "filename": .string(output.filename), "subfolder": .string(output.portableSubfolder),
                            "type": .string(output.type)
                        ]))
                        guard response["deleted"] == .bool(true) else {
                            throw PocketError.message("服务器未确认删除。")
                        }
                    }
                    removed.append(output)
                } catch {
                    result.unconfirmed.append("\(output.filename)：\(error.localizedDescription)")
                }
            }
            progress(index + 1)
        }

        guard !removed.isEmpty else { return result }
        result.completed = Set(removed.map(\.fileID))
        let server = api.serverID
        let previous = mediaArchives[server]
        var archive = previous ?? MediaArchive()
        let aliases = archive.outputs.filter { result.completed.contains($0.fileID) }
        archive.remove(removed)
        mediaArchives[server] = archive
        do { try persistMediaArchives() }
        catch {
            if !deleteFiles {
                mediaArchives[server] = previous
                throw error
            }
            result.archiveWarning = "服务器文件已删除，本机作品记录保存失败。"
        }
        let resources = Set((removed + aliases).map { api.cacheResource(api.mediaURL($0)) })
        for resource in resources { await MediaCache.shared.invalidate(resource: resource) }
        if deleteFiles, client?.serverID == server, removed.contains(where: { $0.type == "output" }) {
            outputDirectoryRevision = UUID()
        }
        return result
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
    let mode: ArtworkDeletion
    var onDeleted: () -> Void
    @State private var failure: String?
    func body(content: Content) -> some View {
        content
            .confirmationDialog(mode == .serverFile ? "永久删除服务器文件？" : "删除作品？",
                isPresented: Binding(get: { output != nil }, set: { if !$0 { output = nil } }),
                titleVisibility: .visible, presenting: output) { output in
                    let server = store.client?.serverID
                    if mode == .work {
                        Button("仅从本机作品移除", role: .destructive) { remove(output, for: server, deleteFile: false) }
                    }
                    if store.pluginCapabilities.contains("media-delete"), output.canDeleteServerFile {
                        Button("永久删除服务器文件", role: .destructive) { remove(output, for: server, deleteFile: true) }
                    }
                    Button("取消", role: .cancel) { }
                } message: { output in
                    let path = [output.type, output.subfolder, output.filename].filter { !$0.isEmpty }.joined(separator: "/")
                    if mode == .serverFile {
                        Text("\(path)\n服务器上的文件会永久删除。")
                    } else if !output.canDeleteServerFile {
                        Text("\(path)\n此文件只能从本机作品列表中移除。")
                    } else {
                        Text(store.pluginCapabilities.contains("media-delete")
                             ? "\(path)\n从本机移除只清理作品列表。永久删除会移除电脑文件。"
                             : "当前可从本机作品中移除。删除电脑文件需更新 Pocket 插件。")
                    }
                }
            .onChange(of: store.client?.serverID) { _, _ in output = nil }
            .alert("文件操作失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("确定", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }
    private func remove(_ output: OutputImage, for server: String?, deleteFile: Bool) {
        Task {
            guard let server, server == store.client?.serverID else { return }
            do {
                if try await store.removeOutput(output, deleteFile: deleteFile) { onDeleted() }
            } catch { failure = error.localizedDescription }
        }
    }
}

extension View {
    func taskDeletionDialog(_ target: Binding<TaskRemovalTarget?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(TaskDeletionDialog(target: target, onDeleted: onDeleted))
    }
    func workDeletionDialog(_ output: Binding<OutputImage?>, mode: ArtworkDeletion = .work,
                            onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(WorkDeletionDialog(output: output, mode: mode, onDeleted: onDeleted))
    }
}
