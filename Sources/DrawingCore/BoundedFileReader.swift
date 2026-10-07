import Foundation

public enum BoundedFileReader {
    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw PaintDocumentError.invalid("読み込み上限が不正です。") }
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var data = Data()
        while let chunk = try stream.read(upToCount: min(1024 * 1024, maximumBytes - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maximumBytes - data.count else { throw PaintDocumentError.invalid("ファイルが大きすぎます。") }
            data.append(chunk)
        }
        return data
    }
}
