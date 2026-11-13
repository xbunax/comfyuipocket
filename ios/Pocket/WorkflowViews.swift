import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import AVFoundation
import CoreMedia
import QuickLook
import QuickLookThumbnailing

private struct WorkflowGroup: Identifiable {
    let id: String
    let title: String
    let items: [Workflow]
}

struct LibraryView: View {
    @Environment(PocketStore.self) private var store
    @State private var importing = false
    @State private var search = ""
    @State private var showPrompts = false
    @AppStorage("collapsedWorkflowGroups") private var collapsedGroupsRaw = ""
    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackground()
                if store.workflows.isEmpty {
                    ContentUnavailableView {
                        Label("把灵感装进口袋", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("连接电脑后，服务端与手机上的工作流会自动双向同步；也可以导入 API 格式 JSON。参数将整理成适合手机的操作面板。")
                    } actions: {
                        Button("导入工作流", systemImage: "square.and.arrow.down") { importing = true }.buttonStyle(.glassProminent)
                        Button("提示词库", systemImage: "text.book.closed") { showPrompts = true }.buttonStyle(.glass)
                    }
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 14) {
                                PocketConnectionSummary()
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 8) { libraryMetrics }
                                    VStack(alignment: .leading, spacing: 8) { libraryMetrics }
                                }
                            }.padding(.vertical, 4)
                        }
                        if searchText.isEmpty {
                            if !pinned.isEmpty {
                                Section("置顶") {
                                    ForEach(pinned) { workflow in row(for: workflow) }
                                }
                            }
                            ForEach(groups) { group in
                                Section {
                                    if !isCollapsed(group.id) {
                                        ForEach(group.items) { workflow in row(for: workflow) }
                                    }
                                } header: {
                                    Button {
                                        withAnimation(.snappy) { toggleGroup(group.id) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text(group.title).textCase(nil)
                                            Text("\(group.items.count)").font(.caption).foregroundStyle(.secondary)
                                            Spacer()
                                            Image(systemName: isCollapsed(group.id) ? "chevron.right" : "chevron.down")
                                                .font(.caption2)
                                        }
                                        .contentShape(Rectangle())
                                        .foregroundStyle(.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            Section("搜索结果") {
                                if searchResults.isEmpty {
                                    Text("没有匹配的工作流。").foregroundStyle(.secondary)
                                } else {
                                    ForEach(searchResults) { workflow in row(for: workflow) }
                                }
                            }
                        }
                    }.pocketListSurface()
                }
            }
            .navigationTitle("工作台")
            .searchable(text: $search, prompt: "搜索工作流")
            .navigationDestination(for: String.self) { WorkflowEditor(id: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("提示词库", systemImage: "text.book.closed") { showPrompts = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导入 API JSON", systemImage: "doc.badge.plus") { importing = true }
                        Button("提示词库", systemImage: "text.book.closed") { showPrompts = true }
                    } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): store.importFile(url); case .failure(let error): store.error = error.localizedDescription }
            }
            .sheet(isPresented: $showPrompts) { PromptLibraryView() }
            .refreshable { await store.syncNow() }
        }
    }

    @ViewBuilder private var libraryMetrics: some View {
        PocketMetric(title: "工作流", value: store.workflows.count, icon: "square.stack.3d.up")
        PocketMetric(title: "置顶", value: pinned.count, icon: "pin")
    }

    private var searchText: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filtered: [Workflow] {
        guard !searchText.isEmpty else { return store.workflows }
        return store.workflows.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var pinned: [Workflow] {
        let lookup = Dictionary(uniqueKeysWithValues: store.workflows.map { ($0.id, $0) })
        return store.pinnedWorkflows.compactMap { lookup[$0] }
    }

    private var unpinned: [Workflow] {
        let pinnedIDs = Set(pinned.map(\.id))
        return filtered.filter { !pinnedIDs.contains($0.id) }
    }

    private var groups: [WorkflowGroup] {
        let grouped = Dictionary(grouping: unpinned) { $0.groupName.lowercased() }
        return grouped.map { key, items in
            WorkflowGroup(id: key, title: items.first?.groupName ?? key,
                          items: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var searchResults: [Workflow] {
        filtered.sorted { a, b in
            let pinnedA = store.isPinned(a.id), pinnedB = store.isPinned(b.id)
            if pinnedA != pinnedB { return pinnedA }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsRaw.split(separator: "\n").map(String.init))
    }
    private func isCollapsed(_ id: String) -> Bool { collapsedGroups.contains(id) }
    private func toggleGroup(_ id: String) {
        var values = collapsedGroups
        if values.contains(id) { values.remove(id) } else { values.insert(id) }
        collapsedGroupsRaw = values.sorted().joined(separator: "\n")
    }

    @ViewBuilder private func row(for workflow: Workflow) -> some View {
        HStack {
            NavigationLink(value: workflow.id) {
                WorkflowRow(workflow: workflow)
            }.accessibilityIdentifier("workflow.\(workflow.id)")
            Button { store.togglePinned(workflow.id) } label: {
                Image(systemName: store.isPinned(workflow.id) ? "pin.fill" : "pin")
                    .foregroundStyle(store.isPinned(workflow.id) ? Color.orange : Color.secondary)
            }.buttonStyle(.borderless)
                .accessibilityIdentifier("pin.\(workflow.id)")
                .accessibilityLabel(store.isPinned(workflow.id) ? "取消置顶 \(workflow.name)" : "置顶 \(workflow.name)")
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.togglePinned(workflow.id)
            } label: {
                Label(store.isPinned(workflow.id) ? "取消置顶" : "置顶",
                      systemImage: store.isPinned(workflow.id) ? "pin.slash" : "pin")
            }.tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) { store.delete(workflow.id) }
            Button("复制") { store.duplicate(workflow) }.tint(.blue)
        }
        .contextMenu {
            Button(store.isPinned(workflow.id) ? "取消置顶" : "置顶", systemImage: "pin") { store.togglePinned(workflow.id) }
            Button("复制", systemImage: "doc.on.doc") { store.duplicate(workflow) }
        }
    }
}

private struct WorkflowRow: View {
    let workflow: Workflow
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title3).foregroundStyle(PocketPalette.accent)
                .frame(width: 42, height: 42)
                .background(PocketPalette.accent.opacity(0.09), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(workflow.name).font(.headline).lineLimit(2)
                Text("\(workflow.prompt.count) 个节点 · \(workflow.fields.count) 项参数")
                    .font(.caption).foregroundStyle(.secondary)
                if let prompt = workflow.fields.first(where: { $0.key == "text" }), !prompt.value.text.isEmpty {
                    Text(prompt.value.text).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 8)
    }
}

