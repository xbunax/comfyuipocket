import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct WorkflowCanvasHost: View {
    @Environment(PocketStore.self) private var store
    var onFinish: (() -> Void)? = nil
    var onShowParameters: ((String) -> Void)? = nil
    @State private var selectedID: String
    init(workflowID: String, onFinish: (() -> Void)? = nil, onShowParameters: ((String) -> Void)? = nil) {
        _selectedID = State(initialValue: workflowID); self.onFinish = onFinish; self.onShowParameters = onShowParameters
    }
    var body: some View {
        Group {
            if let api = store.client {
                WorkflowCanvasView(workflowID: selectedID,
                    session: store.canvasSessions.session(baseURL: api.baseURL, workflowID: selectedID, serverID: api.serverID),
                    selectWorkflow: { selectedID = $0 }, onFinish: onFinish,
                    onShowParameters: onShowParameters.map { action in { action(selectedID) } })
                    .id(CanvasCacheKey(baseURL: api.baseURL, workflowID: selectedID, serverID: api.serverID))
            } else {
                WorkflowCanvasView(workflowID: selectedID, session: CanvasSession(), selectWorkflow: { selectedID = $0 },
                    onFinish: onFinish, onShowParameters: onShowParameters.map { action in { action(selectedID) } })
            }
        }
        .workspaceLayoutReader()
    }
}

