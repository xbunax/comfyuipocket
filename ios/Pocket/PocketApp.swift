import SwiftUI

@main
struct PocketApp: App {
    @State private var store = PocketStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environment(store)
                .tint(PocketPalette.accent)
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

enum PocketPalette {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemMint : .systemTeal
    })
}

struct PocketBackground: View {
    var body: some View {
        LinearGradient(colors: [PocketPalette.accent.opacity(0.07), Color(uiColor: .systemGroupedBackground), Color(uiColor: .systemGroupedBackground)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

/// Shared spacing and background for the app's parameter and activity lists.
extension View {
    func pocketListSurface() -> some View {
        self.listStyle(.insetGrouped)
            .listSectionSpacing(18)
            .scrollContentBackground(.hidden)
            .background(PocketBackground())
    }
}

struct PocketMetric: View {
    let title: String
    let value: Int
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(PocketPalette.accent)
            Text("\(value)").fontWeight(.semibold).monospacedDigit()
            Text(title).foregroundStyle(.secondary)
        }.font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.04), in: .capsule)
            .accessibilityElement(children: .combine)
    }
}

struct PocketConnectionSummary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConnectionBadge()
            SyncBadge()
        }.padding(.vertical, 4)
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
                    VStack(alignment: .leading, spacing: 16) {
                        Label("ComfyUI", systemImage: "server.rack").font(.title2.weight(.semibold))
                        PocketConnectionSummary()
                    }.padding(.vertical, 8)
                }
                Section("ComfyUI 服务器") {
                    TextField("IP 地址，例如 192.168.1.20", text: $store.profile.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    HStack {
                        Text("端口")
                        TextField("端口", text: $store.profile.port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
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
                Section {
                    DisclosureGroup("连接帮助") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("ComfyUI 需监听手机能访问的网卡，例如 --listen 0.0.0.0 --port 8188。")
                            Text("ComfyUI 原生接口没有访问密码。仅在可信局域网内使用，不要把端口开放到公网。")
                            Text("连接后工作流会自动双向同步；直接导入 API JSON 和运行任务不依赖插件。")
                        }.font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
                Section("图片缓存") {
                    Text("自动复用图片和视频首帧预览，内存上限 32 MB，磁盘上限 256 MB。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("清理图片缓存", systemImage: "arrow.clockwise") {
                        Task { await MediaCache.shared.clear(); store.notice = "图片缓存已清理。" }
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle("连接")
        }
    }
}
