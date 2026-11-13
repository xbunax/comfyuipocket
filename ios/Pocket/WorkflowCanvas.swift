import SwiftUI

private struct CanvasNode: Identifiable {
    let value: JSONValue
    var id: String { value["id"].text }
    var title: String { value["title"].text.nonEmpty ?? value["type"].text }
    var rect: CGRect {
        CGRect(x: component(value["pos"], 0), y: component(value["pos"], 1),
               width: max(140, component(value["size"], 0)), height: max(60, component(value["size"], 1)))
    }
    private func component(_ value: JSONValue, _ index: Int) -> Double {
        let result = value.array.count > index ? value.array[index].double : value[String(index)].double
        return result.isFinite ? result : 0
    }
}

struct WorkflowCanvasView: View {
    let workflow: Workflow
    @Environment(\.dismiss) private var dismiss
    @State private var scope = "root"
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1
    @State private var selected: CanvasNode?
    private var subgraphs: [JSONValue] { workflow.canvas?["definitions"]["subgraphs"].array ?? [] }
    private var graph: JSONValue {
        if scope != "root", let graph = subgraphs.first(where: { $0["id"].text == scope }) { return graph }
        return workflow.canvas ?? .null
    }
    private var nodes: [CanvasNode] {
        graph["nodes"].array.map { CanvasNode(value: $0) }.filter { !$0.id.isEmpty }
    }
    private var bounds: CGRect {
        let rects = nodes.map(\.rect) + graph["groups"].array.compactMap { group -> CGRect? in
            let b = group["bounding"].array
            guard b.count >= 4, b.prefix(4).allSatisfy({ $0.double.isFinite }) else { return nil }
            return CGRect(x: b[0].double, y: b[1].double, width: max(0, b[2].double), height: max(0, b[3].double))
        }
        return rects.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -60, dy: -60)
    }
    private var scale: CGFloat { min(2.5, max(0.03, zoom * magnification)) }
    var body: some View {
        NavigationStack {
            Group {
                if nodes.isEmpty {
                    ContentUnavailableView("没有画布布局", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("API 格式 JSON 不含节点坐标。通过电脑端自动同步的工作流可显示原始画布。"))
                } else {
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            Canvas { context, _ in
                                context.scaleBy(x: scale, y: scale)
                                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                                drawGroups(&context)
                                drawLinks(&context)
                                for node in nodes { drawNode(node, in: &context) }
                            }
                            .frame(width: max(geometry.size.width, bounds.width * scale),
                                   height: max(geometry.size.height, bounds.height * scale))
                            .background(Color(red: 0.08, green: 0.09, blue: 0.11))
                            .onTapGesture { point in
                                let original = CGPoint(x: point.x / scale + bounds.minX, y: point.y / scale + bounds.minY)
                                selected = nodes.reversed().first { $0.rect.contains(original) }
                            }
                        }
                        .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in
                            state = value.magnification
                        }.onEnded { value in zoom = min(2.5, max(0.03, zoom * value.magnification)) })
                        .safeAreaInset(edge: .bottom) {
                            HStack {
                                Button("缩小", systemImage: "minus.magnifyingglass") { zoom = max(0.03, zoom / 1.4) }.labelStyle(.iconOnly)
                                Text("\(Int(scale * 100))%").font(.caption.monospacedDigit()).frame(width: 52)
                                Button("放大", systemImage: "plus.magnifyingglass") { zoom = min(2.5, zoom * 1.4) }.labelStyle(.iconOnly)
                                Spacer()
                                Button("适合屏幕", systemImage: "arrow.up.left.and.arrow.down.right") { fit(geometry.size) }
                            }.padding().background(.ultraThinMaterial)
                        }
                        .task(id: scope) { fit(geometry.size) }
                    }
                }
            }
            .navigationTitle("工作流画布").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !subgraphs.isEmpty {
                        Menu {
                            Button("主画布") { scope = "root" }
                            ForEach(Array(subgraphs.enumerated()), id: \.offset) { _, graph in
                                Button(graph["name"].text.nonEmpty ?? graph["id"].text) { scope = graph["id"].text }
                            }
                        } label: { Label("子图", systemImage: "square.stack.3d.up") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .sheet(item: $selected) { node in nodeDetails(node) }
        }
    }
    private func fit(_ size: CGSize) {
        guard !bounds.isNull else { return }
        zoom = min(1, max(0.03, min(size.width / max(1, bounds.width), size.height / max(1, bounds.height))))
    }
    private func drawGroups(_ context: inout GraphicsContext) {
        for group in graph["groups"].array {
            let b = group["bounding"].array
            guard b.count >= 4 else { continue }
            let rect = CGRect(x: b[0].double, y: b[1].double, width: max(0, b[2].double), height: max(0, b[3].double))
            guard !rect.isInfinite, !rect.isNull else { continue }
            let color = color(group["color"].text, fallback: .blue)
            context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(color.opacity(0.1)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(color.opacity(0.55)), lineWidth: 2)
            context.draw(Text(group["title"].text).font(.system(size: 22, weight: .semibold)).foregroundColor(.white.opacity(0.8)),
                         at: CGPoint(x: rect.minX + 10, y: rect.minY + 8), anchor: .topLeading)
        }
    }
    private func drawLinks(_ context: inout GraphicsContext) {
        let lookup = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for link in graph["links"].array {
            let values = link.array
            let sourceID = values.count >= 6 ? values[1].text : link["origin_id"].text
            let targetID = values.count >= 6 ? values[3].text : link["target_id"].text
            let sourceSlot = values.count >= 6 ? values[2].double : link["origin_slot"].double
            let targetSlot = values.count >= 6 ? values[4].double : link["target_slot"].double
            guard let source = lookup[sourceID], let target = lookup[targetID] else { continue }
            let a = CGPoint(x: source.rect.maxX, y: source.rect.minY + min(source.rect.height - 10, 44 + sourceSlot * 20))
            let b = CGPoint(x: target.rect.minX, y: target.rect.minY + min(target.rect.height - 10, 44 + targetSlot * 20))
            let bend = max(50, abs(b.x - a.x) * 0.5)
            var path = Path(); path.move(to: a)
            path.addCurve(to: b, control1: CGPoint(x: a.x + bend, y: a.y), control2: CGPoint(x: b.x - bend, y: b.y))
            context.stroke(path, with: .color(.mint.opacity(0.7)), lineWidth: 2)
        }
    }
    private func drawNode(_ node: CanvasNode, in context: inout GraphicsContext) {
        let rect = node.rect
        context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(color(node.value["bgcolor"].text, fallback: Color(white: 0.17))))
        context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(.white.opacity(0.22)), lineWidth: 1)
        context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 30)),
                     with: .color(color(node.value["color"].text, fallback: Color(white: 0.25))))
        context.draw(Text(String("#\(node.id) \(node.title)".prefix(max(8, Int(rect.width / 8)))))
            .font(.system(size: 13, weight: .semibold)).foregroundColor(.white),
                     at: CGPoint(x: rect.minX + 8, y: rect.minY + 8), anchor: .topLeading)
        for (side, key) in [(false, "inputs"), (true, "outputs")] {
            for (index, port) in node.value[key].array.enumerated() {
                let y = rect.minY + 44 + CGFloat(index) * 20
                guard y < rect.maxY - 8 else { continue }
                let x = side ? rect.maxX : rect.minX
                context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.mint))
                context.draw(Text(String(port["name"].text.prefix(22))).font(.system(size: 11)).foregroundColor(.white.opacity(0.7)),
                             at: CGPoint(x: side ? x - 9 : x + 9, y: y), anchor: side ? .trailing : .leading)
            }
        }
        let portCount = max(node.value["inputs"].array.count, node.value["outputs"].array.count)
        for (index, widget) in node.value["widgets_values"].array.enumerated() {
            let y = rect.minY + 52 + CGFloat(portCount + index) * 20
            guard y < rect.maxY - 10 else { break }
            context.draw(Text(String(widget.text.prefix(max(8, Int(rect.width / 7))))).font(.system(size: 11)).foregroundColor(.white.opacity(0.6)),
                         at: CGPoint(x: rect.minX + 10, y: y), anchor: .leading)
        }
    }
    private func color(_ hex: String, fallback: Color) -> Color {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return fallback }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    private func nodeDetails(_ node: CanvasNode) -> some View {
        NavigationStack {
            List {
                Section("节点") {
                    LabeledContent("ID", value: node.id)
                    LabeledContent("类型", value: node.value["type"].text)
                }
                let promptID = scope == "root" ? node.id : nodesPromptID(node.id)
                if let inputs = workflow.prompt[promptID]?["inputs"].object, !inputs.isEmpty {
                    Section("当前参数") {
                        ForEach(inputs.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading) {
                                Text(key).font(.caption).foregroundStyle(.secondary)
                                Text(inputs[key]?.text.nonEmpty ?? String(describing: inputs[key] ?? .null)).textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    Section("画布中保存的内容") {
                        ForEach(Array(node.value["widgets_values"].array.enumerated()), id: \.offset) { _, value in
                            Text(value.text).textSelection(.enabled)
                        }
                    }
                }
            }.navigationTitle(node.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { selected = nil } }
        }
    }
    private func nodesPromptID(_ id: String) -> String {
        // Execution IDs inside subgraphs can be flattened differently by ComfyUI.
        // Only use an exact match; otherwise display the saved canvas widgets.
        "\(scope):\(id)"
    }
}
