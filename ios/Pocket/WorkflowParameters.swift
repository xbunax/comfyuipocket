import SwiftUI

struct WorkflowParameters: View {
    @Environment(PocketStore.self) private var store
    let workflow: Workflow
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
            let nodes = workflow.nodeSections.filter { $0.purpose == purpose }
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
                            Text("\(nodes.count) 个节点").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: contains(expandedGroups, purpose.rawValue) ? "chevron.down" : "chevron.right")
                        }.foregroundStyle(.primary).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private func nodeView(_ node: WorkflowNodeSection) -> some View {
        let resolution = WorkflowResolution(fields: node.fields)
        let firstDimension = node.fields.first { $0.key == "width" || $0.key == "height" }?.id
        return DisclosureGroup(isExpanded: Binding(get: { contains(expandedNodes, node.id) }, set: { setExpanded(node.id, expanded: $0) })) {
            ForEach(node.fields) { field in
                if index != nil {
                    if let resolution, field.id == resolution.width.id || field.id == resolution.height.id {
                        if field.id == firstDimension { resolutionEditor(resolution) }
                    } else {
                        fieldEditor(field)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(node.title).font(.subheadline.weight(.semibold))
                Text("节点 #\(node.id) · \(node.fields.count) 项参数").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }
    }
    private func fieldEditor(_ field: WorkflowField, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label ?? field.key).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard let current = index else { return }
                    if store.workflows[current].pinned.contains(field.id) { store.workflows[current].pinned.removeAll { $0 == field.id } }
                    else { store.workflows[current].pinned.append(field.id) }
                    store.save(); store.touch(workflow.id)
                } label: { Image(systemName: workflow.pinned.contains(field.id) ? "pin.fill" : "pin") }
                    .font(.caption).buttonStyle(.borderless).accessibilityLabel("收藏参数 \(label ?? field.key)")
            }
            ParameterEditor(field: field, schema: store.nodeInfo[field.classType], preferenceKey: workflow.id,
                value: Binding(get: {
                    store.workflows.first(where: { $0.id == workflow.id })?.prompt[field.nodeID]?["inputs"][field.key] ?? field.value
                }, set: { value in
                    guard let current = index,
                          let liveField = store.workflows[current].fields.first(where: { $0.id == field.id }) else { return }
                    store.workflows[current].set(liveField, value: value); store.save(); store.touch(workflow.id)
                }))
        }.padding(.vertical, 8)
    }
    private func resolutionEditor(_ resolution: WorkflowResolution) -> some View {
        let schema = store.nodeInfo[resolution.width.classType]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                dimension(resolution.width, label: "宽")
                dimension(resolution.height, label: "高")
            }
            Text("常用分辨率").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ResolutionPreset.common) { preset in
                        let selected = resolution.width.value.double == Double(preset.width) && resolution.height.value.double == Double(preset.height)
                        let supported = resolution.values(for: preset, schema: schema) != nil
                        Button { apply(preset, nodeID: resolution.width.nodeID) } label: {
                            Text(preset.id).font(.caption.monospacedDigit())
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .foregroundStyle(selected ? PocketPalette.accent : Color.primary)
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
