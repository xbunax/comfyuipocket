import Foundation
import CryptoKit

struct MediaCacheKey: Hashable, Sendable {
    let resource: String
    let variant: String
    static func resource(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = parts.queryItems?.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        return parts.url!.absoluteString
    }
}

actor MediaCache {
    static let shared = MediaCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PocketMedia", isDirectory: true))
    private struct Entry { var data: Data; var created: Date; var accessed: Date }
    private struct Pending { var id: UUID; var task: Task<Data, Error> }
    private var memory: [MediaCacheKey: Entry] = [:]
    private var pending: [MediaCacheKey: Pending] = [:]
    private var revisions: [String: Int] = [:]
    private var epoch = 0
    private let directory: URL
    private let memoryLimit: Int
    init(directory: URL, memoryLimit: Int = 32 * 1024 * 1024) {
        self.directory = directory.standardizedFileURL
        self.memoryLimit = memoryLimit
    }
    func data(for key: MediaCacheKey, lifetime: TimeInterval = .infinity,
              load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let now = Date()
        if var entry = memory[key], now.timeIntervalSince(entry.created) < lifetime {
            entry.accessed = now; memory[key] = entry; return entry.data
        }
        memory.removeValue(forKey: key)
        let path = file(for: key)
        if let bytes = try? Data(contentsOf: path), bytes.count >= 8 {
            let bits = bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let timestamp = Double(bitPattern: bits)
            if timestamp.isFinite && now.timeIntervalSince1970 - timestamp < lifetime && timestamp <= now.timeIntervalSince1970 {
                let value = Data(bytes.dropFirst(8))
                remember(value, key: key, created: Date(timeIntervalSince1970: timestamp))
                return value
            }
        }
        let revision = revisions[key.resource] ?? 0; let generation = epoch
        if let existing = pending[key] {
            let value = try await existing.task.value
            guard (revisions[key.resource] ?? 0) == revision, epoch == generation else { throw CancellationError() }
            return value
        }
        let id = UUID(); let task = Task { try await load() }
        pending[key] = Pending(id: id, task: task)
        do {
            let value = try await task.value
            guard pending[key]?.id == id else { throw CancellationError() }
            pending.removeValue(forKey: key)
            let created = Date()
            remember(value, key: key, created: created)
            var timestamp = created.timeIntervalSince1970.bitPattern.bigEndian
            var bytes = withUnsafeBytes(of: &timestamp) { Data($0) }; bytes.append(value)
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: path, options: .atomic)
            return value
        } catch {
            if pending[key]?.id == id { pending.removeValue(forKey: key) }
            throw error
        }
    }
    /// Store large media as files. Each caller gets its own temporary copy so
    /// a playback session can close or outlive a manual cache clear.
    func materializeFile(for key: MediaCacheKey, destination: URL,
                         load: @Sendable () async throws -> URL) async throws {
        let path = file(for: key)
        let manager = FileManager.default
        if manager.fileExists(atPath: path.path) {
            try manager.copyItem(at: path, to: destination)
            return
        }
        let generation = epoch, revision = revisions[key.resource] ?? 0
        let temporary = try await load()
        defer { try? manager.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard generation == epoch, revision == (revisions[key.resource] ?? 0) else { throw CancellationError() }
        // A concurrent request might already have populated the same revision.
        if !manager.fileExists(atPath: path.path) {
            do {
                try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: temporary, to: path)
            } catch {
                try manager.copyItem(at: temporary, to: destination)
                return
            }
        }
        try manager.copyItem(at: path, to: destination)
    }
    func invalidate(resource: String) {
        revisions[resource, default: 0] += 1
        memory = memory.filter { $0.key.resource != resource }
        for key in Array(pending.keys) where key.resource == resource {
            pending.removeValue(forKey: key)?.task.cancel()
        }
        let folder = directory.appendingPathComponent(hash(resource), isDirectory: true).standardizedFileURL
        if folder.deletingLastPathComponent() == directory { try? FileManager.default.removeItem(at: folder) }
    }
    func clear() {
        epoch += 1; revisions.removeAll()
        memory.removeAll()
        for item in pending.values { item.task.cancel() }; pending.removeAll()
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.standardizedFileURL.deletingLastPathComponent() == directory {
            try? FileManager.default.removeItem(at: folder)
        }
    }
    private func remember(_ data: Data, key: MediaCacheKey, created: Date) {
        guard data.count <= memoryLimit else { return }
        memory[key] = Entry(data: data, created: created, accessed: Date())
        var total = memory.values.reduce(0) { $0 + $1.data.count }
        for candidate in memory.keys.sorted(by: { memory[$0]!.accessed < memory[$1]!.accessed }) where total > memoryLimit {
            total -= memory.removeValue(forKey: candidate)?.data.count ?? 0
        }
    }
    private func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func file(for key: MediaCacheKey) -> URL {
        directory.appendingPathComponent(hash(key.resource), isDirectory: true).appendingPathComponent(hash(key.variant))
    }
    func diskUsage() -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var size: Int64 = 0
        for case let file as URL in files {
            if let info = try? file.resourceValues(forKeys: Set(keys)), info.isRegularFile == true { size += Int64(info.fileSize ?? 0) }
        }
        return size
    }
}
