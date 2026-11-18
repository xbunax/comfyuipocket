import SwiftUI
import PhotosUI
import Vision
import AVFoundation

struct IrohPairingFields: View {
    @Environment(PocketStore.self) private var store
    @Binding var code: String
    @State private var scanner = false
    @State private var photo: PhotosPickerItem?
    @State private var reading = false
    var body: some View {
        Section {
            if let peer = store.profile.irohPeer {
                VStack(alignment: .leading, spacing: 6) {
                    Label(peer.name, systemImage: "desktopcomputer").font(.headline)
                    Text("设备 \(peer.endpointId.prefix(12))…\(peer.endpointId.suffix(6))")
                        .font(.caption.monospaced()).foregroundStyle(PocketPalette.secondary)
                    Text("已保存配对。断线后会自动重连。若电脑更换地址且无法自动找到，可扫描这台电脑的新二维码刷新地址。")
                        .font(.caption).foregroundStyle(PocketPalette.secondary)
                }.padding(.vertical, 4)
            }
            if !store.connected {
                TextField("粘贴电脑 Pocket 面板生成的配对码", text: $code, axis: .vertical)
                    .lineLimit(3...5).font(.caption.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("pairing.code")
                HStack {
                    Button("扫码", systemImage: "qrcode.viewfinder") { scanner = true }
                    Spacer()
                    Button("粘贴", systemImage: "doc.on.clipboard") { code = UIPasteboard.general.string ?? "" }
                    Spacer()
                    PhotosPicker(selection: $photo, matching: .images) { Label("从图片识别", systemImage: "photo") }
                }.font(.subheadline).buttonStyle(.borderless)
                if reading { ProgressView("正在识别二维码…") }
                if store.profile.irohPeer != nil {
                    Button("忘记这台电脑", systemImage: "link.badge.plus", role: .destructive) {
                        store.profile.irohPeer = nil; store.save(); code = ""
                    }.font(.caption)
                }
            }
        } header: { Text("P2P 配对") } footer: {
            Text("在电脑 ComfyUI 的 Pocket 面板生成配对码或二维码，5 分钟内完成首次配对。仅允许直连，不使用中继；无法直连会明确报错。电脑需安装新版 Pocket 插件及其依赖。")
        }
        .disabled(store.connecting)
        .sheet(isPresented: $scanner) { PairingScanner { code = $0; scanner = false } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                reading = true; defer { reading = false; photo = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), data.count <= 32 * 1024 * 1024 else {
                        throw PocketError.message("二维码图片过大或无法读取。")
                    }
                    let value = try await Task.detached {
                        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
                        try VNImageRequestHandler(data: data).perform([request])
                        guard let value = request.results?.compactMap(\.payloadStringValue).first(where: { $0.hasPrefix("comfypocket://") }) else {
                            throw PocketError.message("图片中没有 Pocket 配对二维码。")
                        }
                        return value
                    }.value
                    _ = try PairingInvitation.parse(value); code = value
                } catch { store.error = error.localizedDescription }
            }
        }
        if let transport = store.irohTransport {
            P2PDiagnostics(transport: transport)
        }
    }
}

