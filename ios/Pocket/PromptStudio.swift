import SwiftUI

struct PromptInputEditor: View {
    @Environment(PocketStore.self) private var store
    @Binding var text: String
    let preferenceKey: String
    @State private var boardRevision = UUID()
    @AppStorage private var blockEditing: Bool
    @State private var showStudio = false
    @State private var showLibrary = false
    init(text: Binding<String>, preferenceKey: String) {
        _text = text
        self.preferenceKey = preferenceKey
        _blockEditing = AppStorage(wrappedValue: false, "promptBlockEditing.\(preferenceKey)")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("提示词分块编辑", isOn: $blockEditing).font(.subheadline).accessibilityIdentifier("promptBlockEditing")
            if blockEditing {
                PromptBoardField(text: $text, storageKey: preferenceKey).id(boardRevision)
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
        .sheet(isPresented: $showStudio, onDismiss: { boardRevision = UUID() }) { PromptStudioView(text: $text, storageKey: preferenceKey) }
        .sheet(isPresented: $showLibrary) { PromptLibraryView(insert: { text = $0 }) }
    }
}

struct PromptStudioView: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let storageKey: String
    @State private var original: String
    @State private var originalBoard: PromptBoardDocument
    @State private var board: PromptBoardDocument
    @State private var conflict = false
    @State private var showLibrary = false
    init(text: Binding<String>, storageKey: String) {
        _text = text; self.storageKey = storageKey
        let document = PromptBoardStorage.load(storageKey, text: text.wrappedValue)
        _board = State(initialValue: document)
        _originalBoard = State(initialValue: document)
        _original = State(initialValue: text.wrappedValue)
    }
    private var draft: String { board.rendered == originalBoard.rendered ? original : board.rendered }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("点按词块打开详情，长按拖动排序，也可拖入其他分类。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    PromptChipBoard(document: $board)
                    GroupBox("最终提示词") {
                        Text(draft.isEmpty ? "尚未添加提示词" : draft)
                            .font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                        if text != original && board != originalBoard { conflict = true }
                        else { apply() }
                    }
                }
            }
            .alert("提示词已在其他位置更新", isPresented: $conflict) {
                Button("保留当前编辑", role: .destructive) { apply(overwrite: true) }
                Button("继续编辑", role: .cancel) { }
            } message: { Text("应用会覆盖期间同步收到的提示词。可先保存新版本再决定。") }
            .sheet(isPresented: $showLibrary) {
                PromptLibraryView(insert: { board.add($0, to: "uncategorized") })
            }
        }
    }
    private func apply(overwrite: Bool = false) {
        if text == original || overwrite {
            text = draft
            PromptBoardStorage.save(storageKey, text: text, document: board)
        }
        dismiss()
    }
}
