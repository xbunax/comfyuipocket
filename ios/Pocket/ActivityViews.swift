import SwiftUI
import Photos
import AVKit

struct QueueView: View {
    @Environment(PocketStore.self) private var store
    @State private var confirming = false
    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionBadge() }
                if let running = store.runningPromptID {
                    Section("正在生成") {
                        if let preview = store.preview, let image = UIImage(data: preview) {
                            Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16))
                        }
                        ProgressView(value: store.progress) { Text(store.activeNode.isEmpty ? "处理中" : "当前节点 #\(store.activeNode)") }
                        Text("当前采样进度 \(Int(store.progress * 100))% · 非整个工作流总进度").font(.caption).foregroundStyle(.secondary)
                        NavigationLink("查看任务详情") { TaskDetailView(promptID: running) }
                        Button("停止服务器当前任务", role: .destructive) { confirming = true }
                    }
                }
                Section("等待执行 · \(store.queue["queue_pending"].array.count)") {
                    if store.queue["queue_pending"].array.isEmpty { Text("队列空闲，灵感随时开始。").foregroundStyle(.secondary) }
                    ForEach(Array(store.queue["queue_pending"].array.enumerated()), id: \.offset) { _, item in
                        let id = item.array.count > 1 ? item.array[1].text : ""
                        NavigationLink { TaskDetailView(promptID: id) } label: {
                            Label(String(id.prefix(8)), systemImage: "clock").font(.body.monospaced())
                        }
                        .swipeActions {
                            Button("取消", role: .destructive) { Task { await store.deletePending(id) } }
                        }
                    }
                }
                Section("最近执行") {
                    ForEach(store.sortedHistoryIDs, id: \.self) { id in
                        let entry = store.history[id]
                        NavigationLink { TaskDetailView(promptID: id) } label: {
                            HStack {
                                Image(systemName: entry["status"]["status_str"].text == "error" ? "exclamationmark.circle" : "checkmark.circle")
                                Text(String(id.prefix(8))).font(.body.monospaced())
                                Spacer()
                                Text(statusLabel(entry["status"]["status_str"].text)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.navigationTitle("任务").refreshable { await store.refresh() }
                .confirmationDialog("停止服务器当前运行的任务？", isPresented: $confirming, titleVisibility: .visible) {
                    Button("停止当前任务", role: .destructive) { Task { await store.interrupt() } }
                } message: { Text("ComfyUI 的停止接口会影响服务器正在执行的任务，包括其他客户端提交的任务。") }
        }
    }
    private func statusLabel(_ status: String) -> String {
        switch status {
        case "success": return "已完成"
        case "error": return "失败"
        default: return status
        }
    }
}

struct TaskDetailView: View {
    @Environment(PocketStore.self) private var store
    let promptID: String
    @State private var selectedOutput: OutputImage?

    private var entry: JSONValue? {
        let value = store.history[promptID]
        return value.object.isEmpty ? nil : value
    }
    private var prompt: JSONValue {
        if let entry, entry["prompt"].array.count > 2 { return entry["prompt"].array[2] }
        if let item = store.queueItem(promptID: promptID), item.array.count > 2 { return item.array[2] }
        return .null
    }
    private var workflow: Workflow? {
        guard !prompt.object.isEmpty,
              let data = try? JSONEncoder().encode(JSONValue.object(["prompt": prompt])) else { return nil }
        return try? Workflow.load(data, name: "任务")
    }
    private var promptFields: [WorkflowField] {
        workflow?.fields.filter { field in
            let key = field.key.lowercased()
            return key == "text" || key.contains("prompt")
        } ?? []
    }
    private var parameterFields: [WorkflowField] {
        workflow?.fields.filter { field in
            let key = field.key.lowercased()
            return key != "text" && !key.contains("prompt")
        } ?? []
    }
    private var outputs: [OutputImage] {
        guard let entry else { return [] }
        return OutputImage.fromHistoryEntry(entry, promptID: promptID)
    }
    private var statusText: String {
        if let entry {
            let status = entry["status"]["status_str"].text
            switch status {
            case "success": return "已完成"
            case "error": return "失败"
            case "": return "已结束"
            default: return status
            }
        }
        if store.isRunning(promptID) { return "正在执行" }
        if store.isPending(promptID) { return "等待执行" }
        return "任务记录不可用"
    }
    var body: some View {
        List {
            Section("状态") {
                LabeledContent("状态", value: statusText)
                Text(promptID).font(.caption.monospaced()).textSelection(.enabled)
                if store.isRunning(promptID) {
                    ProgressView(value: store.progress)
                }
            }
            if store.isRunning(promptID), let preview = store.preview, let image = UIImage(data: preview) {
                Section("实时预览") {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16))
                }
            }
            if !outputs.isEmpty {
                Section("生成产物") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(outputs) { output in
                            Button { selectedOutput = output } label: {
                                RemoteImage(output: output)
                                    .frame(height: 140)
                                    .clipped()
                                    .clipShape(.rect(cornerRadius: 14))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4)
                }
            }
            if !promptFields.isEmpty {
                Section("提示词") {
                    ForEach(promptFields) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(field.nodeTitle) · \(field.key)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(field.value.text).textSelection(.enabled)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !parameterFields.isEmpty {
                Section("使用的参数") {
                    ForEach(parameterFields) { field in
                        LabeledContent("\(field.nodeTitle) · \(field.key)", value: field.value.text)
                            .font(.subheadline)
                    }
                }
            }
            if store.isPending(promptID) {
                Section {
                    Button("取消此任务", role: .destructive) {
                        Task { await store.deletePending(promptID) }
                    }
                }
            }
            if workflow == nil {
                Section {
                    Text("任务参数暂不可用，可能已被历史记录清理。").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedOutput) { ImageDetail(output: $0) }
        .refreshable { await store.refresh() }
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
                    ContentUnavailableView("你的作品将在这里出现", systemImage: "photo.on.rectangle.angled", description: Text("连接服务器后，可查看最近 50 次任务生成的图片和视频。"))
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
            if output.isVideo { Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.mint) }
            else if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView() }
        }.task(id: output.id) {
            guard !output.isVideo else { return }
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
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                if let player { VideoPlayer(player: player) }
                else if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if status.isEmpty { ProgressView() }
                Spacer()
                Text(output.filename).font(.caption).textSelection(.enabled)
                HStack {
                    Button("保存到照片", systemImage: "square.and.arrow.down") {
                        Task {
                            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                            guard auth == .authorized || auth == .limited else { status = "请在系统设置中允许保存照片。"; return }
                            do {
                                if output.isVideo, let shareURL {
                                    try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: shareURL) }
                                } else if let image {
                                    try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
                                }
                                status = "已保存到照片。"
                            } catch { status = error.localizedDescription }
                        }
                    }.buttonStyle(.glassProminent).disabled(shareURL == nil)
                    if let shareURL { ShareLink(item: shareURL) { Label("分享", systemImage: "square.and.arrow.up") }.buttonStyle(.glass) }
                }.padding()
                if !status.isEmpty { Text(status).font(.caption).padding() }
            }.navigationTitle("作品预览").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
                .task {
                    do {
                        guard let file = try await store.client?.download(output) else { return }
                        shareURL = file
                        if output.isVideo {
                            player = AVPlayer(url: file)
                            if URL(fileURLWithPath: output.filename).pathExtension.lowercased() == "webm" { status = "系统可能无法播放 WebM，可使用分享在其他应用中打开。" }
                        } else { image = UIImage(contentsOfFile: file.path) }
                    } catch { status = error.localizedDescription }
                }
                .onDisappear { player?.pause(); if let shareURL { try? FileManager.default.removeItem(at: shareURL) } }
        }
    }
}
