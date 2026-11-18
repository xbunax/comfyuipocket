import SwiftUI
import AVKit
import ImageIO
import Photos

struct ZoomableArtwork: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    func makeUIView(context: Context) -> ArtworkScrollView {
        let view = ArtworkScrollView()
        view.setImage(image)
        view.onTap = onTap
        return view
    }
    func updateUIView(_ view: ArtworkScrollView, context: Context) {
        view.setImage(image)
        view.onTap = onTap
    }
}

final class ArtworkScrollView: UIScrollView, UIScrollViewDelegate {
    private let picture = UIImageView()
    private var lastBounds = CGSize.zero
    var onTap: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; addSubview(picture)
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        bouncesZoom = true; contentInsetAdjustmentBehavior = .never
        let zoomTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        zoomTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(singleTap))
        tap.require(toFail: zoomTap)
        addGestureRecognizer(zoomTap)
        addGestureRecognizer(tap)
        isAccessibilityElement = true
        accessibilityLabel = "作品图片，可双指缩放、拖动查看，双击放大或还原"
        accessibilityHint = "轻点切换预览控件"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setImage(_ image: UIImage) {
        guard picture.image !== image else { return }
        picture.image = image; lastBounds = .zero
        setZoomScale(1, animated: false); picture.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = picture.image, bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }
        if bounds.size != lastBounds {
            lastBounds = bounds.size
            minimumZoomScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            maximumZoomScale = max(1, minimumZoomScale * 8)
            setZoomScale(minimumZoomScale, animated: false)
        }
        centerImage()
    }
    private func centerImage() {
        let inset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
        if contentInset != inset { contentInset = inset }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
    override func accessibilityActivate() -> Bool { onTap?(); return true }
    @objc private func singleTap() { onTap?() }
    @objc private func doubleTap(_ tap: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.1 { setZoomScale(minimumZoomScale, animated: true); return }
        let next = min(maximumZoomScale, minimumZoomScale * 2.5)
        let point = tap.location(in: picture)
        zoom(to: CGRect(x: point.x - bounds.width / next / 2, y: point.y - bounds.height / next / 2,
                        width: bounds.width / next, height: bounds.height / next), animated: true)
    }
}

