import Foundation

/// Serializes recovery saves and prevents an older edit from overwriting a newer generation.
public actor RecoveryWriter {
    private var writtenRevisions: [URL: UInt64] = [:]
    public init() {}
    public func write(_ snapshot: DocumentSnapshot, revision: UInt64, to url: URL) throws {
        if let written = writtenRevisions[url] {
            if written > revision || (written == revision && FileManager.default.fileExists(atPath: url.path)) { return }
        }
        let data = try snapshot.encoded()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        writtenRevisions[url] = revision
    }
}
