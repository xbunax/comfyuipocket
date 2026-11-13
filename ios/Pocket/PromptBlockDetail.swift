import SwiftUI
import Translation

struct PromptBlockDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PromptBlock
    let categories: [PromptCategory]
    let save: (PromptBlock) -> Void
    let delete: () -> Void
    @State private var source = "auto"
    @State private var target = "zh-Hans"
    @State private var configuration: TranslationSession.Configuration?
    @State private var translating = false
    @State private var translated = ""
    @State private var translationError: String?
    @State private var requestText = ""
    @State private var requestID = UUID()
    @State private var confirmingDelete = false

    init(block: PromptBlock, categories: [PromptCategory], save: @escaping (PromptBlock) -> Void, delete: @escaping () -> Void) {
        _draft = State(initialValue: block); self.categories = categories
        self.save = save; self.delete = delete
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("词块内容") {
                    TextEditor(text: $draft.text).frame(minHeight: 110)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("启用这个词块", isOn: $draft.enabled)
                }
                Section {
                    Stepper(value: $draft.weight, in: 0...max(3, draft.weight), step: 0.05) {
                        LabeledContent("权重", value: PromptBlock.weightText(draft.weight))
                    }
                    Button("恢复默认权重") { draft.weight = 1 }
                } header: { Text("生成权重") } footer: {
                    Text("以 (提示词:1.20) 格式提交，实际效果取决于工作流中的文本编码节点。")
                }
                Section("所属分类") {
                    Picker("分类", selection: $draft.categoryID) {
                        ForEach(categories) { Text($0.name).tag($0.id) }
                    }
                }
                translationSection
                Section("提交预览") {
                    Text(draft.enabled ? draft.rendered : "此词块已停用，不会提交到生成任务。")
                        .font(.callout).textSelection(.enabled)
                }
                Section {
                    Button("删除词块", role: .destructive) { confirmingDelete = true }
                }
            }
            .navigationTitle("词块详细设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(draft); dismiss() }
                        .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("删除这个词块？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { delete(); dismiss() }
            }
            .translationTask(configuration) { @MainActor session in
                let id = requestID; let content = requestText
                do {
                    let response = try await session.translate(content)
                    guard id == requestID, !Task.isCancelled else { return }
                    translated = response.targetText; translating = false
                } catch {
                    guard id == requestID, !Task.isCancelled else { return }
                    translating = false
                    translationError = "翻译未完成：\(error.localizedDescription)"
                }
            }
            .onChange(of: draft.text) { _, _ in clearTranslation() }
            .onChange(of: source) { _, _ in clearTranslation() }
            .onChange(of: target) { _, _ in clearTranslation() }
            .onDisappear { requestID = UUID(); configuration = nil }
        }
    }
    private var translationSection: some View {
        Section {
            Picker("原文语言", selection: $source) {
                Text("自动识别").tag("auto")
                Text("中文").tag("zh-Hans")
                Text("英语").tag("en")
            }
            Picker("译文语言", selection: $target) {
                Text("中文").tag("zh-Hans")
                Text("英语").tag("en")
            }
            Button(action: translate) {
                HStack {
                    Label(translating ? "正在翻译…" : "翻译", systemImage: "translate")
                    if translating { Spacer(); ProgressView() }
                }
            }.disabled(translating || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source == target)
            if let translationError {
                Text(translationError).font(.caption).foregroundStyle(.orange)
            }
            if !translated.isEmpty {
                Text(translated).textSelection(.enabled)
                HStack {
                    Button("使用译文", systemImage: "arrow.up.doc") {
                        draft.text = translated
                    }
                    Spacer()
                    ShareLink(item: translated) { Label("分享译文", systemImage: "square.and.arrow.up") }
                }.font(.caption)
            }
        } header: { Text("翻译") } footer: {
            Text("使用 iOS 系统翻译，首次使用某个语言可能需要下载语言包。译文只供预览，点击“使用译文”后才替换内容；权重与分类保持不变。")
        }
    }
    private func translate() {
        requestID = UUID(); requestText = draft.text
        translating = true; translated = ""; translationError = nil
        let sourceLanguage = source == "auto" ? nil : Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
        } else {
            configuration?.source = sourceLanguage; configuration?.target = targetLanguage
            configuration?.invalidate()
        }
    }
    private func clearTranslation() {
        requestID = UUID(); configuration = nil
        translating = false; translated = ""; translationError = nil
    }
}
