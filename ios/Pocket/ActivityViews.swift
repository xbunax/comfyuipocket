import SwiftUI

private enum TaskNavigationTarget: Hashable {
    case batch(String)
    case prompt(String)
}

struct QueueView: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.workspaceLayout) private var layout
    @State private var selectedTask: TaskNavigationTarget?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var confirming = false
    @State private var removing: TaskRemovalTarget?
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
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            List(selection: $selectedTask) {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        ConnectionBadge()
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { taskMetrics }
                            VStack(alignment: .leading, spacing: 8) { taskMetrics }
                        }
                    }.padding(.vertical, 4)
                }
                if store.runningPromptID != nil {
                    Section("当前生成预览") {
                        if let preview = store.preview, let image = UIImage(data: preview) {
                            Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16))
                        }
                        ProgressView(value: store.progress)
                        Text("当前采样进度 \(Int(store.progress * 100))% · 非整个批次总进度")
                            .font(.caption).foregroundStyle(PocketPalette.secondary)
                        Button("停止服务器当前生成", role: .destructive) { confirming = true }
                    }
                }
                Section("当前任务 · \(activeTasks.count + otherQueue.count)") {
                    if activeTasks.isEmpty && otherQueue.isEmpty { Text("队列空闲，灵感随时开始。").foregroundStyle(PocketPalette.secondary) }
                    ForEach(activeTasks) { task in taskRow(task) }
                    ForEach(Array(otherQueue.enumerated()), id: \.offset) { _, item in
                        let id = item.array[1].text
                        NavigationLink(value: TaskNavigationTarget.prompt(id)) {
                            Label(String(id.prefix(8)), systemImage: store.isRunning(id) ? "play.circle" : "clock")
                        }.tag(TaskNavigationTarget.prompt(id)).swipeActions {
                            if store.isPending(id) { Button("取消", role: .destructive) { Task { await store.deletePending(id) } } }
                            if !store.isRunning(id) { Button("删除", role: .destructive) { removing = .prompt(id) } }
                        }
                    }
                }
                Section("最近任务") {
                    ForEach(recentTasks) { task in taskRow(task) }
                    ForEach(store.sortedHistoryIDs.filter { !knownIDs.contains($0) }, id: \.self) { id in
                        NavigationLink(value: TaskNavigationTarget.prompt(id)) {
                            Label(String(id.prefix(8)), systemImage: store.history[id]["status"]["status_str"].text == "error" ? "exclamationmark.circle" : "checkmark.circle")
                        }
                        .tag(TaskNavigationTarget.prompt(id))
                        .swipeActions { Button("删除", role: .destructive) { removing = .prompt(id) } }
                    }
                }
            }.pocketListSurface().navigationTitle("任务").navigationBarTitleDisplayMode(.inline).refreshable { await store.refresh() }
                .navigationSplitViewColumnWidth(min: 260, ideal: layout.navigationWidth, max: 360)
                .taskDeletionDialog($removing)
                .confirmationDialog("停止服务器当前运行的生成？", isPresented: $confirming, titleVisibility: .visible) {
                    Button("停止当前生成", role: .destructive) { Task { await store.interrupt() } }
                } message: { Text("此操作会影响服务器当前执行的生成。批次中等待执行的项目可在任务详情中统一取消。") }
        } detail: {
            NavigationStack {
                switch selectedTask {
                case .batch(let id): GenerationTaskDetailView(taskID: id).id(id)
                case .prompt(let id): TaskDetailView(promptID: id).id(id)
                case nil:
                    ContentUnavailableView("选择任务查看详情", systemImage: "waveform.path",
                        description: Text("查看实时状态、生成产物和实际使用的参数及提示词。"))
                }
            }
            .edgeSwipeBack(enabled: selectedTask != nil) { selectedTask = nil; preferredColumn = .sidebar }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.horizontalSizeClass, layout.usesColumns ? .regular : .compact)
        .onChange(of: selectedTask) { _, next in if next != nil { preferredColumn = .detail } }
    }
    @ViewBuilder private var taskMetrics: some View {
        PocketMetric(title: "进行中", value: activeTasks.count + otherQueue.count, icon: "clock")
        PocketMetric(title: "最近任务", value: recentTasks.count + store.sortedHistoryIDs.filter { !knownIDs.contains($0) }.count, icon: "clock.arrow.circlepath")
    }
    private func taskRow(_ task: GenerationTask) -> some View {
        let summary = task.summary(queue: store.queue, history: store.history)
        return NavigationLink(value: TaskNavigationTarget.batch(task.id)) {
            VStack(alignment: .leading, spacing: 10) {
                Label(task.title, systemImage: task.requestedCount > 1 ? "square.stack.3d.up" : "play.rectangle")
                    .font(.headline).lineLimit(2)
                Text(task.submitting ? "提交中" : (task.submissionError != nil ? "部分提交失败" : summary.label))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(summary.failed > 0 || task.submissionError != nil ? Color.orange : (summary.active ? PocketPalette.accent : Color.secondary))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(PocketPalette.text.opacity(0.04), in: .capsule)
                Text("成功 \(summary.completed) · 失败 \(summary.failed) · 取消 \(summary.cancelled)")
                    .font(.caption).foregroundStyle(PocketPalette.secondary)
                if summary.active || task.submitting {
                    ProgressView(value: Double(summary.finished), total: Double(max(1, task.requestedCount)))
                    Text("已结束 \(summary.finished) / \(task.items.count)")
                        .font(.caption2).foregroundStyle(PocketPalette.secondary)
                }
            }.padding(.vertical, 8)
        }.tag(TaskNavigationTarget.batch(task.id)).swipeActions {
            Button("删除", role: .destructive) { removing = .task(task) }
                .disabled(task.submitting || summary.running > 0 || store.deletingTasks.contains(task.id))
            if summary.pending > 0 && !task.submitting {
                Button("取消待执行项", role: .destructive) { Task { await store.cancelPending(in: task) } }
            }
        }
    }
}

