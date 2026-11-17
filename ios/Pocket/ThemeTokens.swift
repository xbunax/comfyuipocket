import Foundation

struct PocketThemeTokens {
    let accent: UInt32
    let background: UInt32
    let surface: UInt32
    let text: UInt32
    let secondary: UInt32
    let border: UInt32
}

enum PocketColorway: String, CaseIterable, Identifiable {
    case celadon, iris, bay, amber, graphite, gruvbox, mocha
    var id: String { rawValue }
    var title: String {
        switch self {
        case .celadon: "青瓷绿"; case .iris: "鸢尾紫"; case .bay: "海湾蓝"
        case .amber: "琥珀金"; case .graphite: "石墨灰"; case .gruvbox: "Gruvbox"; case .mocha: "Catppuccin Mocha"
        }
    }
    var subtitle: String {
        switch self {
        case .celadon: "清爽 · 延续经典"
        case .iris: "柔和 · 灵感创作"
        case .bay: "明快 · 专注操作"
        case .amber: "温暖 · 醒目重点"
        case .graphite: "克制 · 突出作品"
        case .gruvbox: "暖灰与复古金 · 浅色为 Gruvbox Light"
        case .mocha: "奶紫与蓝灰 · 浅色为 Catppuccin Latte"
        }
    }
    func tokens(dark: Bool) -> PocketThemeTokens {
        // Official community palettes; attribution is bundled in Theme-LICENSE.txt.
        if self == .gruvbox {
            return dark
                ? PocketThemeTokens(accent: 0xfabd2f, background: 0x282828, surface: 0x3c3836, text: 0xebdbb2, secondary: 0xbdae93, border: 0x665c54)
                : PocketThemeTokens(accent: 0xaf3a03, background: 0xfbf1c7, surface: 0xf2e5bc, text: 0x3c3836, secondary: 0x665c54, border: 0xbdae93)
        }
        if self == .mocha {
            return dark
                ? PocketThemeTokens(accent: 0xcba6f7, background: 0x1e1e2e, surface: 0x313244, text: 0xcdd6f4, secondary: 0xa6adc8, border: 0x585b70)
                : PocketThemeTokens(accent: 0x8839ef, background: 0xeff1f5, surface: 0xeff1f5, text: 0x4c4f69, secondary: 0x5c5f77, border: 0x9ca0b0)
        }
        let accent: UInt32
        switch self {
        case .celadon: accent = dark ? 0x54dcca : 0x007d73
        case .iris: accent = dark ? 0xc5adff : 0x6842c2
        case .bay: accent = dark ? 0x81b9ff : 0x1764bc
        case .amber: accent = dark ? 0xf5cb73 : 0x925600
        case .graphite: accent = dark ? 0xcfd4dc : 0x505963
        default: accent = 0x54dcca
        }
        return dark
            ? PocketThemeTokens(accent: accent, background: 0x14171b, surface: 0x22262c, text: 0xf1f3f6, secondary: 0xb3bac5, border: 0x535c68)
            : PocketThemeTokens(accent: accent, background: 0xf4f5f7, surface: 0xffffff, text: 0x20242a, secondary: 0x59616e, border: 0x9aa3b0)
    }
}
