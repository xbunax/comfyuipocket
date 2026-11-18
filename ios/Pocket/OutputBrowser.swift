import SwiftUI

struct OutputBrowserView: View {
    @Environment(PocketStore.self) private var store
    let onPreview: (ArtworkSequence) -> Void
    @AppStorage("outputBrowserLayout") private var displayLayout = "grid"
    @AppStorage("mediaSortKey") private var sortKey = "time"
    @AppStorage("mediaSortAscending") private var ascending = false
    @State private var folder = ""
    @State private var entries: [OutputDirectoryEntry] = []
    @State private var total = 0
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var message: String?
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
                            Text("\(total) 项 · 图片与视频").font(.caption).foregroundStyle(PocketPalette.secondary)
                            Spacer()
                            layoutMenu
                            MediaSortMenu(sortKey: $sortKey, ascending: $ascending)
                                .disabled(!store.pluginCapabilities.contains("output-sort"))
                            Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }
                                .labelStyle(.iconOnly).disabled(loading)
                        }
                        if !store.pluginCapabilities.contains("output-sort") {
                            Text("目录排序需要电脑端 Pocket 插件 v0.8.0；当前按时间从新到旧显示。")
                                .font(.caption).foregroundStyle(PocketPalette.secondary)
                        }
                        if let message {
                            HStack(spacing: 8) {
                                Image(systemName: "folder").foregroundStyle(PocketPalette.accent)
                                Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(2)
                                Spacer(minLength: 0)
                            }.padding(10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .background(PocketPalette.surface, in: .rect(cornerRadius: 12))
                        }.buttonStyle(.plain).hoverEffect(.highlight)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(folders) { entry in
                        Button { folder = entry.path } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").font(.title2).foregroundStyle(PocketPalette.accent)
                                Text(entry.name).font(.subheadline.weight(.medium)).foregroundStyle(PocketPalette.text).lineLimit(2)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(PocketPalette.secondary)
                            }.padding(14).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverEffect(.highlight)
                        if entry.id != folders.last?.id { Divider().padding(.leading, 52) }
                    }
                }.background(PocketPalette.surface, in: .rect(cornerRadius: 18))
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
                                    Text(entry.name).font(.subheadline.weight(.medium)).foregroundStyle(PocketPalette.text).lineLimit(2)
                                    fileMetadata(entry)
                                    Text(Date(timeIntervalSince1970: Double(entry.modified) / 1000), format: .dateTime.month().day().hour().minute())
                                        .font(.caption2).foregroundStyle(PocketPalette.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }.padding(12).contentShape(Rectangle())
                        }.buttonStyle(.plain).hoverEffect(.highlight)
                        if entry.id != files.last?.id { Divider().padding(.leading, 92) }
                    }
                }.background(PocketPalette.surface, in: .rect(cornerRadius: 18))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: displayLayout == "large" ? 260 : 150), spacing: 12)], spacing: 16) {
                    ForEach(files) { entry in
                        Button { preview(entry.output) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                RemoteImage(output: entry.output, fill: true).frame(height: displayLayout == "large" ? 240 : 150)
                                    .clipped().clipShape(.rect(cornerRadius: 14))
                                Text(entry.name).font(.caption).foregroundStyle(PocketPalette.text).lineLimit(2)
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
        }.font(.caption2).foregroundStyle(PocketPalette.secondary)
    }

    private func preview(_ output: OutputImage) {
        guard let api = store.client else { return }
        let directory = folder, order = sortKey, up = ascending
        onPreview(ArtworkSequence(selected: output, items: files.map(\.output), next: nextOffset) { offset in
            try await api.outputDirectory(folder: directory, offset: offset, sort: order, ascending: up)
        })
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

    @MainActor private func load(offset: Int = 0) async {
        let token = UUID(); requestID = token
        if offset == 0 { entries = []; total = 0; nextOffset = nil }
        message = nil
        guard available, let api = store.client else { loading = false; return }
        let requestedFolder = folder
        loading = true
        defer { if requestID == token { loading = false } }
        do {
            let page = try await api.outputDirectory(folder: requestedFolder, offset: offset, sort: sortKey, ascending: ascending)
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
