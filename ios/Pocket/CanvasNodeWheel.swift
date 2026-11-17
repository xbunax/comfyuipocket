import SwiftUI

/// A stable ID, rather than a row number, keeps focus when nodes are refreshed.
struct CanvasNodeWheel: View {
    let session: CanvasSession
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("上下滚动 · 定位原始节点").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let index = session.orderedNodes.firstIndex(where: { $0.id == session.focusedNodeID }) {
                    Text("\(index + 1) / \(session.orderedNodes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 6)
            NodeWheelPicker(nodes: session.orderedNodes, selection: Binding(get: { session.focusedNodeID }, set: {
                session.nodeFocusActive = true
                session.focusedNodeID = $0
            }))
                .frame(height: 94).clipped()
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
            label.textColor = node.mode == 0 ? .label : .secondaryLabel
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
