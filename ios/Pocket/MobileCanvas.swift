import SwiftUI

struct MobileCanvasScene: Decodable {
    var nodes: [MobileCanvasNode] = []
    var groups: [MobileCanvasGroup] = []
    var links: [MobileCanvasLink] = []
    var nested = false
}
struct MobileCanvasGroup: Decodable, Identifiable {
    let id: String
    let title: String
    let x: Double, y: Double, width: Double, height: Double
}
struct MobileCanvasLink: Decodable, Identifiable {
    let id: String, from: String, to: String, type: String
}
struct MobileCanvasNode: Decodable, Identifiable {
    let id: String, title: String, type: String
    let x: Double, y: Double, width: Double, height: Double
    let mode: Int
    let group: String
    let subgraph: Bool
    let widgets: [MobileCanvasWidget]
    var modeTitle: String { mode == 4 ? "旁路" : (mode == 2 ? "静音" : "启用") }
}
struct MobileCanvasWidget: Decodable, Identifiable {
    let id: String, name: String
    let value: JSONValue
    let choices: [JSONValue]
    let min: Double?, max: Double?
}

/// ComfyUI remains the execution/serialization engine; this is the touch UI.
struct MobileCanvas: View {
    let session: CanvasSession
    let openCustom: (String) -> Void
    @State private var group = ""
    @State private var query = ""
    @State private var compact = true
    @State private var moving = false
    @State private var scale: CGFloat = 1
    @State private var offset = CGSize(width: 24, height: 24)
    @State private var gestureOffset: CGSize?
    @State private var gestureScale: CGFloat?
    @State private var movingID: String?
    @State private var moveDelta = CGSize.zero
    @State private var selected: MobileCanvasNode?
    @State private var navigation = false
    @State private var groupMode: Int?
    private var nodes: [MobileCanvasNode] {
        session.scene.nodes.filter { group.isEmpty || $0.group == group }.sorted {
            $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y
        }
    }
    private func rect(_ node: MobileCanvasNode) -> CGRect {
        let index = nodes.firstIndex { $0.id == node.id } ?? 0
        let origin = compact ? CGPoint(x: 0, y: CGFloat(index * 140)) : CGPoint(x: node.x, y: node.y)
        var r = CGRect(origin: origin, size: CGSize(width: 270, height: 104))
        if node.id == movingID { r = r.offsetBy(dx: moveDelta.width / scale, dy: moveDelta.height / scale) }
        return r
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("导航", systemImage: "list.bullet.indent") { navigation = true }
                Spacer()
                Picker("画布排列", selection: $compact) {
                    Text("紧凑").tag(true); Text("原布局").tag(false)
                }.pickerStyle(.segmented).frame(width: 160)
                if session.scene.nested {
                    Button("主图", systemImage: "arrow.up.left") { Task { await session.action("subgraph", arguments: ["id": ""]) } }.labelStyle(.iconOnly)
                }
            }.font(.subheadline).padding(12).background(.regularMaterial)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    groupButton("", "全部")
                    ForEach(session.scene.groups) { g in groupButton(g.id, g.title) }
                    if !group.isEmpty {
                        Menu("分组执行") {
                            Button("启用此分组") { groupMode = 0 }
                            Button("静音此分组") { groupMode = 2 }
                            Button("旁路此分组") { groupMode = 4 }
                        }.font(.caption).padding(10).disabled(!session.loaded)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            GeometryReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    Canvas { context, size in draw(&context, size: size) }
                        .background(Color(uiColor: .systemGroupedBackground))
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 8).onChanged { event in
                            guard session.loaded || !moving else { return }
                            if gestureOffset == nil {
                                gestureOffset = offset
                                if moving && !compact { movingID = hit(event.startLocation)?.id }
                            }
                            if movingID != nil { moveDelta = event.translation }
                            else { offset = CGSize(width: gestureOffset!.width + event.translation.width, height: gestureOffset!.height + event.translation.height) }
                        }.onEnded { _ in
                            if let id = movingID, let node = nodes.first(where: { $0.id == id }) {
                                let x = node.x + Double(moveDelta.width / scale), y = node.y + Double(moveDelta.height / scale)
                                Task { await session.action("moveNode", arguments: ["id": id, "x": x, "y": y]) }
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            }
                            movingID = nil; moveDelta = .zero; gestureOffset = nil
                        })
                        .simultaneousGesture(MagnificationGesture().onChanged { value in
                            if gestureScale == nil { gestureScale = scale }
                            zoom(to: min(3, max(0.08, gestureScale! * value)), size: proxy.size)
                        }.onEnded { _ in gestureScale = nil })
                        .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                            selected = hit(tap.location)
                            if let node = selected { UISelectionFeedbackGenerator().selectionChanged(); Task { await session.action("focus", arguments: ["id": node.id]) } }
                        })
                        .accessibilityLabel("节点画布。使用导航按钮可访问所有节点和参数。")
                    if nodes.isEmpty { ContentUnavailableView("此分组暂无节点", systemImage: "square.dashed") }
                    VStack(spacing: 12) {
                        if !compact {
                            Button { moving.toggle() } label: { Image(systemName: moving ? "hand.draw.fill" : "hand.draw") }
                                .tint(moving ? PocketPalette.accent : .primary).accessibilityLabel(moving ? "结束移动节点" : "移动节点模式")
                        }
                        Button { zoom(to: min(3, scale * 1.3), size: proxy.size) } label: { Image(systemName: "plus") }.accessibilityLabel("放大")
                        Button { zoom(to: max(0.08, scale / 1.3), size: proxy.size) } label: { Image(systemName: "minus") }.accessibilityLabel("缩小")
                        Button { reset(size: proxy.size) } label: { Image(systemName: "viewfinder") }.accessibilityLabel("定位起点")
                    }.font(.title3).buttonStyle(.borderless).padding(16).background(.regularMaterial, in: .capsule).padding(12)
                }.clipped()
                    .onAppear { reset(size: proxy.size) }
                    .onChange(of: group) { _, _ in reset(size: proxy.size) }
                    .onChange(of: compact) { _, _ in moving = false; reset(size: proxy.size) }
            }
            Text(moving ? "拖动节点卡片移动位置；拖动空白平移" : "点击节点编辑 · 拖动空白平移 · 双指缩放")
                .font(.caption2).foregroundStyle(.secondary).padding(6)
        }
        .background(Color(uiColor: .systemBackground))
        .confirmationDialog("更改当前分组中所有执行节点的状态？", isPresented: Binding(get: { groupMode != nil }, set: { if !$0 { groupMode = nil } }), titleVisibility: .visible) {
            Button("应用到分组") {
                if let mode = groupMode {
                    Task { await session.action("groupMode", arguments: ["id": group, "mode": mode]) }
                }
                groupMode = nil
            }
        } message: { Text("这会影响生成内容；折叠或切换分组不会改变执行状态。可通过撤销恢复。") }
        .sheet(item: $selected) { node in
            MobileNodeInspector(session: session, nodeID: node.id) { openCustom(node.id); selected = nil }
        }
        .sheet(isPresented: $navigation) {
            NavigationStack {
                List(session.scene.nodes.filter { query.isEmpty || "\($0.title) \($0.type) #\($0.id)".localizedCaseInsensitiveContains(query) }) { node in
                    Button {
                        group = node.group; navigation = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            let r = rect(node); scale = 1; offset = CGSize(width: 24 - r.minX, height: 24 - r.minY)
                            selected = node
                            await session.action("focus", arguments: ["id": node.id])
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(node.title).foregroundStyle(.primary)
                            Text("#\(node.id) · \(node.modeTitle) · \(node.widgets.count) 项可编辑参数").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.searchable(text: $query, prompt: "名称、类型或节点编号")
                    .navigationTitle("节点导航").toolbar { Button("完成") { navigation = false } }
            }
        }
    }
    private func groupButton(_ id: String, _ title: String) -> some View {
        Button { group = id } label: {
            Text(title).font(.caption).padding(.horizontal, 12).padding(.vertical, 9)
                .foregroundStyle(group == id ? PocketPalette.accent : .primary)
                .background(group == id ? PocketPalette.accent.opacity(0.12) : Color.secondary.opacity(0.08), in: .capsule)
        }.buttonStyle(.plain)
    }
    private func hit(_ point: CGPoint) -> MobileCanvasNode? {
        let world = CGPoint(x: (point.x - offset.width) / scale, y: (point.y - offset.height) / scale)
        return nodes.reversed().first { rect($0).contains(world) }
    }
    private func zoom(to next: CGFloat, size: CGSize) {
        let factor = next / scale
        offset = CGSize(width: size.width / 2 - (size.width / 2 - offset.width) * factor,
                        height: size.height / 2 - (size.height / 2 - offset.height) * factor)
        scale = next
    }
    private func reset(size: CGSize) {
        scale = min(1.2, max(0.5, (size.width - 64) / 270))
        let first = nodes.first.map { rect($0).origin } ?? .zero
        offset = CGSize(width: 24 - first.x * scale, height: 24 - first.y * scale)
    }
    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        context.translateBy(x: offset.width, y: offset.height); context.scaleBy(x: scale, y: scale)
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for link in session.scene.links {
            guard let from = byID[link.from], let to = byID[link.to] else { continue }
            let a = rect(from), b = rect(to)
            var path = Path()
            path.move(to: CGPoint(x: a.maxX, y: a.midY))
            let bend = max(a.maxX, b.maxX) + 28
            path.addCurve(to: CGPoint(x: b.maxX, y: b.midY), control1: CGPoint(x: bend, y: a.midY), control2: CGPoint(x: bend, y: b.midY))
            context.stroke(path, with: .color(PocketPalette.accent.opacity(0.35)), lineWidth: 2)
        }
        for node in nodes {
            let r = rect(node), shape = Path(roundedRect: r, cornerRadius: 16)
            context.fill(shape, with: .color(Color(uiColor: .secondarySystemGroupedBackground)))
            context.stroke(shape, with: .color(node.mode == 0 ? PocketPalette.accent.opacity(0.6) : Color.secondary.opacity(0.4)), lineWidth: 1.5)
            context.draw(context.resolve(Text(node.title).font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)),
                         in: CGRect(x: r.minX + 14, y: r.minY + 12, width: 242, height: 43))
            context.draw(Text("#\(node.id) · \(node.modeTitle)\(node.subgraph ? " · 子图" : "")").font(.system(size: 12)).foregroundColor(.secondary),
                         at: CGPoint(x: r.minX + 14, y: r.minY + 67), anchor: .leading)
            context.draw(Text("\(node.widgets.count) 项参数   ›").font(.system(size: 12)).foregroundColor(PocketPalette.accent),
                         at: CGPoint(x: r.minX + 14, y: r.minY + 88), anchor: .leading)
        }
    }
}

