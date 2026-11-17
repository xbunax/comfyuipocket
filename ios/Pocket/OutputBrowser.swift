import SwiftUI

struct OutputBrowserView: View {
    @Environment(PocketStore.self) private var store
    var onPreview: ((OutputImage, MediaProvenance?) -> Void)? = nil
    @AppStorage("outputBrowserLayout") private var displayLayout = "grid"
    @AppStorage("mediaSortKey") private var sortKey = "time"
    @AppStorage("mediaSortAscending") private var ascending = false
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
                            layoutMenu
                            MediaSortMenu(sortKey: $sortKey, ascending: $ascending)
                                .disabled(!store.pluginCapabilities.contains("output-sort"))
                            Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }
                                .labelStyle(.iconOnly).disabled(loading)
                        }
                        if !store.pluginCapabilities.contains("output-sort") {
                            Text("目录排序需要电脑端 Pocket 插件 v0.8.0；当前按时间从新到旧显示。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let message {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(message, systemImage: "exclamationmark.circle").font(.footnote)
                                Button("重试") { Task { await load(offset: entries.isEmpty ? 0 : (nextOffset ?? 0)) } }
                            }.foregroundStyle(.secondary)
                        }
                        folderSection
                        fileSection
                        if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                        else if let offset = nextOffset {
                            Button("加载更多") { Task { await load(offset: offset) } }
                                .buttonStyle(.glass).frame(maxWidth: .infinity).padding(.vertical, 8)
                        } else if entries.isEmpty && message == nil {
                            ContentUnavailableView("此文件夹暂无图片或视频", systemImage: "folder", description: Text("这里直接显示服务器文件，不受 ComfyUI 任务历史记录是否保留的影响。"))
                        }
                    }.padding(16)
                }.contentMargins(.bottom, 28, for: .scrollContent).refreshable { await load() }
            }
        }
        .task(id: "\(store.client?.serverID ?? "")|\(available)|\(folder)|\(sortKey)|\(ascending)") { await load() }
        .edgeSwipeBack(enabled: !folder.isEmpty) { folder = folder.split(separator: "/").dropLast().joined(separator: "/") }
        .sheet(item: $selected) { output in
            ImageDetail(output: output, allowDeletion: false, knownRecord: provenance(output))
        }
    }

    private var layoutMenu: some View {
        Menu {
            Picker("显示方式", selection: $displayLayout) {
                Label("平铺", systemImage: "square.grid.2x2").tag("grid")
                Label("大图", systemImage: "rectangle").tag("large")
                Label("列表", systemImage: "list.bullet").tag("list")
            }
        } label: { Label("布局", systemImage: displayLayout == "list" ? "list.bullet" : "square.grid.2x2") }
            .font(.subheadline).accessibilityIdentifier("output.layout")
    }

    @ViewBuilder private var folderSection: some View {
        if !folders.isEmpty {
            Label("文件夹 · \(folders.count)", systemImage: "folder").font(.subheadline.weight(.semibold))
            if displayLayout != "list" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: displayLayout == "large" ? 260 : 150), spacing: 12)], spacing: 12) {
                    ForEach(folders) { entry in
                        Button { folder = entry.path } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(PocketPalette.accent)
                                Text(entry.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(16).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                        }.buttonStyle(.plain).hoverEffect(.highlight)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(folders) { entry in
                        Button { folder = entry.path } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").font(.title2).foregroundStyle(PocketPalette.accent)
                                Text(entry.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(14).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverEffect(.highlight)
                        if entry.id != folders.last?.id { Divider().padding(.leading, 52) }
                    }
                }.background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            }
        }
    }

    @ViewBuilder private var fileSection: some View {
        if !files.isEmpty {
            Label("图片与视频 · \(files.count)", systemImage: "photo.on.rectangle").font(.subheadline.weight(.semibold))
            if displayLayout == "list" {
                LazyVStack(spacing: 0) {
                    ForEach(files) { entry in
                        Button { preview(entry.output) } label: {
                            HStack(spacing: 12) {
                                RemoteImage(output: entry.output).frame(width: 68, height: 68).clipped().clipShape(.rect(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                    fileMetadata(entry)
                                    Text(Date(timeIntervalSince1970: Double(entry.modified) / 1000), format: .dateTime.month().day().hour().minute())
                                        .font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }.padding(12).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverEffect(.highlight)
                        if entry.id != files.last?.id { Divider().padding(.leading, 92) }
                    }
                }.background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: displayLayout == "large" ? 260 : 150), spacing: 12)], spacing: 16) {
                    ForEach(files) { entry in
                        Button { preview(entry.output) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                RemoteImage(output: entry.output).frame(height: displayLayout == "large" ? 240 : 150)
                                    .clipped().clipShape(.rect(cornerRadius: 14))
                                Text(entry.name).font(.caption).foregroundStyle(.primary).lineLimit(2)
                                fileMetadata(entry)
                            }
                        }.buttonStyle(.plain).hoverEffect(.highlight)
                    }
                }
            }
        }
    }

    private func fileMetadata(_ entry: OutputDirectoryEntry) -> some View {
        HStack(spacing: 5) {
            Image(systemName: entry.output.isVideo ? "video" : "photo")
            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private func preview(_ output: OutputImage) {
        if let onPreview { onPreview(output, provenance(output)) }
        else { selected = output }
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
                .init(name: "limit", value: "60"), .init(name: "sort", value: sortKey),
                .init(name: "direction", value: ascending ? "ascending" : "descending")
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
