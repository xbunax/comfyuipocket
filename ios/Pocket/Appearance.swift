import SwiftUI

extension PocketColorway {
    var color: Color { resolved(\.accent) }
    func resolved(_ key: KeyPath<PocketThemeTokens, UInt32>) -> Color {
        let light = tokens(dark: false)[keyPath: key], dark = tokens(dark: true)[keyPath: key]
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

@MainActor @Observable final class PocketAppearance {
    static let shared = PocketAppearance()
    var colorway: PocketColorway {
        didSet { UserDefaults.standard.set(colorway.rawValue, forKey: "appearance.colorway") }
    }
    var mode: String {
        didSet { UserDefaults.standard.set(mode, forKey: "appearance.mode") }
    }
    var replacesNodeStyle: Bool {
        didSet { UserDefaults.standard.set(replacesNodeStyle, forKey: "appearance.replacesNodeStyle") }
    }
    var overviewTapFocus: Bool {
        didSet { UserDefaults.standard.set(overviewTapFocus, forKey: "canvas.overviewTapFocus") }
    }
    var colorScheme: ColorScheme? { mode == "dark" ? .dark : mode == "light" ? .light : nil }
    private init() {
        colorway = PocketColorway(rawValue: UserDefaults.standard.string(forKey: "appearance.colorway") ?? "") ?? .celadon
        mode = UserDefaults.standard.string(forKey: "appearance.mode") ?? "system"
        overviewTapFocus = UserDefaults.standard.bool(forKey: "canvas.overviewTapFocus")
        replacesNodeStyle = UserDefaults.standard.bool(forKey: "appearance.replacesNodeStyle")
    }
}

struct AppearanceSettings: View {
    var body: some View {
        @Bindable var appearance = PocketAppearance.shared
        Section("外观与配色") {
            NavigationLink {
                CanvasAppearanceSettings()
            } label: {
                Label("工作流画布", systemImage: "square.3.layers.3d")
            }
            Picker("外观", selection: $appearance.mode) {
                Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
            }.pickerStyle(.segmented)
            ForEach(PocketColorway.allCases) { colorway in
                Button {
                    appearance.colorway = colorway
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10).fill(colorway.color).frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(colorway.title).font(.subheadline.weight(.semibold)).foregroundStyle(PocketPalette.text)
                            Text(colorway.subtitle).font(.caption).foregroundStyle(PocketPalette.secondary)
                        }
                        Spacer()
                        if appearance.colorway == colorway { Image(systemName: "checkmark.circle.fill").foregroundStyle(colorway.color) }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(appearance.colorway == colorway ? [.isSelected] : [])
            }
        }.listRowBackground(PocketPalette.surface)
    }
}

struct CanvasAppearanceSettings: View {
    var body: some View {
        @Bindable var appearance = PocketAppearance.shared
        Form {
            Section {
                Toggle("总览中轻点节点聚焦", isOn: $appearance.overviewTapFocus)
                    .accessibilityIdentifier("canvas.overviewTapFocus")
            } header: { Text("画布操作") } footer: {
                Text("轻点总览中的节点标题或空白处会放大该节点。点「总览」可返回全图。")
            }
            Section {
                Toggle("替换节点样式", isOn: $appearance.replacesNodeStyle)
            } header: { Text("节点外观") } footer: {
                Text("默认关闭，保留 ComfyUI 原生外观。开启后使用主题节点底色；端口、连线、自定义绘制及专用控件保持原样。此设置适用于所有工作流，不会改写工作流文件。")
            }
        }.pocketListSurface().navigationTitle("工作流画布").navigationBarTitleDisplayMode(.inline)
    }
}

/// Glass belongs to navigation and controls; node contents retain their own material.
struct PocketGlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(PocketPalette.surface, in: .rect(cornerRadius: radius))
        } else {
            content.glassEffect(.regular.tint(PocketPalette.accent.opacity(0.045)), in: .rect(cornerRadius: radius))
        }
    }
}

extension View {
    func pocketGlassPanel(radius: CGFloat = 26) -> some View { modifier(PocketGlassPanel(radius: radius)) }
}
