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
            if let transport = store.irohTransport { Label(transport.status, systemImage: "point.3.connected.trianglepath.dotted").font(.caption) }
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
