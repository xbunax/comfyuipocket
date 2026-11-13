import SwiftUI

private struct CanvasNodeType: Decodable, Identifiable {
    let type: String
    let title: String
    let category: String
    var id: String { type }
}

struct CanvasNodeLibrary: View {
    let session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var nodes: [CanvasNodeType] = []
    var body: some View {
        NavigationStack {
            List(nodes.filter { query.isEmpty || "\($0.title) \($0.type) \($0.category)".localizedCaseInsensitiveContains(query) }) { node in
                Button {
                    Task { await session.action("addNode", arguments: ["type": node.type]); dismiss() }
                } label: {
                    VStack(alignment: .leading) { Text(node.title); Text(node.category).font(.caption).foregroundStyle(.secondary) }
                }
            }.navigationTitle("新增节点").searchable(text: $query, prompt: "搜索全部节点")
                .toolbar { Button("取消") { dismiss() } }
                .task {
                    do {
                        if let text = try await session.call("library") as? String {
                            nodes = try JSONDecoder().decode([CanvasNodeType].self, from: Data(text.utf8))
                        }
                    } catch { session.error = error.localizedDescription; dismiss() }
                }
        }
    }
}

private struct CanvasPort: Decodable, Identifiable {
    let slot: Int
    let name: String
    let type: String
    let linked: Bool?
    var id: Int { slot }
}
private struct CanvasPortNode: Decodable, Identifiable {
    let id: String
    let title: String
    let inputs: [CanvasPort]
    let outputs: [CanvasPort]
}

struct CanvasConnections: View {
    let session: CanvasSession
    @Environment(\.dismiss) private var dismiss
    @State private var nodes: [CanvasPortNode] = []
    @State private var source = ""
    @State private var target = ""
    @State private var output = 0
    @State private var input = 0
    @State private var status = ""
    private var selectedSource: CanvasPortNode? { nodes.first { $0.id == source } }
    private var selectedTarget: CanvasPortNode? { nodes.first { $0.id == target } }
    var body: some View {
        NavigationStack {
            Form {
                Section("输出端") {
                    Picker("节点", selection: $source) {
                        Text("选择节点").tag("")
                        ForEach(nodes.filter { !$0.outputs.isEmpty }) { Text("#\($0.id) \($0.title)").tag($0.id) }
                    }
                    Picker("端口", selection: $output) {
                        ForEach(selectedSource?.outputs ?? []) { Text("\($0.name) · \($0.type)").tag($0.slot) }
                    }
                }
                Section("输入端") {
                    Picker("节点", selection: $target) {
                        Text("选择节点").tag("")
                        ForEach(nodes.filter { !$0.inputs.isEmpty }) { Text("#\($0.id) \($0.title)").tag($0.id) }
                    }
                    Picker("端口", selection: $input) {
                        ForEach(selectedTarget?.inputs ?? []) { Text("\($0.name) · \($0.type)\($0.linked == true ? " · 已连接" : "")").tag($0.slot) }
                    }
                }
                Section {
                    Button("连接选定端口") { connect() }.disabled(selectedSource == nil || selectedTarget == nil)
                    Button("断开选定输入", role: .destructive) { disconnect() }
                        .disabled(selectedTarget?.inputs.first(where: { $0.slot == input })?.linked != true)
                    if !status.isEmpty { Text(status).font(.caption) }
                }
                Section { Text("显示当前主图或子图中的节点。也可以直接在画布上拖动端口连线。替换已连接的输入会移除旧连线。") }.font(.caption)
            }.navigationTitle("连接端口").toolbar { Button("完成") { dismiss() } }
                .onChange(of: source) { _, _ in output = 0 }
                .onChange(of: target) { _, _ in input = 0 }
                .task { await refresh() }
        }
    }
    private func connect() {
        Task {
            do {
                _ = try await session.call("connect", arguments: ["from": source, "output": output, "to": target, "input": input])
                status = "已连接"; await refresh()
            } catch { status = error.localizedDescription }
        }
    }
    private func disconnect() {
        Task {
            do {
                _ = try await session.call("disconnect", arguments: ["id": target, "slot": input])
                status = "已断开"; await refresh()
            } catch { status = error.localizedDescription }
        }
    }
    private func refresh() async {
        do {
            if let text = try await session.call("ports") as? String { nodes = try JSONDecoder().decode([CanvasPortNode].self, from: Data(text.utf8)) }
        } catch { status = error.localizedDescription }
    }
}
