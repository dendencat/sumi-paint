import Foundation

public struct RecoveryEntry: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let modified: Date
    public let bytes: Int
}

public enum RecoveryCatalog {
    public static func entries(in folder: URL) throws -> [RecoveryEntry] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            .compactMap { url in
                guard url.pathExtension == "sumipaint" else { return nil }
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return RecoveryEntry(url: url, modified: values.contentModificationDate ?? .distantPast, bytes: values.fileSize ?? 0)
            }.sorted { $0.modified > $1.modified }
    }
    /// Keep a bounded, recent set of checkpoints. Active sessions are protected.
    public static func prune(in folder: URL, maximumEntries: Int = 5,
                             maximumAge: TimeInterval = 7 * 24 * 60 * 60,
                             maximumBytes: Int = 256 * 1024 * 1024,
                             now: Date = .now, protected: Set<URL> = []) throws {
        let candidates = try entries(in: folder)
        let protectedPaths = Set(protected.map { $0.standardizedFileURL.path })
        let active = candidates.filter { protectedPaths.contains($0.url.standardizedFileURL.path) }
        var kept = active.count, bytes = active.reduce(0) { $0 + $1.bytes }
        for entry in candidates where !protectedPaths.contains(entry.url.standardizedFileURL.path) {
            let recent = now.timeIntervalSince(entry.modified) <= maximumAge
            if recent && kept < max(1, maximumEntries) && (kept == 0 || bytes + entry.bytes <= maximumBytes) {
                kept += 1; bytes += entry.bytes
            } else { try remove(entry, from: folder) }
        }
    }
    public static func remove(_ entry: RecoveryEntry, from folder: URL) throws {
        guard entry.url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
              entry.url.pathExtension == "sumipaint" else { throw PaintDocumentError.invalid("復旧ファイルの場所が不正です。") }
        let values = try entry.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PaintDocumentError.invalid("復旧ファイルを削除できません。") }
        try FileManager.default.removeItem(at: entry.url)
    }
}
