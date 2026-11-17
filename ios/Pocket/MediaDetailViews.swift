import SwiftUI
import AVKit
import ImageIO

struct ZoomableArtwork: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ArtworkScrollView {
        let view = ArtworkScrollView(); view.setImage(image); return view
    }
    func updateUIView(_ view: ArtworkScrollView, context: Context) { view.setImage(image) }
}

final class ArtworkScrollView: UIScrollView, UIScrollViewDelegate {
    private let picture = UIImageView()
    private var lastBounds = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; addSubview(picture)
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        bouncesZoom = true; contentInsetAdjustmentBehavior = .never
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfTapsRequired = 2; addGestureRecognizer(tap)
        accessibilityLabel = "作品图片，可双指缩放、拖动查看，双击放大或还原"
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
    @objc private func doubleTap(_ tap: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.1 { setZoomScale(minimumZoomScale, animated: true); return }
        let next = min(maximumZoomScale, minimumZoomScale * 2.5)
        let point = tap.location(in: picture)
        zoom(to: CGRect(x: point.x - bounds.width / next / 2, y: point.y - bounds.height / next / 2,
                        width: bounds.width / next, height: bounds.height / next), animated: true)
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
                    if let record, !record.promptFields.isEmpty {
                        ForEach(record.promptFields) { field in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("\(field.nodeTitle) · \(field.key)").font(.caption).foregroundStyle(PocketPalette.secondary)
                                    Spacer()
                                    Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = field.value.text }.labelStyle(.iconOnly)
                                }
                                Text(field.value.text.isEmpty ? "空提示词" : field.value.text).textSelection(.enabled)
                            }.padding(.vertical, 4)
                        }
                    } else { Text("未找到此作品提交时的提示词记录。").foregroundStyle(PocketPalette.secondary) }
                }
                if let record, !record.parameterFields.isEmpty {
                    Section {
                        DisclosureGroup("生成参数") {
                            ForEach(record.parameterFields) { field in
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