struct WorkflowCanvasView: View {
    let workflowID: String
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceLayout) private var layout
    let session: CanvasSession
    let selectWorkflow: (String) -> Void
    var onFinish: (() -> Void)? = nil
    var onShowParameters: (() -> Void)? = nil
    @State private var canvasSize = CGSize.zero
    @State private var wheelExpanded = false
    @State private var inspectorVisible = true
    @State private var showWorkflows = false
    @State private var showHardware = false
    @State private var hardware = ServerHardware()
    @State private var submitting = false
    @State private var submissionStatus: String?
    @State private var latestPromptID: String?
    @State private var latestTaskID: String?
    @State private var showBatch = false
    @State private var batchCount = 1
    @State private var randomizeBatchSeeds = false
    @State private var showMismatch = false
    @State private var showNodes = false
    @State private var showPorts = false
    @State private var showBookmarks = false
    @State private var showAssets = false
    @State private var importingAsset = false
    @State private var targetedForAsset = false
    @State private var draggingAsset = false
    @State private var selectedAsset: CanvasAssetDrag?
    @State private var assetMessage: String?
    @State private var showSettings = false
    @State private var working = false
    @State private var exporting = false
    @State private var exportDocument = WorkflowDocument(data: Data())
    private var workflow: Workflow? { store.workflows.first { $0.id == workflowID } }
    private var usesAssetSidebar: Bool { UIDevice.current.userInterfaceIdiom == .pad || layout.usesColumns }
    private var canRun: Bool {
        session.loaded && !session.mutating && !submitting && !store.busy && store.connected &&
            !store.restoringConnection && store.connectionRecoveryError == nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.connected, let api = store.client, let workflow {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if showAssets && !usesAssetSidebar && !session.textEditing {
                                assetPanel(horizontal: true).padding(.horizontal, 8).padding(.bottom, 5)
                            }
                            canvasSurface
                        }
                        if showAssets && usesAssetSidebar && !session.textEditing {
                            assetPanel(horizontal: false)
                                .frame(width: layout.usesColumns ? 244 : min(170, max(112, layout.width * 0.42)))
                                .padding(.vertical, 5).padding(.trailing, 5)
                        } else if layout.showsCanvasInspector && inspectorVisible && !session.textEditing {
                            CanvasNodeNavigator(session: session, openBookmarks: { showBookmarks = true })
                                .frame(width: 264).pocketGlassPanel()
                                .padding(.vertical, 8).padding(.horizontal, 12)
                        }
                    }
                    .background(PocketPalette.background)
                    .task(id: api.baseURL) {
                        store.rememberOpened(workflowID)
                        store.canvasEditingID = workflowID
                        store.canvasEditingSession = session
                        store.canvasSessions.attach(session)
                        session.open(workflow: workflow, baseURL: api.baseURL)
                        await session.applyAppearance()
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            if session.loaded, !session.textEditing, !submitting, !working, !session.mutating {
                                await session.refreshScene(); _ = await save()
                            }
                        }
                    }
                    .task(id: api.baseURL) { await pollHardware(api) }
                } else {
                    ContentUnavailableView("连接服务器后编辑画布", systemImage: "network",
                        description: Text("完整编辑器直接连接你的 ComfyUI，支持节点、连线、子图与自定义控件。"))
                }
            }
            .navigationTitle(workflow?.name ?? "工作流画布").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .background(PocketBackground())
            .toolbar(.hidden, for: .navigationBar)
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
                    }.padding(12).background(PocketPalette.surface)
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
            .sheet(isPresented: $showBookmarks) {
                CanvasBookmarkSheet(session: session)
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    AppSettingsView().toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } }
                    }
                }
            }
            .sheet(isPresented: $showHardware) { CanvasHardwareDetails(hardware: hardware, server: store.client?.displayAddress ?? "") }
            .sheet(isPresented: $showBatch) {
                BatchSettingsView(count: $batchCount, randomizeSeeds: $randomizeBatchSeeds) {
                    Task { await run(count: batchCount, seeds: randomizeBatchSeeds ? .everyRun : .preserve) }
                }
            }
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
            .edgeSwipeBack(enabled: !working && !submitting, preferSystem: false) {
                Task {
                    if session.loaded { guard await saveForAction() else { return } }
                    finish()
                }
            }
            .onChange(of: store.error) { _, message in
                if let message, store.canvasEditingSession === session { session.error = message; store.error = nil }
            }
            .onChange(of: PocketAppearance.shared.replacesNodeStyle) { _, _ in Task { await session.applyAppearance() } }
            .onChange(of: PocketAppearance.shared.overviewTapFocus) { _, _ in Task { await session.applyAppearance() } }
            .onChange(of: PocketAppearance.shared.colorway) { _, _ in Task { await session.applyAppearance() } }
            .onChange(of: session.available) { _, available in if available { Task { await session.applyAppearance() } } }
            .onDisappear {
                if store.canvasEditingSession === session { store.canvasEditingID = nil; store.canvasEditingSession = nil }
                store.canvasSessions.detach(session)
                Task { await store.syncNow() }
            }
        }
    }
    private var canvasSurface: some View {
        ZStack {
            CanvasWebView(session: session)
                .allowsHitTesting(session.loaded)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
                .overlay {
                    CanvasAssetTarget(targeted: { targetedForAsset = $0 }, dropped: receiveAsset) { point in
                        if let selectedAsset, !draggingAsset { receiveAsset(selectedAsset, point) }
                    }
                    .allowsHitTesting(showAssets && (draggingAsset || selectedAsset != nil || importingAsset))
                    if targetedForAsset || selectedAsset != nil {
                        Rectangle().strokeBorder(PocketPalette.accent, lineWidth: targetedForAsset ? 2 : 1)
                            .allowsHitTesting(false)
                    }
                }
                .task(id: canvasSize) {
                    do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation() }
                    catch { return }
                    await session.refitViewport(size: canvasSize)
                }
            if session.loading {
                ProgressView(session.loadingMessage).padding(20).background(PocketPalette.surface, in: .rect(cornerRadius: 18))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
    }
    private func assetPanel(horizontal: Bool) -> some View {
        CanvasAssetSidebar(horizontal: horizontal, close: toggleAssetPanel, message: assetMessage, importing: importingAsset,
                           selected: selectedAsset, select: selectAsset, dragBegan: {
            draggingAsset = true
            selectedAsset = nil
            assetMessage = "拖到目标节点后松手。"
        }, dragEnded: { dropped in
            draggingAsset = false
            targetedForAsset = false
            if !dropped && !importingAsset { assetMessage = "未放到画布上。可点选素材，再点目标节点。" }
        }, cancelSelection: clearAssetSelection)
        .pocketGlassPanel()
    }
    private func toggleAssetPanel() {
        showAssets.toggle()
        if !showAssets { clearAssetSelection() }
    }
    private func selectAsset(_ asset: CanvasAssetDrag) {
        guard !importingAsset else { return }
        selectedAsset = selectedAsset == asset ? nil : asset
        assetMessage = nil
    }
    private func clearAssetSelection() {
        selectedAsset = nil
        assetMessage = nil
    }
    private func finish() { if let onFinish { onFinish() } else { dismiss() } }
    private var canvasMenu: some View {
                    Menu {
                        if let onShowParameters {
                            Button("参数面板", systemImage: "slider.horizontal.3") {
                                Task {
                                    if session.loaded { guard await saveForAction() else { return } }
                                    onShowParameters()
                                }
                            }
                        }
                        Button("设置", systemImage: "gearshape") { showSettings = true }
                        Button("批量运行", systemImage: "square.stack.3d.up") { showBatch = true }.disabled(!canRun)
                        Button("切换工作流", systemImage: "square.stack") { showWorkflows = true }
                        Group {
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
                        }.disabled(!session.available)
                    } label: { headerIcon("ellipsis") }.disabled(submitting).buttonStyle(.plain).accessibilityLabel("画布菜单")
    }
    private func headerIcon(_ name: String, prominent: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? .black : PocketPalette.text)
            .frame(width: 34, height: 34)
            .glassEffect(.regular.tint(prominent ? PocketPalette.accent : nil).interactive(), in: .rect(cornerRadius: 11))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
    private var header: some View {
        GlassEffectContainer(spacing: 4) {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Button {
                        Task {
                            if !session.loaded { finish(); return }
                            if await saveForAction() { finish() }
                        }
                    } label: { headerIcon("chevron.left") }
                        .buttonStyle(.plain).disabled(working || submitting).accessibilityLabel("返回工作台")
                    Button { showWorkflows = true } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(workflow?.name ?? "工作流画布").font(.headline).lineLimit(1)
                                Image(systemName: "chevron.down").font(.caption2)
                            }.foregroundStyle(PocketPalette.text)
                            HStack(spacing: 4) {
                                Circle().fill(store.connected ? Color.green : Color.secondary).frame(width: 5, height: 5)
                                Text(runStatus ?? (working ? "保存中…" : session.saveStatus)).lineLimit(1)
                            }.font(.caption2).foregroundStyle(PocketPalette.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("切换工作流")
                        .disabled(submitting || working)
                    Button(action: toggleAssetPanel) { headerIcon("photo.on.rectangle.angled", prominent: showAssets) }
                        .buttonStyle(.plain).disabled(!session.loaded || session.textEditing)
                        .accessibilityLabel(showAssets ? "关闭资产面板" : "打开资产面板")
                        .accessibilityIdentifier("canvas.assets")
                    canvasMenu
                    Button { Task { await run() } } label: {
                        if submitting { ProgressView().controlSize(.small).frame(width: 44, height: 44) }
                        else { headerIcon("play.fill", prominent: true) }
                    }.buttonStyle(CanvasRunButtonStyle(openBatch: { if canRun { showBatch = true } }))
                        .disabled(!canRun)
                        .accessibilityLabel("运行当前画布").accessibilityIdentifier("canvas.run")
                        .accessibilityHint("长按选择批量次数")
                        .accessibilityAction(named: Text("批量运行")) { if canRun { showBatch = true } }
                        .keyboardShortcut(.return, modifiers: .command)
                }
                if !session.textEditing {
                    Button { showHardware = true } label: { CanvasHardwareBar(hardware: hardware) }
                        .buttonStyle(.plain)
                }
            }.padding(.horizontal, 9).padding(.vertical, 2)
        }
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
                if wheelExpanded, session.available, !layout.showsCanvasInspector { CanvasNodeWheel(session: session, compact: true) }
                HStack(spacing: 10) {
                    Button {
                        session.nodeFocusActive = false
                        Task { await session.action("fit") }
                    } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }
                        .accessibilityLabel("工作流总览").disabled(!session.available)
                    if layout.showsCanvasInspector {
                        zoomButton("minus.magnifyingglass", "缩小画布", factor: 1 / 1.25)
                        zoomButton("plus.magnifyingglass", "放大画布", factor: 1.25)
                    }
                    Button {
                        if layout.showsCanvasInspector { inspectorVisible.toggle() }
                        else { wheelExpanded.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            if !session.focusedNodeID.isEmpty {
                                Text("#\(session.focusedNodeID)").font(.caption.monospacedDigit()).foregroundStyle(PocketPalette.secondary)
                            }
                            Text(session.scene.nodes.first { $0.id == session.focusedNodeID }?.title ?? "选择节点")
                                .font(.subheadline.weight(.medium)).lineLimit(1)
                            Image(systemName: wheelExpanded ? "chevron.down" : "chevron.up").font(.caption2)
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(!session.available).accessibilityLabel("展开或收起节点轮盘")
                    Button { showBookmarks = true } label: {
                        Image(systemName: "star").frame(width: 44, height: 44)
                    }.accessibilityLabel("收藏节点与快速定位").accessibilityIdentifier("canvas.bookmarks")
                        .disabled(!session.available)
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
                    } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                        .accessibilityLabel("画布工具").disabled(!session.loaded || submitting)
                }.buttonStyle(.borderless).padding(.horizontal, 8)
            }
        }.pocketGlassPanel().padding(.horizontal, 12).padding(.vertical, 4)
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
        if submitting { return submissionStatus }
        if let taskID = latestTaskID, let task = store.currentGenerationTasks.first(where: { $0.id == taskID }),
           task.requestedCount > 1 {
            let summary = task.summary(queue: store.queue, history: store.history)
            let count = "\(summary.finished)/\(task.requestedCount)"
            if summary.running > 0 { return "批量生成中 · \(count)" }
            if summary.pending > 0 { return "批量已排队 · \(count)" }
            if summary.finished == task.items.count && summary.finished > 0 {
                return summary.completed == task.requestedCount ? "批量完成 · \(count)" : "批量已结束 · \(summary.completed) 次成功"
            }
            return submissionStatus
        }
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
    private func run(count: Int = 1, seeds: BatchSeedMode = .preserve) async {
        guard canRun else { return }
        submitting = true; submissionStatus = "正在保存并提交…"
        latestPromptID = nil; latestTaskID = nil
        defer { submitting = false }
        guard await saveForAction(), let workflow = self.workflow else { submissionStatus = "提交未完成"; return }
        let result = await store.enqueue(workflow, count: count, seeds: seeds)
        if let error = result.error { session.error = error }
        if let id = result.promptIDs.first {
            latestPromptID = id; latestTaskID = result.taskID
            submissionStatus = count > 1 ? "已提交 \(result.promptIDs.count)/\(count) 次生成" : "已排队 · \(id.prefix(8))"
        }
        else { submissionStatus = "提交失败" }
    }
    private func zoomButton(_ icon: String, _ title: String, factor: Double) -> some View {
        Button {
            session.nodeFocusActive = false
            Task { await session.action("zoom", arguments: ["factor": factor]) }
        } label: { Image(systemName: icon).frame(width: 44, height: 44) }
            .accessibilityLabel(title).disabled(!session.available)
    }
    private func command(_ name: String) { Task { await session.action("command", arguments: ["name": name]) } }
    private func receiveAsset(_ drag: CanvasAssetDrag, _ point: CGPoint) {
        guard !importingAsset else { return }
        guard !submitting, session.loaded, !session.mutating, !session.textEditing else {
            assetMessage = "请在画布完成当前编辑后再添加素材。"
            return
        }
        importingAsset = true
        session.mutating = true
        Task {
            defer { importingAsset = false; session.mutating = false }
            do {
                let deadline = Date().addingTimeInterval(3)
                while working {
                    guard Date() < deadline else { throw PocketError.message("画布正在保存，请稍后再添加。") }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard let api = store.client, store.canvasEditingSession === session
                else { throw PocketError.message("资产或画布已不可用。") }
                guard drag.serverID == api.serverID else { throw PocketError.message("请在同一服务器的画布中导入资产。") }
                let asset = drag.asset, token = UUID().uuidString
                let target = try await session.call("prepareAsset", arguments: ["x": point.x, "y": point.y, "token": token, "asset": [
                    "filename": asset.filename, "subfolder": asset.portableSubfolder, "type": asset.type,
                    "media_kind": asset.isVideo ? "video" : "image"
                ]]) as? String
                if target == "reference" {
                    assetMessage = "已交给节点处理，请查看节点内的结果。"
                } else {
                    if target == "input" {
                        guard store.pluginCapabilities.contains("canvas-assets") else {
                            throw PocketError.message("更新电脑端 Pocket 插件后可导入。")
                        }
                        let value = try await api.importAsset(asset)
                        guard store.client === api, store.canvasEditingSession === session else {
                            throw PocketError.message("画布已切换，请重新拖放。")
                        }
                        _ = try await session.call("importAsset", arguments: ["token": token, "value": value])
                    } else if target != "reference-added" {
                        throw PocketError.message("资产未添加，请拖到支持此文件的输入区。")
                    }
                    await session.refreshScene()
                    session.mutating = false
                    assetMessage = await save() ? "已导入 \(asset.filename)" : "已添加 \(asset.filename)，画布尚未保存。"
                }
                selectedAsset = nil
            } catch {
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                assetMessage = message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
                if store.canvasEditingSession === session { await session.focusSelection() }
            }
        }
    }
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

private struct CanvasRunButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var enabled
    let openBatch: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .gesture(LongPressGesture(minimumDuration: 0.45).exclusively(before: TapGesture()).onEnded { result in
                guard enabled else { return }
                switch result {
                case .first: openBatch()
                case .second: configuration.trigger()
                }
            })
            .accessibilityAction { if enabled { configuration.trigger() } }
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
            "prepareAsset": "return window.PocketCanvas.prepareAsset(x, y, asset, token);",
            "importAsset": "return await window.PocketCanvas.importAsset(token, value);",
            "overviewPreference": "return window.PocketCanvas.overviewPreference(enabled);",
            "nodeAppearance": "return window.PocketCanvas.nodeAppearance(enabled, palette);",
            "stepParameter": "return await window.PocketCanvas.stepParameter(id, type, name, direction, path);",
            "widget": "return await window.PocketCanvas.widget(id, index, value, name);",
            "moveNode": "return window.PocketCanvas.moveNode(id, x, y);",
            "removeNode": "return window.PocketCanvas.removeNode(id);",
            "groupMode": "return window.PocketCanvas.groupMode(id, mode);",
            "nodeMode": "return window.PocketCanvas.nodeMode(id, mode);",
            "focus": "return window.PocketCanvas.focus(id);",
            "focusBookmark": "return window.PocketCanvas.focusBookmark(path, id, type);",
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
        let readOnlyMethods: Set<String> = ["load", "rebuild", "scene", "focus", "focusBookmark", "fit", "zoom", "ports", "library", "subgraph", "viewport", "finishText", "chrome", "tools", "nodeAppearance", "overviewPreference"]
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
    func location(for node: MobileCanvasNode) -> CanvasNodeLocation? {
        guard let path = scene.graphPath else { return nil }
        return CanvasNodeLocation(path: path, nodeID: node.id, type: node.type, title: node.title)
    }
    func focusBookmark(_ location: CanvasNodeLocation) async -> Bool {
        guard available, !textEditing else { return false }
        do {
            guard try await call("focusBookmark", arguments: ["path": location.path, "id": location.nodeID, "type": location.type]) as? Bool == true else { return false }
            nodeFocusActive = true; focusedNodeID = location.nodeID
            await refreshScene()
            return true
        } catch { self.error = error.localizedDescription; return false }
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
    func applyAppearance() async {
        guard available else { return }
        let appearance = PocketAppearance.shared
        // Canvas controls and custom widgets use their original dark renderer;
        // a dark community surface preserves their contrast in light app mode.
        let surface = String(format: "#%06X", appearance.colorway.tokens(dark: true).surface)
        do {
            _ = try await call("overviewPreference", arguments: ["enabled": appearance.overviewTapFocus])
            let supported = try await call("nodeAppearance", arguments: ["enabled": appearance.replacesNodeStyle, "palette": ["surface": surface]]) as? Bool
            if appearance.replacesNodeStyle && supported != true {
                error = "当前 ComfyUI 绘制器不支持主题节点底色，已保留原生样式。"
            }
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
        case "overviewFocus":
            guard available, loaded, !textEditing, let id = body["nodeID"] as? String else { return }
            focusedNodeID = id; nodeFocusActive = true
            Task { await refreshScene() }
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