struct WorkflowEditor: View {
    @Environment(PocketStore.self) private var store
    let id: String
    @State private var showGraph = false
    @State private var showCanvas = false
    @State private var arranging = false
    @State private var exporting = false
    @State private var document = WorkflowDocument(data: Data())
    @State private var randomizeBatchSeeds = true
    @State private var batchCount = 1
    @State private var showBatchSettings = false
    @State private var selectedOutput: OutputImage?
    private var index: Int? { store.workflows.firstIndex { $0.id == id } }
    var body: some View {
        Group {
            if let index {
                let workflow = store.workflows[index]
                let outputs = store.images(forWorkflow: id)
                List {
                    Section {
                        TextField("工作流名称", text: Binding(get: { store.workflows[index].name }, set: { store.workflows[index].name = $0; store.save(); store.touch(id) }))
                            .font(.title3.bold())
                        HStack {
                            Button("画布视图", systemImage: "square.3.layers.3d") { showCanvas = true }
                                .accessibilityIdentifier("workflowCanvasButton")
                            Spacer()
                            Button(store.isPinned(id) ? "取消置顶" : "置顶工作流", systemImage: store.isPinned(id) ? "pin.fill" : "pin") {
                                store.togglePinned(id)
                            }
                        }.font(.caption).buttonStyle(.borderless)
                        Text("\(workflow.prompt.count) 个节点 · \(workflow.fields.count) 项参数")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if arranging {
                        Section("拖动调整参数顺序") {
                            ForEach(workflow.fields) { field in
                                Label("\(field.nodeTitle) · \(field.key)", systemImage: "slider.horizontal.3")
                            }.onMove { source, destination in
                                var order = workflow.fields.map(\.id); order.move(fromOffsets: source, toOffset: destination)
                                store.workflows[index].pinned = order; store.save(); store.touch(id)
                            }
                        }.environment(\.editMode, .constant(.active))
                    } else {
                        WorkflowParameters(workflow: workflow)
                        if store.latestTask(for: id) != nil || !store.latestPromptIDs(for: id).isEmpty {
                            Section("最新任务生成结果") {
                                if store.isActivePrompt(for: id), let data = store.preview, let image = UIImage(data: data) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("实时预览").font(.caption).foregroundStyle(.secondary)
                                        Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16))
                                    }.padding(.vertical, 4)
                                }
                                if outputs.isEmpty {
                                    Text(store.hasQueuedPrompt(for: id) ? "正在生成，完成后会显示在这里。" : "暂无生成结果。")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(outputs) { output in
                                                Button { selectedOutput = output } label: {
                                                    VStack(alignment: .leading, spacing: 6) {
                                                        RemoteImage(output: output)
                                                            .frame(width: 150, height: 170)
                                                            .clipped()
                                                            .clipShape(.rect(cornerRadius: 16))
                                                        Text(output.filename)
                                                            .font(.caption2).lineLimit(1)
                                                            .frame(width: 150, alignment: .leading)
                                                    }
                                                }.buttonStyle(.plain)
                                            }
                                        }.padding(.vertical, 4)
                                    }
                                    .sheet(item: $selectedOutput) { ImageDetail(output: $0) }
                                }
                            }
                        }
                    }
                }
                .pocketListSurface()
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        ConnectionBadge()
                        HStack(spacing: 12) {
                            Button { showBatchSettings = true } label: {
                                Label(batchCount > 1 ? "批量 ×\(batchCount)" : "批量", systemImage: "square.stack.3d.up")
                                    .padding(.vertical, 5)
                            }.buttonStyle(.glass).disabled(store.busy)
                            Button {
                                Task { await store.submit(store.workflows[index], count: batchCount, randomizeSeeds: randomizeBatchSeeds) }
                            } label: {
                                Label(store.busy ? "提交中" : (batchCount > 1 ? "运行 ×\(batchCount)" : "运行"), systemImage: "play.fill")
                                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                            }.buttonStyle(.glassProminent).disabled(!store.connected || store.busy)
                        }
                    }.padding(16).glassEffect(in: .rect(cornerRadius: 24)).padding(.horizontal, 16).padding(.bottom, 6)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(arranging ? "完成排列" : "排列参数", systemImage: "arrow.up.arrow.down") { arranging.toggle() }
                            Button("节点依赖", systemImage: "point.3.connected.trianglepath.dotted") { showGraph = true }
                            Button("画布视图", systemImage: "square.3.layers.3d") { showCanvas = true }
                            Button("导出工作流", systemImage: "square.and.arrow.up") {
                                do { document = WorkflowDocument(data: try JSONEncoder().encode(workflow)); exporting = true }
                                catch { store.error = error.localizedDescription }
                            }
                        } label: { Image(systemName: "ellipsis") }
                    }
                }
                .sheet(isPresented: $showGraph) { GraphView(workflow: workflow) }
                .sheet(isPresented: $showCanvas) { WorkflowCanvasView(workflow: workflow) }
                .sheet(isPresented: $showBatchSettings) { BatchSettingsView(count: $batchCount, randomizeSeeds: $randomizeBatchSeeds) }
                .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: workflow.name) { result in
                    if case .failure(let error) = result { store.error = error.localizedDescription }
                }
            } else { ContentUnavailableView("工作流已删除", systemImage: "doc") }
        }
        .navigationTitle("创作").navigationBarTitleDisplayMode(.inline)
    }
}

