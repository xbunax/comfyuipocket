import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import AVFoundation
import CoreMedia

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
                        Section { ConnectionBadge(); SyncBadge() }.listRowBackground(Color.clear)
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
                    }.scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("工作台")
            .searchable(text: $search, prompt: "搜索工作流")
            .navigationDestination(for: String.self) { WorkflowEditor(id: $0) }
            .toolbar {
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
        NavigationLink(value: workflow.id) {
            WorkflowRow(workflow: workflow, pinned: store.isPinned(workflow.id))
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
    }
}

private struct WorkflowRow: View {
    let workflow: Workflow
    let pinned: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.mint)
                Text(workflow.name).font(.headline)
                if pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
            }
            Text("\(workflow.prompt.count) 个节点 · \(workflow.fields.count) 个可编辑参数")
                .font(.caption).foregroundStyle(.secondary)
            if let prompt = workflow.fields.first(where: { $0.key == "text" }) {
                Text(prompt.value.text).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }
}

struct WorkflowEditor: View {
    @Environment(PocketStore.self) private var store
    let id: String
    @State private var showGraph = false
    @State private var arranging = false
    @State private var exporting = false
    @State private var document = WorkflowDocument(data: Data())
    @State private var batchCount = 1
    @State private var randomizeBatchSeeds = true
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
                        Text("提示词和常用参数优先展示。点击图钉收藏；在“排列”中拖动调整顺序。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.isActivePrompt(for: id) || !outputs.isEmpty {
                        Section("生成结果") {
                            if store.isActivePrompt(for: id), let data = store.preview, let image = UIImage(data: data) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("实时预览").font(.caption).foregroundStyle(.secondary)
                                    Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16))
                                }.padding(.vertical, 4)
                            }
                            if outputs.isEmpty {
                                Text(store.isActivePrompt(for: id) ? "正在生成，完成后会显示在这里。" : "暂无生成结果。")
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
                        ForEach(workflow.fields) { field in
                            Section {
                                ParameterEditor(field: field, schema: store.nodeInfo[field.classType], value: Binding(
                                    get: { store.workflows[index].prompt[field.nodeID]?["inputs"][field.key] ?? field.value },
                                    set: { store.workflows[index].set(field, value: $0); store.save(); store.touch(id) }
                                ))
                            } header: {
                                HStack {
                                    Text("\(field.nodeTitle) · \(field.key)")
                                    Spacer()
                                    Button {
                                        if workflow.pinned.contains(field.id) { store.workflows[index].pinned.removeAll { $0 == field.id } }
                                        else { store.workflows[index].pinned.append(field.id) }
                                        store.save(); store.touch(id)
                                    } label: { Image(systemName: workflow.pinned.contains(field.id) ? "pin.fill" : "pin") }
                                        .accessibilityLabel("收藏参数 \(field.key)")
                                }
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.connected ? "准备就绪" : "先连接服务器").font(.caption.bold())
                            Text("\(workflow.prompt.count) 个节点").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Picker("任务数量", selection: $batchCount) {
                                ForEach([1, 2, 3, 4, 6, 8, 12], id: \.self) { count in
                                    Text("\(count) 个任务").tag(count)
                                }
                            }
                            Toggle("后续任务随机种子", isOn: $randomizeBatchSeeds)
                        } label: {
                            Label(batchCount > 1 ? "×\(batchCount)" : "批量", systemImage: "square.stack.3d.up")
                        }.buttonStyle(.glass).disabled(store.busy)
                        Button {
                            Task { await store.submit(store.workflows[index], count: batchCount, randomizeSeeds: randomizeBatchSeeds) }
                        } label: {
                            Label(store.busy ? "提交中" : (batchCount > 1 ? "运行 ×\(batchCount)" : "运行"), systemImage: "play.fill")
                                .padding(.horizontal, 6)
                        }.buttonStyle(.glassProminent).disabled(!store.connected || store.busy)
                    }.padding().glassEffect(in: .rect(cornerRadius: 28)).padding(.horizontal).padding(.bottom, 6)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(arranging ? "完成排列" : "排列参数", systemImage: "arrow.up.arrow.down") { arranging.toggle() }
                            Button("节点依赖", systemImage: "point.3.connected.trianglepath.dotted") { showGraph = true }
                            Button("导出工作流", systemImage: "square.and.arrow.up") {
                                do { document = WorkflowDocument(data: try JSONEncoder().encode(workflow)); exporting = true }
                                catch { store.error = error.localizedDescription }
                            }
                        } label: { Image(systemName: "ellipsis") }
                    }
                }
                .sheet(isPresented: $showGraph) { GraphView(workflow: workflow) }
                .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: workflow.name) { result in
                    if case .failure(let error) = result { store.error = error.localizedDescription }
                }
            } else { ContentUnavailableView("工作流已删除", systemImage: "doc") }
        }
        .navigationTitle("创作").navigationBarTitleDisplayMode(.inline)
    }
}

