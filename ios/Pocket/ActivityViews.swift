import SwiftUI
import Photos

struct QueueView: View {
    @Environment(PocketStore.self) private var store
    @State private var confirming = false
    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionBadge() }
                if !store.activePrompt.isEmpty || !store.queue["queue_running"].array.isEmpty {
                    Section("正在生成") {
                        if let preview = store.preview, let image = UIImage(data: preview) {
                            Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16))
                        }
                        ProgressView(value: store.progress) { Text(store.activeNode.isEmpty ? "处理中" : "当前节点 #\(store.activeNode)") }
                        Text("当前采样进度 \(Int(store.progress * 100))% · 非整个工作流总进度").font(.caption).foregroundStyle(.secondary)
                        Button("停止服务器当前任务", role: .destructive) { confirming = true }
                    }
                }
                Section("等待执行 · \(store.queue["queue_pending"].array.count)") {
                    if store.queue["queue_pending"].array.isEmpty { Text("队列空闲，灵感随时开始。").foregroundStyle(.secondary) }
                    ForEach(Array(store.queue["queue_pending"].array.enumerated()), id: \.offset) { _, item in
                        let id = item.array.count > 1 ? item.array[1].text : ""
                        HStack {
                            Label(String(id.prefix(8)), systemImage: "clock").font(.body.monospaced())
                            Spacer()
                            Button("取消", role: .destructive) { Task { await store.deletePending(id) } }
                        }
                    }
                }
                Section("最近执行") {
                    ForEach(store.history.object.keys.sorted(), id: \.self) { id in
                        let entry = store.history[id]
                        HStack {
                            Image(systemName: entry["status"]["status_str"].text == "error" ? "exclamationmark.circle" : "checkmark.circle")
                            Text(String(id.prefix(8))).font(.body.monospaced())
                            Spacer()
                            Text(entry["status"]["status_str"].text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("任务").refreshable { await store.refresh() }
                .confirmationDialog("停止服务器当前运行的任务？", isPresented: $confirming, titleVisibility: .visible) {
                    Button("停止当前任务", role: .destructive) { Task { await store.interrupt() } }
                } message: { Text("ComfyUI 的停止接口会影响服务器正在执行的任务，包括其他客户端提交的任务。") }
        }
    }
}

struct GalleryView: View {
    @Environment(PocketStore.self) private var store
    @State private var selected: OutputImage?
    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackground()
                if store.images.isEmpty {
                    ContentUnavailableView("你的作品将在这里出现", systemImage: "photo.on.rectangle.angled", description: Text("连接服务器后，可查看最近 50 次任务生成的图片。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(store.images) { image in
                                Button { selected = image } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        RemoteImage(output: image).frame(height: 180).clipped().clipShape(.rect(cornerRadius: 20))
                                        Text(image.filename).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding()
                    }.refreshable { await store.refresh() }
                }
            }.navigationTitle("作品")
                .toolbar { Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refresh() } }.disabled(!store.connected) }
                .sheet(item: $selected) { ImageDetail(output: $0) }
        }
    }
}

struct RemoteImage: View {
    @Environment(PocketStore.self) private var store
    let output: OutputImage
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView() }
        }.task(id: output.id) {
            do {
                guard let data = try await store.client?.image(output), let decoded = UIImage(data: data) else { failed = true; return }
                image = decoded
            } catch { failed = true }
        }
    }
}

struct ImageDetail: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let output: OutputImage
    @State private var image: UIImage?
    @State private var shareURL: URL?
    @State private var status = ""
    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView() }
                Spacer()
                Text(output.filename).font(.caption).textSelection(.enabled)
                HStack {
                    Button("保存到照片", systemImage: "square.and.arrow.down") {
                        Task {
                            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                            guard auth == .authorized || auth == .limited, let image else { status = "请在系统设置中允许保存照片。"; return }
                            do {
                                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
                                status = "已保存到照片。"
                            } catch { status = error.localizedDescription }
                        }
                    }.buttonStyle(.glassProminent).disabled(image == nil)
                    if let shareURL { ShareLink(item: shareURL) { Label("分享", systemImage: "square.and.arrow.up") }.buttonStyle(.glass) }
                }.padding()
                if !status.isEmpty { Text(status).font(.caption).padding() }
            }.navigationTitle("作品预览").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
                .task {
                    do {
                        guard let data = try await store.client?.image(output) else { return }
                        image = UIImage(data: data)
                        let safeName = URL(fileURLWithPath: output.filename).lastPathComponent
                        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
                        try data.write(to: file, options: .atomic); shareURL = file
                    } catch { status = error.localizedDescription }
                }
                .onDisappear { if let shareURL { try? FileManager.default.removeItem(at: shareURL) } }
        }
    }
}