struct ImageDetail: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let output: OutputImage
    var deletion: ArtworkDeletion = .work
    var sequence: ArtworkSequence?
    @State private var image: UIImage?
    @State private var file: URL?
    @State private var player: AVPlayer?
    @State private var status: String?
    @State private var removing: OutputImage?
    @State private var showDetails = false
    @State private var fileInfo = ArtworkFileInfo()
    @State private var record: MediaProvenance?
    @State private var inspected = false
    @State private var chromeVisible = true
    @State private var activity = UUID()
    @State private var scrubbing = false
    @State private var browsingThumbnails = false
    @State private var saving = false

    private var autoHide: Bool {
        chromeVisible && (image != nil || player != nil) && !voiceOver && !scrubbing
            && !browsingThumbnails && sequence?.loading != true && !saving && !showDetails && removing == nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            header.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible).accessibilityHidden(!chromeVisible)
        }
        .overlay(alignment: .bottom) {
            controls.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible).accessibilityHidden(!chromeVisible)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .edgeSwipeBack(enabled: !saving, preferSystem: false) { dismiss() }
        .accessibilityAction(.escape) { if !saving { dismiss() } }
        .sheet(isPresented: $showDetails) { ArtworkDetails(output: output, file: fileInfo, record: record) }
        .workDeletionDialog($removing, mode: deletion, onDeleted: { dismiss() })
        .task { await open() }
        .task(id: autoHide ? activity : nil) {
            guard autoHide else { return }
            do {
                try await Task.sleep(for: .seconds(4))
                try Task.checkCancellation()
                showChrome(false)
            } catch { }
        }
        .onChange(of: voiceOver) { _, enabled in if enabled { showChrome(true) } }
        .onChange(of: store.client?.serverID) { _, _ in dismiss() }
        .onDisappear {
            player?.pause()
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }

    @ViewBuilder private var media: some View {
        if let image {
            ZoomableArtwork(image: image) { showChrome(!chromeVisible) }
        } else {
            ZStack {
                Color.clear
                if let player { ArtworkVideoSurface(player: player).accessibilityHidden(true) }
                else if status == nil { ProgressView().tint(.white).accessibilityLabel("正在打开预览") }
            }
            .contentShape(Rectangle())
            .onTapGesture { showChrome(!chromeVisible) }
            .accessibilityAction(named: Text(chromeVisible ? "隐藏预览控件" : "显示预览控件")) {
                showChrome(!chromeVisible)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }.buttonStyle(.glass).accessibilityLabel("关闭预览").keyboardShortcut(.escape, modifiers: [])
                .disabled(saving)
            Text(output.filename).font(.subheadline.weight(.semibold))
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            if deletion == .work || store.pluginCapabilities.contains("media-delete") {
                Button(role: .destructive) { removing = output } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }.buttonStyle(.glass)
                    .disabled(store.deletingOutputs.contains(output.assetID) || saving)
                    .accessibilityLabel(deletion == .serverFile ? "删除服务器文件" : "删除作品")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background {
            LinearGradient(colors: [.black.opacity(0.78), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top).allowsHitTesting(false)
        }
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
    }

    private var controls: some View {
        VStack(spacing: 5) {
            if let status {
                Text(status).font(.footnote).multilineTextAlignment(.center)
                    .padding(.vertical, 5).padding(.horizontal, 14)
            }
            if let player {
                ArtworkPlaybackControls(player: player, duration: fileInfo.duration, onActivity: keepChrome) { active in
                    scrubbing = active
                    keepChrome()
                }.padding(.horizontal, 14)
            }
            if let sequence, sequence.items.count > 1 || sequence.next != nil {
                ArtworkFilmstrip(sequence: sequence) { active in
                    browsingThumbnails = active
                    keepChrome()
                }
            }
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    if let sequence, sequence.items.count > 1,
                       let index = sequence.items.firstIndex(where: { $0.id == output.id }) {
                        Text("\(index + 1) / \(sequence.items.count)\(sequence.next == nil ? "" : "+")")
                    }
                    if let resolution = fileInfo.resolution { Text(resolution) }
                }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button { showDetails = true } label: {
                    Image(systemName: "info.circle").frame(width: 44, height: 44)
                }.accessibilityLabel("作品详情").disabled(!inspected)
                Button { Task { await saveToPhotos() } } label: {
                    if saving { ProgressView().frame(width: 44, height: 44) }
                    else { Image(systemName: "arrow.down.to.line").frame(width: 44, height: 44) }
                }.accessibilityLabel("保存到照片").disabled((image == nil && (!output.isVideo || file == nil)) || saving)
                if let file {
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                        .accessibilityLabel("分享文件")
                }
            }.buttonStyle(.glass).padding(.horizontal, 14)
        }
        .padding(.vertical, 6)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
        }
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
    }

    private func keepChrome() { activity = UUID() }
    private func showChrome(_ visible: Bool) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { chromeVisible = visible }
        if visible { keepChrome() }
    }

    private func open() async {
        defer { if !Task.isCancelled { inspected = true } }
        guard let client = store.client else { status = "请先连接服务器。"; return }
        do {
            let downloaded = try await client.download(output)
            guard !Task.isCancelled, store.client?.serverID == client.serverID else {
                try? FileManager.default.removeItem(at: downloaded)
                return
            }
            file = downloaded
            if output.isVideo {
                player = AVPlayer(url: downloaded)
                if downloaded.pathExtension.lowercased() == "webm" { status = "WebM 可通过分享在其他播放器中打开。" }
            } else {
                image = UIImage(contentsOfFile: downloaded.path)
                if image == nil { status = "无法显示图片，可通过分享打开原文件。" }
            }
            async let info = ArtworkFileInfo.read(downloaded, video: output.isVideo)
            async let embedded = ArtworkMetadata.read(downloaded, video: output.isVideo)
            let (details, metadata) = await (info, embedded)
            guard !Task.isCancelled, store.client?.serverID == client.serverID else { return }
            fileInfo = details
            record = store.currentMediaArchive.record(for: output, embedded: metadata)
            keepChrome()
        } catch {
            guard !Task.isCancelled else { return }
            record = store.currentMediaArchive.record(for: output, embedded: nil)
            status = error.localizedDescription
        }
    }

    private func saveToPhotos() async {
        guard !saving else { return }
        saving = true
        defer { saving = false; keepChrome() }
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else {
            status = "请在系统设置中允许保存照片。"
            return
        }
        do {
            if output.isVideo, let file {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file) }
            } else if let image {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            } else { return }
            status = "已保存到照片。"
        } catch { status = error.localizedDescription }
    }
}

