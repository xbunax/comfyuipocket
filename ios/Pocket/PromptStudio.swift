import SwiftUI

struct PromptInputEditor: View {
    @Environment(PocketStore.self) private var store
    @Binding var text: String
    @AppStorage private var blockEditing: Bool
    @State private var showStudio = false
    @State private var showLibrary = false
    init(text: Binding<String>, preferenceKey: String) {
        _text = text
        _blockEditing = AppStorage(wrappedValue: false, "promptBlockEditing.\(preferenceKey)")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("提示词分块编辑", isOn: $blockEditing).font(.subheadline).accessibilityIdentifier("promptBlockEditing")
            if blockEditing {
                PromptBlockList(text: $text)
            } else {
                TextField("提示词", text: $text, axis: .vertical)
                    .lineLimit(4...12)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Button("可视化编辑", systemImage: "square.grid.2x2") { showStudio = true }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("promptVisualEditor")
            HStack(spacing: 16) {
                Button("保存的版本", systemImage: "text.book.closed") { showLibrary = true }
                Button("保存新版本", systemImage: "square.and.arrow.down") {
                    if store.savePrompt(title: "", text: text) != nil { store.notice = "已保存提示词版本。" }
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.caption).buttonStyle(.borderless)
        }
        .sheet(isPresented: $showStudio) { PromptStudioView(text: $text) }
        .sheet(isPresented: $showLibrary) { PromptLibraryView(insert: { text = $0 }) }
    }
}

struct PromptStudioView: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    @State private var draft: String
    @State private var original: String
    @State private var conflict = false
    @State private var showLibrary = false
    init(text: Binding<String>) {
        _text = text
        _draft = State(initialValue: text.wrappedValue)
        _original = State(initialValue: text.wrappedValue)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("把提示词拆成卡片，调整顺序、启停和权重。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    PromptBlockList(text: $draft)
                    GroupBox("最终提示词") {
                        Text(draft.isEmpty ? "尚未添加提示词" : draft)
                            .font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("权重使用 ComfyUI 的 (提示词:1.20) 语法，实际效果取决于工作流中的文本编码节点。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("插入已存版本", systemImage: "text.book.closed") { showLibrary = true }
                        Spacer()
                        Button("保存新版本", systemImage: "square.and.arrow.down") {
                            if store.savePrompt(title: "", text: draft) != nil { store.notice = "已保存提示词版本。" }
                        }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.font(.caption).buttonStyle(.bordered)
                }.padding()
            }
            .navigationTitle("提示词可视化编辑").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        if text != original && draft != original { conflict = true }
                        else { if draft != original { text = draft }; dismiss() }
                    }
                }
            }
            .alert("提示词已在其他位置更新", isPresented: $conflict) {
                Button("保留当前编辑", role: .destructive) { text = draft; dismiss() }
                Button("继续编辑", role: .cancel) { }
            } message: { Text("应用会覆盖期间同步收到的提示词。可先保存新版本再决定。") }
            .sheet(isPresented: $showLibrary) {
                PromptLibraryView(insert: { value in
                    draft = draft.isEmpty ? value : draft + ", " + value
                })
            }
        }
    }
}

struct PromptBlockList: View {
    @Binding var text: String
    @State private var blocks: [PromptBlock] = []
    @State private var rendered = ""
    @State private var newText = ""
    var body: some View {
        VStack(spacing: 10) {
            ForEach($blocks) { $block in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("启用", isOn: $block.enabled).labelsHidden()
                            .accessibilityLabel("启用提示词 \(block.text)")
                        Text("提示词 \((blocks.firstIndex(where: { $0.id == block.id }) ?? 0) + 1)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { move(block.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(block.id == blocks.first?.id).accessibilityLabel("上移提示词")
                        Button { move(block.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(block.id == blocks.last?.id).accessibilityLabel("下移提示词")
                        Button(role: .destructive) { blocks.removeAll { $0.id == block.id } } label: {
                            Image(systemName: "trash")
                        }.accessibilityLabel("删除提示词")
                    }.buttonStyle(.borderless)
                    TextField("提示词内容", text: $block.text, axis: .vertical)
                        .lineLimit(1...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .opacity(block.enabled ? 1 : 0.45)
                    Stepper(value: $block.weight, in: 0...max(3, block.weight), step: 0.05) {
                        Text("权重 \(PromptBlock.weightText(block.weight))").font(.caption.monospacedDigit())
                    }.disabled(!block.enabled)
                }
                .padding(12)
                .background(block.enabled ? Color.mint.opacity(0.08) : Color.secondary.opacity(0.06), in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.15)))
            }
            HStack(alignment: .top) {
                TextField("添加提示词（逗号分块）", text: $newText, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("添加", systemImage: "plus") {
                    blocks.append(contentsOf: PromptBlocks.parse(newText)); newText = ""
                }.disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.buttonStyle(.borderless)
        }
        .onAppear { reset(text) }
        .onChange(of: blocks) { _, next in
            // Parsing on entry or receiving external edits never rewrites the source.
            let value = PromptBlocks.render(next)
            if value != rendered { rendered = value; text = value }
        }
        .onChange(of: text) { _, next in
            if next != rendered { reset(next) }
        }
    }
    private func reset(_ value: String) {
        let parsed = PromptBlocks.parse(value)
        rendered = PromptBlocks.render(parsed); blocks = parsed
    }
    private func move(_ id: UUID, by delta: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }), blocks.indices.contains(index + delta) else { return }
        blocks.swapAt(index, index + delta)
    }
}
