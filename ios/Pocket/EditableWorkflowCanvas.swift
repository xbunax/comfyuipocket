import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct WorkflowCanvasHost: View {
    @Environment(PocketStore.self) private var store
    @State private var selectedID: String
    init(workflowID: String) { _selectedID = State(initialValue: workflowID) }
    var body: some View {
        Group {
            if let api = store.client {
                WorkflowCanvasView(workflowID: selectedID,
                    session: store.canvasSessions.session(baseURL: api.baseURL, workflowID: selectedID),
                    selectWorkflow: { selectedID = $0 })
                    .id(CanvasCacheKey(baseURL: api.baseURL, workflowID: selectedID))
            } else {
                WorkflowCanvasView(workflowID: selectedID, session: CanvasSession(), selectWorkflow: { selectedID = $0 })
            }
        }
    }
}

struct WorkflowCanvasView: View {
    let workflowID: String
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: CanvasSession
    let selectWorkflow: (String) -> Void
    @State private var canvasSize = CGSize.zero
    @State private var wheelExpanded = false
    @State private var showWorkflows = false
    @State private var showHardware = false
    @State private var hardware = ServerHardware()
    @State private var submitting = false
    @State private var submissionStatus: String?
    @State private var latestPromptID: String?
    @State private var showMismatch = false
    @State private var showNodes = false
    @State private var showPorts = false
    @State private var working = false
    @State private var exporting = false
    @State private var exportDocument = WorkflowDocument(data: Data())
    private var workflow: Workflow? { store.workflows.first { $0.id == workflowID } }

