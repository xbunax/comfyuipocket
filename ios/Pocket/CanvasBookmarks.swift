import SwiftUI

struct CanvasBookmarkButton: View {
    @Environment(PocketStore.self) private var store
    let session: CanvasSession
    let node: MobileCanvasNode
    private var saved: Bool {
        guard let key = session.cacheKey, let location = session.location(for: node) else { return false }
        return store.nodeBookmarks.contains(server: key.server, workflowID: key.workflowID, location: location)
    }
    var body: some View {
        Button {
            guard let key = session.cacheKey, let location = session.location(for: node) else { return }
            store.toggleNodeBookmark(location, key: key)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Image(systemName: saved ? "star.fill" : "star")
                .foregroundStyle(saved ? PocketPalette.accent : Color.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.borderless)
            .disabled(session.cacheKey == nil || session.scene.graphPath == nil)
            .accessibilityLabel("\(saved ? "取消收藏" : "收藏节点")：\(node.title)")
    }
}

struct CanvasBookmarkSheet: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: CanvasSession
    @State private var search = ""
    @State private var locating = false
    @State private var detent: PresentationDetent = .medium
    private var bookmarks: [NodeBookmark] {
        guard let key = session.cacheKey else { return [] }
        return store.nodeBookmarks.bookmarks(server: key.server, workflowID: key.workflowID)
    }
    var body: some View {
        NavigationStack {
            List {
                if let node = session.scene.nodes.first(where: { $0.id == session.focusedNodeID }) {
                    Section("当前定位节点") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(node.title).font(.subheadline.weight(.semibold))
                                Text("#\(node.id) · \(node.type)").font(.caption).foregroundStyle(PocketPalette.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            CanvasBookmarkButton(session: session, node: node)
                        }
                    }
                }
                Section {
                    if bookmarks.isEmpty {
                        Label("点星标收藏常用节点，之后点收藏项即可放大定位。", systemImage: "star")
                            .font(.subheadline).foregroundStyle(PocketPalette.secondary).padding(.vertical, 12)
                    }
                    if !bookmarks.isEmpty && bookmarks.filter(matches).isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                    ForEach(bookmarks.filter(matches)) { bookmark in
                        let resolved = store.nodeBookmarks.resolved(bookmark, in: session.scene.bookmarkNodes)
                        HStack {
                            Button {
                                guard let resolved else { return }
                                locating = true
                                Task {
                                    let focused = await session.focusBookmark(resolved)
                                    locating = false
                                    if focused { UISelectionFeedbackGenerator().selectionChanged(); dismiss() }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(resolved?.title ?? bookmark.location.title).font(.subheadline.weight(.medium)).foregroundStyle(PocketPalette.text)
                                    Text(resolved == nil ? "节点已移除或类型改变" : "#\(bookmark.location.nodeID) · \(breadcrumb(bookmark.location))")
                                        .font(.caption).foregroundStyle(PocketPalette.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(resolved == nil || locating || session.textEditing)
                            Button { store.removeNodeBookmark(bookmark) } label: {
                                Image(systemName: "star.fill").frame(width: 44, height: 44)
                            }.buttonStyle(.borderless).accessibilityLabel("取消收藏：\(bookmark.location.title)")
                        }
                        .listRowBackground(isFocused(bookmark.location) ? PocketPalette.accent.opacity(0.16) : PocketPalette.surface.opacity(0.4))
                        .swipeActions(edge: .trailing) {
                            Button("取消收藏", systemImage: "star.slash", role: .destructive) { store.removeNodeBookmark(bookmark) }
                        }
                        .accessibilityAddTraits(isFocused(bookmark.location) ? [.isSelected] : [])
                    }
                } header: { Text("本工作流收藏 · \(bookmarks.count)") }
                footer: { Text("收藏保存在本机，按服务器和工作流分别记录。点收藏项会定位原始画布中的节点。") }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
                .foregroundStyle(PocketPalette.text)
                .navigationTitle("收藏节点 · \(bookmarks.count)").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "搜索收藏名称、类型或编号")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await session.refreshScene() }
                .onChange(of: search) { _, value in if !value.isEmpty { detent = .large } }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
    }
    private func isFocused(_ location: CanvasNodeLocation) -> Bool {
        location.path == session.scene.graphPath && location.nodeID == session.focusedNodeID &&
            session.scene.nodes.contains { $0.id == location.nodeID && $0.type == location.type }
    }
    private func breadcrumb(_ location: CanvasNodeLocation) -> String {
        var parts = ["主图"]
        for (index, id) in location.path.enumerated() {
            let parent = Array(location.path.prefix(index))
            parts.append(session.scene.bookmarkNodes.first { $0.path == parent && $0.nodeID == id }?.title ?? "子图 #\(id)")
        }
        if location.path == session.scene.graphPath,
           let node = session.scene.nodes.first(where: { $0.id == location.nodeID }),
           let group = session.scene.groups.first(where: { $0.id == node.group }) { parts.append(group.title) }
        return parts.joined(separator: " / ")
    }
    private func matches(_ bookmark: NodeBookmark) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = store.nodeBookmarks.resolved(bookmark, in: session.scene.bookmarkNodes) ?? bookmark.location
        return query.isEmpty || [location.title, location.type, location.nodeID].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
