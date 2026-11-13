import Foundation

struct PromptBlock: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var weight: Double = 1
    var enabled = true
    private var original: String
    private var originalText: String
    private var originalWeight: Double

    init(text: String, weight: Double = 1, original: String? = nil) {
        self.text = text; self.weight = weight
        self.original = original ?? text
        self.originalText = text; self.originalWeight = weight
    }
    var rendered: String {
        guard enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        if text == originalText && weight == originalWeight { return original }
        if weight == 1 { return text }
        return "(\(text):\(Self.weightText(weight)))"
    }
    static func weightText(_ weight: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), weight)
    }
}

enum PromptBlocks {
    // Split only at the top level. Preserve escaped punctuation, LoRA tags,
    // weighted expressions, schedules and nested syntax as indivisible blocks.
    static func parse(_ text: String) -> [PromptBlock] {
        var parts: [String] = []; var current = ""; var stack: [Character] = []
        var escaped = false
        let closers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "<": ">"]
        for char in text {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" { current.append(char); escaped = true; continue }
            if let closer = closers[char] { stack.append(closer) }
            else if stack.last == char { stack.removeLast() }
            if stack.isEmpty && (char == "," || char == "，" || char.isNewline) {
                parts.append(current); current = ""
            } else { current.append(char) }
        }
        parts.append(current)
        return parts.compactMap { raw in
            let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if let weighted = weighted(raw) {
                return PromptBlock(text: weighted.0, weight: weighted.1, original: raw)
            }
            return PromptBlock(text: raw)
        }
    }
    static func render(_ blocks: [PromptBlock]) -> String {
        blocks.map(\.rendered).filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private static func weighted(_ text: String) -> (String, Double)? {
        guard text.first == "(", text.last == ")" else { return nil }
        var depth = 0; var escaped = false; var colon: String.Index?
        for index in text.indices {
            let char = text[index]
            if escaped { escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "(" { depth += 1 }
            if char == ")" {
                depth -= 1
                if depth == 0 && index != text.index(before: text.endIndex) { return nil }
            }
            if char == ":" && depth == 1 { colon = index }
        }
        guard depth == 0, let colon,
              let weight = Double(text[text.index(after: colon)..<text.index(before: text.endIndex)]),
              weight.isFinite, weight >= 0 else { return nil }
        return (String(text[text.index(after: text.startIndex)..<colon]), weight)
    }
}
