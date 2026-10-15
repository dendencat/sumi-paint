import XCTest
@testable import DrawingCore

final class RecoveryTests: XCTestCase {
    func testRemovedRecoveryCanBeWrittenAgainWithoutNewEdits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("recovery.sumipaint"), properties = LayerProperties(name: "作品")
        let snapshot = DocumentSnapshot(width: 2, height: 2,
            layers: [.init(properties: properties, pixels: Data(repeating: 0, count: 16))], selectedLayerID: properties.id)
        let writer = RecoveryWriter()
        try await writer.write(snapshot, revision: 5, to: url)
        try FileManager.default.removeItem(at: url)
        try await writer.write(snapshot, revision: 5, to: url)
        XCTAssertEqual(try DocumentSnapshot.decode(Data(contentsOf: url)), snapshot)
    }
    func testContinuousEditsCannotPostponeCheckpoint() {
        var schedule = RecoverySchedule(idleDelay: 2, maximumInterval: 10)
        for i in 0...10 { schedule.noteChange(at: Double(i)); XCTAssertLessThanOrEqual(schedule.delay(at: Double(i))!, max(0, 10 - Double(i))) }
        XCTAssertEqual(schedule.delay(at: 10), 0)
        schedule.reset(); XCTAssertNil(schedule.delay(at: 11))
        schedule.noteChange(at: 12); XCTAssertEqual(schedule.delay(at: 13), 1)
    }
    func testCatalogIncludesOlderFilesAndPreventsDeletionOutsideFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for i in 0..<3 { try Data([UInt8(i)]).write(to: folder.appendingPathComponent("\(i).sumipaint")) }
        let entries = try RecoveryCatalog.entries(in: folder)
        XCTAssertEqual(entries.count, 3)
        try RecoveryCatalog.remove(entries[0], from: folder)
        XCTAssertEqual(try RecoveryCatalog.entries(in: folder).count, 2)
        let other = folder.appendingPathComponent("subfolder", isDirectory: true)
        XCTAssertThrowsError(try RecoveryCatalog.remove(entries[1], from: other))
        let target = folder.appendingPathComponent("do-not-remove")
        try Data([9]).write(to: target)
        let link = folder.appendingPathComponent("linked.sumipaint")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(try RecoveryCatalog.entries(in: folder).contains { $0.url == link })
        let forged = RecoveryEntry(url: link, modified: .now, bytes: 1)
        XCTAssertThrowsError(try RecoveryCatalog.remove(forged, from: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
    func testRetentionBoundsAgeCountBytesAndProtectsActiveFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        var urls: [URL] = []
        for index in 0..<7 {
            let url = folder.appendingPathComponent("\(index).sumipaint"); urls.append(url)
            try Data(repeating: 0, count: 10).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(index) * 86400)], ofItemAtPath: url.path)
        }
        try RecoveryCatalog.prune(in: folder, maximumEntries: 3, maximumAge: 3 * 86400,
            maximumBytes: 30, now: now, protected: [urls[6]])
        XCTAssertEqual(Set(try RecoveryCatalog.entries(in: folder).map { $0.url.standardizedFileURL }), Set([urls[0], urls[1], urls[6]].map(\.standardizedFileURL)))
        try RecoveryCatalog.prune(in: folder, maximumEntries: 5, maximumAge: 86400,
            maximumBytes: 10, now: now)
        XCTAssertEqual(try RecoveryCatalog.entries(in: folder).map { $0.url.standardizedFileURL }, [urls[0].standardizedFileURL])
    }

}
