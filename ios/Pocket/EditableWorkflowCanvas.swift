import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct WorkflowCanvasView: View {
    let workflowID: String
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var session = CanvasSession()
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
                        if session.loading {
                            ProgressView("正在启动完整画布…").padding(20).background(.regularMaterial, in: .rect(cornerRadius: 18))
                        }
                    }
                    .task(id: api.baseURL) {
                        store.canvasEditingID = workflowID
                        session.open(workflow: workflow, baseURL: api.baseURL)
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            if session.loaded, !working { _ = await save() }
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
                            if await save() { dismiss() }
                        }
                    }.disabled(working)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let issue = session.mismatch {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(issue).font(.caption)
                        Button("保留副本并从当前参数重建画布") {
                            guard let workflow else { return }
                            store.duplicate(workflow)
                            Task { await session.action("rebuild", arguments: ["name": workflow.name]) }
                        }.buttonStyle(.glass)
                    }.padding().background(.regularMaterial)
                }
            }
            .alert("画布操作失败", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
                Button("重试加载") { if let workflow, let api = store.client { session.open(workflow: workflow, baseURL: api.baseURL) } }
                Button("关闭", role: .cancel) { session.error = nil }
            } message: { Text(session.error ?? "") }
            .sheet(isPresented: $showNodes) { CanvasNodeLibrary(session: session) }
            .sheet(isPresented: $showPorts) { CanvasConnections(session: session) }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: workflow?.name ?? "Workflow") { result in
                if case .failure(let error) = result { session.error = error.localizedDescription }
            }
            .interactiveDismissDisabled()
            .onDisappear {
                if store.canvasEditingID == workflowID { store.canvasEditingID = nil }
                session.webView?.stopLoading()
                Task { await store.syncNow() }
            }
        }
    }
    private var controls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    Button("新增节点", systemImage: "plus") { showNodes = true }.accessibilityIdentifier("canvas.addNode")
                    Button("连接端口", systemImage: "point.3.connected.trianglepath.dotted") { showPorts = true }.accessibilityIdentifier("canvas.connect")
                    Button("适合屏幕", systemImage: "arrow.up.left.and.arrow.down.right") { Task { await session.action("fit") } }
                    Button("缩小", systemImage: "minus.magnifyingglass") { Task { await session.action("zoom", arguments: ["factor": 0.75]) } }.labelStyle(.iconOnly)
                    Button("放大", systemImage: "plus.magnifyingglass") { Task { await session.action("zoom", arguments: ["factor": 1.33]) } }.labelStyle(.iconOnly)
                }.font(.subheadline).buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 8)
            }.disabled(!session.loaded || working)
            HStack {
                Text(session.saveStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        }.background(.regularMaterial)
    }
    private func command(_ name: String) { Task { await session.action("command", arguments: ["name": name]) } }
    @discardableResult private func save() async -> Bool {
        guard !working else { return false }
        working = true; defer { working = false }
        do {
            let text = try await session.snapshot()
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
        self.baseURL = baseURL; loading = true; loaded = false; mismatch = nil; error = nil; lastSaved = ""
        do { initialText = String(decoding: try JSONEncoder().encode(workflow), as: UTF8.self) }
        catch { self.error = error.localizedDescription; loading = false; return }
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "pocket_canvas", value: "1")]
        view().load(URLRequest(url: parts.url!))
    }
    func call(_ method: String, arguments: [String: Any] = [:]) async throws -> Any {
        guard let webView else { throw PocketError.message("画布尚未启动。") }
        let scripts: [String: String] = [
            "snapshot": "return await window.PocketCanvas.snapshot();", "load": "return await window.PocketCanvas.load(text);",
            "rebuild": "return await window.PocketCanvas.rebuild(name);", "command": "return await window.PocketCanvas.command(name);",
            "fit": "return window.PocketCanvas.fit();", "zoom": "return window.PocketCanvas.zoom(factor);",
            "addNode": "return window.PocketCanvas.addNode(type);", "library": "return window.PocketCanvas.library();",
            "ports": "return window.PocketCanvas.ports();", "connect": "return window.PocketCanvas.connect(from, output, to, input);",
            "disconnect": "return window.PocketCanvas.disconnect(id, slot);"
        ]
        guard let script = scripts[method] else { throw PocketError.message("无效的画布操作。") }
        return try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
    }
    func snapshot() async throws -> String {
        guard let text = try await call("snapshot") as? String, text.utf8.count <= 20 * 1024 * 1024 else { throw PocketError.message("画布内容无效或超过 20 MB。") }
        return text
    }
    func action(_ name: String, arguments: [String: Any] = [:]) async {
        do { _ = try await call(name, arguments: arguments) }
        catch {
            if name == "load" || name == "rebuild" { loading = false }
            self.error = error.localizedDescription
        }
    }
    private func trusted(_ url: URL?) -> Bool {
        guard let url, let baseURL else { return false }
        return url.scheme == baseURL.scheme && url.host == baseURL.host && url.port == baseURL.port
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, trusted(message.frameInfo.request.url), let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "ready": Task { await action("load", arguments: ["text": initialText]) }
        case "loaded": loading = false; loaded = true; mismatch = nil
        case "mismatch": loading = false; loaded = false; mismatch = body["message"] as? String
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
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loaded = false; loading = false; error = "画布进程已暂停，请重新载入。已保存的修改仍在手机中。" }
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
