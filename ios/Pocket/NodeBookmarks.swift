import Foundation

struct CanvasNodeLocation: Codable, Equatable, Identifiable {
    var path: [String]
    var nodeID: String
    var type: String
    var title: String
    var id: String { Self.key(path + [nodeID, type]) }
    static func key(_ parts: [String]) -> String {
        // JSON preserves boundaries even for IDs containing slashes or colons.
        (try? JSONEncoder().encode(parts).base64EncodedString()) ?? ""
    }
}

struct NodeBookmark: Codable, Equatable, Identifiable {
    let server: String
    let workflowID: String
    var location: CanvasNodeLocation
    var id: String { CanvasNodeLocation.key([server, workflowID, location.id]) }
}

struct NodeBookmarkLibrary: Codable, Equatable {
    private(set) var entries: [NodeBookmark] = []
    func bookmarks(server: String, workflowID: String) -> [NodeBookmark] {
        entries.filter { $0.server == server && $0.workflowID == workflowID }
    }
    func contains(server: String, workflowID: String, location: CanvasNodeLocation) -> Bool {
        entries.contains { $0.server == server && $0.workflowID == workflowID && $0.location.id == location.id }
    }
    mutating func toggle(server: String, workflowID: String, location: CanvasNodeLocation) {
        let bookmark = NodeBookmark(server: server, workflowID: workflowID, location: location)
        if entries.contains(where: { $0.id == bookmark.id }) { remove(bookmark.id) }
        else { entries.append(bookmark) }
    }
    mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }
    // Missing nodes remain saved so undo/reload can recover them. A reused ID
    // with a different node type never silently becomes the old favorite.
    func resolved(_ bookmark: NodeBookmark, in locations: [CanvasNodeLocation]) -> CanvasNodeLocation? {
        locations.first { $0.id == bookmark.location.id }
    }
}
