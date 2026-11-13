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
        DisclosureGroup(isExpanded: Binding(get: { contains(expandedNodes, node.id) }, set: { setExpanded(node.id, expanded: $0) })) {
            ForEach(node.fields) { field in
                if let index {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(field.key).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                if store.workflows[index].pinned.contains(field.id) { store.workflows[index].pinned.removeAll { $0 == field.id } }
                                else { store.workflows[index].pinned.append(field.id) }
                                store.save(); store.touch(workflow.id)
                            } label: { Image(systemName: workflow.pinned.contains(field.id) ? "pin.fill" : "pin") }
                                .buttonStyle(.borderless).accessibilityLabel("收藏参数 \(field.key)")
                        }
                        ParameterEditor(field: field, schema: store.nodeInfo[field.classType], preferenceKey: workflow.id,
                            value: Binding(get: {
                                store.workflows.first(where: { $0.id == workflow.id })?.prompt[field.nodeID]?["inputs"][field.key] ?? field.value
                            }, set: { value in
                                guard let current = store.workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
                                store.workflows[current].set(field, value: value); store.save(); store.touch(workflow.id)
                            }))
                    }.padding(.vertical, 8)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(node.title).font(.subheadline.weight(.semibold))
                Text("节点 #\(node.id) · \(node.fields.count) 项参数").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }
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