    var body: some View {
        NavigationStack {
            Group {
                if store.connected, let api = store.client, let workflow {
                    ZStack {
                        CanvasWebView(session: session)
                            .allowsHitTesting(session.loaded)
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
                            .task(id: canvasSize) {
                                do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation() }
                                catch { return }
                                await session.refitViewport(size: canvasSize)
                            }
                        if session.loading {
                            ProgressView(session.loadingMessage).padding(20).background(.regularMaterial, in: .rect(cornerRadius: 18))
                        }
                    }
                    .task(id: api.baseURL) {
                        store.canvasEditingID = workflowID
                        store.canvasEditingSession = session
                        store.canvasSessions.attach(session)
                        session.open(workflow: workflow, baseURL: api.baseURL)
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            if session.loaded, !session.textEditing, !submitting, !working, !session.mutating {
                                await session.refreshScene(); _ = await save()
                            }
                        }
                    }
                    .task(id: api.baseURL) { await pollHardware(api) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { controls }
                } else {
                    ContentUnavailableView("连接服务器后编辑画布", systemImage: "network",
                        description: Text("完整编辑器直接连接你的 ComfyUI，支持节点、连线、子图与自定义控件。"))
                }
            }
            .navigationTitle(workflow?.name ?? "工作流画布").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("切换工作流", systemImage: "square.stack") { showWorkflows = true }
                        Button(session.showPanels ? "隐藏 ComfyUI 面板" : "显示 ComfyUI 面板", systemImage: "sidebar.left") {
                            Task { await session.setPanels(!session.showPanels) }
                        }
                        Divider()
                        Button("撤销", systemImage: "arrow.uturn.backward") { command("undo") }
                        Button("重做", systemImage: "arrow.uturn.forward") { command("redo") }
                        Button("复制选中内容", systemImage: "doc.on.doc") { command("copy") }
                        Button("粘贴", systemImage: "doc.on.clipboard") { command("paste") }
                        Button("全选", systemImage: "checkmark.square") { command("selectAll") }
                        Button("删除选中内容", systemImage: "trash", role: .destructive) { command("delete") }
                        Button("导出工作流", systemImage: "square.and.arrow.up") {
                            Task {
                                guard await saveForAction(), let workflow = self.workflow else { return }
                                do { exportDocument = WorkflowDocument(data: try JSONEncoder().encode(workflow)); exporting = true }
                                catch { session.error = error.localizedDescription }
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }.disabled(!session.available || submitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await run() } } label: {
                        if submitting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "play.fill").frame(minWidth: 26) }
                    }.buttonStyle(.glassProminent).disabled(!session.loaded || submitting || store.busy)
                        .accessibilityLabel("运行当前画布").accessibilityIdentifier("canvas.run")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task {
                            if !session.loaded { dismiss(); return }
                            if await saveForAction() { dismiss() }
                        }
                    }.disabled(working || submitting)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                header
                if let issue = session.mismatch {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(issue).font(.caption)
                        HStack {
                            Button("查看差异") { showMismatch = true }
                            Spacer()
                            Button("重新载入") { if let workflow, let api = store.client { session.open(workflow: workflow, baseURL: api.baseURL, force: true) } }
                        }.font(.caption).buttonStyle(.borderless)
                    }.padding(12).background(.regularMaterial)
                }
                }
            }
            .alert("画布操作失败", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
                Button("重试加载") { if let workflow, let api = store.client { session.open(workflow: workflow, baseURL: api.baseURL, force: true) } }
                Button("关闭", role: .cancel) { session.error = nil }
            } message: { Text(session.error ?? "") }
            .sheet(isPresented: $showMismatch) {
                NavigationStack {
                    List {
                        Section { Text("节点可只读查看。以下字段尚未与执行参数对应，保存和运行已暂停，原有数据会保留。") }
                        Section("字段") { ForEach(session.mismatchFields, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) } }
                        Section {
                            Button("保留副本并从当前参数重建画布") {
                                guard let workflow else { return }
                                store.duplicate(workflow); showMismatch = false
                                Task { await session.action("rebuild", arguments: ["name": workflow.name]) }
                            }
                        }
                    }.navigationTitle("参数差异").toolbar { Button("完成") { showMismatch = false } }
                }
            }
            .sheet(isPresented: $showNodes) { CanvasNodeLibrary(session: session) }
            .sheet(isPresented: $showPorts) { CanvasConnections(session: session) }
            .sheet(isPresented: $showHardware) { CanvasHardwareDetails(hardware: hardware, server: store.client?.baseURL.absoluteString ?? "") }
            .sheet(isPresented: $showWorkflows) {
                NavigationStack {
                    List(store.workflows) { item in
                        Button {
                            Task {
                                if session.loaded { guard await saveForAction() else { return } }
                                showWorkflows = false
                                if item.id != workflowID { selectWorkflow(item.id) }
                            }
                        } label: {
                            HStack { Text(item.name); Spacer(); if item.id == workflowID { Image(systemName: "checkmark") } }
                        }.disabled(working || submitting)
                    }.navigationTitle("切换工作流").toolbar { Button("完成") { showWorkflows = false } }
                }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: workflow?.name ?? "Workflow") { result in
                if case .failure(let error) = result { session.error = error.localizedDescription }
            }
            .interactiveDismissDisabled()
            .onChange(of: store.error) { _, message in
                if let message, store.canvasEditingSession === session { session.error = message; store.error = nil }
            }
            .onDisappear {
                if store.canvasEditingSession === session { store.canvasEditingID = nil; store.canvasEditingSession = nil }
                store.canvasSessions.detach(session)
                Task { await store.syncNow() }
            }
        }
    }
    private var header: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(store.connected ? Color.green : Color.secondary).frame(width: 5, height: 5)
                Text(store.client?.baseURL.host ?? "未连接").lineLimit(1)
                Spacer(minLength: 8)
                Text(runStatus ?? (session.reused ? "缓存已就绪" : (working ? "保存中…" : "自动保存")))
                    .lineLimit(1).foregroundStyle(submissionStatus == nil ? Color.secondary : PocketPalette.accent)
            }.font(.caption2)
            Button { showHardware = true } label: { CanvasHardwareBar(hardware: hardware) }.buttonStyle(.plain)
        }.padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
    }
    private var controls: some View {
        VStack(spacing: 0) {
            if session.textEditing {
                HStack {
                    Label("编辑文本", systemImage: "text.cursor").font(.caption)
                    Spacer()
                    Button("完成输入", systemImage: "keyboard.chevron.compact.down") {
                        Task { await session.action("finishText") }
                    }.buttonStyle(.glass)
                }.padding(.horizontal, 14).padding(.vertical, 6)
            } else {
                if wheelExpanded, session.available { CanvasNodeWheel(session: session, compact: true) }
                HStack(spacing: 10) {
                    Button {
                        session.nodeFocusActive = false
                        Task { await session.action("fit") }
                    } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 36, height: 36) }
                        .accessibilityLabel("工作流总览").disabled(!session.available)
                    Button { wheelExpanded.toggle() } label: {
                        VStack(spacing: 2) {
                            HStack(spacing: 5) {
                                Text(session.scene.nodes.first { $0.id == session.focusedNodeID }?.title ?? "选择节点").lineLimit(1)
                                Image(systemName: wheelExpanded ? "chevron.down" : "chevron.up").font(.caption2)
                            }.font(.subheadline.weight(.medium))
                            Text("\(session.scene.nodes.count) 个节点 · \(wheelExpanded ? "上下滚动定位" : "点按展开轮盘")")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: 36)
                    }.disabled(!session.available).accessibilityLabel("展开或收起节点轮盘")
                    Button { Task { await session.setPanels(!session.showPanels) } } label: {
                        Image(systemName: "sidebar.left").frame(width: 36, height: 36)
                            .foregroundStyle(session.showPanels ? PocketPalette.accent : Color.primary)
                    }.accessibilityLabel(session.showPanels ? "隐藏 ComfyUI 面板" : "显示 ComfyUI 面板").disabled(!session.available)
                    Menu {
                        Button("聚焦当前节点", systemImage: "scope") {
                            session.nodeFocusActive = true
                            Task { await session.focusSelection() }
                        }
                        Button("切换工作流", systemImage: "square.stack") { showWorkflows = true }
                        Toggle("节点浮动工具", isOn: Binding(get: { session.showFloatingTools }, set: { enabled in
                            Task { await session.setFloatingTools(enabled) }
                        }))
                        Button("保存画布", systemImage: "square.and.arrow.down") { Task { _ = await saveForAction() } }
                        Button("新增节点", systemImage: "plus") { showNodes = true }.accessibilityIdentifier("canvas.addNode")
                        Button("连接端口", systemImage: "point.3.connected.trianglepath.dotted") { showPorts = true }.accessibilityIdentifier("canvas.connect")
                        if session.scene.nested {
                            Button("返回主图", systemImage: "arrow.uturn.backward") {
                                session.nodeFocusActive = false
                                Task { await session.action("subgraph", arguments: ["id": ""]); await session.action("fit") }
                            }
                        }
                        Divider()
                        Button("重新加载画布", systemImage: "arrow.clockwise") {
                            if let workflow, let api = store.client { session.open(workflow: workflow, baseURL: api.baseURL, force: true) }
                        }
                    } label: { Image(systemName: "slider.horizontal.3").frame(width: 36, height: 36) }
                        .accessibilityLabel("画布工具").disabled(!session.loaded || submitting)
                }.buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 5)
            }
        }.background(.regularMaterial)
    }
    private func pollHardware(_ api: ComfyClient) async {
        var resourcesAvailable: Bool? = nil
        while !Task.isCancelled {
            do {
                let stats = try await api.hardwareJSON("system_stats")
                var resources: JSONValue?
                if resourcesAvailable != false {
                    do { resources = try await api.hardwareJSON("nodeui/v1/resources"); resourcesAvailable = true }
                    catch { if resourcesAvailable == nil { resourcesAvailable = false } }
                }
                guard !Task.isCancelled, store.client === api else { return }
                hardware = ServerHardware(stats: stats, resources: resources, sampledAt: Date())
            } catch { if !Task.isCancelled { hardware = ServerHardware() } }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }
    private var runStatus: String? {
        guard let id = latestPromptID else { return submissionStatus }
        if store.activePrompt == id { return "生成中 · \(Int(store.progress * 100))%" }
        switch store.history[id]["status"]["status_str"].text {
        case "success": return "生成完成"
        case "error": return "生成失败 · 查看任务详情"
        default: return submissionStatus
        }
    }
    private func saveForAction() async -> Bool {
        if session.textEditing { await session.action("finishText"); session.textEditing = false }
        let deadline = Date().addingTimeInterval(30)
        while working {
            guard Date() < deadline else { session.error = "保存尚未完成，请稍后重试。"; return false }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        let saved = await save()
        if !saved, session.error == nil { session.error = "节点仍在更新，请完成当前操作后重试。" }
        return saved
    }
    private func run() async {
        guard !submitting else { return }
        submitting = true; submissionStatus = "正在保存并提交…"
        defer { submitting = false }
        guard await saveForAction(), let workflow = self.workflow else { submissionStatus = "提交未完成"; return }
        let result = await store.enqueue(workflow)
        if let error = result.error { session.error = error }
        if let id = result.promptIDs.first { latestPromptID = id; submissionStatus = "已排队 · \(id.prefix(8))" }
        else { submissionStatus = "提交失败" }
    }
    private func command(_ name: String) { Task { await session.action("command", arguments: ["name": name]) } }
    @discardableResult private func save() async -> Bool {
        guard !working, !session.mutating else { return false }
        working = true; defer { working = false }
        do {
            guard let text = try await session.snapshot() else { return false }
            if text != session.lastSaved {
                let document = try JSONDecoder().decode(CanvasDocument.self, from: Data(text.utf8))
                try store.applyCanvasDocument(document, to: workflowID)
                session.lastSaved = text
                session.saveStatus = "已保存到手机 · 自动同步"
            }
            if let workflow = self.workflow { session.remember(workflow) }
            return true
        } catch { session.error = error.localizedDescription; return false }
    }
}

@MainActor @Observable
final class CanvasSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var scene = MobileCanvasScene()
    var available = false
    var focusedNodeID = ""
    var nodeFocusActive = false
    var textEditing = false
    var mismatchFields: [String] = []
    var mutating = false
    var loading = true
    var loaded = false
    var error: String?
    var mismatch: String?
    var saveStatus = "修改会自动保存"
    var lastSaved = ""
    var reused = false
    var showPanels = false
    var showFloatingTools = false
    var loadingMessage = "正在准备节点与画布…"
    @ObservationIgnored var webView: WKWebView?
    @ObservationIgnored var cacheKey: CanvasCacheKey?
    @ObservationIgnored private var baseURL: URL?
    @ObservationIgnored private var initialText = ""
    @ObservationIgnored private var runtimeReady = false
    @ObservationIgnored private var revision: CanvasRevision?
    @ObservationIgnored private var pendingRevision: CanvasRevision?
    @ObservationIgnored private var viewportSize = CGSize.zero

    func view() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.userContentController.add(CanvasMessageHandler(session: self), name: "pocketCanvas")
        config.userContentController.addUserScript(WKUserScript(source: "window.__POCKET_CANVAS__ = true; try { localStorage.setItem('comfyui-pocket.auto.v1', 'off'); } catch {}", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let file = Bundle.main.url(forResource: "CanvasBridge", withExtension: "js"), let source = try? String(contentsOf: file, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        } else { error = "画布组件缺失，请重新安装应用。" }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        web.scrollView.bounces = false
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.isOpaque = false
        #if DEBUG
        web.isInspectable = true
        #endif
        self.webView = web
        return web
    }
    func open(workflow: Workflow, baseURL: URL, force: Bool = false) {
        let incoming = CanvasRevision(workflow)
        if !force, self.baseURL == baseURL, pendingRevision == incoming, loading, webView != nil, error == nil { return }
        let plan = CanvasOpenPlan.resolve(sameServer: self.baseURL == baseURL, runtimeReady: runtimeReady,
            available: available, current: revision, incoming: incoming, force: force)
        if plan == .reuse { reused = true; return }
        self.baseURL = baseURL; loading = true; loaded = false; available = false; textEditing = false; scene = MobileCanvasScene(); focusedNodeID = ""; nodeFocusActive = false; mismatch = nil; mismatchFields = []; error = nil; lastSaved = ""
        reused = false; pendingRevision = incoming
        do { initialText = String(decoding: try JSONEncoder().encode(workflow), as: UTF8.self) }
        catch { self.error = error.localizedDescription; loading = false; return }
        if plan == .updateGraph {
            loadingMessage = "正在更新本机画布…"
            Task { await action("load", arguments: ["text": initialText]) }
            return
        }
        runtimeReady = false; revision = nil
        showPanels = false; showFloatingTools = false
        loadingMessage = "正在准备节点与画布…"
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "pocket_canvas", value: "1")]
        view().load(URLRequest(url: parts.url!, cachePolicy: force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy, timeoutInterval: 180))
    }
    func remember(_ workflow: Workflow) {
        revision = CanvasRevision(workflow); pendingRevision = revision
    }
    func discard() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "pocketCanvas")
        webView = nil; runtimeReady = false; available = false; loaded = false; loading = true; textEditing = false
        revision = nil; pendingRevision = nil; viewportSize = .zero
    }
    func call(_ method: String, arguments: [String: Any] = [:]) async throws -> Any {
        guard let webView else { throw PocketError.message("画布尚未启动。") }
        let scripts: [String: String] = [
            "scene": "return window.PocketCanvas.scene();",
            "widget": "return await window.PocketCanvas.widget(id, index, value, name);",
            "moveNode": "return window.PocketCanvas.moveNode(id, x, y);",
            "removeNode": "return window.PocketCanvas.removeNode(id);",
            "groupMode": "return window.PocketCanvas.groupMode(id, mode);",
            "nodeMode": "return window.PocketCanvas.nodeMode(id, mode);",
            "focus": "return window.PocketCanvas.focus(id);",
            "subgraph": "return window.PocketCanvas.subgraph(id);",
            "snapshot": "return await window.PocketCanvas.snapshot();", "load": "return await window.PocketCanvas.load(text);",
            "rebuild": "return await window.PocketCanvas.rebuild(name);", "command": "return await window.PocketCanvas.command(name);",
            "fit": "return window.PocketCanvas.fit();", "zoom": "return window.PocketCanvas.zoom(factor);",
            "tools": "return window.PocketCanvas.tools(enabled);",
            "chrome": "return await window.PocketCanvas.chrome(enabled);",
            "viewport": "return window.PocketCanvas.viewport();", "finishText": "return window.PocketCanvas.finishText();",
            "addNode": "return window.PocketCanvas.addNode(type);", "library": "return window.PocketCanvas.library();",
            "ports": "return window.PocketCanvas.ports();", "connect": "return window.PocketCanvas.connect(from, output, to, input);",
            "disconnect": "return window.PocketCanvas.disconnect(id, slot);"
        ]
        let readOnlyMethods: Set<String> = ["load", "rebuild", "scene", "focus", "fit", "zoom", "ports", "library", "subgraph", "viewport", "finishText", "chrome", "tools"]
        if !loaded && !readOnlyMethods.contains(method) { throw PocketError.message("请先解决画布参数差异，再进行修改。") }
        guard let script = scripts[method] else { throw PocketError.message("无效的画布操作。") }
        return try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page) ?? NSNull()
    }
    func snapshot() async throws -> String? {
        guard !textEditing else { return nil }
        let result = try await call("snapshot")
        if result is NSNull { return nil }
        guard let text = result as? String, text.utf8.count <= 20 * 1024 * 1024 else { throw PocketError.message("画布内容无效或超过 20 MB。") }
        return text
    }
    func action(_ name: String, arguments: [String: Any] = [:]) async {
        do {
            _ = try await call(name, arguments: arguments)
            if available { await refreshScene() }
        }
        catch {
            if name == "load" || name == "rebuild" { loading = false }
            self.error = error.localizedDescription
        }
    }
    func refreshScene() async {
        do {
            if let text = try await call("scene") as? String {
                scene = try JSONDecoder().decode(MobileCanvasScene.self, from: Data(text.utf8))
                if !scene.nodes.contains(where: { $0.id == focusedNodeID }) {
                    focusedNodeID = orderedNodes.first?.id ?? ""
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    var orderedNodes: [MobileCanvasNode] {
        scene.nodes.sorted { a, b in a.y == b.y ? (a.x == b.x ? a.id.localizedStandardCompare(b.id) == .orderedAscending : a.x < b.x) : a.y < b.y }
    }
    func focusSelection() async {
        guard available, !textEditing, nodeFocusActive, !focusedNodeID.isEmpty else { return }
        do { _ = try await call("focus", arguments: ["id": focusedNodeID]) }
        catch { self.error = error.localizedDescription }
    }
    func setPanels(_ enabled: Bool) async {
        do {
            _ = try await call("chrome", arguments: ["enabled": enabled])
            showPanels = enabled
            await refitViewport()
        } catch { self.error = error.localizedDescription }
    }
    func setFloatingTools(_ enabled: Bool) async {
        do { _ = try await call("tools", arguments: ["enabled": enabled]); showFloatingTools = enabled }
        catch { self.error = error.localizedDescription }
    }
    func refitViewport(size: CGSize? = nil) async {
        if let size {
            guard size.width > 0, size.height > 0, size != viewportSize else { return }
            viewportSize = size
        }
        guard available else { return }
        do { if try await call("viewport") as? Bool == true { return } }
        catch { self.error = error.localizedDescription; return }
        if nodeFocusActive { await focusSelection() }
        else {
            do { _ = try await call("fit") }
            catch { self.error = error.localizedDescription }
        }
    }
    private func trusted(_ url: URL?) -> Bool {
        guard let url, let baseURL else { return false }
        return url.scheme == baseURL.scheme && url.host == baseURL.host && url.port == baseURL.port
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, trusted(message.frameInfo.request.url), let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "foreignGraph":
            // Keep navigation available, but never save this graph over the
            // original. A later open updates graph data in the cached runtime.
            loaded = false; revision = nil
        case "loading": if loading { loadingMessage = body["message"] as? String ?? loadingMessage }
        case "textEditing":
            textEditing = body["active"] as? Bool ?? false
            if textEditing, let id = body["nodeID"] as? String, scene.nodes.contains(where: { $0.id == id }) { focusedNodeID = id }
        case "ready": runtimeReady = true; Task { await action("load", arguments: ["text": initialText]) }
        case "loaded": revision = pendingRevision; loading = false; loaded = true; available = true; mismatch = nil; mismatchFields = []; Task { await refreshScene(); await focusSelection() }
        case "mismatch": revision = pendingRevision; loading = false; loaded = false; available = true; mismatch = body["message"] as? String; mismatchFields = body["fields"] as? [String] ?? []; Task { await refreshScene(); await focusSelection() }
        case "error": loading = false; error = body["message"] as? String
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        decisionHandler(trusted(navigationAction.request.url) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loading = false; self.error = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false; self.error = error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { runtimeReady = false; loaded = false; available = false; textEditing = false; loading = false; error = "画布进程已暂停，请重新载入。已保存的修改仍在手机中。" }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        dialog(webView, message: message, confirm: false) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        dialog(webView, message: message, confirm: true, complete: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: prompt, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        present(alert, webView: webView, fallback: { completionHandler(nil) })
    }
    private func dialog(_ webView: WKWebView, message: String, confirm: Bool, complete: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "ComfyUI", message: message, preferredStyle: .alert)
        if confirm { alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in complete(false) }) }
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in complete(true) })
        present(alert, webView: webView, fallback: { complete(false) })
    }
    private func present(_ alert: UIAlertController, webView: WKWebView, fallback: () -> Void) {
        var controller = webView.window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        guard let controller else { fallback(); return }
        controller.present(alert, animated: true)
    }
}

private struct CanvasWebView: UIViewRepresentable {
    let session: CanvasSession
    func makeUIView(context: Context) -> WKWebView { session.view() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// WebKit retains script handlers. Use a weak target so evicting a cached canvas
/// actually releases its page, sockets and editor instead of creating a cycle.
@MainActor private final class CanvasMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: CanvasSession?
    init(session: CanvasSession) { self.session = session }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.userContentController(userContentController, didReceive: message)
    }
}
