import SwiftUI
import Photos
import AVKit

struct QueueView: View {
    @Environment(PocketStore.self) private var store
    @State private var confirming = false
    private var knownIDs: Set<String> { Set(store.currentGenerationTasks.flatMap { $0.items.map(\.id) }) }
    private var activeTasks: [GenerationTask] {
        store.currentGenerationTasks.filter { $0.submitting || $0.summary(queue: store.queue, history: store.history).active }
    }
    private var recentTasks: [GenerationTask] {
        store.currentGenerationTasks.filter { !$0.submitting && !$0.summary(queue: store.queue, history: store.history).active }
    }
    private var otherQueue: [JSONValue] {
        (store.queue["queue_running"].array + store.queue["queue_pending"].array).filter {
            $0.array.count > 1 && !knownIDs.contains($0.array[1].text)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionBadge() }
                if store.runningPromptID != nil {
                    Section("当前生成预览") {
                        if let preview = store.preview, let image = UIImage(data: preview) {
                            Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16))
                        }
                        ProgressView(value: store.progress)
                        Text("当前采样进度 \(Int(store.progress * 100))% · 非整个批次总进度")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("停止服务器当前生成", role: .destructive) { confirming = true }
                    }
                }
                Section("当前任务 · \(activeTasks.count + otherQueue.count)") {
                    if activeTasks.isEmpty && otherQueue.isEmpty { Text("队列空闲，灵感随时开始。").foregroundStyle(.secondary) }
                    ForEach(activeTasks) { task in taskRow(task) }
                    ForEach(Array(otherQueue.enumerated()), id: \.offset) { _, item in
                        let id = item.array[1].text
                        NavigationLink { TaskDetailView(promptID: id) } label: {
                            Label(String(id.prefix(8)), systemImage: store.isRunning(id) ? "play.circle" : "clock")
                        }.swipeActions {
                            if store.isPending(id) { Button("取消", role: .destructive) { Task { await store.deletePending(id) } } }
                        }
                    }
                }
                Section("最近任务") {
                    ForEach(recentTasks) { task in taskRow(task) }
                    ForEach(store.sortedHistoryIDs.filter { !knownIDs.contains($0) }, id: \.self) { id in
                        NavigationLink { TaskDetailView(promptID: id) } label: {
                            Label(String(id.prefix(8)), systemImage: store.history[id]["status"]["status_str"].text == "error" ? "exclamationmark.circle" : "checkmark.circle")
                        }
                    }
                }
            }.navigationTitle("任务").refreshable { await store.refresh() }
                .confirmationDialog("停止服务器当前运行的生成？", isPresented: $confirming, titleVisibility: .visible) {
                    Button("停止当前生成", role: .destructive) { Task { await store.interrupt() } }
                } message: { Text("此操作会影响服务器当前执行的生成。批次中等待执行的项目可在任务详情中统一取消。") }
        }
    }
    private func taskRow(_ task: GenerationTask) -> some View {
        let summary = task.summary(queue: store.queue, history: store.history)
        return NavigationLink { GenerationTaskDetailView(taskID: task.id) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(task.title, systemImage: task.requestedCount > 1 ? "square.stack.3d.up" : "play.rectangle")
                    Spacer()
                    Text(task.submitting ? "提交中" : (task.submissionError != nil ? "部分提交失败" : summary.label))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("已结束 \(summary.finished)/\(task.items.count) · 成功 \(summary.completed) · 失败 \(summary.failed) · 取消 \(summary.cancelled)")
                    .font(.caption).foregroundStyle(.secondary)
                if summary.active || task.submitting {
                    ProgressView(value: Double(summary.finished), total: Double(max(1, task.requestedCount)))
                }
            }.padding(.vertical, 4)
        }.swipeActions {
            if summary.pending > 0 && !task.submitting {
                Button("取消待执行项", role: .destructive) { Task { await store.cancelPending(in: task) } }
            }
        }
    }
}