struct MobileNodeInspector: View {
    let session: CanvasSession
    let nodeID: String
    let openCustom: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MobileCanvasWidget?
    @State private var pendingMode: Int?
    @State private var deleting = false
    private var node: MobileCanvasNode? { session.scene.nodes.first { $0.id == nodeID } }
    var body: some View {
        NavigationStack {
            List {
                if let node {
                    Section {
                        Text(node.type).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Menu("执行状态：\(node.modeTitle)") {
                            Button("启用") { pendingMode = 0 }; Button("静音（不执行）") { pendingMode = 2 }; Button("旁路（跳过处理）") { pendingMode = 4 }
                        }
                        .disabled(!session.loaded)
                        if node.subgraph { Button("进入子图", systemImage: "square.stack.3d.down.right") {
                            Task { await session.action("subgraph", arguments: ["id": nodeID]); dismiss() }
                        } }
                        Button("删除此节点", role: .destructive) { deleting = true }.disabled(!session.loaded)
                        Button("打开专用控件", systemImage: "rectangle.and.hand.point.up.left") { openCustom(); dismiss() }.disabled(!session.loaded)
                    } footer: { Text("复杂时间轴、遮罩和插件专用交互可进入专用控件。更改执行状态会影响生成结果。") }
                    Section("参数") {
                        ForEach(node.widgets) { widget in
                            Button { editing = widget } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(widget.name).font(.subheadline).foregroundStyle(.secondary)
                                    Text(widget.value.text.isEmpty ? "未填写" : widget.value.text).lineLimit(3).foregroundStyle(.primary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }.disabled(!session.loaded)
                        }
                    }
                }
            }.navigationTitle(node?.title ?? "节点").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
                .sheet(item: $editing) { widget in MobileWidgetEditor(session: session, nodeID: nodeID, widget: widget) }
                .confirmationDialog("删除此节点及其连线？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("删除节点", role: .destructive) { Task { await session.action("removeNode", arguments: ["id": nodeID]); dismiss() } }
                }
                .confirmationDialog("更改此节点的执行状态？", isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }), titleVisibility: .visible) {
                    Button("应用状态") { if let mode = pendingMode { Task { await session.action("nodeMode", arguments: ["id": nodeID, "mode": mode]) }; pendingMode = nil } }
                }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

struct MobileWidgetEditor: View {
    let session: CanvasSession
    let nodeID: String
    let widget: MobileCanvasWidget
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var flag = false
    @State private var saving = false
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                if case .bool = widget.value { Toggle(widget.name, isOn: $flag) }
                else if !widget.choices.isEmpty {
                    Picker(widget.name, selection: $text) {
                        ForEach(widget.choices.map(\.text), id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.inline)
                } else if case .string = widget.value {
                    TextEditor(text: $text).frame(minHeight: 260).textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    TextField(widget.name, text: $text).keyboardType(.numbersAndPunctuation)
                    if let min = widget.min, let max = widget.max { Text("范围 \(min.formatted()) – \(max.formatted())").font(.caption) }
                }
                if let issue { Text(issue).foregroundStyle(.red).font(.caption) }
            }.navigationTitle(widget.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("应用") { Task { await apply() } }.disabled(saving) }
                }.onAppear { text = widget.value.text; flag = widget.value == .bool(true) }
                .interactiveDismissDisabled(saving)
        }
    }
    private func apply() async {
        saving = true; defer { saving = false }
        do {
            let value: Any
            switch widget.value {
            case .bool: value = flag
            case .string: value = text
            default:
                guard let number = Double(text), number.isFinite else { throw PocketError.message("请输入有效数字。") }
                // WebKit/ComfyUI widgets use JavaScript numbers; do not silently round large integer edits.
                switch widget.value {
                case .integer, .unsigned:
                    guard number.rounded() == number, abs(number) <= 9007199254740991 else {
                        throw PocketError.message("请输入可精确表示的整数；大种子请在工作流参数页修改。")
                    }
                default: break
                }
                value = number
            }
            session.mutating = true; defer { session.mutating = false }
            _ = try await session.call("widget", arguments: ["id": nodeID, "index": widget.id, "value": value, "name": widget.name])
            await session.refreshScene(); dismiss()
        } catch { issue = error.localizedDescription }
    }
}
