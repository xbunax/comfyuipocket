import Foundation

struct OutputDirectoryPage: Codable, Equatable {
    let folder: String
    let entries: [OutputDirectoryEntry]
    let total: Int
    let nextOffset: Int?
}

struct OutputDirectoryEntry: Codable, Equatable, Identifiable {
    let name: String
    let path: String
    let kind: String
    let subfolder: String
    let size: Int64
    let modified: Int64
    var id: String { path }
    var isFolder: Bool { kind == "folder" }
    var output: OutputImage {
        OutputImage(promptID: "output-file:\(path):\(modified):\(size)", filename: name, subfolder: subfolder, type: "output")
    }
}
