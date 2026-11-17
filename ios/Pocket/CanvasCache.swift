import Foundation

struct CanvasCacheKey: Hashable {
    let server: String
    let workflowID: String
    init(baseURL: URL, workflowID: String) {
        server = baseURL.absoluteString
        self.workflowID = workflowID
    }
}

/// Only data used by the graph invalidates a live canvas. UI ordering and pins do not.
struct CanvasRevision: Equatable {
    let prompt: [String: JSONValue]
    let canvas: JSONValue?
    init(_ workflow: Workflow) { prompt = workflow.prompt; canvas = workflow.canvas }
}

enum CanvasOpenPlan: Equatable {
    case reuse, updateGraph, reloadPage
    static func resolve(sameServer: Bool, runtimeReady: Bool, available: Bool,
                        current: CanvasRevision?, incoming: CanvasRevision, force: Bool) -> Self {
        guard !force, sameServer, runtimeReady else { return .reloadPage }
        return available && current == incoming ? .reuse : .updateGraph
    }
}

/// Bounded LRU storage. An attached editor is never evicted by another acquisition
/// or a memory warning; inactive editors may be recreated from the disk library.
struct CanvasMemoryCache<Value> {
    private(set) var keys: [CanvasCacheKey] = []
    private var values: [CanvasCacheKey: Value] = [:]
    private var attached: Set<CanvasCacheKey> = []
    let capacity: Int
    var onEvict: (Value) -> Void = { _ in }

    init(capacity: Int = 2, onEvict: @escaping (Value) -> Void = { _ in }) {
        self.capacity = max(1, capacity); self.onEvict = onEvict
    }
    mutating func acquire(_ key: CanvasCacheKey, create: () -> Value) -> Value {
        let value: Value
        if let existing = values[key] { value = existing }
        else { value = create(); values[key] = value }
        keys.removeAll { $0 == key }; keys.append(key)
        trim(keeping: key)
        return value
    }
    mutating func attach(_ key: CanvasCacheKey) { attached.insert(key) }
    mutating func detach(_ key: CanvasCacheKey) { attached.remove(key); trim() }
    mutating func discardInactive(workflowID: String? = nil) {
        for key in keys where !attached.contains(key) && (workflowID == nil || key.workflowID == workflowID) { remove(key) }
    }
    private mutating func trim(keeping key: CanvasCacheKey? = nil) {
        while values.count > capacity {
            guard let victim = keys.first(where: { $0 != key && !attached.contains($0) }) else { return }
            remove(victim)
        }
    }
    private mutating func remove(_ key: CanvasCacheKey) {
        keys.removeAll { $0 == key }
        if let value = values.removeValue(forKey: key) { onEvict(value) }
    }
}
