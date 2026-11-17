import SwiftUI

private struct WorkspaceLayoutKey: EnvironmentKey {
    static let defaultValue = WorkspaceLayout()
}

extension EnvironmentValues {
    var workspaceLayout: WorkspaceLayout {
        get { self[WorkspaceLayoutKey.self] }
        set { self[WorkspaceLayoutKey.self] = newValue }
    }
}

/// Re-measure each presentation: a sheet's space can differ from the main window.
private struct WorkspaceLayoutReader: ViewModifier {
    @AppStorage("workspaceLayoutMode") private var mode = "automatic"
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let layout = WorkspaceLayout(width: Double(geometry.size.width), height: Double(geometry.size.height),
                                         mode: WorkspaceLayoutMode(rawValue: mode) ?? .automatic)
            content.environment(\.workspaceLayout, layout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension View {
    func workspaceLayoutReader() -> some View { modifier(WorkspaceLayoutReader()) }
}
