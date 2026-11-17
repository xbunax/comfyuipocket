import SwiftUI

struct AppSettingsView: View {
    @AppStorage("defaultWorkflowView") private var defaultView = "parameters"
    var body: some View {
        Form {
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
        }.pocketListSurface().navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
    }
}