private struct ArtworkVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerView { PlayerView() }
    func updateUIView(_ view: PlayerView, context: Context) { view.playerLayer.player = player }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

private struct ArtworkPlaybackControls: View {
    let player: AVPlayer
    let duration: Double?
    let onActivity: () -> Void
    let onScrub: (Bool) -> Void
    @State private var scrubTime: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let elapsed = player.currentTime().seconds
            let time = elapsed.isFinite ? max(0, elapsed) : 0
            let playing = player.timeControlStatus != .paused
            HStack(spacing: 12) {
                Button {
                    if playing { player.pause() }
                    else {
                        if let duration, time >= duration - 0.1 { seek(0) }
                        player.play()
                    }
                    onActivity()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.buttonStyle(.glass).accessibilityLabel(playing ? "暂停" : "播放")
                if let duration, duration.isFinite, duration > 0 {
                    Slider(value: Binding(get: { min(duration, scrubTime ?? time) }, set: { value in
                        if scrubTime != nil { scrubTime = value }
                        else { seek(value); onActivity() }
                    }), in: 0...duration, onEditingChanged: { editing in
                        if editing { scrubTime = time }
                        else if let scrubTime { seek(scrubTime); self.scrubTime = nil }
                        onScrub(editing)
                    }).accessibilityLabel("播放进度")
                    Text("\(clock(scrubTime ?? time)) / \(clock(duration))")
                        .font(.caption.monospacedDigit()).fixedSize()
                } else {
                    Spacer()
                    if player.currentItem?.status == .failed { Text("无法播放此视频").font(.footnote) }
                }
            }
        }
    }

    private func seek(_ time: Double) { player.seek(to: CMTime(seconds: time, preferredTimescale: 600)) }
    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private enum ArtworkMetadata {
    static func read(_ file: URL, video: Bool) async -> MediaProvenance? {
        if video {
            // VideoHelperSuite writes the submitted graph in an FFmpeg comment.
            let asset = AVURLAsset(url: file)
            guard let items = try? await asset.load(.metadata) else { return nil }
            for item in items {
                guard item.commonKey == .commonKeyDescription || item.identifier == .iTunesMetadataUserComment
                        || item.identifier == .quickTimeMetadataComment || item.identifier == .quickTimeUserDataComment,
                      let text = try? await item.load(.stringValue), text.utf8.count <= 20 * 1024 * 1024,
                      let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                      let record = MediaProvenance.embeddedPrompt(value["prompt"]) else { continue }
                return record
            }
            return nil
        }
        guard file.pathExtension.lowercased() == "png",
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return MediaProvenance.embeddedPNG(data)
    }
}

