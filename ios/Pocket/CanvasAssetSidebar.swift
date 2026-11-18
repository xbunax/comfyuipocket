import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let pocketCanvasAsset = UTType(exportedAs: "com.xbunax.comfyuipocket.canvas-asset", conformingTo: .data)
}

struct CanvasAssetDrag: Codable, Equatable {
    let serverID: String
    let asset: OutputImage

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = asset.filename
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pocketCanvasAsset.identifier, visibility: .ownProcess) { complete in
            complete(data, nil)
            return nil
        }
        return provider
    }
}

struct CanvasAssetSidebar: View {
    @Environment(PocketStore.self) private var store
    private enum Source: String, CaseIterable, Identifiable {
        case output = "输出", input = "输入", recent = "最近"
        var id: String { rawValue }
    }
    let horizontal: Bool
    let close: () -> Void
    let message: String?
    let importing: Bool
    let selected: CanvasAssetDrag?
    let select: (CanvasAssetDrag) -> Void
    let dragBegan: () -> Void
    let dragEnded: (Bool) -> Void
    let cancelSelection: () -> Void
    @State private var source: Source = .output
    @State private var folder = ""
    @State private var entries: [OutputDirectoryEntry] = []
    @State private var next: Int?
    @State private var loading = false
    @State private var failure: String?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("资产").font(.subheadline.weight(.semibold))
                if horizontal { sourcePicker }
                else { Spacer() }
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .buttonStyle(.plain).accessibilityLabel("关闭资产面板")
            }
            if !horizontal { sourcePicker }
            if !folder.isEmpty, source != .recent {
                Button {
                    folder = folder.split(separator: "/").dropLast().joined(separator: "/")
                } label: {
                    Label(folder.split(separator: "/").last.map(String.init) ?? folder, systemImage: "chevron.up")
                        .lineLimit(1)
                }.font(.caption).accessibilityHint("返回上一级文件夹")
            }
            if horizontal {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .center, spacing: 8) { assetTiles }
                }
                .scrollIndicators(.hidden)
                .frame(height: 96)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) { assetTiles }
                }
                .refreshable { if source != .recent { await load() } }
            }
            if importing {
                ProgressView("正在导入…").font(.caption).controlSize(.small)
            } else if let selected {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.asset.filename).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Text(message ?? "点画布里的节点或参考图区。").lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button("取消", action: cancelSelection).buttonStyle(.borderless)
                }.font(.caption2).foregroundStyle(PocketPalette.secondary)
            } else {
                Text(message ?? "长按拖入画布，或点选素材再点目标节点。")
                    .font(.caption2).foregroundStyle(PocketPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 4)
        .frame(maxWidth: horizontal ? .infinity : nil, maxHeight: horizontal ? nil : .infinity, alignment: .topLeading)
        .task(id: "\(store.client?.serverID ?? "")/\(source.id)/\(folder)/\(store.outputDirectoryRevision)/\(store.pluginCapabilities.sorted())") { await load() }
    }

    private var sourcePicker: some View {
        Picker("资产来源", selection: $source) {
            ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: source) { _, _ in folder = "" }
    }

    @ViewBuilder private var assetTiles: some View {
        if source == .recent {
            if store.images.isEmpty { Text("还没有最近作品").font(.caption) }
            ForEach(store.images) { assetRow($0) }
        } else {
            ForEach(entries) { entry in
                if entry.isFolder {
                    Button { folder = entry.path } label: {
                        Label(entry.name, systemImage: "folder")
                            .font(.caption).lineLimit(2)
                            .frame(maxWidth: horizontal ? nil : .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .frame(width: horizontal ? 108 : nil, height: horizontal ? 88 : nil, alignment: .center)
                            .background(horizontal ? PocketPalette.background : Color.clear, in: .rect(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else {
                    assetRow(entry.asset(type: source == .input ? "input" : "output"))
                }
            }
            if loading { ProgressView().controlSize(.small) }
            else if let failure {
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure).foregroundStyle(PocketPalette.secondary)
                    Button("重试") { Task { await load(offset: next ?? 0) } }
                }.font(.caption)
            } else if let next {
                Button("加载更多") { Task { await load(offset: next) } }.font(.caption)
            } else if entries.isEmpty {
                Text("此文件夹暂无图片或视频").font(.caption).foregroundStyle(PocketPalette.secondary)
            }
        }
    }

    private func assetRow(_ asset: OutputImage) -> some View {
        let drag = CanvasAssetDrag(serverID: store.client?.serverID ?? "", asset: asset)
        return VStack(alignment: .leading, spacing: 4) {
            RemoteImage(output: asset, fill: true).frame(height: horizontal ? 59 : 76).clipShape(.rect(cornerRadius: 7))
            Text(asset.filename).font(.caption2).lineLimit(2).truncationMode(.middle)
                .foregroundStyle(PocketPalette.text)
        }
        .padding(4).frame(width: horizontal ? 112 : nil)
        .background(PocketPalette.background, in: .rect(cornerRadius: 9))
        .overlay {
            if selected == drag { RoundedRectangle(cornerRadius: 9).strokeBorder(PocketPalette.accent, lineWidth: 2) }
        }
        .accessibilityHidden(true)
        .overlay {
            CanvasAssetTileInput(asset: drag, selected: selected == drag, select: { select(drag) },
                                 dragBegan: dragBegan, dragEnded: dragEnded)
        }
    }

    private func load(offset: Int = 0) async {
        let id = UUID()
        requestID = id
        if offset == 0 { entries = []; next = nil }
        loading = false
        failure = nil
        let requested = source, path = folder
        guard requested != .recent, let api = store.client else { return }
        let capabilities = store.pluginCapabilities
        guard capabilities.contains(requested == .input ? "canvas-assets" : "output-browser") else {
            failure = "更新服务器 Pocket 插件后可浏览此目录。"
            return
        }
        loading = true
        defer { if requestID == id { loading = false } }
        do {
            let result = try await api.outputDirectory(folder: path, offset: offset, sort: "time", ascending: false, input: requested == .input)
            guard !Task.isCancelled, requestID == id, requested == source, path == folder, store.client === api else { return }
            var seen = Set(entries.map(\.id))
            entries += result.entries.filter { seen.insert($0.id).inserted }
            next = result.nextOffset
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}

/// Keep both ends of the drag in UIKit. The payload stays in the same app.
private struct CanvasAssetTileInput: UIViewRepresentable {
    let asset: CanvasAssetDrag
    let selected: Bool
    let select: () -> Void
    let dragBegan: () -> Void
    let dragEnded: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.isAccessibilityElement = true
        button.addTarget(context.coordinator, action: #selector(Coordinator.selectAsset), for: .touchUpInside)
        let drag = UIDragInteraction(delegate: context.coordinator)
        drag.isEnabled = true
        button.addInteraction(drag)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.accessibilityLabel = asset.asset.filename
        button.accessibilityHint = "轻点后选取目标节点，也可按住拖入画布"
        button.accessibilityTraits = selected ? [.button, .selected] : .button
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Coordinator: NSObject, UIDragInteractionDelegate {
        var parent: CanvasAssetTileInput
        init(_ parent: CanvasAssetTileInput) { self.parent = parent }
        @objc func selectAsset() { parent.select() }
        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            let item = UIDragItem(itemProvider: parent.asset.provider())
            item.localObject = parent.asset
            return [item]
        }
        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) { parent.dragBegan() }
        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
            parent.dragEnded(operation == .copy)
        }
        func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
    }
}

struct CanvasAssetTarget: UIViewRepresentable {
    let targeted: (Bool) -> Void
    let dropped: (CanvasAssetDrag, CGPoint) -> Void
    let tapped: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.addInteraction(UIDropInteraction(delegate: context.coordinator))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var parent: CanvasAssetTarget
        init(_ parent: CanvasAssetTarget) { self.parent = parent }
        private func position(_ point: CGPoint, in view: UIView) -> CGPoint? {
            guard view.bounds.width > 0, view.bounds.height > 0, view.bounds.contains(point) else { return nil }
            return CGPoint(x: (point.x - view.bounds.minX) / view.bounds.width,
                           y: (point.y - view.bounds.minY) / view.bounds.height)
        }
        private func asset(in session: UIDropSession) -> CanvasAssetDrag? {
            session.items.first?.localObject as? CanvasAssetDrag
        }
        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool { asset(in: session) != nil }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) { parent.targeted(true) }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { parent.targeted(false) }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { parent.targeted(false) }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }
        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard let asset = asset(in: session), let view = interaction.view,
                  let point = position(session.location(in: view), in: view) else { return }
            parent.targeted(false)
            parent.dropped(asset, point)
        }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view, let point = position(recognizer.location(in: view), in: view) else { return }
            parent.tapped(point)
        }
    }
}
