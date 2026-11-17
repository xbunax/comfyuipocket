import Foundation

/// Layout follows the window, including iPhone Mirroring, rather than device idiom.
enum WorkspaceLayoutMode: String, CaseIterable {
    case automatic, compact, expanded
}

struct WorkspaceLayout: Equatable {
    var width: Double = 0
    var height: Double = 0
    var mode: WorkspaceLayoutMode = .automatic
    var usesColumns: Bool {
        guard width.isFinite, height.isFinite, height >= 320 else { return false }
        switch mode {
        case .automatic: return width >= 820
        case .compact: return false
        case .expanded: return width >= 680
        }
    }
    var navigationWidth: Double { min(320, max(240, width * 0.28)) }
    var showsCanvasInspector: Bool { usesColumns && width >= 960 && height >= 480 }
    var showsPromptPreview: Bool { usesColumns && width >= 960 }
}