private struct P2PDiagnostics: View {
    let transport: IrohTransport
    @State private var showLog = false
    private var test: DirectSpeedTest { transport.speedTest }
    var body: some View {
        Section("连接进度") {
            HStack(spacing: 12) {
                Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
                Rectangle().fill(.secondary.opacity(0.35)).frame(height: 1)
                Image(systemName: transport.directReady ? "link" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(transport.directReady ? PocketPalette.accent : .orange)
                Rectangle().fill(.secondary.opacity(0.35)).frame(height: 1)
                Image(systemName: "desktopcomputer")
            }.font(.title3).padding(.horizontal, 20).accessibilityHidden(true)
            Label(transport.status, systemImage: transport.directReady ? "checkmark.circle" : "network")
                .font(.subheadline.weight(.medium))
            if transport.canRetryNow {
                Button("现在重试", systemImage: "arrow.clockwise") { Task { await transport.retryNow() } }
            }
            DisclosureGroup("连接日志", isExpanded: $showLog) {
                ForEach(transport.events.reversed()) { event in
                    HStack(alignment: .firstTextBaseline) {
                        Text(event.time, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit())
                        Text(event.message).font(.caption)
                    }.foregroundStyle(PocketPalette.secondary)
                }
            }
        }
        Section {
            if transport.supportsSpeedTest {
                Button {
                    if test.running { test.cancel() } else { transport.testSpeed() }
                } label: {
                    HStack {
                        Label(test.running ? "取消测速" : "P2P 测速", systemImage: "speedometer")
                        Spacer()
                        if test.running { ProgressView().controlSize(.small) }
                    }
                }.disabled(!transport.directReady && !test.running)
                if !test.stage.isEmpty {
                    Text(test.stage).font(.caption).foregroundStyle(PocketPalette.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { readings }
                        VStack(alignment: .leading, spacing: 8) { readings }
                    }
                }
            } else if transport.directReady {
                Text("将电脑端 Pocket 插件更新到 0.10.0 并重启，即可测试当前直连。").font(.footnote)
            } else {
                Label("建立直连后可测速", systemImage: "speedometer").foregroundStyle(PocketPalette.secondary)
            }
        } header: { Text("直连测速") } footer: {
            Text("测量手机到这台电脑的往返延迟，以及实际上传和下载速度。每次测试两个方向各传输 2 MiB。")
        }
    }
    @ViewBuilder private var readings: some View {
        reading("往返延迟", value: test.latency, unit: "ms")
        reading("下载", value: test.download, unit: "Mbps")
        reading("上传", value: test.upload, unit: "Mbps")
    }
    private func reading(_ title: String, value: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(PocketPalette.secondary)
            Text(value.map { $0.formatted(.number.precision(.fractionLength(0...2))) + " " + unit } ?? "—")
                .font(.subheadline.monospacedDigit().weight(.medium)).fixedSize(horizontal: true, vertical: false)
        }.accessibilityElement(children: .combine)
    }
}

private struct PairingScanner: View {
    @Environment(\.dismiss) private var dismiss
    let onCode: (String) -> Void
    @State private var message: String?
    var body: some View {
        NavigationStack {
            ZStack {
                PairingCamera(onCode: onCode, onError: { message = $0 })
                if let message {
                    ContentUnavailableView("无法使用相机", systemImage: "camera", description: Text(message + "\n可以改用粘贴配对码或从图片识别。"))
                        .background(PocketPalette.surface)
                } else {
                    VStack { Spacer(); Label("对准电脑上的 Pocket 二维码", systemImage: "qrcode.viewfinder").padding().background(PocketPalette.surface, in: .capsule).padding(.bottom, 24) }
                }
            }.navigationTitle("扫描配对码").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct PairingCamera: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> PairingCameraController {
        PairingCameraController(onCode: onCode, onError: onError)
    }
    func updateUIViewController(_ controller: PairingCameraController, context: Context) {}
    static func dismantleUIViewController(_ controller: PairingCameraController, coordinator: ()) { controller.stop() }
}

private final class PairingCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var read = false
    private var active = true
    private let onCode: (String) -> Void
    private let onError: (String) -> Void
    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode; self.onError = onError; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard active else { return }
            guard granted else { onError("请在系统设置中允许使用相机。"); return }
            do {
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    onError("当前设备没有可用的相机。"); return
                }
                let input = try AVCaptureDeviceInput(device: camera), output = AVCaptureMetadataOutput()
                capture.beginConfiguration()
                guard capture.canAddInput(input), capture.canAddOutput(output) else {
                    capture.commitConfiguration(); onError("当前环境无法启动相机。"); return
                }
                capture.addInput(input); capture.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                capture.commitConfiguration()
                let layer = AVCaptureVideoPreviewLayer(session: capture); layer.videoGravity = .resizeAspectFill
                view.layer.addSublayer(layer); preview = layer; layer.frame = view.bounds
                let session = capture; DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
            } catch { onError("相机启动失败。"); }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { active = false; let session = capture; DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() } }
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first(where: { $0.hasPrefix("comfypocket://") }) else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.read else { return }; self.read = true; self.stop(); self.onCode(value)
        }
    }
}