struct GenerationTaskDetailView: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskID: String
    @State private var selectedOutput: OutputImage?
    @State private var removing: TaskRemovalTarget?
    private var task: GenerationTask? { store.currentGenerationTasks.first { $0.id == taskID } }
    var body: some View {
        Group {
            if let task {
                let summary = task.summary(queue: store.queue, history: store.history)
                let outputs = task.items.flatMap { store.outputs(forPromptID: $0.id) }
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
                                .font(.caption).foregroundStyle(PocketPalette.secondary)
                        }
                        if let error = task.submissionError { Text(error).foregroundStyle(.orange) }
                        if !task.submitting && task.items.count < task.requestedCount {
                            Text("未提交的生成不会自动重试，避免重复执行。")
                                .font(.caption).foregroundStyle(PocketPalette.secondary)
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
                                    Text(itemStatus(item)).font(.caption).foregroundStyle(PocketPalette.secondary)
                                }
                            }
                        }
                    }
                    if summary.pending > 0 && !task.submitting {
                        Section { Button("取消本任务全部待执行项", role: .destructive) { Task { await store.cancelPending(in: task) } } }
                    }
                }.pocketListSurface().navigationTitle(task.requestedCount > 1 ? "批量任务详情" : "任务详情")
                    .toolbar {
                        Button("删除任务", systemImage: "trash", role: .destructive) { removing = .task(task) }
                            .disabled(task.submitting || summary.running > 0 || store.deletingTasks.contains(task.id))
                    }
            } else {
                ContentUnavailableView("任务不可用", systemImage: "clock", description: Text("请连接提交任务时的服务器。"))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedOutput) { ImageDetail(output: $0) }
        .taskDeletionDialog($removing, onDeleted: { dismiss() })
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
    @Environment(\.dismiss) private var dismiss
    let promptID: String
    var snapshot: [String: JSONValue]? = nil
    var cancelled = false
    @State private var selectedOutput: OutputImage?
    @State private var removing: TaskRemovalTarget?

    private var entry: JSONValue? {
        let value = store.history[promptID]
        return value.object.isEmpty ? nil : value
    }
    private var prompt: JSONValue {
        if let entry, entry["prompt"].array.count > 2 { return entry["prompt"].array[2] }
        if let item = store.queueItem(promptID: promptID), item.array.count > 2 { return item.array[2] }
        return snapshot.map(JSONValue.object) ?? .null
    }
    private var generation: GenerationDetails {
        if let record = store.currentMediaArchive.provenance?[promptID] {
            return ExecutionPrompts(record: record).details()
        }
        let queued = store.queueItem(promptID: promptID)?.array ?? []
        let requested = queued.count > 4 ? queued[4].array.map(\.text) : nil
        let record = MediaProvenance(prompt: prompt.object, workflowID: "", workflowName: "", taskID: promptID,
                                     createdAt: 0, requestedOutputs: requested)
        return ExecutionPrompts(record: record).details()
    }
    private var outputs: [OutputImage] {
        store.outputs(forPromptID: promptID)
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
        let generation = generation
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
            if !generation.prompts.isEmpty {
                Section("提示词") {
                    ForEach(generation.prompts) { GenerationPromptRow(prompt: $0) }
                }
            }
            if !generation.parameters.isEmpty {
                Section("使用的参数") {
                    ForEach(generation.parameters) { field in
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
            if prompt.object.isEmpty && store.currentMediaArchive.provenance?[promptID] == nil {
                Section {
                    Text("任务参数暂不可用，可能已被历史记录清理。").foregroundStyle(PocketPalette.secondary)
                }
            }
        }
        .pocketListSurface()
        .navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedOutput) { ImageDetail(output: $0) }
        .toolbar {
            if !store.currentGenerationTasks.contains(where: { $0.items.contains(where: { $0.id == promptID }) }) {
                Button("删除任务", systemImage: "trash", role: .destructive) { removing = .prompt(promptID) }
                    .disabled(store.isRunning(promptID))
            }
        }
        .taskDeletionDialog($removing, onDeleted: { dismiss() })
        .refreshable { await store.refresh() }
    }
}