struct ArtworkFileInfo {
    var width: Int?
    var height: Int?
    var duration: Double?
    var frameRate: Double?
    var bytes: Int64?
    var resolution: String? { if let width, let height { return "\(width) × \(height)" }; return nil }
    static func read(_ file: URL, video: Bool) async -> ArtworkFileInfo {
        var result = ArtworkFileInfo()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), let bytes = attributes[.size] as? NSNumber {
            result.bytes = bytes.int64Value
        }
        if video {
            let asset = AVURLAsset(url: file)
            if let time = try? await asset.load(.duration), time.seconds.isFinite { result.duration = time.seconds }
            if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first {
                if let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                    let display = size.applying(transform)
                    result.width = Int(abs(display.width).rounded()); result.height = Int(abs(display.height).rounded())
                }
                if let rate = try? await track.load(.nominalFrameRate), rate > 0 { result.frameRate = Double(rate) }
            }
        } else if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            result.width = properties[kCGImagePropertyPixelWidth] as? Int
            result.height = properties[kCGImagePropertyPixelHeight] as? Int
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
                let width = result.width; result.width = result.height; result.height = width
            }
        }
        return result
    }
}

struct ArtworkDetails: View {
    let output: OutputImage
    let file: ArtworkFileInfo
    let record: MediaProvenance?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let generation = record.map { ExecutionPrompts(record: $0).details(for: output) } ?? GenerationDetails()
        NavigationStack {
            List {
                Section("文件") {
                    LabeledContent("文件名", value: output.filename)
                    LabeledContent("类型", value: output.isVideo ? "视频" : "图片")
                    LabeledContent("分辨率", value: file.resolution ?? "暂无法读取")
                    if let bytes = file.bytes { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                    if let duration = file.duration { LabeledContent("时长", value: "\(duration.formatted(.number.precision(.fractionLength(2)))) 秒") }
                    if let fps = file.frameRate { LabeledContent("帧率", value: "\(fps.formatted(.number.precision(.fractionLength(2)))) fps") }
                }
                Section("工作流与任务") {
                    LabeledContent("工作流", value: record?.workflowName.nonEmpty ?? "未记录名称")
                    if let id = record?.workflowID.nonEmpty { Text("工作流 ID：\(id)").font(.caption.monospaced()).textSelection(.enabled) }
                    Text("任务 ID：\(record?.taskID.nonEmpty ?? output.promptID)").font(.caption.monospaced()).textSelection(.enabled)
                    Text("生成 ID：\(output.promptID)").font(.caption.monospaced()).textSelection(.enabled)
                    if let created = record?.createdAt, created > 1_000_000_000 {
                        LabeledContent("提交时间") { Text(Date(timeIntervalSince1970: created), format: .dateTime) }
                    }
                    if let record {
                        LabeledContent("执行节点", value: "\(record.prompt.count) 个")
                        DisclosureGroup("节点类型") {
                            ForEach(record.prompt.keys.sorted(), id: \.self) { id in
                                Text("#\(id) · \(record.prompt[id]?["class_type"].text ?? "")").font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
                Section("使用的提示词") {
                    if generation.prompts.isEmpty {
                        Text("此作品没有可核实的提示词记录。").foregroundStyle(PocketPalette.secondary)
                    } else {
                        ForEach(generation.prompts) { GenerationPromptRow(prompt: $0) }
                    }
                }
                if !generation.parameters.isEmpty {
                    Section {
                        DisclosureGroup("生成参数") {
                            ForEach(generation.parameters) { field in
                                LabeledContent("\(field.nodeTitle) · \(field.key)", value: field.value.text).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
            }.navigationTitle("作品详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}

struct GenerationPromptRow: View {
    let prompt: GenerationPrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(prompt.role.title) · \(prompt.nodeTitle)")
                    .font(.caption.weight(.medium)).foregroundStyle(PocketPalette.secondary)
                Spacer()
                Button("复制提示词", systemImage: "doc.on.doc") { UIPasteboard.general.string = prompt.text }
                    .buttonStyle(.borderless).labelStyle(.iconOnly)
            }
            if prompt.submittedInput {
                Text("提交原文 · 改写结果未记录").font(.caption2).foregroundStyle(PocketPalette.secondary)
            }
            Text(prompt.text).textSelection(.enabled)
        }.padding(.vertical, 4)
    }
}
