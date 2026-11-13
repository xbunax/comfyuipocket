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
    var tailnetStatus: JSONValue = .object([:])
    var pluginAvailable = false
    var busy = false
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var lastConnection = UUID()
    private static var libraryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("workflows.json")
    }
    init() {
        profile = (UserDefaults.standard.data(forKey: "server").flatMap { try? JSONDecoder().decode(ServerProfile.self, from: $0) }) ?? ServerProfile()
        workflows = (try? JSONDecoder().decode([Workflow].self, from: Data(contentsOf: Self.libraryURL))) ?? []
    }
    func save() {
        do {
            try JSONEncoder().encode(workflows).write(to: Self.libraryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            UserDefaults.standard.set(try JSONEncoder().encode(profile), forKey: "server")
        } catch { self.error = "本地保存失败：\(error.localizedDescription)" }
    }
    func connect() async {
        guard !connecting else { return }
        disconnect(); connecting = true
        let attempt = UUID(); lastConnection = attempt
        defer { if lastConnection == attempt { connecting = false } }
        do {
            let target = try profile.baseURL()
            var base = target; var token = ""
            if profile.tailscale {
                try await TailnetBridge.shared.start(controlURL: profile.controlURL)
                tailnetStatus = try await TailnetBridge.shared.status()
                guard tailnetStatus["state"].text == "Running" else {
                    throw PocketError.message("请先在组网设置中完成 Tailscale 登录，再连接服务器。")
                }
                (base, token) = try await TailnetBridge.shared.forward(target)
            }
            let next = ComfyClient(baseURL: base, bridgeToken: token)
            _ = try await next.json("system_stats")
            guard lastConnection == attempt else { return }
            client = next; connected = true; save()
            startEvents(next)
            await refresh()
            do { nodeInfo = try await next.json("object_info") } catch { self.notice = "节点元信息暂不可用，仍可编辑已有参数。" }
            pluginAvailable = (try? await next.json("pocket/v1/info"))?["version"].text.nonEmpty != nil
        } catch { if lastConnection == attempt { self.error = error.localizedDescription } }
    }
    func disconnect() {
        lastConnection = UUID(); connecting = false
        events?.cancel(); events = nil; polling?.cancel(); polling = nil
        client?.disconnect(); client = nil; connected = false; socketConnected = false
        queue = .object([:]); history = .object([:]); nodeInfo = .object([:])
        preview = nil; progress = 0; activeNode = ""; activePrompt = ""; pluginAvailable = false
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
    }
    func resume() async {
        guard connected, let client else { return }
        startEvents(client); await refresh()
    }
    func suspend() { events?.cancel(); polling?.cancel(); client?.disconnect(); socketConnected = false }
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
    func submit(_ workflow: Workflow) async {
        guard let api = client, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let reply = try await api.json("prompt", method: "POST", body: .object([
                "prompt": .object(workflow.prompt), "client_id": .string(api.clientID)
            ]))
            guard !reply["prompt_id"].text.isEmpty else { throw PocketError.message("提交失败：\(reply)") }
            notice = "已加入队列 · \(workflow.name)"; save(); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func deletePending(_ id: String) async {
        do { _ = try await client?.json("queue", method: "POST", body: .object(["delete": .array([.string(id)])])); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func interrupt() async {
        do { _ = try await client?.json("interrupt", method: "POST", body: .object([:])); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func sync() async {
        guard let api = client, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let list = try await api.json("pocket/v1/workflows")
            var count = 0
            for item in list["workflows"].array {
                let full = try await api.json("pocket/v1/workflows/\(item["id"].text)")
                let workflow = try Workflow.load(JSONEncoder().encode(full), name: item["name"].text)
                // Preserve the user's mobile parameter edits. Re-import a deleted item to get a fresh server copy.
                if !workflows.contains(where: { $0.id == workflow.id }) { workflows.append(workflow); count += 1 }
            }
            save(); notice = "导入 \(count) 个新工作流；已存在的本地编辑已保留。"
        } catch { self.error = "同步失败。请安装 Pocket 插件并从桌面导出工作流。\n\(error.localizedDescription)" }
    }
    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 20_000_000 else { throw PocketError.message("工作流文件不能超过 20 MB。") }
            var workflow = try Workflow.load(data, name: url.deletingPathExtension().lastPathComponent)
            if workflows.contains(where: { $0.id == workflow.id }) { workflow.id = UUID().uuidString }
            workflows.append(workflow); save()
        } catch { self.error = error.localizedDescription }
    }
    var images: [OutputImage] {
        history.object.sorted { ($0.value["prompt"].array.first?.double ?? 0) > ($1.value["prompt"].array.first?.double ?? 0) }.flatMap { id, entry in
            entry["outputs"].object.sorted(by: { $0.key < $1.key }).flatMap { _, output in
                let files = output["images"].array + output["gifs"].array + output["videos"].array
                var seen = Set<String>()
                return files.compactMap {
                    guard !$0["filename"].text.isEmpty else { return nil }
                    let item = OutputImage(promptID: id, filename: $0["filename"].text, subfolder: $0["subfolder"].text, type: $0["type"].text.nonEmpty ?? "output")
                    return seen.insert(item.id).inserted ? item : nil
                }
            }
        }
    }
}