struct GalleryView: View {
    private enum SectionTab: String {
        case workflow, files
    }
    @Environment(PocketStore.self) private var store
    @State private var section: SectionTab = .workflow
    @State private var folder = ""
    @State private var preview: ArtworkSequence?
    @State private var removing: OutputImage?
    @State private var expanded: Set<String> = []
    @AppStorage("mediaSortKey") private var sortKey = "time"
    @AppStorage("mediaSortAscending") private var ascending = false
    @State private var sizes: [String: Int64] = [:]
    @State private var readingSizes = false
    @State private var sizeRefresh = UUID()
    private var order: MediaSortKey { MediaSortKey(rawValue: sortKey) ?? .time }
    private var groups: [MediaTaskGroup] {
        var archive = store.currentMediaArchive
        archive.rememberTasks(store.currentGenerationTasks)
        return MediaOrdering.groups(archive.galleryGroups, key: order, ascending: ascending, sizes: sizes)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { galleryTitle; Spacer(minLength: 0); gallerySources }
                    VStack(alignment: .leading, spacing: 2) {
                        galleryTitle
                        HStack { gallerySources }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 6)
                Divider()
                ZStack {
                    PocketBackground()
                    if section == .files {
                        OutputBrowserView(folder: $folder) { preview = $0 }
                            .id(store.client?.serverID ?? "")
                    } else {
                        workflowOutputs
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(GalleryPageSwipe(enabled: preview == nil && (section == .workflow || folder.isEmpty)) { left in
                    if left && section == .workflow {
                        folder = ""
                        section = .files
                    } else if !left && section == .files && folder.isEmpty {
                        section = .workflow
                    }
                })
            }
            .navigationTitle("作品").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .fullScreenCover(item: $preview) { items in
            ImageDetail(output: items.selected, deletion: items.deletion, sequence: items)
                .id(items.selected.id)
        }
        .workDeletionDialog($removing)
        .onChange(of: store.client?.serverID) { _, _ in
            folder = ""; preview = nil; expanded.removeAll(); sizes = [:]
        }
        .task(id: "\(store.client?.serverID ?? "")|\(section.rawValue)|\(sortKey)|\(sizeRefresh)|\(store.images.map(\.id).joined(separator: "|"))") {
            guard section == .workflow, order == .size, let api = store.client else { readingSizes = false; return }
            readingSizes = true
            let result = await api.mediaSizes(store.images)
            guard !Task.isCancelled, store.client === api else { return }
            sizes = result; readingSizes = false
        }
    }

    @ViewBuilder private var workflowOutputs: some View {
        let items = groups
        if items.isEmpty {
            ContentUnavailableView("你的作品将在这里出现", systemImage: "photo.on.rectangle.angled",
                description: Text("这里按生成任务显示工作流输出。"))
        } else {
            ScrollView {
                HStack {
                    Text("\(items.count) 个任务 · \(items.reduce(0) { $0 + $1.outputs.count }) 件作品")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("全部折叠") { expanded.removeAll() }.font(.caption).disabled(expanded.isEmpty)
                }.padding(.horizontal, 20).padding(.top, 8)
                if order == .size {
                    Text(readingSizes ? "正在读取文件大小…" : "按任务产物合计大小排序")
                        .font(.caption).foregroundStyle(PocketPalette.secondary).padding(.horizontal, 20)
                }
                LazyVStack(spacing: 14) {
                    ForEach(items) { group in
                        GalleryTaskCard(group: group, expanded: Binding(get: { expanded.contains(group.id) }, set: {
                            if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) }
                        }), onPreview: { file in
                            let ordered = MediaOrdering.outputs(group.outputs, key: order, ascending: ascending, sizes: sizes)
                            preview = ArtworkSequence(selected: file, items: ordered)
                        }, removing: $removing, sortKey: order, ascending: ascending, sizes: sizes)
                    }
                }.padding(16)
            }.contentMargins(.bottom, 28, for: .scrollContent)
                .refreshable { await store.refresh(); sizeRefresh = UUID() }
        }
    }

    private var galleryTitle: some View {
        Text("作品").font(.title2.bold()).fixedSize().accessibilityAddTraits(.isHeader)
    }
    @ViewBuilder private var gallerySources: some View {
        Picker("作品来源", selection: $section) {
            Text("工作流输出").tag(SectionTab.workflow)
            Text("文件预览").tag(SectionTab.files)
        }.pickerStyle(.segmented).frame(maxWidth: 250).accessibilityIdentifier("gallery.source")
        if section == .workflow {
            Menu {
                MediaSortMenu(sortKey: $sortKey, ascending: $ascending)
                Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refresh(); sizeRefresh = UUID() } }.disabled(!store.connected)
            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
        }
    }
}