struct GenerationTaskDetailView: View {
    @Environment(PocketStore.self) private var store
    let taskID: String
    @State private var selectedOutput: OutputImage?
    private var task: GenerationTask? { store.currentGenerationTasks.first { $0.id == taskID } }
    var body: some View {
        Group {
            if let task {
                let summary = task.summary(queue: store.queue, history: store.history)
                let outputs = task.items.flatMap { OutputImage.fromHistoryEntry(store.history[$0.id], promptID: $0.id) }
                List {
                    Section("任务概况") {
                        Text(task.title).font(.headline)
                        LabeledContent("状态", value: task.submitting ? "提交中" : summary.label)
                        LabeledContent("已提交", value: "\(task.items.count)/\(task.requestedCount) 次生成")
                        LabeledContent("已结束", value: "\(summary.finished)/\(task.items.count)")
                        LabeledContent("成功 / 失败 / 取消", value: "\(summary.completed) / \(summary.failed) / \(summary.cancelled)")
                        ProgressView(value: Double(summary.finished), total: Double(max(1, task.requestedCount)))
                        if summary.unavailable > 0 {
                            Text("\(summary.unavailable) 项记录暂不可用；已保留提交时的参数。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = task.submissionError { Text(error).foregroundStyle(.orange) }
                        if !task.submitting && task.items.count < task.requestedCount {
                            Text("未提交的生成不会自动重试，避免重复执行。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if task.items.contains(where: { $0.id == store.runningPromptID }), let data = store.preview, let image = UIImage(data: data) {
                        Section("实时预览") {
                            Image(uiImage: image).resizable().scaledToFit()
                            ProgressView(value: store.progress)
                        }
                    }
                    if !outputs.isEmpty {
                        Section("全部生成产物 · \(outputs.count)") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))]) {
                                ForEach(outputs) { output in
                                    Button { selectedOutput = output } label: {
                                        RemoteImage(output: output).frame(height: 140).clipped().clipShape(.rect(cornerRadius: 12))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Section("各次生成 · 提示词与实际参数") {
                        ForEach(Array(task.items.enumerated()), id: \.element.id) { index, item in
                            NavigationLink { TaskDetailView(promptID: item.id, snapshot: item.prompt, cancelled: item.cancelled) } label: {
                                HStack {
                                    Text("第 \(index + 1) 次生成")
                                    Spacer()
                                    Text(itemStatus(item)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if summary.pending > 0 && !task.submitting {
                        Section { Button("取消本任务全部待执行项", role: .destructive) { Task { await store.cancelPending(in: task) } } }
                    }
                }.navigationTitle(task.requestedCount > 1 ? "批量任务详情" : "任务详情")
            } else {
                ContentUnavailableView("任务不可用", systemImage: "clock", description: Text("请连接提交任务时的服务器。"))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedOutput) { ImageDetail(output: $0) }
        .refreshable { await store.refresh() }
    }
    private func itemStatus(_ item: GenerationItem) -> String {
        if store.isRunning(item.id) { return "正在生成" }
        if store.isPending(item.id) { return "等待执行" }
        switch store.history[item.id]["status"]["status_str"].text {
        case "success": return "已完成"
        case "error": return "失败"
        default: return item.cancelled ? "已取消" : "记录暂不可用"
        }
    }
}

struct TaskDetailView: View {
    @Environment(PocketStore.self) private var store
    let promptID: String
    var snapshot: [String: JSONValue]? = nil
    var cancelled = false
    @State private var selectedOutput: OutputImage?

    private var entry: JSONValue? {
        let value = store.history[promptID]
        return value.object.isEmpty ? nil : value
    }
    private var prompt: JSONValue {
        if let entry, entry["prompt"].array.count > 2 { return entry["prompt"].array[2] }
        if let item = store.queueItem(promptID: promptID), item.array.count > 2 { return item.array[2] }
        return snapshot.map(JSONValue.object) ?? .null
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
    private var errorMessage: String? {
        guard let entry else { return nil }
        for message in entry["status"]["messages"].array {
            if message.array.count > 1, message.array[0].text == "execution_error" {
                return message.array[1]["exception_message"].text.nonEmpty
            }
        }
        return nil
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
        if cancelled { return "已取消" }
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
            if let errorMessage {
                Section("错误信息") {
                    Text(errorMessage).font(.caption.monospaced()).textSelection(.enabled)
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
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                if output.isVideo { Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white).shadow(radius: 3) }
            }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView() }
        }.task(id: "\(store.client?.baseURL.absoluteString ?? "")|\(output.id)") {
            image = nil; failed = false
            do {
                if output.isVideo, let api = store.client {
                    let url = api.url("view", query: [.init(name: "filename", value: output.filename), .init(name: "subfolder", value: output.subfolder), .init(name: "type", value: output.type)])
                    let decoded = await MediaThumbnail.video(url)
                    guard !Task.isCancelled else { return }
                    image = decoded; failed = image == nil; return
                }
                guard let data = try await store.client?.image(output), let decoded = MediaThumbnail.image(data) else { failed = true; return }
                guard !Task.isCancelled else { return }
                image = decoded
            } catch { if !Task.isCancelled { failed = true } }
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
