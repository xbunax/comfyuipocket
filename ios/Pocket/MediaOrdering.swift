import Foundation

enum MediaSortKey: String, CaseIterable {
    case time, name, size
    var title: String { switch self { case .time: return "时间"; case .name: return "名称"; case .size: return "大小" } }
}

enum MediaOrdering {
    static func totalSize(_ outputs: [OutputImage], sizes: [String: Int64]) -> Int64? {
        var total: Int64 = 0
        var seen = Set<String>()
        for output in outputs where seen.insert(output.assetID).inserted {
            guard let size = sizes[output.assetID], size >= 0 else { return nil }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return nil }; total = sum.partialValue
        }
        return total
    }
    static func groups(_ groups: [MediaTaskGroup], key: MediaSortKey, ascending: Bool, sizes: [String: Int64]) -> [MediaTaskGroup] {
        groups.sorted { a, b in
            switch key {
            case .time:
                if a.createdAt != b.createdAt { return ascending ? a.createdAt < b.createdAt : a.createdAt > b.createdAt }
            case .name:
                let order = a.name.localizedStandardCompare(b.name)
                if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            case .size:
                let x = totalSize(a.outputs, sizes: sizes), y = totalSize(b.outputs, sizes: sizes)
                if (x == nil) != (y == nil) { return x != nil } // Unknown stays last in either direction.
                if let x, let y, x != y { return ascending ? x < y : x > y }
            }
            return a.id < b.id
        }
    }
    static func outputs(_ outputs: [OutputImage], key: MediaSortKey, ascending: Bool, sizes: [String: Int64]) -> [OutputImage] {
        guard key != .time else { return ascending ? Array(outputs.reversed()) : outputs }
        return outputs.sorted { a, b in
            if key == .size {
                let x = sizes[a.assetID], y = sizes[b.assetID]
                if (x == nil) != (y == nil) { return x != nil }
                if let x, let y, x != y { return ascending ? x < y : x > y }
            }
            let order = a.filename.localizedStandardCompare(b.filename)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            return a.id < b.id
        }
    }
}
