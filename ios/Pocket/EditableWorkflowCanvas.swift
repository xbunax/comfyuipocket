import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct WorkflowCanvasView: View {
    let workflowID: String
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var session = CanvasSession()
    @State private var canvasSize = CGSize.zero
    @State private var showCanvasTools = false
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
                                await session.refitViewport()
                            }
                        if session.loading {
                            ProgressView("正在准备节点与画布…").padding(20).background(.regularMaterial, in: .rect(cornerRadius: 18))
                        }
                    }
                    .task(id: api.baseURL) {
                        store.canvasEditingID = workflowID
                        session.open(workflow: workflow, baseURL: api.baseURL)
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            if session.loaded, !session.textEditing, !working, !session.mutating {
                                await session.refreshScene(); _ = await save()
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { controls }
                } else {
                    ContentUnavailableView("连接服务器后编辑画布", systemImage: "network",
                        description: Text("完整编辑器直接连接你的 ComfyUI，支持节点、连线、子图与自定义控件。"))
                }
            }
            .navigationTitle("工作流画布").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("撤销", systemImage: "arrow.uturn.backward") { command("undo") }
                        Button("重做", systemImage: "arrow.uturn.forward") { command("redo") }
                        Button("复制选中内容", systemImage: "doc.on.doc") { command("copy") }
                        Button("粘贴", systemImage: "doc.on.clipboard") { command("paste") }
                        Button("全选", systemImage: "checkmark.square") { command("selectAll") }
                        Button("删除选中内容", systemImage: "trash", role: .destructive) { command("delete") }
                        Button("导出工作流", systemImage: "square.and.arrow.up") {
                            Task {
                                guard await save(), let workflow = self.workflow else { return }
                                do { exportDocument = WorkflowDocument(data: try JSONEncoder().encode(workflow)); exporting = true }
                                catch { session.error = error.localizedDescription }
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }.disabled(!session.loaded || working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task {
                            if !session.loaded { dismiss(); return }
                            if session.textEditing {
                                await session.action("finishText")
                                session.textEditing = false
                            }
                            if await save() { dismiss() }
                        }
                    }.disabled(working)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let issue = session.mismatch {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(issue).font(.caption)
                        HStack {
                            Button("查看差异") { showMismatch = true }
                            Spacer()
                            Button("重新载入") { if let workflow, let api = store.client { session.open(workflow: workflow, baseURL: api.baseURL) } }
                        }.font(.caption).buttonStyle(.borderless)
                    }.padding(12).background(.regularMaterial)
                }
            }
            .alert("画布操作失败", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
                Button("重试加载") { if let workflow, let api = store.client { session.open(workflow: workflow, baseURL: api.baseURL) } }
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
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: workflow?.name ?? "Workflow") { result in
                if case .failure(let error) = result { session.error = error.localizedDescription }
            }
            .interactiveDismissDisabled()
            .onChange(of: session.loading) { _, loading in
                if loading { showCanvasTools = false }
            }
            .onDisappear {
                if store.canvasEditingID == workflowID { store.canvasEditingID = nil }
                session.webView?.stopLoading()
                Task { await store.syncNow() }
            }
        }
    }
    private var controls: some View {
        VStack(spacing: 8) {
            if session.textEditing {
                HStack {
                    Label("编辑文本", systemImage: "text.cursor").font(.subheadline)
                    Spacer()
                    Button("完成输入", systemImage: "keyboard.chevron.compact.down") {
                        Task { await session.action("finishText") }
                    }.buttonStyle(.glass)
                }.padding(.horizontal, 16).padding(.vertical, 8)
            } else {
            if session.available {
                CanvasNodeWheel(session: session)
            }
            HStack {
                Button("总览", systemImage: "arrow.up.left.and.arrow.down.right") {
                    session.nodeFocusActive = false
                    Task { await session.action("fit") }
                }.disabled(!session.available)
                Spacer()
                Button("聚焦节点", systemImage: "scope") {
                    session.nodeFocusActive = true
                    Task { await session.focusSelection() }
                }.disabled(!session.available || session.focusedNodeID.isEmpty)
                Spacer()
                Menu {
                    Toggle("画布浮动工具", isOn: $showCanvasTools)
                    Button("缩小", systemImage: "minus.magnifyingglass") { Task { await session.action("zoom", arguments: ["factor": 0.75]) } }
                    Button("放大", systemImage: "plus.magnifyingglass") { Task { await session.action("zoom", arguments: ["factor": 1.33]) } }
                    if session.scene.nested {
                        Button("返回主图", systemImage: "arrow.uturn.backward") {
                            session.nodeFocusActive = false
                            Task { await session.action("subgraph", arguments: ["id": ""]); await session.action("fit") }
                        }
                    }
                    Divider()
                    Button("新增节点", systemImage: "plus") { showNodes = true }.accessibilityIdentifier("canvas.addNode")
                    Button("连接端口", systemImage: "point.3.connected.trianglepath.dotted") { showPorts = true }.accessibilityIdentifier("canvas.connect")
                } label: { Label("画布工具", systemImage: "slider.horizontal.3") }.disabled(!session.loaded || working)
            }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 4)
                .onChange(of: showCanvasTools) { _, enabled in
                    guard session.loaded else { return }
                    Task { await session.action("tools", arguments: ["enabled": enabled]) }
                }
            HStack(spacing: 12) {
                Text(session.loaded ? "自动保存" : "只读查看").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存") { Task { _ = await save() } }.buttonStyle(.glass)
                Button {
                    Task {
                        guard await save(), let workflow = self.workflow else { return }
                        await store.submit(workflow, count: 1, randomizeSeeds: false)
                    }
                } label: { Label(store.busy ? "提交中" : "运行", systemImage: "play.fill") }
                    .buttonStyle(.glassProminent).disabled(store.busy)
            }.disabled(!session.loaded || working).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }.background(.regularMaterial)
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
    @ObservationIgnored var webView: WKWebView?
    @ObservationIgnored private var baseURL: URL?
    @ObservationIgnored private var initialText = ""

    func view() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.userContentController.add(self, name: "pocketCanvas")
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
    func open(workflow: Workflow, baseURL: URL) {
        self.baseURL = baseURL; loading = true; loaded = false; available = false; textEditing = false; scene = MobileCanvasScene(); focusedNodeID = ""; nodeFocusActive = false; mismatch = nil; mismatchFields = []; error = nil; lastSaved = ""
        do { initialText = String(decoding: try JSONEncoder().encode(workflow), as: UTF8.self) }
        catch { self.error = error.localizedDescription; loading = false; return }
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "pocket_canvas", value: "1")]
        view().load(URLRequest(url: parts.url!))
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
            "viewport": "return window.PocketCanvas.viewport();", "finishText": "return window.PocketCanvas.finishText();",
            "addNode": "return window.PocketCanvas.addNode(type);", "library": "return window.PocketCanvas.library();",
            "ports": "return window.PocketCanvas.ports();", "connect": "return window.PocketCanvas.connect(from, output, to, input);",
            "disconnect": "return window.PocketCanvas.disconnect(id, slot);"
        ]
        let readOnlyMethods: Set<String> = ["load", "rebuild", "scene", "focus", "fit", "zoom", "ports", "library", "subgraph", "viewport", "finishText"]
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
    func refitViewport() async {
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
        case "textEditing":
            textEditing = body["active"] as? Bool ?? false
            if textEditing, let id = body["nodeID"] as? String, scene.nodes.contains(where: { $0.id == id }) { focusedNodeID = id }
        case "ready": Task { await action("load", arguments: ["text": initialText]) }
        case "loaded": loading = false; loaded = true; available = true; mismatch = nil; mismatchFields = []; Task { await refreshScene(); await focusSelection() }
        case "mismatch": loading = false; loaded = false; available = true; mismatch = body["message"] as? String; mismatchFields = body["fields"] as? [String] ?? []; Task { await refreshScene(); await focusSelection() }
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
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loaded = false; available = false; textEditing = false; loading = false; error = "画布进程已暂停，请重新载入。已保存的修改仍在手机中。" }
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
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { uiView.configuration.userContentController.removeScriptMessageHandler(forName: "pocketCanvas") }
}
