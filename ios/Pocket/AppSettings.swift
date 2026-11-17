import SwiftUI

struct AppSettingsView: View {
    @AppStorage("defaultWorkflowView") private var defaultView = "parameters"
    @AppStorage("workspaceLayoutMode") private var layoutMode = "automatic"
    var body: some View {
        Form {
            Section {
                Picker("界面布局", selection: $layoutMode) {
                    Text("自动适应窗口").tag("automatic")
                    Text("紧凑单栏").tag("compact")
                    Text("大屏分栏").tag("expanded")
                }
                Label("⌘1 工作台 · ⌘2 任务 · ⌘3 作品 · ⌘4 连接", systemImage: "keyboard")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("iPad 与 Mac 镜像") } footer: {
                Text("按当前窗口宽度适配，支持 iPad 分屏与可调整大小的 iPhone 镜像窗口。大屏分栏至少需要 680 点宽度；窗口较窄时保留单栏。镜像窗口是否可自由调整由系统版本决定。")
            }
            Section {
                Picker("默认视图", selection: $defaultView) {
                    Label("参数面板", systemImage: "slider.horizontal.3").tag("parameters")
                    Label("工作流画布", systemImage: "square.3.layers.3d").tag("canvas")
                }
            } header: {
                Text("工作流")
            } footer: {
                Text("从工作台打开工作流时使用此视图。仍可随时进入画布或返回参数面板；画布需要连接服务器。")
            }
        }.pocketListSurface().frame(maxWidth: 760).frame(maxWidth: .infinity).background(PocketBackground())
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
    }
}
