import SwiftUI

@MainActor @Observable
final class PocketStore {
    var profile: ServerProfile
    var workflows: [Workflow]
    var client: ComfyClient?
    var irohTransport: IrohTransport?
    var incomingPairingCode: String?
    var connected = false
    var restoringConnection = false
    var connectionRecoveryError: String?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private let generationActivities = GenerationActivities()
    private var canMonitorServer: Bool { !suspended || generationActivities.hasBackgroundExecution }
    @ObservationIgnored private var recovery: Task<Void, Never>?
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
    var canvasEditingID: String?
    @ObservationIgnored var canvasEditingSession: CanvasSession?
    @ObservationIgnored let canvasSessions = CanvasSessionCache()
    var prompts: [SavedPrompt] = []
    var pinnedWorkflows: [String] = []
    private var lastWorkflows = UserDefaults.standard.dictionary(forKey: "library.lastWorkflow") as? [String: String] ?? [:]
    var lastOpenedWorkflow: Workflow? {
        let last = lastWorkflows[client?.serverID ?? "local"]
        return workflows.first { $0.id == last }
    }
    func rememberOpened(_ id: String) {
        let server = client?.serverID ?? "local"
        guard lastWorkflows[server] != id else { return }
        lastWorkflows[server] = id
        UserDefaults.standard.set(lastWorkflows, forKey: "library.lastWorkflow")
    }
    func lastOutput(for workflowID: String) -> OutputImage? {
        let archive = currentMediaArchive
        return archive.outputs.first { archive.provenance?[$0.promptID]?.workflowID == workflowID }
            ?? images(forWorkflow: workflowID).first
    }
    var nodeBookmarks = NodeBookmarkLibrary()
    var generationTasks: [GenerationTask] = []
    var mediaArchives: [String: MediaArchive] = [:]
    var pluginCapabilities: Set<String> = []
    var deletingTasks: Set<String> = []
    var deletingOutputs: Set<String> = []
    var outputDirectoryRevision = UUID()
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
    private static var tasksURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("generation-tasks.json")
    }
    private static var mediaArchiveURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("media-archive.json")
    }
    init() {
        profile = (UserDefaults.standard.data(forKey: "server").flatMap { try? JSONDecoder().decode(ServerProfile.self, from: $0) }) ?? ServerProfile()
        workflows = (try? JSONDecoder().decode([Workflow].self, from: Data(contentsOf: Self.libraryURL))) ?? []
        prompts = (try? JSONDecoder().decode([SavedPrompt].self, from: Data(contentsOf: Self.promptsURL))) ?? []
        pinnedWorkflows = UserDefaults.standard.stringArray(forKey: "pinnedWorkflows") ?? []
        nodeBookmarks = UserDefaults.standard.data(forKey: "nodeBookmarks.v1")
            .flatMap { try? JSONDecoder().decode(NodeBookmarkLibrary.self, from: $0) } ?? NodeBookmarkLibrary()
        generationTasks = (try? JSONDecoder().decode([GenerationTask].self, from: Data(contentsOf: Self.tasksURL))) ?? []
        mediaArchives = (try? JSONDecoder().decode([String: MediaArchive].self, from: Data(contentsOf: Self.mediaArchiveURL))) ?? [:]
        for index in generationTasks.indices { generationTasks[index].submitting = false }
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
            // Fetch saved canvas data once when upgrading older phone libraries.
            if workflows[index].canvas == nil { syncRecords[workflows[index].id]?.serverUpdatedAt = 0 }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["POCKET_UI_FIXTURES"] == "1" { loadUITestFixtures() }
        #endif
    }
    #if DEBUG
    private func loadUITestFixtures() {
        let id = String(repeating: "a", count: 32)
        let prompt: [String: JSONValue] = [
            "1": .object(["class_type": .string("CLIPTextEncode"), "inputs": .object(["text": .string("portrait, (soft light:1.20), <lora:example:0.8>")])]),
            "2": .object(["class_type": .string("LoadImage"), "inputs": .object(["image": .string("")])])
        ]
        let canvas = try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"nodes":[{"id":1,"type":"CLIPTextEncode","pos":[-120,80],"size":[300,180],"inputs":[],"outputs":[{"name":"CONDITIONING"}],"widgets_values":["portrait"]},{"id":2,"type":"LoadImage","pos":[260,160],"size":[280,200],"inputs":[{"name":"image"}],"widgets_values":[]}],"links":[[1,1,0,2,0,"IMAGE"]],"groups":[]}"#.utf8))
        workflows = [Workflow(id: id, name: "UI Canvas Workflow", prompt: prompt, canvas: canvas)]
        nodeInfo = .object(["LoadImage": .object(["input": .object(["required": .object([
            "image": .array([.array([.string("sample.png")]), .object(["image_upload": .bool(true)])])
        ])])])])
        client = ComfyClient(baseURL: URL(string: "http://127.0.0.1:8188")!)
        generationTasks = [GenerationTask(id: "ui-batch", server: client!.serverID, workflowID: id,
            name: "UI Canvas Workflow", createdAt: 1, requestedCount: 2,
            items: [GenerationItem(id: "ui-done", prompt: prompt), GenerationItem(id: "ui-pending", prompt: prompt)])]
        history = .object(["ui-done": .object(["status": .object(["status_str": .string("success")])])])
        queue = .object(["queue_pending": .array([.array([.integer(2), .string("ui-pending"), .object(prompt)])])])
    }
    #endif
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
    func saveRecentPrompts() {
        UserDefaults.standard.set(try? JSONEncoder().encode(recentPrompts), forKey: "recentPrompts")
    }
    func saveGenerationTasks() {
        do {
            try JSONEncoder().encode(generationTasks).write(to: Self.tasksURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = "任务记录保存失败：\(error.localizedDescription)" }
    }
    func persistMediaArchives() throws {
        try JSONEncoder().encode(mediaArchives).write(to: Self.mediaArchiveURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func mergeMedia(_ history: JSONValue, server: String) throws {
        var archive = mediaArchives[server] ?? MediaArchive()
        archive.ingest(history)
        archive.rememberTasks(generationTasks.filter { $0.server == server })
        if archive != mediaArchives[server] {
            mediaArchives[server] = archive
            try persistMediaArchives()
        }
    }
    var currentMediaArchive: MediaArchive {
        guard let server = client?.serverID else { return MediaArchive() }
        return mediaArchives[server] ?? MediaArchive()
    }
    var currentGenerationTasks: [GenerationTask] {
        guard let server = client?.serverID else { return [] }
        let hidden = mediaArchives[server]?.deletedTaskIDs ?? []
        return generationTasks.filter { $0.server == server && !hidden.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }
    func isPinned(_ id: String) -> Bool { pinnedWorkflows.contains(id) }
    func toggleNodeBookmark(_ location: CanvasNodeLocation, key: CanvasCacheKey) {
        nodeBookmarks.toggle(server: key.server, workflowID: key.workflowID, location: location)
        persistNodeBookmarks()
    }
    func removeNodeBookmark(_ bookmark: NodeBookmark) {
        nodeBookmarks.remove(bookmark.id); persistNodeBookmarks()
    }
    private func persistNodeBookmarks() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(nodeBookmarks), forKey: "nodeBookmarks.v1") }
        catch { self.error = "节点收藏保存失败：\(error.localizedDescription)" }
    }
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
        let line = text.split(whereSeparator: { $0.isNewline }).first.map { String($0) } ?? "未命名提示词"
        let value = line.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "未命名提示词" : String(value.prefix(30))
    }
    func connect(pairingCode: String? = nil) async {
        guard !connecting else { return }
        disconnect(); connecting = true
        let attempt = UUID(); lastConnection = attempt
        defer { if lastConnection == attempt { connecting = false } }
        do {
            let next: ComfyClient
            if profile.connectionMethod == "iroh" {
                let invite: PairingInvitation?
                if let code = pairingCode?.nonEmpty { invite = try PairingInvitation.parse(code) }
                else { invite = nil }
                guard let peer = invite?.peer ?? profile.irohPeer else {
                    throw PocketError.message("请先扫描或粘贴电脑上生成的配对码。")
                }
                let transport = IrohTransport(peer: peer, token: invite?.token)
                irohTransport = transport
                try await transport.start()
                guard lastConnection == attempt else { transport.stop(); return }
                profile.irohPeer = transport.peer; save()
                transport.onReconnect = { [weak self] peer in
                    guard let self, self.lastConnection == attempt, self.profile.irohPeer != peer else { return }
                    self.profile.irohPeer = peer
                    self.save()
                }
                guard let url = transport.baseURL, let access = transport.access else {
                    throw PocketError.message("本地直连通道未就绪。")
                }
                next = ComfyClient(baseURL: url, serverID: peer.serverID, loopbackAccess: access,
                                   displayAddress: "P2P · \(peer.name)")
            } else {
                next = ComfyClient(baseURL: try profile.baseURL())
            }
            _ = try await next.json("system_stats")
            guard lastConnection == attempt else { return }
            client = next; connected = true; save()
            if suspended { irohTransport?.suspendMonitoring() }
            startEvents(next)
            await refresh()
            guard client === next, !restoringConnection else { return }
            do {
                let definitions = try await next.json("object_info")
                if client === next { nodeInfo = definitions }
            } catch {
                if client === next, !restoringConnection { notice = "节点元信息暂不可用，仍可编辑已有参数。" }
            }
            await refreshPluginInfo(next, initial: true)
            guard client === next, !restoringConnection else { return }
            if pluginAvailable {
                await syncNow()
            } else {
                syncStatus = "未检测到 Pocket 插件"
                notice = "未检测到 Pocket 插件，工作流自动同步已停用。"
            }
        } catch {
            if lastConnection == attempt {
                irohTransport?.stop(status: "本次连接未完成")
                self.error = error.localizedDescription
            }
        }
    }
    private func refreshPluginInfo(_ api: ComfyClient, initial: Bool = false) async {
        let info = try? await api.json("pocket/v1/info")
        guard client === api, !restoringConnection, info != nil || initial else { return }
        pluginAvailable = info?["version"].text.nonEmpty != nil
        pluginCapabilities = Set(info?["capabilities"].array.map(\.text) ?? [])
    }
    func disconnect() {
        lastConnection = UUID(); connecting = false
        recovery?.cancel(); recovery = nil; restoringConnection = false
        connectionRecoveryError = nil
        events?.cancel(); events = nil; polling?.cancel(); polling = nil
        syncLoop?.cancel(); syncLoop = nil; pushTask?.cancel(); pushTask = nil
        client?.disconnect(); client = nil; connected = false; socketConnected = false
        generationActivities.stop()
        irohTransport?.stop(); irohTransport = nil
        queue = .object([:]); history = .object([:]); nodeInfo = .object([:])
        preview = nil; progress = 0; activeNode = ""; activePrompt = ""
        pluginAvailable = false; syncing = false; syncStatus = "等待连接"
        pluginCapabilities = []
    }
    private func startEvents(_ api: ComfyClient) {
        guard canMonitorServer, client === api else { return }
        events?.cancel()
        events = Task { [weak self] in
            await api.listen(event: { [weak self] event in self?.handle(event) },
                             preview: { [weak self] data in if let self, !self.suspended { self.preview = data } },
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
        guard !suspended else { return }
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.syncNow()
            }
        }
    }
    func resume() async {
        guard suspended else { return }
        suspended = false
        guard connected, let client else { return }
        if let transport = irohTransport {
            restoreP2P(client, transport: transport)
            return
        }
        startEvents(client); await refresh(); await syncNow()
    }
    func suspend() {
        suspended = true
        syncLoop?.cancel(); pushTask?.cancel()
        updateBackgroundExecution()
    }
    private func updateBackgroundExecution() {
        guard suspended, let api = client else { return }
        if generationActivities.hasBackgroundExecution {
            guard events == nil || events?.isCancelled == true else { return }
            if let transport = irohTransport { restoreP2P(api, transport: transport) }
            else { startEvents(api); Task { await refresh() } }
            return
        }
        recovery?.cancel(); recovery = nil; restoringConnection = false
        irohTransport?.suspendMonitoring()
        events?.cancel(); polling?.cancel()
        client?.disconnect(); socketConnected = false
    }
    func retryServerConnection() {
        guard let api = client, let transport = irohTransport else { return }
        restoreP2P(api, transport: transport, force: true)
    }
    private func restoreP2P(_ api: ComfyClient, transport: IrohTransport, force: Bool = false) {
        guard canMonitorServer, recovery == nil, client === api else { return }
        restoringConnection = true
        connectionRecoveryError = nil
        notice = nil
        if pluginAvailable { syncStatus = "直连恢复后自动同步" }
        events?.cancel(); polling?.cancel(); syncLoop?.cancel(); pushTask?.cancel()
        socketConnected = false
        transport.suspendMonitoring()
        recovery = Task { [weak self] in
            for attempt in 0..<3 {
                guard let self, !Task.isCancelled, self.client === api, self.canMonitorServer else { return }
                var verifying = false
                do {
                    try await transport.prepareToResume(reopenLocalChannel: attempt == 1 || (force && attempt == 0),
                                                        reconnectPeer: attempt == 2)
                    try Task.checkCancellation()
                    guard let url = transport.baseURL, let access = transport.access else {
                        throw PocketError.message("本地通道未就绪。")
                    }
                    let next: ComfyClient
                    if url == api.baseURL && access.token == api.loopbackAccess?.token {
                        api.renewSession()
                        next = api
                    } else {
                        next = ComfyClient(baseURL: url, serverID: api.serverID, loopbackAccess: access,
                                           displayAddress: api.displayAddress, clientID: api.clientID)
                    }
                    transport.verifyServerAccess()
                    verifying = true
                    try await next.probeServer()
                    try Task.checkCancellation()
                    guard self.client === api, self.canMonitorServer else { return }
                    self.client = next
                    self.recovery = nil
                    self.restoringConnection = false
                    transport.didRestoreServerAccess()
                    self.startEvents(next)
                    await self.refresh()
                    await self.refreshPluginInfo(next)
                    await self.syncNow()
                    return
                } catch {
                    guard !Task.isCancelled, self.client === api, self.canMonitorServer else { return }
                    transport.recordRecoveryFailure(error, verifying: verifying, retrying: attempt < 2)
                    if attempt == 2 {
                        self.recovery = nil
                        self.restoringConnection = false
                        self.connectionRecoveryError = error.localizedDescription
                        self.syncStatus = "等待重新连接"
                        return
                    }
                    do { try await Task.sleep(for: .seconds(attempt + 1)) } catch { return }
                }
            }
        }
    }
    private func handle(_ event: JSONValue) {
        let d = event["data"]
        switch event["type"].text {
        case "execution_start":
            activePrompt = d["prompt_id"].text; progress = 0; preview = nil
            updateGenerationActivities()
        case "progress":
            if let prompt = d["prompt_id"].text.nonEmpty { activePrompt = prompt }
            progress = d["max"].double > 0 ? min(1, d["value"].double / d["max"].double) : 0
            updateGenerationActivities()
        case "executing":
            activeNode = d["node"].text
            if d["node"] == .null { progress = 1; activePrompt = ""; Task { await refresh() } }
        case "execution_error":
            error = "节点 \(d["node_id"].text)：\(d["exception_message"].text)"; activePrompt = ""; Task { await refresh() }
        case "execution_interrupted": activePrompt = ""; progress = 0; Task { await refresh() }
        case "executed", "execution_success", "status": Task { await refresh() }
        default: break
        }
    }
    func refresh() async {
        guard canMonitorServer, !restoringConnection, connectionRecoveryError == nil, let api = client else { return }
        do {
            let q = try await api.json("queue")
            let h = try await api.json("history", query: [.init(name: "max_items", value: "200")])
            guard canMonitorServer, !restoringConnection, !Task.isCancelled, client === api else { return }
            if let transport = irohTransport, profile.irohPeer != transport.peer { profile.irohPeer = transport.peer; save() }
            try mergeMedia(h, server: api.serverID)
            queue = q; history = currentMediaArchive.visibleHistory(h)
            restoreGenerationTasks(server: api.serverID)
            updateGenerationActivities()
        } catch {
            guard canMonitorServer, !restoringConnection, !Task.isCancelled, client === api else { return }
            if let transport = irohTransport, let code = (error as? URLError)?.code,
               [.cannotConnectToHost, .networkConnectionLost, .timedOut].contains(code) {
                restoreP2P(api, transport: transport)
            } else {
                notice = "刷新失败：\(error.localizedDescription)"
            }
        }
    }
    private func updateGenerationActivities() {
        generationActivities.update(tasks: currentGenerationTasks, queue: queue, history: history,
                                    activePrompt: activePrompt, progress: progress)
    }
    func submit(_ workflow: Workflow, count: Int = 1, randomizeSeeds: Bool = false) async {
        let result = await enqueue(workflow, count: count, randomizeSeeds: randomizeSeeds)
        if let message = result.error { error = message }
    }
    func enqueue(_ workflow: Workflow, count: Int = 1, randomizeSeeds: Bool = false) async -> GenerationSubmission {
        guard let api = client, connected else { return GenerationSubmission(error: "服务器尚未连接。") }
        guard !busy else { return GenerationSubmission(error: "其他任务正在提交，请稍后重试。") }
        guard !workflow.prompt.isEmpty else { return GenerationSubmission(error: "画布中还没有可执行节点，请先添加并连接节点。") }
        busy = true; defer { busy = false }
        let total = max(1, min(count, 20))
        let taskID = UUID().uuidString
        generationTasks.insert(GenerationTask(id: taskID, server: api.serverID, workflowID: workflow.id,
                                              name: workflow.name, createdAt: Date().timeIntervalSince1970,
                                              requestedCount: total, submitting: true), at: 0)
        generationActivities.backgroundExecutionChanged = { [weak self] in self?.updateBackgroundExecution() }
        generationActivities.start(generationTasks[0])
        saveGenerationTasks()
        var queued = 0
        var result = GenerationSubmission(taskID: taskID)
        defer {
            if let index = generationTasks.firstIndex(where: { $0.id == taskID }) { generationTasks[index].submitting = false }
            saveGenerationTasks()
            updateGenerationActivities()
        }
        do {
            for index in 0..<total {
                guard client === api else { throw PocketError.message("服务器连接已改变，后续生成未提交。") }
                var submitted = workflow
                if randomizeSeeds && index > 0 { submitted.randomizeSeeds() }
                let reply = try await api.json("prompt", method: "POST", body: .object([
                    "prompt": .object(submitted.prompt), "client_id": .string(api.clientID),
                    "extra_data": .object(["pocket_task": .object([
                        "id": .string(taskID), "name": .string(workflow.name), "workflow_id": .string(workflow.id),
                        "count": .integer(Int64(total)), "index": .integer(Int64(index)),
                        "created_at": .number(generationTasks.first(where: { $0.id == taskID })?.createdAt ?? 0)
                    ])])
                ]))
                let promptID = reply["prompt_id"].text
                guard !promptID.isEmpty else { throw PocketError.message("提交失败：\(reply)") }
                recordPrompt(promptID, workflowID: workflow.id)
                result.promptIDs.append(promptID)
                if let taskIndex = generationTasks.firstIndex(where: { $0.id == taskID }) {
                    generationTasks[taskIndex].items.append(GenerationItem(id: promptID, prompt: submitted.prompt, sequence: index))
                }
                saveGenerationTasks()
                queued += 1
                updateGenerationActivities()
            }
            notice = "已加入 1 个任务 · \(workflow.name)\(queued > 1 ? "（\(queued) 次生成）" : "")"
            save(); await refresh()
        } catch {
            result.error = error.localizedDescription
            if let index = generationTasks.firstIndex(where: { $0.id == taskID }) {
                generationTasks[index].submissionError = error.localizedDescription
            }
            if queued > 0 { notice = "批次已提交 \(queued)/\(total) 次生成，后续提交失败。" }
            await refresh()
        }
        return result
    }
    private func recordPrompt(_ promptID: String, workflowID: String) {
        var ids = recentPrompts[workflowID] ?? []
        ids.removeAll { $0 == promptID }
        ids.insert(promptID, at: 0)
        recentPrompts[workflowID] = Array(ids.prefix(200))
        saveRecentPrompts()
    }
    func deletePending(_ id: String) async {
        do {
            guard let api = client else { return }
            _ = try await api.json("queue", method: "POST", body: .object(["delete": .array([.string(id)])]))
            for index in generationTasks.indices where generationTasks[index].server == api.serverID {
                if let child = generationTasks[index].items.firstIndex(where: { $0.id == id }) { generationTasks[index].items[child].cancelled = true }
            }
            saveGenerationTasks(); await refresh()
        }
        catch { self.error = error.localizedDescription }
    }
    func interrupt() async {
        do { _ = try await client?.json("interrupt", method: "POST", body: .object([:])); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func cancelPending(in task: GenerationTask) async {
        guard let api = client, !task.submitting, task.server == api.serverID else { return }
        let ids = task.items.map(\.id).filter { isPending($0) }
        guard !ids.isEmpty else { return }
        do {
            _ = try await api.json("queue", method: "POST", body: .object(["delete": .array(ids.map(JSONValue.string))]))
            if let index = generationTasks.firstIndex(where: { $0.id == task.id && $0.server == task.server }) {
                for child in generationTasks[index].items.indices where ids.contains(generationTasks[index].items[child].id) {
                    generationTasks[index].items[child].cancelled = true
                }
            }
            saveGenerationTasks(); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func restoreGenerationTasks(server: String) {
        let rows = queue["queue_running"].array + queue["queue_pending"].array + history.object.values.map { $0["prompt"] }
        var changed = false
        for row in rows where row.array.count > 3 {
            let meta = row.array[3]["pocket_task"]
            let id = meta["id"].text
            let promptID = row.array[1].text
            guard !id.isEmpty, !promptID.isEmpty else { continue }
            let archive = mediaArchives[server] ?? MediaArchive()
            guard !archive.deletedTaskIDs.contains(id), !archive.deletedPromptIDs.contains(promptID) else { continue }
            var index = generationTasks.firstIndex { $0.id == id && $0.server == server }
            if index == nil {
                generationTasks.append(GenerationTask(id: id, server: server, workflowID: meta["workflow_id"].text,
                    name: meta["name"].text.nonEmpty ?? "工作流", createdAt: meta["created_at"].double,
                    requestedCount: max(1, Int(meta["count"].double))))
                index = generationTasks.count - 1; changed = true
            }
            guard let index, !generationTasks[index].items.contains(where: { $0.id == promptID }) else { continue }
            generationTasks[index].items.append(GenerationItem(id: promptID, prompt: row.array[2].object,
                sequence: Int(meta["index"].double)))
            generationTasks[index].items.sort { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
            changed = true
        }
        if changed { saveGenerationTasks() }
    }
    func applyCanvasDocument(_ document: CanvasDocument, to id: String) throws {
        guard let index = workflows.firstIndex(where: { $0.id == id }) else { throw PocketError.message("工作流已被删除。") }
        let updated = try document.applying(to: workflows[index])
        guard updated != workflows[index] else { return }
        workflows[index] = updated
        save(); touch(id)
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
        canvasSessions.remove(workflowID: id)
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
        guard let api = client, connected, pluginAvailable, !syncing, !suspended, !restoringConnection else { return }
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
                if id == canvasEditingID { continue }
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
                    workflows[index].canvas = remote.canvas
                } else {
                    workflows.append(remote)
                }
                syncRecords[id] = SyncRecord(serverUpdatedAt: full["updatedAt"].double, dirty: false)
                changed = true
            }
            for id in WorkflowSync.idsToRemove(records: syncRecords, serverIDs: serverIDs, pendingDeletes: pendingDeletes) {
                if id == canvasEditingID { continue }
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
        guard let api = client, connected, pluginAvailable, !syncing, !suspended, !restoringConnection else { return }
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
            var payload: [String: JSONValue] = [
                "id": .string(targetID), "name": .string(workflow.name), "prompt": .object(workflow.prompt)
            ]
            if let canvas = workflow.canvas { payload["workflow"] = canvas }
            let reply = try await api.json("pocket/v1/workflows", method: "POST", body: .object(payload))
            guard client === api else { return }
            guard let current = workflows.first(where: { $0.id == targetID }) else { continue }
            syncRecords[targetID] = SyncRecord(serverUpdatedAt: reply["updatedAt"].double, dirty: current != workflow)
        }
    }
    private func recordSyncError(_ error: Error) {
        guard !Task.isCancelled, !suspended, !restoringConnection else { return }
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
    func forgetPromptIDs(_ ids: Set<String>) {
        for key in Array(recentPrompts.keys) { recentPrompts[key]?.removeAll { ids.contains($0) } }
        saveRecentPrompts()
    }
    func latestTask(for workflowID: String) -> GenerationTask? {
        currentGenerationTasks.first { $0.workflowID == workflowID }
    }
    func latestPromptIDs(for workflowID: String) -> [String] {
        WorkflowResults.latestPromptIDs(workflowID: workflowID, tasks: currentGenerationTasks,
                                       legacyIDs: (recentPrompts[workflowID] ?? []).filter { !currentMediaArchive.deletedPromptIDs.contains($0) })
    }
    func isActivePrompt(for workflowID: String) -> Bool {
        !activePrompt.isEmpty && latestPromptIDs(for: workflowID).contains(activePrompt)
    }
    func hasQueuedPrompt(for workflowID: String) -> Bool {
        let ids = Set(latestPromptIDs(for: workflowID))
        return (queue["queue_running"].array + queue["queue_pending"].array).contains {
            $0.array.count > 1 && ids.contains($0.array[1].text)
        }
    }
    func outputs(forPromptID promptID: String) -> [OutputImage] {
        var seen = Set<String>()
        let items = OutputImage.fromHistoryEntry(history[promptID], promptID: promptID)
            + currentMediaArchive.outputs.filter { $0.promptID == promptID }
        return currentMediaArchive.visible(items).filter { seen.insert($0.id).inserted }
    }
    func images(forWorkflow workflowID: String) -> [OutputImage] {
        latestPromptIDs(for: workflowID).flatMap { outputs(forPromptID: $0) }
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
        currentMediaArchive.gallery
    }
}
