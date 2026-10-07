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
    public static func remove(_ entry: RecoveryEntry, from folder: URL) throws {
        guard entry.url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
              entry.url.pathExtension == "sumipaint" else { throw PaintDocumentError.invalid("復旧ファイルの場所が不正です。") }
        let values = try entry.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PaintDocumentError.invalid("復旧ファイルを削除できません。") }
        try FileManager.default.removeItem(at: entry.url)
    }
}
