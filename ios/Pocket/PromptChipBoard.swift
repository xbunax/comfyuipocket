import SwiftUI

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
    var functionFilter: PromptWordFunction? = nil
    @State private var boardID = UUID()
    @State private var haptics = PromptDragHaptics()
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
                if functionFilter == nil || document.blocks.contains(where: { $0.categoryID == category.id && $0.function == functionFilter }) {
                    categoryCard(category)
                }
            }
            Button("新建分类", systemImage: "plus") { addingCategory = true }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.secondary.opacity(0.04), in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
                .buttonStyle(.plain)
        }
        .onDisappear { resetDrag() }
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
        let blocks = document.blocks.filter { $0.categoryID == category.id && (functionFilter == nil || $0.function == functionFilter) }
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
        .background(PromptCategoryDropZone(actions: dropActions(category: category.id, target: nil)))
    }
    private func chip(_ block: PromptBlock, category: String) -> some View {
        PromptNativeChip(block: block, boardID: boardID, highlighted: highlightedWord == block.id,
            dragging: dragged == block.id, actions: dropActions(category: category, target: block.id),
            edit: { selected = block }, delete: { document.blocks.removeAll { $0.id == block.id } },
            move: { moveWord(block, by: $0) }, lifted: {
                dragged = block.id; highlightedCategory = nil; highlightedWord = nil; haptics.began()
            }, ended: { resetDrag() })
    }
    private func dropActions(category: String, target: UUID?) -> PromptWordDropActions {
        PromptWordDropActions(boardID: boardID, accepts: { id in document.blocks.contains { $0.id == id } }, entered: {
            guard let dragged, target != dragged else { return }
            if highlightedCategory != category || highlightedWord != target {
                highlightedCategory = category; highlightedWord = target; haptics.targetChanged()
            }
        }, exited: {
            if highlightedCategory == category && highlightedWord == target {
                highlightedCategory = nil; highlightedWord = nil
            }
        }, dropped: { id in
            let before = document
            withAnimation(.snappy(duration: 0.18)) { document.move(id, to: category, over: target) }
            if document != before { haptics.completed() }
            resetDrag()
        })
    }
    private func resetDrag() { dragged = nil; highlightedCategory = nil; highlightedWord = nil }
    private func moveWord(_ block: PromptBlock, by delta: Int) {
        let siblings = document.blocks.filter { $0.categoryID == block.categoryID }
        guard let index = siblings.firstIndex(where: { $0.id == block.id }), siblings.indices.contains(index + delta) else { return }
        document.move(block.id, to: block.categoryID, over: siblings[index + delta].id)
        haptics.completed()
    }
    private func moveCategory(_ id: String, by delta: Int) {
        guard let index = document.categories.firstIndex(where: { $0.id == id }), document.categories.indices.contains(index + delta) else { return }
        document.categories.swapAt(index, index + delta)
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
