import Foundation

enum PromptWordFunction: String, Codable, CaseIterable, Identifiable, Sendable {
    case subject, style, composition, lighting, camera, color, quality, negative, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .subject: return "主体与场景"
        case .style: return "画风与材质"
        case .composition: return "构图与视角"
        case .lighting: return "光照"
        case .camera: return "镜头与景深"
        case .color: return "色彩"
        case .quality: return "画质与细节"
        case .negative: return "排除与负面"
        case .other: return "其他"
        }
    }
    /// Conservative local keyword matching; the user can override ambiguous phrases.
    static func recognize(_ text: String) -> Self {
        let text = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if text.hasPrefix("<lora:") || text.hasPrefix("<lyco:") { return .style }
        if text.range(of: #"\b\d+(?:\.\d+)?\s*mm\b|\bf/\d"#, options: .regularExpression) != nil { return .camera }
        for rule in rules where rule.words.contains(where: { matches($0, in: text) }) { return rule.function }
        return .other
    }
    private static func matches(_ word: String, in text: String) -> Bool {
        // CJK text doesn't require whitespace; Latin terms must have word boundaries.
        if word.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { return text.contains(word) }
        var start = text.startIndex
        func isLatinWordCharacter(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { (97...122).contains($0.value) || (48...57).contains($0.value) }
        }
        while start < text.endIndex, let range = text.range(of: word, range: start..<text.endIndex) {
            let left = range.lowerBound == text.startIndex || !isLatinWordCharacter(text[text.index(before: range.lowerBound)])
            let right = range.upperBound == text.endIndex || !isLatinWordCharacter(text[range.upperBound])
            if left && right { return true }
            start = range.upperBound
        }
        return false
    }
    private static let rules: [(function: PromptWordFunction, words: [String])] = [
        (.negative, ["bad anatomy", "bad hands", "low quality", "worst quality", "lowres", "watermark", "extra fingers", "extra limbs", "deformed", "disfigured", "negative prompt", "without", "no text", "no watermark", "负面", "排除", "不要", "水印", "畸形", "多余手指"]),
        (.camera, ["lens", "focal", "aperture", "depth of field", "bokeh", "dof", "dslr", "镜头", "焦距", "光圈", "景深", "虚化"]),
        (.lighting, ["light", "lighting", "lit", "shadows", "shadow", "sunlight", "backlight", "backlighting", "subsurface scattering", "sunrise", "sunset", "光照", "光线", "柔光", "逆光", "侧光", "顶光", "阴影", "散射", "补光"]),
        (.color, ["color", "colour", "palette", "monochrome", "black and white", "vibrant", "pastel", "saturated", "desaturated", "色彩", "色调", "调色", "黑白", "暖色", "冷色", "饱和度"]),
        (.composition, ["composition", "portrait", "full body", "upper body", "close-up", "close up", "wide shot", "medium shot", "centered", "rule of thirds", "perspective", "from above", "from below", "dutch angle", "构图", "人像", "半身", "全身", "特写", "俯视", "仰视", "视角", "居中"]),
        (.style, ["realistic", "photorealistic", "ultra-realistic", "anime", "illustration", "watercolor", "oil painting", "sketch", "cinematic", "film grain", "3d", "render", "pixel art", "texture", "材质", "纹理", "写实", "动漫", "动画", "插画", "油画", "水彩", "素描", "像素", "电影感"]),
        (.quality, ["masterpiece", "best quality", "high quality", "high resolution", "high res", "ultra high res", "highly detailed", "hyper-detailed", "detailed", "intricate", "8k", "4k", "hd", "画质", "高质量", "细节", "精细", "高清", "锐利", "杰作"]),
        (.subject, ["woman", "women", "girl", "girls", "man", "men", "boy", "boys", "person", "people", "1girl", "1boy", "face", "skin", "hair", "body", "dress", "skirt", "lingerie", "shirt", "outfit", "dog", "cat", "tree", "mountain", "city", "landscape", "room", "人物", "角色", "女孩", "女性", "男性", "男孩", "皮肤", "头发", "服装", "衣服", "场景", "风景", "城市", "室内", "猫", "狗"])
    ]
}

extension PromptBoardDocument {
    func words(matching function: PromptWordFunction?) -> [PromptBlock] {
        orderedBlocks.filter { function == nil || $0.function == function }
    }
}
