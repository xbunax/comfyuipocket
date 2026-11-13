import SwiftUI

struct PromptLibraryView: View {
    private enum EditorTarget: Identifiable {
        case create
        case edit(SavedPrompt)
        var id: String {
            switch self {
            case .create: return "new"
            case .edit(let prompt): return prompt.id
            }
        }
    }
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var insert: ((String) -> Void)? = nil
    @State private var search = ""
    @State private var editor: EditorTarget?
    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "text.book.closed").font(.largeTitle).foregroundStyle(.secondary)
                            Text(store.prompts.isEmpty ? "还没有保存的提示词。" : "没有匹配的提示词。")
                                .foregroundStyle(.secondary)
                            if store.prompts.isEmpty {
                                Text("在提示词输入框下点“保存提示词”，或点右上角新建。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
                ForEach(filtered) { prompt in
                    row(prompt)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let insert {
                                insert(prompt.text)
                                dismiss()
                            } else {
                                editor = .edit(prompt)
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { store.deletePrompt(prompt.id) }
                            Button("编辑") { editor = .edit(prompt) }.tint(.blue)
                        }
                }
            }
            .searchable(text: $search, prompt: "搜索标题或内容")
            .navigationTitle("提示词库")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("新建", systemImage: "plus") { editor = .create } }
            }
            .sheet(item: $editor) { target in
                switch target {
                case .create: PromptEditorSheet(prompt: nil)
                case .edit(let prompt): PromptEditorSheet(prompt: prompt)
                }
            }
        }
    }
    private var filtered: [SavedPrompt] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.prompts }
        return store.prompts.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query)
        }
    }
    private func row(_ prompt: SavedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt.title).font(.headline)
            Text(prompt.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if insert != nil {
                Label("点按插入", systemImage: "arrow.down.to.line.compact")
                    .font(.caption2).foregroundStyle(.mint)
            }
        }.padding(.vertical, 4)
    }
}

struct PromptEditorSheet: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let prompt: SavedPrompt?
    @State private var title = ""
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("标题（可选）", text: $title)
                Section("内容") {
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !text.isEmpty {
                    Section("预览") {
                        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(6)
                    }
                }
            }
            .navigationTitle(prompt == nil ? "新建提示词" : "编辑提示词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        _ = store.savePrompt(title: title, text: text, id: prompt?.id)
                        dismiss()
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let prompt {
                    title = prompt.title
                    text = prompt.text
                }
            }
        }
    }
}
