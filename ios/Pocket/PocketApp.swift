import SwiftUI

@main
struct PocketApp: App {
    @State private var store = PocketStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environment(store)
                .tint(.mint)
                .onChange(of: phase) { _, value in
                    if value == .active { Task { await store.resume() } }
                    else if value == .background { store.suspend() }
                }
        }
    }
}

struct RootView: View {
    @Environment(PocketStore.self) private var store
    var body: some View {
        @Bindable var store = store
        TabView {
            Tab("工作台", systemImage: "square.stack.3d.up") { LibraryView() }
            Tab("任务", systemImage: "waveform.path") { QueueView() }
            Tab("作品", systemImage: "photo.on.rectangle.angled") { GalleryView() }
            Tab("连接", systemImage: "network") { ConnectionView() }
        }
        .alert("需要处理", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .overlay(alignment: .top) {
            if let notice = store.notice {
                HStack {
                    Text(notice).font(.footnote)
                    Button { store.notice = nil } label: { Image(systemName: "xmark.circle.fill") }
                }
                .padding().glassEffect(in: .rect(cornerRadius: 20)).padding(.horizontal)
                .task(id: notice) { try? await Task.sleep(for: .seconds(5)); if store.notice == notice { store.notice = nil } }
            }
        }
    }
}

struct PocketBackground: View {
    var body: some View {
        LinearGradient(colors: [.mint.opacity(0.16), .cyan.opacity(0.04), Color(uiColor: .systemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

struct ConnectionBadge: View {
    @Environment(PocketStore.self) private var store
    var body: some View {
        Label(store.connected ? (store.socketConnected ? "已连接 · 实时" : "已连接 · 重连实时通道") : "尚未连接", systemImage: store.connected ? "circle.fill" : "circle")
            .font(.caption).foregroundStyle(store.connected ? .green : .secondary)
    }
}

struct ConnectionView: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var starting = false
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    Label("你的算力，随身可用。", systemImage: "sparkles").font(.title2.bold())
                    Text("通过 IP 与端口直接连接自己的 ComfyUI。工作流和图片在手机与服务器之间传输。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ConnectionBadge()
                }
                Section("ComfyUI 服务器") {
                    TextField("IP 地址，例如 192.168.1.20", text: $store.profile.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("端口", text: $store.profile.port).keyboardType(.numberPad)
                    Toggle("HTTPS", isOn: $store.profile.https)
                    Toggle("使用内置 Tailscale", isOn: $store.profile.tailscale)
                }.disabled(store.connected || store.connecting)
                if store.profile.tailscale {
                    Section("应用内组网") {
                        Text("本应用作为独立设备加入你的 Tailnet，无需另装 VPN 应用。ComfyUI 电脑也需要加入同一个网络；地址填写电脑的 Tailscale IP。")
                        Label("仅允许点对点数据传输", systemImage: "lock.shield")
                        Text("禁用 DERP 连接与 Peer Relay 的业务数据；无法直连时连接会失败。登录和网络发现仍使用协调服务与 STUN，可填写自建 Headscale 地址。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("控制服务器（留空使用 Tailscale）", text: $store.profile.controlURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(store.connected)
                        if !store.tailnetStatus["state"].text.isEmpty {
                            LabeledContent("节点状态", value: store.tailnetStatus["state"].text)
                            ForEach(store.tailnetStatus["ips"].array.map(\.text), id: \.self) { Text($0).font(.caption.monospaced()) }
                        }
                        Button(starting ? "正在启动…" : "启动 / 刷新 Tailscale") {
                            Task {
                                starting = true; defer { starting = false }
                                do {
                                    try await TailnetBridge.shared.start(controlURL: store.profile.controlURL)
                                    store.tailnetStatus = try await TailnetBridge.shared.status()
                                    store.save()
                                } catch { store.error = error.localizedDescription }
                            }
                        }.disabled(starting || store.connecting)
                        if let url = URL(string: store.tailnetStatus["authURL"].text), url.scheme == "https" {
                            Button("在浏览器登录 Tailscale", systemImage: "arrow.up.right.square") { openURL(url) }
                        }
                        Button("停止组网", role: .destructive) {
                            store.disconnect()
                            Task { await TailnetBridge.shared.stop(); store.tailnetStatus = .object([:]) }
                        }.disabled(starting)
                    }
                }
                Section {
                    if store.connected {
                        Button("断开服务器", role: .destructive) { store.disconnect() }
                    } else {
                        Button { Task { await store.connect() } } label: {
                            HStack { if store.connecting { ProgressView() }; Text(store.connecting ? "正在连接…" : "连接服务器").frame(maxWidth: .infinity) }
                        }.buttonStyle(.glassProminent).disabled(store.connecting)
                    }
                }
                Section("连接提示") {
                    Text("局域网使用电脑的局域网 IP。ComfyUI 需监听该网卡，例如 --listen 0.0.0.0 --port 8188。")
                    Text("ComfyUI 原生接口没有访问密码。仅在可信局域网或受 Tailnet ACL 保护的网络使用，不要把端口开放到公网。")
                    Text("Pocket 服务端插件用于工作流同步；直接导入 API JSON 和运行任务不依赖插件。")
                }.font(.footnote)
            }
            .navigationTitle("连接")
            .task {
                while !Task.isCancelled {
                    if store.profile.tailscale, !store.tailnetStatus.object.isEmpty {
                        if let status = try? await TailnetBridge.shared.status() { store.tailnetStatus = status }
                    }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }
}