private struct GalleryPageSwipe: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let changePage: (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = enabled
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) { pan.isEnabled = enabled }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        guard enabled, pan.state == .ended else { return }
        let movement = pan.translation(in: pan.view)
        let velocity = pan.velocity(in: pan.view)
        guard abs(movement.x) > abs(movement.y) * 1.35,
              abs(movement.x) >= 64 || (abs(movement.x) >= 28 && abs(velocity.x) >= 550 && movement.x * velocity.x > 0)
        else { return }
        changePage(movement.x < 0)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let speed = pan.velocity(in: pan.view)
            return abs(speed.x) > abs(speed.y) * 1.35
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

private struct GalleryTaskCard: View {
    @Environment(PocketStore.self) private var store
    let group: MediaTaskGroup
    @Binding var expanded: Bool
    let onPreview: (OutputImage) -> Void
    @Binding var removing: OutputImage?
    var sortKey: MediaSortKey = .time
    var ascending = false
    var sizes: [String: Int64] = [:]
    private var orderedOutputs: [OutputImage] { MediaOrdering.outputs(group.outputs, key: sortKey, ascending: ascending, sizes: sizes) }
    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    if let cover = orderedOutputs.first {
                        RemoteImage(output: cover).frame(width: 64, height: 72).clipped().clipShape(.rect(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.name).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(PocketPalette.text)
                        Text(group.summary).font(.caption).foregroundStyle(PocketPalette.secondary)
                        if let bytes = MediaOrdering.totalSize(group.outputs, sizes: sizes) {
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption2).foregroundStyle(PocketPalette.secondary)
                        }
                        Text("ID \(group.taskID)").font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(PocketPalette.secondary)
                        if group.createdAt > 1_000_000_000 {
                            Text(Date(timeIntervalSince1970: group.createdAt), format: .dateTime.month().day().hour().minute())
                                .font(.caption2).foregroundStyle(PocketPalette.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(PocketPalette.secondary)
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(expanded ? "已展开" : "已折叠")
                .contextMenu { Button("复制任务 ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = group.taskID } }
            if expanded {
                Divider().padding(.horizontal, 14)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(orderedOutputs) { image in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { onPreview(image) } label: {
                                RemoteImage(output: image).frame(height: 150).clipped().clipShape(.rect(cornerRadius: 12))
                            }.buttonStyle(.plain)
                            HStack {
                                Text(image.filename).font(.caption2).lineLimit(1).foregroundStyle(PocketPalette.secondary)
                                Spacer(minLength: 0)
                                Button("删除作品", systemImage: "trash", role: .destructive) { removing = image }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(store.deletingOutputs.contains(image.assetID))
                            }
                        }.contextMenu { Button("删除作品", systemImage: "trash", role: .destructive) { removing = image } }
                    }
                }.padding(14)
            }
        }.background(PocketPalette.surface, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(PocketPalette.text.opacity(0.05)))
    }
}

@MainActor @Observable final class ArtworkSequence: Identifiable {
    let id = UUID()
    let deletion: ArtworkDeletion
    var selected: OutputImage
    var items: [OutputImage]
    private(set) var next: Int?
    private(set) var loading = false
    private(set) var error: String?
    private let page: ((Int) async throws -> OutputDirectoryPage)?
    init(selected: OutputImage, items: [OutputImage], deletion: ArtworkDeletion = .work,
         next: Int? = nil, page: ((Int) async throws -> OutputDirectoryPage)? = nil) {
        self.selected = selected; self.items = items; self.deletion = deletion; self.next = next; self.page = page
    }
    func loadMore() async {
        guard !loading, let next, let page else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await page(next)
            try Task.checkCancellation()
            var seen = Set(items.map(\.assetID))
            items += result.entries.filter { !$0.isFolder }.map(\.output).filter { seen.insert($0.assetID).inserted }
            self.next = result.nextOffset.flatMap { $0 > next ? $0 : nil }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct ArtworkFilmstrip: View {
    let sequence: ArtworkSequence
    let onScrollChanged: (Bool) -> Void
    var body: some View {
        VStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(sequence.items) { item in
                            Button { sequence.selected = item } label: {
                                RemoteImage(output: item, fill: true).frame(width: 46, height: 46)
                                    .clipShape(.rect(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                                        item.id == sequence.selected.id ? PocketPalette.accent : .clear, lineWidth: 3))
                            }.buttonStyle(.plain).id(item.id).accessibilityLabel(item.filename)
                                .accessibilityAddTraits(item.id == sequence.selected.id ? .isSelected : [])
                        }
                        if sequence.next != nil {
                            Button(sequence.loading ? "读取中…" : (sequence.error == nil ? "加载更多" : "重试")) {
                                Task { await sequence.loadMore() }
                            }.disabled(sequence.loading).font(.caption)
                        }
                    }.padding(.horizontal, 14)
                }.frame(height: 50)
                    .onScrollPhaseChange { _, phase in onScrollChanged(phase != .idle) }
                    .onAppear { proxy.scrollTo(sequence.selected.id, anchor: .center) }
            }
            if let error = sequence.error { Text(error).font(.caption2).lineLimit(2) }
        }
    }
}

struct RemoteImage: View {
    @Environment(PocketStore.self) private var store
    let output: OutputImage
    var fill = false
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            if let image {
                if fill {
                    GeometryReader { geometry in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                if output.isVideo { Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white).shadow(radius: 3) }
            }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(PocketPalette.secondary) }
            else { ProgressView() }
        }.task(id: "\(store.client?.serverID ?? "")|\(output.id)") {
            image = nil; failed = false
            do {
                guard let api = store.client else { failed = true; return }
                let decoded = try await MediaThumbnail.cached(url: api.mediaURL(output), revision: output.promptID,
                    kind: output.isVideo ? .video : .image, resource: api.cacheResource(api.mediaURL(output))) { try await api.image(output) }
                guard !Task.isCancelled else { return }
                image = decoded
            } catch { if !Task.isCancelled { failed = true } }

        }.onDisappear { image = nil }
    }
}
