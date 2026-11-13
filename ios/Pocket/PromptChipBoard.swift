import SwiftUI
import UniformTypeIdentifiers

@MainActor enum PromptBoardStorage {
    private struct Saved: Codable {
        var sourceText: String
        var document: PromptBoardDocument
    }
    static func load(_ key: String, text: String) -> PromptBoardDocument {
        guard let data = UserDefaults.standard.data(forKey: "promptBoard.\(key)"),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return PromptBoardDocument(text: text) }
        var document = saved.document
        if saved.sourceText != text { document.synchronize(text) }
        return document
    }
    static func save(_ key: String, text: String, document: PromptBoardDocument) {
        if let data = try? JSONEncoder().encode(Saved(sourceText: text, document: document)) {
            UserDefaults.standard.set(data, forKey: "promptBoard.\(key)")
        }
    }
}

struct PromptBoardField: View {
    @Binding var text: String
    let storageKey: String
    @State private var document: PromptBoardDocument
    @State private var rendered: String
    init(text: Binding<String>, storageKey: String) {
        _text = text; self.storageKey = storageKey
        let document = PromptBoardStorage.load(storageKey, text: text.wrappedValue)
        _document = State(initialValue: document); _rendered = State(initialValue: document.rendered)
    }
    var body: some View {
        PromptChipBoard(document: $document)
            .onChange(of: document) { _, next in
                if next.rendered != rendered { rendered = next.rendered; text = next.rendered }
                PromptBoardStorage.save(storageKey, text: text, document: next)
            }
            .onChange(of: text) { _, next in
                if next != rendered {
                    var nextDocument = document; nextDocument.synchronize(next)
                    rendered = nextDocument.rendered; document = nextDocument
                    PromptBoardStorage.save(storageKey, text: next, document: nextDocument)
                }
            }
    }
}

/// Wrap compact, intrinsic-width words into rows instead of using a vertical list.
struct PromptFlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let naturalWidth = subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = max(1, proposedWidth ?? naturalWidth)
        return arrange(subviews, width: width).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.minX, y: bounds.minY + position.minY),
                                 anchor: .topLeading, proposal: ProposedViewSize(position.size))
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGRect]) {
        var x: CGFloat = 0; var y: CGFloat = 0; var rowHeight: CGFloat = 0
        var positions: [CGRect] = []
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let measured = view.sizeThatFits(ProposedViewSize(width: min(max(1, width), ideal.width), height: nil))
            let size = CGSize(width: min(max(1, width), measured.width), height: measured.height)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), positions)
    }
}

