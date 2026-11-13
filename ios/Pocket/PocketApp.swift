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

struct SyncBadge: View {
    @Environment(PocketStore.self) private var store
    var body: some View {
        HStack(spacing: 6) {
            if store.syncing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: store.pluginAvailable ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                    .foregroundStyle(store.pluginAvailable ? .mint : .orange)
            }
            Text(store.connected ? store.syncStatus : "连接后自动同步工作流")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ConnectionView: View {
    @Environment(PocketStore.self) private var store
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    Label("你的算力，随身可用。", systemImage: "sparkles").font(.title2.bold())
                    Text("通过 IP 与端口直接连接自己的 ComfyUI。工作流和图片在手机与服务器之间传输。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ConnectionBadge()
                    SyncBadge()
                }
                Section("ComfyUI 服务器") {
                    TextField("IP 地址，例如 192.168.1.20", text: $store.profile.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("端口", text: $store.profile.port).keyboardType(.numberPad)
                    Toggle("HTTPS", isOn: $store.profile.https)
                }.disabled(store.connected || store.connecting)
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
                    Text("ComfyUI 需监听手机能访问的网卡，例如 --listen 0.0.0.0 --port 8188。")
                    Text("ComfyUI 原生接口没有访问密码。仅在可信局域网内使用，不要把端口开放到公网。")
                    Text("连接后工作流会自动双向同步；直接导入 API JSON 和运行任务不依赖插件。")
                }.font(.footnote)
            }
            .navigationTitle("连接")
        }
    }
}
