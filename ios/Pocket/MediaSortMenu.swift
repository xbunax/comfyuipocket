import SwiftUI

struct MediaSortMenu: View {
    @Binding var sortKey: String
    @Binding var ascending: Bool
    var body: some View {
        Menu {
            Picker("排序依据", selection: $sortKey) {
                ForEach(MediaSortKey.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Picker("顺序", selection: $ascending) {
                Label("升序", systemImage: "arrow.up").tag(true)
                Label("降序", systemImage: "arrow.down").tag(false)
            }
        } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
            .accessibilityLabel("按\(MediaSortKey(rawValue: sortKey)?.title ?? "时间")\(ascending ? "升序" : "降序")排序")
    }
}