struct PromptChipBoard: View {
    @Binding var document: PromptBoardDocument
    @State private var dragged: UUID?
    @State private var selected: PromptBlock?
    @State private var addingTo: PromptCategory?
    @State private var categoryEditor: PromptCategory?
    @State private var addingCategory = false
    @State private var highlightedCategory: String?
    @State private var highlightedWord: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(document.categories) { category in
                categoryCard(category)
            }
            Button("新建分类", systemImage: "plus") { addingCategory = true }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.secondary.opacity(0.04), in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
                .buttonStyle(.plain)
        }
        .sheet(item: $selected) { block in
            PromptBlockDetailView(block: block, categories: document.categories, save: { edited in
                guard let index = document.blocks.firstIndex(where: { $0.id == edited.id }) else { return }
                document.blocks[index] = edited
            }, delete: { document.blocks.removeAll { $0.id == block.id } })
        }
        .sheet(item: $addingTo) { category in
            AddPromptWordsSheet(categoryName: category.name) { document.add($0, to: category.id) }
        }
        .sheet(item: $categoryEditor) { category in
            PromptCategorySheet(name: category.name) { name in
                if let index = document.categories.firstIndex(where: { $0.id == category.id }) { document.categories[index].name = name }
            }
        }
        .sheet(isPresented: $addingCategory) {
            PromptCategorySheet(name: "") { document.categories.append(PromptCategory(id: UUID().uuidString, name: $0)) }
        }
    }
    private func categoryCard(_ category: PromptCategory) -> some View {
        let blocks = document.blocks.filter { $0.categoryID == category.id }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(Color.mint.opacity(0.8)).frame(width: 8, height: 8)
                Button {
                    if let index = document.categories.firstIndex(where: { $0.id == category.id }) {
                        withAnimation(.snappy) { document.categories[index].collapsed.toggle() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(category.name).font(.subheadline.weight(.semibold))
                        Text("\(blocks.count)").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: category.collapsed ? "chevron.right" : "chevron.down").font(.caption2)
                    }.foregroundStyle(.primary)
                }.buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("重命名", systemImage: "pencil") { categoryEditor = category }
                    Button("上移分类", systemImage: "arrow.up") { moveCategory(category.id, by: -1) }
                        .disabled(category.id == document.categories.first?.id)
                    Button("下移分类", systemImage: "arrow.down") { moveCategory(category.id, by: 1) }
                        .disabled(category.id == document.categories.last?.id)
                    if category.id != "uncategorized" {
                        Button("删除分类并保留词块", systemImage: "trash", role: .destructive) { document.removeCategory(category.id) }
                    }
                } label: { Image(systemName: "ellipsis").padding(6) }
            }
            if !category.collapsed {
                PromptFlowLayout {
                    ForEach(blocks) { block in chip(block, category: category.id) }
                }
                Button("添加词块", systemImage: "plus") { addingTo = category }
                    .font(.subheadline).buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightedCategory == category.id ? Color.mint.opacity(0.12) : Color.secondary.opacity(0.06),
                    in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.secondary.opacity(0.12)))
        .onDrop(of: [UTType.text], delegate: PromptWordDropDelegate(document: $document, dragged: $dragged,
            highlighted: $highlightedCategory, highlightedWord: $highlightedWord, categoryID: category.id, target: nil))
    }
    private func chip(_ block: PromptBlock, category: String) -> some View {
        HStack(spacing: 6) {
            Button { selected = block } label: {
                HStack(spacing: 6) {
                    if !block.enabled { Image(systemName: "pause.circle").font(.caption) }
                    Text(block.text).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                    if block.weight != 1 { Text(PromptBlock.weightText(block.weight)).font(.caption2.monospacedDigit()).foregroundStyle(.mint) }
                }
                .foregroundStyle(block.enabled ? Color.primary : Color.secondary)
                .padding(.leading, 12).padding(.vertical, 11)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("编辑词块 \(block.text)")
                .accessibilityIdentifier("promptChip.\(block.text)")
            Button {
                document.blocks.removeAll { $0.id == block.id }
            } label: { Image(systemName: "xmark").font(.caption).padding(.trailing, 10).padding(.vertical, 12) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("删除词块 \(block.text)")
        }
        .background(block.enabled ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.04), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(highlightedWord == block.id ? Color.mint : Color.secondary.opacity(0.3),
                                                               lineWidth: highlightedWord == block.id ? 2 : 1))
        .opacity(dragged == block.id ? 0.45 : 1)
        .onDrag {
            dragged = block.id
            let provider = PromptWordDragProvider(object: "pocket-word:\(block.id.uuidString)" as NSString)
            provider.suggestedName = "pocket-word:\(block.id.uuidString)"
            provider.didEnd = { if dragged == block.id { dragged = nil; highlightedCategory = nil; highlightedWord = nil } }
            return provider
        }
        .onDrop(of: [UTType.text], delegate: PromptWordDropDelegate(document: $document, dragged: $dragged,
            highlighted: $highlightedCategory, highlightedWord: $highlightedWord, categoryID: category, target: block.id))
        .accessibilityAction(named: "前移") { moveWord(block, by: -1) }
        .accessibilityAction(named: "后移") { moveWord(block, by: 1) }
    }
    private func moveWord(_ block: PromptBlock, by delta: Int) {
        let siblings = document.blocks.filter { $0.categoryID == block.categoryID }
        guard let index = siblings.firstIndex(where: { $0.id == block.id }), siblings.indices.contains(index + delta) else { return }
        document.move(block.id, to: block.categoryID, over: siblings[index + delta].id)
    }
    private func moveCategory(_ id: String, by delta: Int) {
        guard let index = document.categories.firstIndex(where: { $0.id == id }), document.categories.indices.contains(index + delta) else { return }
        document.categories.swapAt(index, index + delta)
    }
}

private struct PromptWordDropDelegate: DropDelegate {
    @Binding var document: PromptBoardDocument
    @Binding var dragged: UUID?
    @Binding var highlighted: String?
    @Binding var highlightedWord: UUID?
    let categoryID: String
    let target: UUID?
    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged else { return false }
        return info.itemProviders(for: [UTType.text]).contains { $0.suggestedName == "pocket-word:\(dragged.uuidString)" }
    }
    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        highlighted = categoryID
        highlightedWord = target
    }
    func dropExited(info: DropInfo) {
        if highlighted == categoryID { highlighted = nil }
        if highlightedWord == target { highlightedWord = nil }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let id = dragged else { return false }
        withAnimation(.snappy(duration: 0.18)) { document.move(id, to: categoryID, over: target) }
        dragged = nil; highlighted = nil; highlightedWord = nil; return true
    }
}

private final class PromptWordDragProvider: NSItemProvider {
    var didEnd: (@MainActor () -> Void)?
    deinit {
        let completion = didEnd
        Task { @MainActor in completion?() }
    }
}

private struct AddPromptWordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let categoryName: String
    let add: (String) -> Void
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("输入提示词", text: $text, axis: .vertical).lineLimit(4...10)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("添加到 \(categoryName)") }
                footer: { Text("逗号或换行可添加多个词块，括号、LoRA 与调度表达式会保留完整。") }
            }.navigationTitle("添加词块").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") { add(text); dismiss() }.disabled(PromptBlocks.parse(text).isEmpty)
                    }
                }
        }.presentationDetents([.medium, .large])
    }
}

private struct PromptCategorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let save: (String) -> Void
    init(name: String, save: @escaping (String) -> Void) { _name = State(initialValue: name); self.save = save }
    var body: some View {
        NavigationStack {
            Form { TextField("分类名称", text: $name) }
                .navigationTitle("提示词分类").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save(name.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.presentationDetents([.medium])
    }
}
