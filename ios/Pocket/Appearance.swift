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
    var colorScheme: ColorScheme? { mode == "dark" ? .dark : mode == "light" ? .light : nil }
    private init() {
        colorway = PocketColorway(rawValue: UserDefaults.standard.string(forKey: "appearance.colorway") ?? "") ?? .celadon
        mode = UserDefaults.standard.string(forKey: "appearance.mode") ?? "system"
    }
}

struct AppearanceSettings: View {
    var body: some View {
        @Bindable var appearance = PocketAppearance.shared
        Section("外观与配色") {
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
