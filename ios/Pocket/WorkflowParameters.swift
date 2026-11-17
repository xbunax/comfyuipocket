import SwiftUI

struct WorkflowParameters: View {
    @Environment(PocketStore.self) private var store
    let workflow: Workflow
    @AppStorage("workflow.showAllParameters") private var showAll = false
    @State private var expandedSlots: Set<String> = []
    @AppStorage private var expandedGroups: String
    @AppStorage private var expandedNodes: String
    init(workflow: Workflow) {
        self.workflow = workflow
        _expandedGroups = AppStorage(wrappedValue: "prompts\nmedia\nsampling", "workflowParameterGroups.\(workflow.id)")
        let initialNodes = workflow.nodeSections.filter { node in
            [.prompts, .media].contains(node.purpose) || node.fields.contains { workflow.pinned.contains($0.id) }
        }.map(\.id).joined(separator: "\n")
        _expandedNodes = AppStorage(wrappedValue: initialNodes, "workflowParameterNodes.\(workflow.id)")
    }
    private var index: Int? { store.workflows.firstIndex { $0.id == workflow.id } }
    var body: some View {
        Section {
            Picker("参数范围", selection: $showAll) {
                Text("常用操作").tag(false); Text("全部参数").tag(true)
            }.pickerStyle(.segmented)
            Text(showAll ? "展开节点查看高级设置；内部时间轴数据通过专用编辑器维护。" : "素材、提示词与生成设置优先显示。收藏的参数也会保留在这里。")
                .font(.caption).foregroundStyle(PocketPalette.secondary)
            HStack {
                Button("展开全部", systemImage: "arrow.down.right.and.arrow.up.left") {
                    expandedGroups = WorkflowNodePurpose.allCases.map(\.rawValue).joined(separator: "\n")
                    expandedNodes = workflow.nodeSections.map(\.id).joined(separator: "\n")
                }
                Spacer()
                Button("折叠全部", systemImage: "arrow.up.left.and.arrow.down.right") { expandedGroups = ""; expandedNodes = "" }
            }.font(.caption).buttonStyle(.borderless)
        }
        ForEach(WorkflowNodePurpose.allCases) { purpose in
            let nodes = workflow.nodeSections.filter { $0.purpose == purpose && !visibleFields($0).isEmpty }
            if !nodes.isEmpty {
                Section {
                    if contains(expandedGroups, purpose.rawValue) {
                        ForEach(nodes) { node in nodeView(node) }
                    }
                } header: {
                    Button {
                        withAnimation(.snappy) { toggle(&expandedGroups, purpose.rawValue) }
                    } label: {
                        HStack {
                            Text(purpose.title).textCase(nil)
                            Text("\(nodes.count) 个节点").font(.caption).foregroundStyle(PocketPalette.secondary)
                            Spacer()
                            Image(systemName: contains(expandedGroups, purpose.rawValue) ? "chevron.down" : "chevron.right")
                        }.foregroundStyle(PocketPalette.text).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private func nodeView(_ node: WorkflowNodeSection) -> some View {
        let fields = visibleFields(node)
        let resolution = WorkflowResolution(fields: fields)
        let firstDimension = fields.first { $0.id == resolution?.width.id || $0.id == resolution?.height.id }?.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { setExpanded(node.id, expanded: !contains(expandedNodes, node.id)) }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.title).font(.subheadline.weight(.semibold))
                        Text("节点 #\(node.id) · \(node.fields.count) 项参数").font(.caption).foregroundStyle(PocketPalette.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: contains(expandedNodes, node.id) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(PocketPalette.secondary)
                }.foregroundStyle(PocketPalette.text).padding(.vertical, 6).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(contains(expandedNodes, node.id) ? "已展开" : "已折叠")
            if contains(expandedNodes, node.id) {
                if node.fields.first?.classType.contains("LoraStack") == true {
                    loraSlots(node)
                } else {
                ForEach(fields) { field in
                    if index != nil {
                        if let resolution, field.id == resolution.width.id || field.id == resolution.height.id {
                            if field.id == firstDimension { resolutionEditor(resolution) }
                        } else {
                            fieldEditor(field)
                        }
                    }
                }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }
    private func visibleFields(_ node: WorkflowNodeSection) -> [WorkflowField] {
        node.fields.filter { !MobileField.isInternal($0) && (showAll || MobileField.isCommon($0) || workflow.pinned.contains($0.id)) }
    }
    private func fieldBinding(_ field: WorkflowField) -> Binding<JSONValue> {
        Binding(get: { store.workflows.first { $0.id == workflow.id }?.prompt[field.nodeID]?["inputs"][field.key] ?? field.value }, set: { value in
            guard let current = index, let live = store.workflows[current].fields.first(where: { $0.id == field.id }) else { return }
            store.workflows[current].set(live, value: value); store.save(); store.touch(workflow.id)
        })
    }
    private func loraSlots(_ node: WorkflowNodeSection) -> some View {
        let count = Int(node.fields.first { $0.key == "槽位数" }?.value.double ?? 16)
        let slots = Array(Set(node.fields.compactMap { MobileField.slot($0.key) })).sorted().filter { showAll || $0 <= count }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(node.fields.filter { MobileField.slot($0.key) == nil }) { field in fieldEditor(field) }
            ForEach(slots, id: \.self) { slot in
                let fields = node.fields.filter { MobileField.slot($0.key) == slot }
                let enabled = fields.first { $0.key.hasPrefix("启用_") }?.value == .bool(true)
                let key = "\(node.id).\(slot)"
                DisclosureGroup(isExpanded: Binding(get: { expandedSlots.contains(key) }, set: { if $0 { expandedSlots.insert(key) } else { expandedSlots.remove(key) } })) {
                    ForEach(fields) { field in fieldEditor(field) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LoRA \(slot) · \(enabled ? "已启用" : "未启用")").font(.subheadline)
                        if enabled, let model = fields.first(where: { $0.key.hasPrefix("LoRA_") }) {
                            Text(model.value.text).font(.caption).foregroundStyle(PocketPalette.secondary).lineLimit(1)
                        }
                    }
                }.padding(10).background(Color.secondary.opacity(0.05), in: .rect(cornerRadius: 12))
            }
        }
    }
    private func fieldEditor(_ field: WorkflowField, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label ?? field.key).font(.caption).foregroundStyle(PocketPalette.secondary)
                Spacer()
                Button {
                    guard let current = index else { return }
                    if store.workflows[current].pinned.contains(field.id) { store.workflows[current].pinned.removeAll { $0 == field.id } }
                    else { store.workflows[current].pinned.append(field.id) }
                    store.save(); store.touch(workflow.id)
                } label: { Image(systemName: workflow.pinned.contains(field.id) ? "pin.fill" : "pin") }
                    .font(.caption).buttonStyle(.borderless).accessibilityLabel("收藏参数 \(label ?? field.key)")
            }
            if field.classType == "LazyH3Director", field.key == "timeline_data" {
                H3StoryboardEditor(workflowID: workflow.id, nodeID: field.nodeID)
            } else if field.key == "图片数据", field.classType.contains("Workbench") {
                WorkbenchImageEditor(value: fieldBinding(field))
            } else {
            ParameterEditor(field: field, schema: store.nodeInfo[field.classType], preferenceKey: workflow.id,
                value: Binding(get: {
                    store.workflows.first(where: { $0.id == workflow.id })?.prompt[field.nodeID]?["inputs"][field.key] ?? field.value
                }, set: { value in
                    guard let current = index,
                          let liveField = store.workflows[current].fields.first(where: { $0.id == field.id }) else { return }
                    store.workflows[current].set(liveField, value: value); store.save(); store.touch(workflow.id)
                }))
            }
        }.padding(.vertical, 8)
    }
    private func resolutionEditor(_ resolution: WorkflowResolution) -> some View {
        let schema = store.nodeInfo[resolution.width.classType]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                dimension(resolution.width, label: "宽")
                dimension(resolution.height, label: "高")
            }
            HStack {
                Text("常用分辨率").font(.caption).foregroundStyle(PocketPalette.secondary)
                Spacer()
                Menu {
                    ForEach(ResolutionPreset.common) { preset in
                        let selected = resolution.width.value.double == Double(preset.width) && resolution.height.value.double == Double(preset.height)
                        Button { apply(preset, nodeID: resolution.width.nodeID) } label: {
                            if selected { Label(preset.title, systemImage: "checkmark") }
                            else { Text(preset.title) }
                        }.disabled(resolution.values(for: preset, schema: schema) == nil)
                    }
                } label: {
                    Label("全部预设", systemImage: "slider.horizontal.3")
                }.font(.caption).buttonStyle(.borderless)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ResolutionPreset.quick) { preset in
                        let selected = resolution.width.value.double == Double(preset.width) && resolution.height.value.double == Double(preset.height)
                        let supported = resolution.values(for: preset, schema: schema) != nil
                        Button { apply(preset, nodeID: resolution.width.nodeID) } label: {
                            VStack(spacing: 4) {
                                if let name = preset.name { Text(name).font(.caption.weight(.medium)) }
                                Text(preset.id).font(.caption.monospacedDigit())
                            }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .foregroundStyle(selected ? PocketPalette.accent : PocketPalette.text)
                                .background(selected ? PocketPalette.accent.opacity(0.12) : Color.secondary.opacity(0.06), in: .capsule)
                                .overlay(Capsule().strokeBorder(selected ? PocketPalette.accent.opacity(0.4) : Color.clear))
                        }.buttonStyle(.plain)
                            .disabled(!supported).opacity(supported ? 1 : 0.35)
                            .accessibilityLabel("宽 \(preset.width)，高 \(preset.height)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }.padding(.vertical, 8)
    }
    private func dimension(_ field: WorkflowField, label: String) -> some View {
        fieldEditor(field, label: label)
            .font(.title3.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.05), in: .rect(cornerRadius: 14))
    }
    private func apply(_ preset: ResolutionPreset, nodeID: String) {
        guard let current = index,
              let node = store.workflows[current].nodeSections.first(where: { $0.id == nodeID }),
              let resolution = WorkflowResolution(fields: node.fields),
              let values = resolution.values(for: preset, schema: store.nodeInfo[resolution.width.classType]) else { return }
        store.workflows[current].set(resolution.width, value: values.width)
        store.workflows[current].set(resolution.height, value: values.height)
        store.save(); store.touch(workflow.id)
    }
    private func contains(_ source: String, _ id: String) -> Bool { source.split(separator: "\n").contains(Substring(id)) }
    private func toggle(_ source: inout String, _ id: String) {
        var ids = Set(source.split(separator: "\n").map(String.init))
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        source = ids.sorted().joined(separator: "\n")
    }
    private func setExpanded(_ id: String, expanded: Bool) {
        if contains(expandedNodes, id) != expanded { toggle(&expandedNodes, id) }
    }
}
