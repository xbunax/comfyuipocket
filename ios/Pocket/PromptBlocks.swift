import Foundation

struct PromptBlock: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var weight: Double = 1
    var enabled = true
    var categoryID = "uncategorized"
    var functionOverride: PromptWordFunction? = nil
    var function: PromptWordFunction { functionOverride ?? PromptWordFunction.recognize(text) }
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

struct PromptCategory: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var collapsed = false
    static var uncategorized: Self { Self(id: "uncategorized", name: "未分类") }
}

struct PromptBoardDocument: Codable, Equatable {
    var categories: [PromptCategory] = [.uncategorized]
    var blocks: [PromptBlock] = []
    init(text: String) { blocks = PromptBlocks.parse(text) }
    var orderedBlocks: [PromptBlock] {
        categories.flatMap { category in blocks.filter { $0.categoryID == category.id } }
    }
    var rendered: String { PromptBlocks.render(orderedBlocks) }
    mutating func add(_ text: String, to categoryID: String) {
        guard categories.contains(where: { $0.id == categoryID }) else { return }
        blocks.append(contentsOf: PromptBlocks.parse(text).map { block in
            var block = block; block.categoryID = categoryID; return block
        })
    }
    mutating func move(_ id: UUID, to categoryID: String, over target: UUID? = nil) {
        guard categories.contains(where: { $0.id == categoryID }),
              let source = blocks.firstIndex(where: { $0.id == id }), id != target else { return }
        let targetIndex = target.flatMap { target in blocks.firstIndex { $0.id == target } }
        var item = blocks.remove(at: source)
        item.categoryID = categoryID
        if let target, let destination = blocks.firstIndex(where: { $0.id == target }) {
            blocks.insert(item, at: destination + ((targetIndex ?? source) > source ? 1 : 0))
        } else { blocks.append(item) }
    }
    mutating func removeCategory(_ id: String) {
        guard id != "uncategorized" else { return }
        for index in blocks.indices where blocks[index].categoryID == id { blocks[index].categoryID = "uncategorized" }
        categories.removeAll { $0.id == id }
    }
    mutating func synchronize(_ text: String) {
        var available = blocks
        blocks = PromptBlocks.parse(text).map { parsed in
            if let index = available.firstIndex(where: { $0.enabled && $0.rendered == parsed.rendered }) {
                return available.remove(at: index)
            }
            return parsed
        }
        // Disabled words are local drafts, so receiving active text must not lose them.
        blocks.append(contentsOf: available.filter { !$0.enabled })
        // An externally edited prompt owns its order. Preserve matching category
        // names only while that grouping can represent the new order exactly.
        if rendered != PromptBlocks.render(PromptBlocks.parse(text)) {
            for index in blocks.indices where blocks[index].enabled { blocks[index].categoryID = "uncategorized" }
        }
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
