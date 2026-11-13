import SwiftUI
import PhotosUI
import AVKit
import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ImageIO

@MainActor enum MediaThumbnail {
    static func image(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    static func video(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, _ in
                continuation.resume(returning: image.map { UIImage(cgImage: $0) })
            }
        }
    }
    static func file(_ url: URL) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 800, height: 600), scale: 1,
                                                  representationTypes: .all)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                continuation.resume(returning: thumbnail?.uiImage)
            }
        }
    }
}

struct MediaFieldEditor: View {
    @Environment(PocketStore.self) private var store
    @Binding var value: JSONValue
    let kind: MediaKind
    var choices: [String] = []
    @State private var photo: PhotosPickerItem?
    @State private var uploading = false
    @State private var showWorks = false
    @State private var showFiles = false
    @State private var showServer = false
    @State private var pendingThumbnail: UIImage?
    private var text: String { value.text }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if uploading, let pendingThumbnail {
                Image(uiImage: pendingThumbnail).resizable().scaledToFit().frame(maxHeight: 200)
                    .clipShape(.rect(cornerRadius: 16))
            } else { InputMediaPreview(value: text, kind: kind) }
            if !text.isEmpty { Text(MediaFile.split(text).filename).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            if uploading { ProgressView("正在上传，完成后更新工作流输入…").font(.caption) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { selectionButtons }
                VStack(alignment: .leading, spacing: 12) { selectionButtons }
            }.font(.caption).buttonStyle(.borderless).disabled(!store.connected || uploading)
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .sheet(isPresented: $showWorks) { WorkPicker(kind: kind) { output in Task { await useWork(output) } } }
        .sheet(isPresented: $showServer) {
            ServerMediaPicker(choices: Array(Set(choices + (text.isEmpty ? [] : [text]))).sorted(), kind: kind) { value = .string($0) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: kind == .image ? [.image] : (kind == .video ? [.movie, .video] : [.item])) { result in
            switch result {
            case .success(let url): Task { await importFile(url) }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
    }
    @ViewBuilder private var selectionButtons: some View {
        if kind != .file {
            PhotosPicker(selection: $photo, matching: kind == .video ? PHPickerFilter.videos : PHPickerFilter.images) {
                Label("相册", systemImage: "photo.badge.plus")
            }
        }
        Button("本地文件", systemImage: "folder") { showFiles = true }
        if !choices.isEmpty { Button("服务器文件", systemImage: "server.rack") { showServer = true } }
        Button("从作品选择", systemImage: "photo.on.rectangle.angled") { showWorks = true }
    }
    private func importPhoto(_ item: PhotosPickerItem) async {
        guard !uploading else { return }
        uploading = true; defer { uploading = false; photo = nil; pendingThumbnail = nil }
        do {
            guard let api = store.client, let data = try await item.loadTransferable(type: Data.self) else {
                throw PocketError.message("无法读取所选文件，请检查连接和文件访问权限。")
            }
            let type = item.supportedContentTypes.first
            try await upload(data, filename: "pocket-\(UUID().uuidString).\(type?.preferredFilenameExtension ?? "png")",
                             mime: type?.preferredMIMEType ?? "application/octet-stream", api: api)
        } catch { store.error = error.localizedDescription }
    }
    private func importFile(_ url: URL) async {
        guard !uploading else { return }
        uploading = true; defer { uploading = false; pendingThumbnail = nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let api = store.client else { throw PocketError.message("请先连接服务器。") }
            let type = UTType(filenameExtension: url.pathExtension)
            try await upload(Data(contentsOf: url), filename: url.lastPathComponent,
                             mime: type?.preferredMIMEType ?? "application/octet-stream", api: api)
        } catch { store.error = error.localizedDescription }
    }
    private func useWork(_ output: OutputImage) async {
        guard !uploading else { return }
        uploading = true; defer { uploading = false; pendingThumbnail = nil }
        do {
            guard let api = store.client else { throw PocketError.message("请先连接服务器。") }
            let data = try await api.image(output)
            try await upload(data, filename: output.filename, mime: output.mimeType, api: api)
        } catch { store.error = error.localizedDescription }
    }
    private func upload(_ data: Data, filename: String, mime: String, api: ComfyClient) async throws {
        var payload = data; var name = filename; var contentType = mime
        if kind == .image {
            guard let image = UIImage(data: data), let png = image.pngData() else { throw PocketError.message("无法读取图片。") }
            pendingThumbnail = MediaThumbnail.image(data); payload = png; name = "pocket-\(UUID().uuidString).png"; contentType = "image/png"
        } else {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(URL(fileURLWithPath: filename).lastPathComponent)")
            try data.write(to: url)
            pendingThumbnail = kind == .video ? await MediaThumbnail.video(url) : await MediaThumbnail.file(url)
            try? FileManager.default.removeItem(at: url)
        }
        let remote = try await api.upload(payload, filename: name, mime: contentType)
        guard store.client === api else { throw PocketError.message("连接已改变，请在当前服务器重新选择文件。") }
        value = .string(remote)
    }
}

struct InputMediaPreview: View {
    @Environment(PocketStore.self) private var store
    let value: String
    let kind: MediaKind
    @State private var image: UIImage?
    @State private var failed = false
    @State private var loading = false
    @State private var localFile: URL?
    @State private var quickLookURL: URL?
    @State private var showFull = false
    @State private var retry = 0
    private var identity: String { "\(store.client?.baseURL.absoluteString ?? "")|\(value)|\(retry)" }
    var body: some View {
        Button {
            if failed { retry += 1 }
            else if kind == .file { quickLookURL = localFile }
            else if !value.isEmpty { showFull = true }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.08))
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16))
                    if kind == .video { Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white).shadow(radius: 4) }
                } else if loading { ProgressView("加载预览…").font(.caption) }
                else {
                    VStack(spacing: 6) {
                        Image(systemName: kind == .video ? "film" : (kind == .image ? "photo" : "doc.richtext")).font(.title2)
                        Text(value.isEmpty ? "尚未选择文件" : (failed ? "预览加载失败，点按重试" : "点按预览文件"))
                            .font(.caption)
                    }.foregroundStyle(.secondary)
                }
            }.frame(height: 180)
        }.buttonStyle(.plain)
        .accessibilityIdentifier("inputMediaPreview")
        .task(id: identity) { await load() }
        .quickLookPreview($quickLookURL)
        .sheet(isPresented: $showFull) {
            NavigationStack {
                Group {
                    if kind == .video, let url = store.client?.inputMediaURL(value) { InputVideoPlayer(url: url) }
                    else if let image { Image(uiImage: image).resizable().scaledToFit() }
                }.navigationTitle("输入预览").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("关闭") { showFull = false } }
            }
        }
        .onDisappear { if let localFile { try? FileManager.default.removeItem(at: localFile) } }
    }
    private func load() async {
        let expected = identity
        image = nil; failed = false; loading = true
        if let localFile { try? FileManager.default.removeItem(at: localFile); self.localFile = nil }
        defer { if identity == expected { loading = false } }
        guard !value.isEmpty, let api = store.client else { return }
        do {
            let decoded: UIImage?
            if kind == .video {
                // AVFoundation requests the first frame with HTTP range requests.
                decoded = await MediaThumbnail.video(api.inputMediaURL(value))
            } else {
                let data = try await api.inputMedia(value)
                if kind == .image { decoded = MediaThumbnail.image(data) }
                else {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(MediaFile.split(value).filename)")
                    try data.write(to: file)
                    decoded = await MediaThumbnail.file(file)
                    if identity == expected && !Task.isCancelled { localFile = file }
                    else { try? FileManager.default.removeItem(at: file) }
                }
            }
            guard identity == expected, !Task.isCancelled else { return }
            image = decoded; failed = decoded == nil && localFile == nil
        } catch { if identity == expected && !Task.isCancelled { failed = true } }
    }
}

private struct InputVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player).onAppear { player = AVPlayer(url: url) }.onDisappear { player?.pause(); player = nil }
    }
}

private struct ServerMediaPicker: View {
    @Environment(\.dismiss) private var dismiss
    let choices: [String]
    let kind: MediaKind
    let select: (String) -> Void
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List(choices.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { name in
                Button { select(name); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        InputMediaPreview(value: name, kind: kind).allowsHitTesting(false)
                        Text(name).font(.caption).foregroundStyle(.primary).lineLimit(2)
                    }
                }.buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "搜索文件")
            .navigationTitle("预览并选择文件").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("取消") { dismiss() } }
        }
    }
}
