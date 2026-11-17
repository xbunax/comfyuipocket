import SwiftUI

struct OutputBrowserView: View {
    @Environment(PocketStore.self) private var store
    @State private var folder = ""
    @State private var entries: [OutputDirectoryEntry] = []
    @State private var total = 0
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var message: String?
    @State private var selected: OutputImage?
    @State private var requestID = UUID()
    private var folders: [OutputDirectoryEntry] { entries.filter(\.isFolder) }
    private var files: [OutputDirectoryEntry] { entries.filter { !$0.isFolder } }
    private var available: Bool { store.connected && store.pluginCapabilities.contains("output-browser") }

    var body: some View {
        Group {
            if !store.connected {
                ContentUnavailableView("请先连接 ComfyUI", systemImage: "externaldrive.badge.wifi", description: Text("连接后可浏览电脑 output 目录中的历史图片和视频。"))
            } else if !available {
                ContentUnavailableView("需要更新电脑端插件", systemImage: "arrow.down.circle", description: Text("历史 Output 需要 Pocket 插件 v0.7.0。更新后重启 ComfyUI，并重新连接 App。"))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        breadcrumbs
                        HStack {
                            Text("\(total) 项 · 图片与视频").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }
                                .labelStyle(.iconOnly).disabled(loading)
                        }
                        if let message {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(message, systemImage: "exclamationmark.circle").font(.footnote)
                                Button("重试") { Task { await load(offset: entries.isEmpty ? 0 : (nextOffset ?? 0)) } }
                            }.foregroundStyle(.secondary)
                        }
                        if !folders.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(folders) { entry in
                                    Button { folder = entry.path } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "folder.fill").font(.title2).foregroundStyle(PocketPalette.accent)
                                            Text(entry.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                        }.padding(14).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    if entry.id != folders.last?.id { Divider().padding(.leading, 52) }
                                }
                            }.background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 16) {
                            ForEach(files) { entry in
                                Button { selected = entry.output } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        RemoteImage(output: entry.output).frame(height: 150).clipped().clipShape(.rect(cornerRadius: 14))
                                        Text(entry.name).font(.caption).foregroundStyle(.primary).lineLimit(2)
                                        HStack(spacing: 4) {
                                            if entry.output.isVideo { Image(systemName: "video") }
                                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                            Spacer(minLength: 0)
                                        }.font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                        else if let offset = nextOffset {
                            Button("加载更多") { Task { await load(offset: offset) } }
                                .buttonStyle(.glass).frame(maxWidth: .infinity).padding(.vertical, 8)
                        } else if entries.isEmpty && message == nil {
                            ContentUnavailableView("此文件夹暂无图片或视频", systemImage: "folder", description: Text("这里直接显示服务器文件，不受 ComfyUI 任务历史记录是否保留的影响。"))
                        }
                    }.padding(16)
                }.refreshable { await load() }
            }
        }
        .task(id: "\(store.client?.baseURL.absoluteString ?? "")|\(available)|\(folder)") { await load() }
        .sheet(item: $selected) { output in
            ImageDetail(output: output, allowDeletion: false, knownRecord: provenance(output))
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { folder = "" } label: { Label("Output", systemImage: "externaldrive") }
                let parts = folder.split(separator: "/").map(String.init)
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(part) { folder = parts.prefix(index + 1).joined(separator: "/") }
                }
            }.font(.subheadline.weight(.medium)).buttonStyle(.plain)
        }.padding(.vertical, 4)
    }

    private func provenance(_ output: OutputImage) -> MediaProvenance? {
        let archive = store.currentMediaArchive
        guard let known = archive.outputs.first(where: { $0.assetID == output.assetID }) else { return nil }
        return archive.provenance?[known.promptID]
    }

    @MainActor private func load(offset: Int = 0) async {
        let token = UUID(); requestID = token
        if offset == 0 { entries = []; total = 0; nextOffset = nil }
        message = nil
        guard available, let api = store.client else { loading = false; return }
        let requestedFolder = folder
        loading = true
        defer { if requestID == token { loading = false } }
        do {
            let value = try await api.json("pocket/v1/outputs", query: [
                .init(name: "folder", value: requestedFolder), .init(name: "offset", value: String(offset)),
                .init(name: "limit", value: "60")
            ])
            let page = try JSONDecoder().decode(OutputDirectoryPage.self, from: JSONEncoder().encode(value))
            guard !Task.isCancelled, requestID == token, store.client === api, folder == requestedFolder else { return }
            var seen = Set(entries.map(\.id))
            entries += page.entries.filter { seen.insert($0.id).inserted }
            total = page.total; nextOffset = page.nextOffset
        } catch {
            guard !Task.isCancelled, requestID == token, store.client === api else { return }
            message = "无法读取此文件夹：\(error.localizedDescription)"
        }
    }
}
