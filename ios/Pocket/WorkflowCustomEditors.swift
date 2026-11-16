import SwiftUI

struct WorkbenchImageEditor: View {
    @Binding var value: JSONValue
    @State private var selection: JSONValue = .string("")
    @State private var adding = false
    private var collection: WorkbenchImages? { try? WorkbenchImages(value.text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let collection {
                ForEach(Array(collection.items.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 8) {
                        InputMediaPreview(value: WorkbenchImages.reference(item), kind: .image)
                        HStack {
                            Text("参考图 \(index + 1)").font(.caption)
                            if !item["mask"].text.isEmpty { Label("含遮罩", systemImage: "square.dashed").font(.caption) }
                            Spacer()
                            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index + 1 == collection.items.count)
                            Button(role: .destructive) { change { $0.items.remove(at: index) } } label: { Image(systemName: "trash") }
                        }.buttonStyle(.borderless)
                    }
                }
                Button("添加参考图", systemImage: "plus") { selection = .string(""); adding = true }
                    .disabled(collection.items.count >= 10)
                Text("支持相册、本地文件和作品。排序会保留已有遮罩；遮罩绘制请在专用控件中操作。")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Label("此图片格式请在画布专用控件中编辑", systemImage: "rectangle.and.hand.point.up.left").font(.caption) }
        }.sheet(isPresented: $adding) {
            NavigationStack {
                Form { MediaFieldEditor(value: $selection, kind: .image) }
                    .navigationTitle("添加参考图")
                    .toolbar { Button("取消") { adding = false } }
                    .onChange(of: selection) { _, next in
                        guard !next.text.isEmpty else { return }
                        change { $0.items.append(WorkbenchImages.item(next.text)) }; adding = false
                    }
            }
        }
    }
    private func change(_ edit: (inout WorkbenchImages) -> Void) {
        guard var c = collection else { return }; edit(&c)
        if let text = try? c.encoded() { value = .string(text) }
    }
    private func move(_ index: Int, by delta: Int) { change { c in
        guard c.items.indices.contains(index + delta) else { return }
        c.items.swapAt(index, index + delta)
    } }
}

struct H3StoryboardEditor: View {
    let workflowID: String
    let nodeID: String
    @Environment(PocketStore.self) private var store
    @State private var expanded: Set<Int> = [0]
    private var inputs: JSONValue { store.workflows.first { $0.id == workflowID }?.prompt[nodeID]?["inputs"] ?? .null }
    private var storyboard: H3Storyboard? { try? H3Storyboard(inputs["timeline_data"].text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let storyboard {
                Label("\(storyboard.segments.count) 个分镜 · \(inputs["workspace_mode"].text)", systemImage: "film.stack").font(.headline)
                if !storyboard.editable {
                    Text("此时间轴含媒体轨道、裁切或特殊结构。可在画布中选择导演台，打开专用控件编辑，原数据会完整保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(storyboard.segments.enumerated()), id: \.offset) { index, segment in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(index) }, set: { if $0 { expanded.insert(index) } else { expanded.remove(index) } })) {
                        if storyboard.editable {
                            PromptInputEditor(text: Binding(get: { self.storyboard?.segments[safe: index]?["prompt"].text ?? "" },
                                set: { edit(index, key: "prompt", value: .string($0)) }), preferenceKey: "\(workflowID).\(nodeID).shot\(index)", context: "分镜 \(index + 1)")
                            HStack {
                                Button("前移") { mutate { b in var list = b.segments; list.swapAt(index, index - 1); b.replaceSegments(list) } }.disabled(index == 0)
                                Button("后移") { mutate { b in var list = b.segments; list.swapAt(index, index + 1); b.replaceSegments(list) } }.disabled(index + 1 == storyboard.segments.count)
                                Spacer()
                                Button("删除", role: .destructive) { mutate { b in var list = b.segments; list.remove(at: index); b.replaceSegments(list) } }.disabled(storyboard.segments.count == 1)
                            }.font(.caption).buttonStyle(.borderless)
                            Stepper("时长 \(Int(segment["length"].double)) 帧", value: Binding(get: { Int(self.storyboard?.segments[safe: index]?["length"].double ?? 1) },
                                set: { edit(index, key: "length", value: .integer(Int64($0))) }), in: 1...100000)
                        } else {
                            Text(segment["prompt"].text).font(.subheadline).textSelection(.enabled)
                            Text("\(Int(segment["length"].double)) 帧 · \(segment["type"].text)").font(.caption)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("分镜 \(index + 1)").font(.subheadline.bold())
                            Text(segment["prompt"].text.isEmpty ? "未填写提示词" : segment["prompt"].text).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(12).background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 14))
                }
                if storyboard.editable {
                    Button("添加分镜", systemImage: "plus") {
                        mutate { b in
                            var list = b.segments
                            list.append(.object(["id": .string(UUID().uuidString), "start": .integer(0), "length": .integer(120), "type": .string("text"), "prompt": .string("")]))
                            b.replaceSegments(list)
                        }
                    }.buttonStyle(.borderless)
                }
            } else { Text("导演台数据暂不可识别，请打开画布中的专用控件。").font(.caption) }
        }
    }
    private func edit(_ index: Int, key: String, value: JSONValue) {
        mutate { $0.update(index: index, key: key, value: value) }
    }
    private func mutate(_ update: (inout H3Storyboard) -> Void) {
        guard var board = storyboard, let wi = store.workflows.firstIndex(where: { $0.id == workflowID }) else { return }
        update(&board)
        do {
            let updates = try board.inputs(fps: inputs["frame_rate"].double)
            var node = store.workflows[wi].prompt[nodeID]?.object ?? [:]
            var fields = node["inputs"]?.object ?? [:]
            for (key, next) in updates where fields[key] != nil { fields[key] = next }
            node["inputs"] = .object(fields); store.workflows[wi].prompt[nodeID] = .object(node)
            store.save(); store.touch(workflowID)
        } catch { store.error = error.localizedDescription }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
