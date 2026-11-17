import SwiftUI

/// Pointer-friendly navigation on larger windows; it moves the real canvas camera.
struct CanvasNodeNavigator: View {
    @Environment(PocketStore.self) private var store
    let session: CanvasSession
    var openBookmarks: (() -> Void)? = nil
    @State private var search = ""
    @State private var favoritesOnly = false
    private var nodes: [MobileCanvasNode] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.orderedNodes.filter { node in
            let matches = query.isEmpty || node.title.localizedCaseInsensitiveContains(query) || node.id.localizedCaseInsensitiveContains(query) || node.type.localizedCaseInsensitiveContains(query)
            guard matches, favoritesOnly else { return matches }
            guard let key = session.cacheKey, let location = session.location(for: node) else { return false }
            return store.nodeBookmarks.contains(server: key.server, workflowID: key.workflowID, location: location)
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("节点导航", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                Spacer()
                Text("\(session.orderedNodes.count)").font(.caption.monospacedDigit()).foregroundStyle(PocketPalette.secondary)
                if let openBookmarks {
                    Button(action: openBookmarks) { Image(systemName: "star").frame(width: 44, height: 44) }
                        .buttonStyle(.borderless).accessibilityLabel("查看本工作流全部收藏")
                }
            }.padding(.horizontal, 16).padding(.top, 16)
            TextField("搜索名称、类型或节点 ID", text: $search)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            Picker("节点筛选", selection: $favoritesOnly) {
                Text("全部节点").tag(false)
                Text("已收藏").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal, 12)
            HStack {
                Button("上一个", systemImage: "chevron.up") { move(-1) }
                Spacer()
                Button("下一个", systemImage: "chevron.down") { move(1) }
            }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 16)
                .disabled(session.orderedNodes.isEmpty || session.textEditing)
            List(nodes) { node in
                HStack(spacing: 0) {
                Button {
                    session.nodeFocusActive = true; session.focusedNodeID = node.id
                    Task { await session.focusSelection() }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.title).font(.subheadline.weight(.medium)).foregroundStyle(PocketPalette.text)
                            Text("#\(node.id) · \(node.type)").font(.caption2).foregroundStyle(PocketPalette.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if session.focusedNodeID == node.id { Image(systemName: "scope").foregroundStyle(PocketPalette.accent) }
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(session.textEditing)
                CanvasBookmarkButton(session: session, node: node)
                }.listRowBackground(session.focusedNodeID == node.id ? PocketPalette.accent.opacity(0.1) : Color.clear)
                    .hoverEffect(.highlight)
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }
    private func move(_ offset: Int) {
        let nodes = nodes
        guard !nodes.isEmpty else { return }
        let current = nodes.firstIndex { $0.id == session.focusedNodeID } ?? 0
        let next = min(nodes.count - 1, max(0, current + offset))
        session.nodeFocusActive = true; session.focusedNodeID = nodes[next].id
        Task { await session.focusSelection() }
    }
}

/// A stable ID, rather than a row number, keeps focus when nodes are refreshed.
struct CanvasNodeWheel: View {
    let session: CanvasSession
    var compact = false
    var body: some View {
        VStack(spacing: 0) {
            if !compact { HStack {
                Text("上下滚动 · 定位原始节点").font(.caption).foregroundStyle(PocketPalette.secondary)
                Spacer()
                if let index = session.orderedNodes.firstIndex(where: { $0.id == session.focusedNodeID }) {
                    Text("\(index + 1) / \(session.orderedNodes.count)").font(.caption.monospacedDigit()).foregroundStyle(PocketPalette.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 6) }
            NodeWheelPicker(nodes: session.orderedNodes, selection: Binding(get: { session.focusedNodeID }, set: {
                session.nodeFocusActive = true
                session.focusedNodeID = $0
            }))
                .frame(height: compact ? 76 : 94).clipped()
        }
        .task(id: session.focusedNodeID) {
            do { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() }
            catch { return }
            await session.focusSelection()
        }
    }
}

private struct NodeWheelPicker: UIViewRepresentable {
    let nodes: [MobileCanvasNode]
    @Binding var selection: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator; picker.delegate = context.coordinator
        picker.accessibilityLabel = "节点轮盘"
        return picker
    }
    func updateUIView(_ picker: UIPickerView, context: Context) {
        let coordinator = context.coordinator
        let content = nodes.map { "\($0.id)|\($0.title)|\($0.mode)" }
        coordinator.parent = self
        if content != coordinator.content {
            coordinator.content = content; picker.reloadAllComponents()
        }
        if let row = nodes.firstIndex(where: { $0.id == selection }), picker.selectedRow(inComponent: 0) != row {
            picker.selectRow(row, inComponent: 0, animated: false)
        }
    }
    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: NodeWheelPicker
        var content: [String] = []
        let feedback = UISelectionFeedbackGenerator()
        init(_ parent: NodeWheelPicker) { self.parent = parent }
        func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int { parent.nodes.count }
        func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat { 32 }
        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
            let label = (view as? UILabel) ?? UILabel()
            guard parent.nodes.indices.contains(row) else { return label }
            let node = parent.nodes[row]
            label.text = "#\(node.id)  \(node.title)\(node.mode == 0 ? "" : " · \(node.modeTitle)")"
            label.textAlignment = .center; label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.75
            label.textColor = node.mode == 0 ? UIColor(PocketPalette.text) : UIColor(PocketPalette.secondary)
            label.accessibilityLabel = "节点 \(node.id)，\(node.title)，\(node.modeTitle)"
            return label
        }
        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            guard parent.nodes.indices.contains(row), parent.selection != parent.nodes[row].id else { return }
            parent.selection = parent.nodes[row].id
            feedback.selectionChanged(); feedback.prepare()
        }
    }
}