private struct BatchSettingsView: View {
    @Binding var count: Int
    @Binding var randomizeSeeds: Bool
    @ScaledMetric(relativeTo: .body) private var sheetHeight: CGFloat = 240
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("批量次数").font(.headline)
                Spacer()
                Text("\(count) 次").font(.title3.bold().monospacedDigit())
                    .foregroundStyle(PocketPalette.accent)
            }
            Slider(value: Binding(get: { Double(count) }, set: { count = Int($0.rounded()) }), in: 1...20, step: 1)
                .accessibilityLabel("批量生成次数").accessibilityValue("\(count) 次")
            HStack { Text("1"); Spacer(); Text("20") }.font(.caption).foregroundStyle(.secondary)
            Toggle("后续生成随机种子", isOn: $randomizeSeeds)
                .font(.subheadline).accessibilityIdentifier("batchRandomizeSeeds")
        }.padding(24)
            .presentationDetents([.height(sheetHeight)])
            .presentationDragIndicator(.visible)
    }
}

struct ParameterEditor: View {
    @Environment(PocketStore.self) private var store
    let field: WorkflowField
    let schema: JSONValue
    var preferenceKey: String = "default"
    @Binding var value: JSONValue
    @State private var numericDraft = ""
    private var descriptor: [JSONValue] {
        (schema["input"]["required"].object[field.key] ?? schema["input"]["optional"].object[field.key] ?? .null).array
    }
    private var isPromptField: Bool {
        let key = field.key.lowercased()
        return key == "text" || key.contains("prompt")
    }
    private var choices: [JSONValue] { InputSchema.choices(descriptor) }
    private var mediaKind: MediaKind? {
        if let detected = MediaFile.kind(for: field) { return detected }
        guard case .string = value, descriptor.count > 1 else { return nil }
        if descriptor[1]["image_upload"] == .bool(true) { return .image }
        if descriptor[1]["video_upload"] == .bool(true) { return .video }
        if descriptor[1]["audio_upload"] == .bool(true) { return .file }
        return nil
    }
    var body: some View {
        Group {
            if case .bool(let current) = value {
                Toggle(field.key, isOn: Binding(get: { current }, set: { value = .bool($0) }))
            } else if let mediaKind {
                MediaFieldEditor(value: $value, kind: mediaKind, choices: choices.map(\.text))
            } else if !choices.isEmpty {
                Picker(field.key, selection: Binding(get: { value.text }, set: { text in value = choices.first(where: { $0.text == text }) ?? .string(text) })) {
                    if !choices.map(\.text).contains(value.text) { Text(value.text).tag(value.text) }
                    ForEach(choices.map(\.text), id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
            } else if case .string = value {
                if isPromptField {
                    PromptInputEditor(text: Binding(get: { value.text }, set: { value = .string($0) }),
                                      preferenceKey: preferenceKey + "." + field.id,
                                      context: "\(field.nodeTitle) · \(field.key)")
                } else {
                    TextField(field.key, text: Binding(get: { value.text }, set: { value = .string($0) }), axis: .vertical)
                        .lineLimit(field.priority == 0 ? 4...12 : 1...5)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } else {
                HStack {
                    TextField(field.key, text: $numericDraft)
                        .keyboardType(.numbersAndPunctuation).monospacedDigit()
                        .onAppear { numericDraft = value.text }
                        .onChange(of: value) { _, newValue in if Double(numericDraft) != newValue.double { numericDraft = newValue.text } }
                        .onChange(of: numericDraft) { _, text in
                            let next: JSONValue?
                            if case .integer = value { next = Int64(text).map(JSONValue.integer) ?? UInt64(text).map(JSONValue.unsigned) }
                            else if case .unsigned = value { next = UInt64(text).map(JSONValue.unsigned) }
                            else { next = Double(text).flatMap { $0.isFinite ? .number($0) : nil } }
                            if let next {
                                let config = descriptor.count > 1 ? descriptor[1] : .null
                                if config.object["min"] != nil && next.double < config["min"].double { return }
                                if config.object["max"] != nil && next.double > config["max"].double { return }
                                value = next
                            }
                        }
                    if field.key.contains("seed") {
                        Button { value = .integer(Int64.random(in: 0...Int64(UInt32.max))); numericDraft = value.text } label: { Image(systemName: "dice") }
                            .accessibilityLabel("随机种子")
                    }
                }
                if numericDraft != value.text && Double(numericDraft) != Double(value.text) {
                    Text("输入无效或超出范围；运行时仍使用 \(value.text)。").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

struct WorkPicker: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let kind: MediaKind
    let onSelect: (OutputImage) -> Void
    private var filtered: [OutputImage] {
        store.images.filter { kind == .file || (kind == .video ? $0.isVideo : !$0.isVideo) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                if filtered.isEmpty {
                    ContentUnavailableView("没有可用的作品", systemImage: "photo.on.rectangle.angled",
                                           description: Text("先生成图片或视频，再从这里选择。"))
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { output in
                            Button {
                                onSelect(output)
                                dismiss()
                            } label: {
                                VStack(spacing: 6) {
                                    RemoteImage(output: output)
                                        .frame(height: 120)
                                        .clipped()
                                        .clipShape(.rect(cornerRadius: 14))
                                    Text(output.filename).font(.caption2).lineLimit(1)
                                }
                            }.buttonStyle(.plain)
                        }
                    }.padding()
                }
            }
            .navigationTitle(kind == .video ? "选择作品视频" : "选择作品图片")
            .toolbar { Button("取消") { dismiss() } }
        }
    }
}

struct GraphView: View {
    let workflow: Workflow
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(workflow.prompt.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { id in
                let node = workflow.prompt[id]!
                VStack(alignment: .leading, spacing: 8) {
                    Text("#\(id)  \(node["_meta"]["title"].text.nonEmpty ?? node["class_type"].text)").font(.headline)
                    Text(node["class_type"].text).font(.caption).foregroundStyle(.secondary)
                    ForEach(node["inputs"].object.keys.sorted(), id: \.self) { key in
                        let input = node["inputs"][key]
                        if input.array.count == 2, case .string(let source) = input.array[0] {
                            Label("#\(source) → \(key)", systemImage: "arrow.turn.down.right").font(.subheadline.monospaced())
                        }
                    }
                }.padding(.vertical, 6)
            }.navigationTitle("节点依赖").toolbar { Button("完成") { dismiss() } }
        }
    }
}

struct WorkflowDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
