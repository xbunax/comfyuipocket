import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct LibraryView: View {
    @Environment(PocketStore.self) private var store
    @State private var importing = false
    @State private var search = ""
    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackground()
                if store.workflows.isEmpty {
                    ContentUnavailableView {
                        Label("把灵感装进口袋", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("连接电脑后同步工作流，或导入 API 格式 JSON。参数将自动整理成适合手机的操作面板。")
                    } actions: {
                        Button("导入工作流", systemImage: "square.and.arrow.down") { importing = true }.buttonStyle(.glassProminent)
                    }
                } else {
                    List {
                        Section { ConnectionBadge() }.listRowBackground(Color.clear)
                        ForEach(store.workflows.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { workflow in
                            NavigationLink(value: workflow.id) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack { Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.mint); Text(workflow.name).font(.headline) }
                                    Text("\(workflow.prompt.count) 个节点 · \(workflow.fields.count) 个可编辑参数")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let prompt = workflow.fields.first(where: { $0.key == "text" }) {
                                        Text(prompt.value.text).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 8)
                            }
                            .swipeActions {
                                Button("删除", role: .destructive) { store.workflows.removeAll { $0.id == workflow.id }; store.save() }
                                Button("复制") { var copy = workflow; copy.id = UUID().uuidString; copy.name += " 副本"; store.workflows.append(copy); store.save() }.tint(.blue)
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
                        Button("从电脑同步", systemImage: "arrow.triangle.2.circlepath") { Task { await store.sync() } }.disabled(!store.connected || store.busy)
                    } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): store.importFile(url); case .failure(let error): store.error = error.localizedDescription }
            }
            .refreshable { await store.sync() }
        }
    }
}

struct WorkflowEditor: View {
    @Environment(PocketStore.self) private var store
    let id: String
    @State private var showGraph = false
    @State private var arranging = false
    @State private var exporting = false
    @State private var document = WorkflowDocument(data: Data())
    private var index: Int? { store.workflows.firstIndex { $0.id == id } }
    var body: some View {
        Group {
            if let index {
                let workflow = store.workflows[index]
                List {
                    Section {
                        TextField("工作流名称", text: Binding(get: { store.workflows[index].name }, set: { store.workflows[index].name = $0; store.save() }))
                            .font(.title3.bold())
                        Text("提示词和常用参数优先展示。点击图钉收藏；在“排列”中拖动调整顺序。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if arranging {
                        Section("拖动调整参数顺序") {
                            ForEach(workflow.fields) { field in
                                Label("\(field.nodeTitle) · \(field.key)", systemImage: "slider.horizontal.3")
                            }.onMove { source, destination in
                                var order = workflow.fields.map(\.id); order.move(fromOffsets: source, toOffset: destination)
                                store.workflows[index].pinned = order; store.save()
                            }
                        }.environment(\.editMode, .constant(.active))
                    } else {
                        ForEach(workflow.fields) { field in
                            Section {
                                ParameterEditor(field: field, schema: store.nodeInfo[field.classType], value: Binding(
                                    get: { store.workflows[index].prompt[field.nodeID]?["inputs"][field.key] ?? field.value },
                                    set: { store.workflows[index].set(field, value: $0); store.save() }
                                ))
                            } header: {
                                HStack {
                                    Text("\(field.nodeTitle) · \(field.key)")
                                    Spacer()
                                    Button {
                                        if workflow.pinned.contains(field.id) { store.workflows[index].pinned.removeAll { $0 == field.id } }
                                        else { store.workflows[index].pinned.append(field.id) }
                                        store.save()
                                    } label: { Image(systemName: workflow.pinned.contains(field.id) ? "pin.fill" : "pin") }
                                        .accessibilityLabel("收藏参数 \(field.key)")
                                }
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading) {
                            Text(store.connected ? "准备就绪" : "先连接服务器").font(.caption.bold())
                            Text("\(workflow.prompt.count) 个节点").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await store.submit(store.workflows[index]) } } label: {
                            Label(store.busy ? "提交中" : "运行工作流", systemImage: "play.fill").padding(.horizontal, 8)
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
    @State private var photo: PhotosPickerItem?
    @State private var uploading = false
    @State private var numericDraft = ""
    private var descriptor: [JSONValue] {
        (schema["input"]["required"].object[field.key] ?? schema["input"]["optional"].object[field.key] ?? .null).array
    }
    var body: some View {
        Group {
            if case .bool(let current) = value {
                Toggle(field.key, isOn: Binding(get: { current }, set: { value = .bool($0) }))
            } else if let first = descriptor.first, case .array(let choices) = first {
                Picker(field.key, selection: Binding(get: { value.text }, set: { value = .string($0) })) {
                    if !choices.map(\.text).contains(value.text) { Text(value.text).tag(value.text) }
                    ForEach(choices.map(\.text), id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                imagePicker
            } else if case .string = value {
                TextField(field.key, text: Binding(get: { value.text }, set: { value = .string($0) }), axis: .vertical)
                    .lineLimit(field.priority == 0 ? 4...12 : 1...5)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                imagePicker
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
    @ViewBuilder private var imagePicker: some View {
        if field.key == "image" {
            PhotosPicker(selection: $photo, matching: .images) {
                Label(uploading ? "上传中…" : "从照片上传", systemImage: "photo.badge.plus")
            }.disabled(!store.connected || uploading)
                .onChange(of: photo) { _, item in
                    guard let item else { return }
                    Task {
                        uploading = true; defer { uploading = false; photo = nil }
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self), let ui = UIImage(data: data), let png = ui.pngData(), let api = store.client else { throw PocketError.message("无法读取照片。") }
                            let name = try await api.upload(png, filename: "pocket-\(UUID().uuidString).png", mime: "image/png")
                            value = .string(name)
                        } catch { store.error = error.localizedDescription }
                    }
                }
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