struct ParameterEditor: View {
    @Environment(PocketStore.self) private var store
    let field: WorkflowField
    let schema: JSONValue
    @Binding var value: JSONValue
    @State private var numericDraft = ""
    @State private var showPrompts = false
    private var descriptor: [JSONValue] {
        (schema["input"]["required"].object[field.key] ?? schema["input"]["optional"].object[field.key] ?? .null).array
    }
    private var isPromptField: Bool {
        let key = field.key.lowercased()
        return key == "text" || key.contains("prompt")
    }
    private var mediaKind: MediaKind? { MediaFile.kind(for: field) }
    var body: some View {
        Group {
            if case .bool(let current) = value {
                Toggle(field.key, isOn: Binding(get: { current }, set: { value = .bool($0) }))
            } else if let first = descriptor.first, case .array(let choices) = first {
                Picker(field.key, selection: Binding(get: { value.text }, set: { text in value = choices.first(where: { $0.text == text }) ?? .string(text) })) {
                    if !choices.map(\.text).contains(value.text) { Text(value.text).tag(value.text) }
                    ForEach(choices.map(\.text), id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
            } else if case .string = value {
                if let mediaKind {
                    MediaFieldEditor(kind: mediaKind, value: $value)
                } else {
                    TextField(field.key, text: Binding(get: { value.text }, set: { value = .string($0) }), axis: .vertical)
                        .lineLimit(field.priority == 0 ? 4...12 : 1...5)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if isPromptField { promptButtons }
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
    private var promptButtons: some View {
        HStack(spacing: 16) {
            Button { showPrompts = true } label: { Label("提示词库", systemImage: "text.book.closed") }
            Button { savePrompt() } label: { Label("保存提示词", systemImage: "square.and.arrow.down") }
        }
        .font(.caption)
        .sheet(isPresented: $showPrompts) {
            PromptLibraryView(insert: { value = .string($0) })
        }
    }
    private func savePrompt() {
        let text = value.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.notice = "提示词为空。"
            return
        }
        _ = store.savePrompt(title: "", text: text)
        store.notice = "已保存到提示词库。"
    }
}

struct MediaFieldEditor: View {
    @Environment(PocketStore.self) private var store
    @Binding var value: JSONValue
    let kind: MediaKind
    @State private var photo: PhotosPickerItem?
    @State private var uploading = false
    @State private var showWorks = false
    private var text: String { value.text }
    private var filename: String { MediaFile.split(text).filename }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InputMediaPreview(value: text, kind: kind)
            if !filename.isEmpty {
                Text(filename).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 12) {
                PhotosPicker(selection: $photo, matching: kind == .video ? PHPickerFilter.videos : PHPickerFilter.images) {
                    Label(uploading ? "上传中…" : (kind == .video ? "本地视频" : "本地照片"),
                          systemImage: kind == .video ? "film" : "photo.badge.plus")
                }.disabled(!store.connected || uploading)
                Button { showWorks = true } label: {
                    Label("从作品选择", systemImage: "photo.on.rectangle.angled")
                }.buttonStyle(.glass)
                    .disabled(!store.connected || uploading)
            }.font(.caption)
            if uploading { ProgressView().controlSize(.mini) }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .sheet(isPresented: $showWorks) {
            WorkPicker(kind: kind) { output in
                Task { await useWork(output) }
            }
        }
    }
    private func importPhoto(_ item: PhotosPickerItem) async {
        uploading = true; defer { uploading = false; photo = nil }
        do {
            guard let api = store.client else { throw PocketError.message("请先连接服务器。") }
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PocketError.message("无法读取所选文件。")
            }
            let filename: String
            let mime: String
            var payload = data
            if kind == .video {
                let type = item.supportedContentTypes.first
                filename = "pocket-\(UUID().uuidString).\(type?.preferredFilenameExtension ?? "mov")"
                mime = type?.preferredMIMEType ?? "video/quicktime"
            } else {
                guard let image = UIImage(data: data), let png = image.pngData() else {
                    throw PocketError.message("无法读取图片。")
                }
                payload = png
                filename = "pocket-\(UUID().uuidString).png"
                mime = "image/png"
            }
            let name = try await api.upload(payload, filename: filename, mime: mime)
            value = .string(name)
        } catch { store.error = error.localizedDescription }
    }
    private func useWork(_ output: OutputImage) async {
        uploading = true; defer { uploading = false }
        do {
            guard let api = store.client else { throw PocketError.message("请先连接服务器。") }
            let data = try await api.image(output)
            let name = try await api.upload(data, filename: output.filename, mime: output.mimeType)
            value = .string(name)
        } catch { store.error = error.localizedDescription }
    }
}

struct InputMediaPreview: View {
    @Environment(PocketStore.self) private var store
    let value: String
    let kind: MediaKind
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.08))
            if value.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: kind == .video ? "film" : "photo").font(.title2)
                    Text(kind == .video ? "尚未选择视频" : "尚未选择图片").font(.caption)
                }.foregroundStyle(.secondary)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16))
            } else if kind == .video {
                VStack(spacing: 6) {
                    Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.mint)
                    Text("视频已选择").font(.caption).foregroundStyle(.secondary)
                }
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark").font(.title2)
                    Text("预览不可用").font(.caption)
                }.foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(height: 170)
        .task(id: value) { await load() }
    }
    private func load() async {
        image = nil; failed = false
        guard !value.isEmpty, let api = store.client else { return }
        do {
            let data = try await api.inputMedia(value)
            if kind == .video {
                image = await videoThumbnail(data)
            } else if let decoded = UIImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
        } catch { failed = true }
    }
    private func videoThumbnail(_ data: Data) async -> UIImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pocket-input-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        do { try data.write(to: url) } catch { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cgImage, _, _, _ in
                if let cgImage { continuation.resume(returning: UIImage(cgImage: cgImage)) }
                else { continuation.resume(returning: nil) }
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
        store.images.filter { kind == .video ? $0.isVideo : !$0.isVideo }
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
