import SwiftUI

/// Quick edits and word blocks stay inline; Edit mode opens the larger page.
struct PromptInputEditor: View {
    @Binding var text: String
    let preferenceKey: String
    let context: String
    @AppStorage private var blockEditing: Bool
    @State private var showEditor = false
    @State private var boardRevision = UUID()
    @FocusState private var inputFocused: Bool
    init(text: Binding<String>, preferenceKey: String, context: String = "") {
        _text = text; self.preferenceKey = preferenceKey; self.context = context
        _blockEditing = AppStorage(wrappedValue: false, "promptBlockEditing.\(preferenceKey)")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("提示词分块编辑", isOn: $blockEditing)
                .font(.subheadline).accessibilityIdentifier("inlinePromptBlockEditing")
                .onChange(of: blockEditing) { _, _ in inputFocused = false }
            if blockEditing {
                PromptBoardField(text: $text, storageKey: preferenceKey)
                    .id(boardRevision)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("提示词", text: $text, axis: .vertical)
                    .lineLimit(4...12)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($inputFocused)
                    .accessibilityIdentifier("inlinePromptInput")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(PocketPalette.accent.opacity(0.05), in: .rect(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PocketPalette.accent.opacity(0.15)))
            }
            HStack {
                Text("\(text.count) 字符").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    inputFocused = false
                    showEditor = true
                } label: {
                    Label("编辑模式", systemImage: "arrow.up.left.and.arrow.down.right")
                }.font(.subheadline).buttonStyle(.borderless)
                    .accessibilityIdentifier("promptVisualEditor")
            }
        }
        .fullScreenCover(isPresented: $showEditor, onDismiss: { boardRevision = UUID() }) {
            PromptStudioView(text: $text, storageKey: preferenceKey, context: context)
        }
    }
}

struct PromptStudioView: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let storageKey: String
    let context: String
    @AppStorage private var blockEditing: Bool
    @State private var original: String
    @State private var originalBoard: PromptBoardDocument
    @State private var board: PromptBoardDocument
    @State private var draft: String
    @State private var conflict = false
    @State private var discard = false
    @State private var showLibrary = false
    @State private var savedVersion = false
    @FocusState private var textFocused: Bool

    init(text: Binding<String>, storageKey: String, context: String = "") {
        _text = text; self.storageKey = storageKey; self.context = context
        _blockEditing = AppStorage(wrappedValue: false, "promptBlockEditing.\(storageKey)")
        let document = PromptBoardStorage.load(storageKey, text: text.wrappedValue)
        _board = State(initialValue: document)
        _originalBoard = State(initialValue: document)
        _original = State(initialValue: text.wrappedValue)
        _draft = State(initialValue: text.wrappedValue)
    }
    private var changed: Bool { draft != original || board != originalBoard }
    // Synchronize only when entering block mode, preserving raw spacing until a word actually changes.
    private var mode: Binding<Bool> {
        Binding(get: { blockEditing }, set: { next in
            textFocused = false
            if next { board.synchronize(draft) }
            blockEditing = next
        })
    }
    private var editableBoard: Binding<PromptBoardDocument> {
        Binding(get: { board }, set: { next in
            if next.rendered != board.rendered { draft = next.rendered }
            board = next
        })
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    if !context.isEmpty {
                        Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Toggle("词块编辑", isOn: mode)
                        .font(.subheadline.weight(.medium)).accessibilityIdentifier("promptBlockEditing")
                }.padding(.horizontal, 20).padding(.vertical, 14)
                if blockEditing {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("点按设置权重与翻译，长按拖动词块。")
                                .font(.caption).foregroundStyle(.secondary)
                            PromptChipBoard(document: editableBoard)
                            DisclosureGroup("最终提示词") {
                                Text(draft.isEmpty ? "尚未添加提示词" : draft)
                                    .font(.callout).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }.font(.subheadline).padding(16)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                        }.padding(.horizontal, 20).padding(.bottom, 20)
                    }.scrollDismissesKeyboard(.interactively)
                } else {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draft)
                            .font(.body).lineSpacing(6)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .scrollContentBackground(.hidden)
                            .focused($textFocused)
                            .padding(12)
                            .accessibilityLabel("提示词内容").accessibilityIdentifier("promptTextEditor")
                        if draft.isEmpty {
                            Text("在这里输入提示词…")
                                .foregroundStyle(.tertiary).padding(.horizontal, 17).padding(.top, 20)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.05)))
                    .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            .background(PocketBackground())
            .safeAreaInset(edge: .bottom, spacing: 0) { versionBar }
            .navigationTitle("编辑提示词").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if changed { discard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        textFocused = false
                        if text != original && changed { conflict = true }
                        else { apply() }
                    }.fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { textFocused = false }
                }
            }
            .interactiveDismissDisabled(changed)
            .confirmationDialog("放弃这次编辑？", isPresented: $discard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
            .alert("提示词已在其他位置更新", isPresented: $conflict) {
                Button("保留当前编辑", role: .destructive) { apply(overwrite: true) }
                Button("继续编辑", role: .cancel) { }
            } message: { Text("应用会覆盖期间同步收到的提示词。可先保存新版本再决定。") }
            .sheet(isPresented: $showLibrary) {
                PromptLibraryView(insert: { incoming in
                    if blockEditing {
                        var next = board; next.add(incoming, to: "uncategorized"); editableBoard.wrappedValue = next
                    } else {
                        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? incoming : draft + ", " + incoming
                    }
                }, replace: { incoming in
                    board = PromptBoardDocument(text: incoming)
                    draft = incoming
                })
            }
            .onChange(of: draft) { _, _ in savedVersion = false }
        }
    }
    private var versionBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(savedVersion ? "已保存新版本" : "\(draft.count) 字符")
                Spacer()
                Text("应用后更新工作流")
            }.font(.caption2).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { versionButtons }
                VStack(spacing: 10) { versionButtons }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
    }
    @ViewBuilder private var versionButtons: some View {
        Button { textFocused = false; showLibrary = true } label: {
            Label("保存的版本", systemImage: "text.book.closed").frame(maxWidth: .infinity)
        }.buttonStyle(.bordered)
        Button {
            if store.savePrompt(title: "", text: draft) != nil { savedVersion = true }
        } label: {
            Label("保存新版本", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
        }.buttonStyle(.bordered).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func apply(overwrite: Bool = false) {
        if text == original || overwrite {
            if !blockEditing { board.synchronize(draft) }
            text = draft
            PromptBoardStorage.save(storageKey, text: text, document: board)
        }
        dismiss()
    }
}
