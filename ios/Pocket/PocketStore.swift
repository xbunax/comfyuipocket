import SwiftUI

@MainActor @Observable
final class PocketStore {
    var profile: ServerProfile
    var workflows: [Workflow]
    var client: ComfyClient?
    var connected = false
    var connecting = false
    var socketConnected = false
    var error: String?
    var notice: String?
    var nodeInfo: JSONValue = .object([:])
    var queue: JSONValue = .object([:])
    var history: JSONValue = .object([:])
    var progress = 0.0
    var activeNode = ""
    var activePrompt = ""
    var preview: Data?
    var pluginAvailable = false
    var syncStatus = "等待连接"
    var syncing = false
    var busy = false
    var prompts: [SavedPrompt] = []
    var pinnedWorkflows: [String] = []
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var syncLoop: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var lastConnection = UUID()
    @ObservationIgnored private var syncRecords: [String: SyncRecord] = [:]
    @ObservationIgnored private var pendingDeletes: Set<String> = []
    @ObservationIgnored private var lastSyncError: String?
    @ObservationIgnored private var recentPrompts: [String: [String]] = [:]
    private static var libraryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("workflows.json")
    }
    private static var promptsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("prompts.json")
    }
    init() {
        profile = (UserDefaults.standard.data(forKey: "server").flatMap { try? JSONDecoder().decode(ServerProfile.self, from: $0) }) ?? ServerProfile()
        workflows = (try? JSONDecoder().decode([Workflow].self, from: Data(contentsOf: Self.libraryURL))) ?? []
        prompts = (try? JSONDecoder().decode([SavedPrompt].self, from: Data(contentsOf: Self.promptsURL))) ?? []
        pinnedWorkflows = UserDefaults.standard.stringArray(forKey: "pinnedWorkflows") ?? []
        recentPrompts = (UserDefaults.standard.data(forKey: "recentPrompts").flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) }) ?? [:]
        syncRecords = (UserDefaults.standard.data(forKey: "syncRecords").flatMap { try? JSONDecoder().decode([String: SyncRecord].self, from: $0) }) ?? [:]
        pendingDeletes = Set(UserDefaults.standard.stringArray(forKey: "pendingDeletes") ?? [])
        // Normalize legacy UUIDs and keep phone edits from versions before automatic sync.
        for index in workflows.indices {
            let id = workflows[index].id
            let canonical = id.count == 32 && id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
            if !canonical {
                let next = Workflow.newID()
                workflows[index].id = next
                syncRecords.removeValue(forKey: id)
                syncRecords[next] = SyncRecord(serverUpdatedAt: 0, dirty: true)
            } else if syncRecords[id] == nil {
                syncRecords[id] = SyncRecord(serverUpdatedAt: 0, dirty: true)
            }
        }
    }
    func save() {
        do {
            try JSONEncoder().encode(workflows).write(to: Self.libraryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            UserDefaults.standard.set(try JSONEncoder().encode(profile), forKey: "server")
        } catch { self.error = "本地保存失败：\(error.localizedDescription)" }
    }
    private func saveSyncState() {
        UserDefaults.standard.set(try? JSONEncoder().encode(syncRecords), forKey: "syncRecords")
        UserDefaults.standard.set(Array(pendingDeletes), forKey: "pendingDeletes")
    }
    private func savePrompts() {
        do {
            try JSONEncoder().encode(prompts).write(to: Self.promptsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = "提示词保存失败：\(error.localizedDescription)" }
    }
    private func savePinned() {
        UserDefaults.standard.set(pinnedWorkflows, forKey: "pinnedWorkflows")
    }
    private func saveRecentPrompts() {
        UserDefaults.standard.set(try? JSONEncoder().encode(recentPrompts), forKey: "recentPrompts")
    }
    func isPinned(_ id: String) -> Bool { pinnedWorkflows.contains(id) }
    func togglePinned(_ id: String) {
        if let index = pinnedWorkflows.firstIndex(of: id) { pinnedWorkflows.remove(at: index) }
        else { pinnedWorkflows.insert(id, at: 0) }
        savePinned()
    }
    private func forgetPinned(_ id: String) {
        guard pinnedWorkflows.contains(id) else { return }
        pinnedWorkflows.removeAll { $0 == id }
        savePinned()
    }
    @discardableResult
    func savePrompt(title: String, text: String, id: String? = nil) -> SavedPrompt? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleValue = cleanTitle.isEmpty ? defaultPromptTitle(value) : cleanTitle
        let now = Date().timeIntervalSince1970
        let saved: SavedPrompt
        if let id, let index = prompts.firstIndex(where: { $0.id == id }) {
            prompts[index].title = titleValue
            prompts[index].text = value
            prompts[index].updatedAt = now
            saved = prompts[index]
        } else {
            saved = SavedPrompt(id: UUID().uuidString, title: titleValue, text: value, updatedAt: now)
            prompts.append(saved)
        }
        prompts.sort { $0.updatedAt > $1.updatedAt }
        savePrompts()
        return saved
    }
    func deletePrompt(_ id: String) {
        prompts.removeAll { $0.id == id }
        savePrompts()
    }
    private func defaultPromptTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "未命名提示词"
        let value = line.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "未命名提示词" : String(value.prefix(30))
    }
    func connect() async {
        guard !connecting else { return }
        disconnect(); connecting = true
        let attempt = UUID(); lastConnection = attempt
        defer { if lastConnection == attempt { connecting = false } }
        do {
            let next = ComfyClient(baseURL: try profile.baseURL())
            _ = try await next.json("system_stats")
            guard lastConnection == attempt else { return }
            client = next; connected = true; save()
            startEvents(next)
            await refresh()
            do { nodeInfo = try await next.json("object_info") } catch { self.notice = "节点元信息暂不可用，仍可编辑已有参数。" }
            pluginAvailable = (try? await next.json("pocket/v1/info"))?["version"].text.nonEmpty != nil
            if pluginAvailable {
                await syncNow()
            } else {
                syncStatus = "未检测到 Pocket 插件"
                notice = "未检测到 Pocket 插件，工作流自动同步已停用。"
            }
        } catch { if lastConnection == attempt { self.error = error.localizedDescription } }
    }
    func disconnect() {
        lastConnection = UUID(); connecting = false
        events?.cancel(); events = nil; polling?.cancel(); polling = nil
        syncLoop?.cancel(); syncLoop = nil; pushTask?.cancel(); pushTask = nil
        client?.disconnect(); client = nil; connected = false; socketConnected = false
        queue = .object([:]); history = .object([:]); nodeInfo = .object([:])
        preview = nil; progress = 0; activeNode = ""; activePrompt = ""
        pluginAvailable = false; syncing = false; syncStatus = "等待连接"
    }
    private func startEvents(_ api: ComfyClient) {
        events?.cancel()
        events = Task { [weak self] in
            await api.listen(event: { [weak self] event in self?.handle(event) },
                             preview: { [weak self] data in self?.preview = data },
                             state: { [weak self] state in self?.socketConnected = state })
        }
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
        syncLoop?.cancel()
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.syncNow()
            }
        }
    }
    func resume() async {
        guard connected, let client else { return }
        startEvents(client); await refresh(); await syncNow()
    }
    func suspend() {
        events?.cancel(); polling?.cancel(); syncLoop?.cancel(); pushTask?.cancel()
        client?.disconnect(); socketConnected = false
    }
    private func handle(_ event: JSONValue) {
        let d = event["data"]
        switch event["type"].text {
        case "execution_start": activePrompt = d["prompt_id"].text; progress = 0; preview = nil
        case "progress": progress = d["max"].double > 0 ? min(1, d["value"].double / d["max"].double) : 0
        case "executing":
            activeNode = d["node"].text
            if d["node"] == .null { progress = 1; activePrompt = ""; Task { await refresh() } }
        case "execution_error":
            error = "节点 \(d["node_id"].text)：\(d["exception_message"].text)"; activePrompt = ""; Task { await refresh() }
        case "execution_interrupted": activePrompt = ""; progress = 0; Task { await refresh() }
        case "executed", "status": Task { await refresh() }
        default: break
        }
    }
    func refresh() async {
        guard let api = client else { return }
        do {
            let q = try await api.json("queue")
            let h = try await api.json("history", query: [.init(name: "max_items", value: "50")])
            guard client === api else { return }
            queue = q; history = h
        } catch { if client === api { notice = "刷新失败：\(error.localizedDescription)" } }
    }
    func submit(_ workflow: Workflow, count: Int = 1, randomizeSeeds: Bool = false) async {
        guard let api = client, !busy else { return }
        busy = true; defer { busy = false }
        let total = max(1, min(count, 20))
        var queued = 0
        do {
            for index in 0..<total {
                var submitted = workflow
                if randomizeSeeds && index > 0 { submitted.randomizeSeeds() }
                let reply = try await api.json("prompt", method: "POST", body: .object([
                    "prompt": .object(submitted.prompt), "client_id": .string(api.clientID)
                ]))
                let promptID = reply["prompt_id"].text
                guard !promptID.isEmpty else { throw PocketError.message("提交失败：\(reply)") }
                recordPrompt(promptID, workflowID: workflow.id)
                queued += 1
            }
            notice = queued > 1 ? "已加入队列 · \(workflow.name) ×\(queued)" : "已加入队列 · \(workflow.name)"
            save(); await refresh()
        } catch {
            self.error = error.localizedDescription
            if queued > 0 { notice = "已加入 \(queued) 个任务，后续提交失败。" }
        }
    }
    private func recordPrompt(_ promptID: String, workflowID: String) {
        var ids = recentPrompts[workflowID] ?? []
        ids.removeAll { $0 == promptID }
        ids.insert(promptID, at: 0)
        recentPrompts[workflowID] = Array(ids.prefix(12))
        saveRecentPrompts()
    }
    func deletePending(_ id: String) async {
        do { _ = try await client?.json("queue", method: "POST", body: .object(["delete": .array([.string(id)])])); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func interrupt() async {
        do { _ = try await client?.json("interrupt", method: "POST", body: .object([:])); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func touch(_ id: String) {
        var record = syncRecords[id] ?? SyncRecord()
        record.dirty = true
        syncRecords[id] = record
        saveSyncState()
        guard connected, pluginAvailable else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.pushNow()
        }
    }
    func delete(_ id: String) {
        let canonical = id.count == 32 && id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
        if canonical { pendingDeletes.insert(id) }
        syncRecords.removeValue(forKey: id)
        workflows.removeAll { $0.id == id }
        forgetPinned(id)
        save(); saveSyncState()
        guard canonical, connected, pluginAvailable else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in await self?.pushNow() }
    }
    func duplicate(_ workflow: Workflow) {
        var copy = workflow
        copy.id = Workflow.newID()
        copy.name += " 副本"
        workflows.append(copy)
        syncRecords[copy.id] = SyncRecord(dirty: true)
        save(); saveSyncState(); touch(copy.id)
    }
    func syncNow() async {
        guard let api = client, connected, pluginAvailable, !syncing else { return }
        syncing = true; defer { syncing = false }
        syncStatus = "正在自动同步"
        do { try await flushPendingDeletes(api) } catch { recordSyncError(error) }
        do { try await pushDirty(api) } catch { recordSyncError(error) }
        guard client === api else { return }
        do {
            let list = try await api.json("pocket/v1/workflows")
            guard client === api else { return }
            var serverIDs = Set<String>()
            var changed = false
            for item in list["workflows"].array {
                let id = item["id"].text
                guard id.count == 32, !pendingDeletes.contains(id) else { continue }
                serverIDs.insert(id)
                let remoteUpdated = item["updatedAt"].double
                if let record = syncRecords[id], record.dirty {
                    continue
                }
                if let known = syncRecords[id]?.serverUpdatedAt, remoteUpdated > 0, known == remoteUpdated,
                   workflows.contains(where: { $0.id == id }) {
                    continue
                }
                let full = try await api.json("pocket/v1/workflows/\(id)")
                guard client === api else { return }
                let remote = try Workflow.load(JSONEncoder().encode(full), name: item["name"].text)
                if let index = workflows.firstIndex(where: { $0.id == id }) {
                    workflows[index].name = remote.name
                    workflows[index].prompt = remote.prompt
                } else {
                    workflows.append(remote)
                }
                syncRecords[id] = SyncRecord(serverUpdatedAt: full["updatedAt"].double, dirty: false)
                changed = true
            }
            for id in WorkflowSync.idsToRemove(records: syncRecords, serverIDs: serverIDs, pendingDeletes: pendingDeletes) {
                workflows.removeAll { $0.id == id }
                syncRecords.removeValue(forKey: id)
                changed = true
            }
            let validIDs = Set(workflows.map(\.id))
            let pinnedBefore = pinnedWorkflows.count
            pinnedWorkflows.removeAll { !validIDs.contains($0) }
            if pinnedWorkflows.count != pinnedBefore { savePinned() }
            if changed { save() }
            saveSyncState()
            lastSyncError = nil
            syncStatus = "已自动同步"
        } catch { recordSyncError(error) }
    }
    private func pushNow() async {
        guard let api = client, connected, pluginAvailable, !syncing else { return }
        syncing = true; defer { syncing = false }
        do {
            try await flushPendingDeletes(api)
            guard client === api else { return }
            try await pushDirty(api)
            guard client === api else { return }
            saveSyncState()
            lastSyncError = nil
            syncStatus = "已自动同步"
        } catch { recordSyncError(error) }
    }
    private func flushPendingDeletes(_ api: ComfyClient) async throws {
        for id in pendingDeletes {
            try await api.remove("pocket/v1/workflows/\(id)")
            guard client === api else { return }
            pendingDeletes.remove(id)
        }
    }
    private func pushDirty(_ api: ComfyClient) async throws {
        let dirtyIDs = workflows.filter { syncRecords[$0.id]?.dirty == true }.map(\.id)
        for id in dirtyIDs {
            guard client === api, let index = workflows.firstIndex(where: { $0.id == id }) else { continue }
            var targetID = id
            if id.count != 32 || id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) == nil {
                targetID = Workflow.newID()
                workflows[index].id = targetID
                syncRecords.removeValue(forKey: id)
            }
            let workflow = workflows[index]
            let reply = try await api.json("pocket/v1/workflows", method: "POST", body: .object([
                "id": .string(targetID), "name": .string(workflow.name), "prompt": .object(workflow.prompt)
            ]))
            guard client === api else { return }
            syncRecords[targetID] = SyncRecord(serverUpdatedAt: reply["updatedAt"].double, dirty: false)
        }
    }
    private func recordSyncError(_ error: Error) {
        syncStatus = "同步暂不可用"
        let message = error.localizedDescription
        guard lastSyncError != message else { return }
        lastSyncError = message
        notice = "自动同步失败：\(message)"
    }
    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 20_000_000 else { throw PocketError.message("工作流文件不能超过 20 MB。") }
            var workflow = try Workflow.load(data, name: url.deletingPathExtension().lastPathComponent)
            if workflows.contains(where: { $0.id == workflow.id }) { workflow.id = Workflow.newID() }
            workflows.append(workflow); save(); touch(workflow.id)
        } catch { self.error = error.localizedDescription }
    }
    func recentPromptIDs(for workflowID: String) -> [String] {
        recentPrompts[workflowID] ?? []
    }
    func isActivePrompt(for workflowID: String) -> Bool {
        guard !activePrompt.isEmpty else { return false }
        return (recentPrompts[workflowID] ?? []).contains(activePrompt)
    }
    func hasQueuedPrompt(for workflowID: String) -> Bool {
        let ids = Set(recentPrompts[workflowID] ?? [])
        guard !ids.isEmpty else { return false }
        return (queue["queue_running"].array + queue["queue_pending"].array).contains { item in
            item.array.count > 1 && ids.contains(item.array[1].text)
        }
    }
    func images(forWorkflow workflowID: String) -> [OutputImage] {
        var result: [OutputImage] = []
        var seen = Set<String>()
        for promptID in recentPrompts[workflowID] ?? [] {
            for item in OutputImage.fromHistoryEntry(history[promptID], promptID: promptID) where seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        return result
    }
    func queueItem(promptID: String) -> JSONValue? {
        (queue["queue_running"].array + queue["queue_pending"].array).first { item in
            item.array.count > 1 && item.array[1].text == promptID
        }
    }
    func isRunning(_ promptID: String) -> Bool {
        queue["queue_running"].array.contains { $0.array.count > 1 && $0.array[1].text == promptID }
    }
    func isPending(_ promptID: String) -> Bool {
        queue["queue_pending"].array.contains { $0.array.count > 1 && $0.array[1].text == promptID }
    }
    var runningPromptID: String? {
        queue["queue_running"].array.first.flatMap { item in
            item.array.count > 1 ? item.array[1].text.nonEmpty : nil
        }
    }
    var sortedHistoryIDs: [String] {
        history.object.sorted { a, b in
            (a.value["prompt"].array.first?.double ?? 0) > (b.value["prompt"].array.first?.double ?? 0)
        }.map { $0.key }
    }
    var images: [OutputImage] {
        OutputImage.fromHistory(history)
    }
}
