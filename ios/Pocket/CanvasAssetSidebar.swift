import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pocketCanvasAsset = UTType(exportedAs: "com.xbunax.comfyuipocket.canvas-asset", conformingTo: .data)
}

struct CanvasAssetDrag: Codable {
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
    let close: () -> Void
    let message: String?
    let importing: Bool
    @State private var source: Source = .output
    @State private var folder = ""
    @State private var entries: [OutputDirectoryEntry] = []
    @State private var next: Int?
    @State private var loading = false
    @State private var failure: String?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("资产").font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .buttonStyle(.plain).accessibilityLabel("关闭资产侧栏")
            }
            Picker("资产来源", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
                .onChange(of: source) { _, _ in folder = "" }
            if !folder.isEmpty, source != .recent {
                Button {
                    folder = folder.split(separator: "/").dropLast().joined(separator: "/")
                } label: {
                    Label(folder.split(separator: "/").last.map(String.init) ?? folder, systemImage: "chevron.up")
                        .lineLimit(1)
                }.font(.caption).accessibilityHint("返回上一级文件夹")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if source == .recent {
                        if store.images.isEmpty { Text("还没有最近作品").font(.caption) }
                        ForEach(store.images) { assetRow($0) }
                    } else {
                        ForEach(entries) { entry in
                            if entry.isFolder {
                                Button { folder = entry.path } label: {
                                    Label(entry.name, systemImage: "folder")
                                        .font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            } else {
                                assetRow(entry.asset(type: source == .input ? "input" : "output"))
                            }
                        }
                        if loading { ProgressView().controlSize(.small) }
                        else if let failure {
                            Text(failure).font(.caption).foregroundStyle(PocketPalette.secondary)
                            Button("重试") { Task { await load(offset: next ?? 0) } }.font(.caption)
                        } else if let next {
                            Button("加载更多") { Task { await load(offset: next) } }.font(.caption)
                        } else if entries.isEmpty {
                            Text("此文件夹暂无图片或视频").font(.caption).foregroundStyle(PocketPalette.secondary)
                        }
                    }
                }
            }.refreshable { if source != .recent { await load() } }
            if importing {
                ProgressView("正在导入…").font(.caption).controlSize(.small)
            } else {
                Text(message ?? "拖到兼容的加载节点，或将图片拖到节点的参考图区。")
                    .font(.caption2).foregroundStyle(PocketPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(store.client?.serverID ?? "")/\(source.id)/\(folder)/\(store.outputDirectoryRevision)/\(store.pluginCapabilities.sorted())") { await load() }
    }

    private func assetRow(_ asset: OutputImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(output: asset, fill: true).frame(height: 76).clipShape(.rect(cornerRadius: 7))
            Text(asset.filename).font(.caption2).lineLimit(2).truncationMode(.middle)
                .foregroundStyle(PocketPalette.text)
        }
        .padding(4).background(PocketPalette.background, in: .rect(cornerRadius: 9))
        .contentShape(Rectangle())
        .onDrag { CanvasAssetDrag(serverID: store.client?.serverID ?? "", asset: asset).provider() }
        .accessibilityElement(children: .combine)
        .accessibilityHint("拖到画布中对应的输入节点")
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
