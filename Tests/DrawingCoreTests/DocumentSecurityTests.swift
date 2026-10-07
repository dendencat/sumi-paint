import XCTest
@testable import DrawingCore

final class DocumentSecurityTests: XCTestCase {
    private func document() -> DocumentSnapshot {
        let properties = LayerProperties(name: "線画 🎨")
        return .init(width: 2, height: 2, layers: [.init(properties: properties,
            pixels: Data(repeating: 0, count: 16))], selectedLayerID: properties.id)
    }
    private func dictionary() throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: document().encoded(), format: nil) as? [String: Any])
    }
    private func encode(_ object: [String: Any], format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
    }
    func testRejectsRepeatedLayerReferencesBeforeModelDecoding() throws {
        XCTAssertThrowsError(try DocumentSnapshot.decode(repeatedLayerReferences(64)))
        // Expand serialized references without allocating a 250,000-element model in the fixture builder.
        XCTAssertThrowsError(try DocumentSnapshot.decode(repeatedLayerReferences(250_000)))
    }
    private func repeatedLayerReferences(_ count: UInt32) throws -> Data {
        let original = try document().encoded(), trailer = original.count - 32
        func integer(_ offset: Int, _ bytes: Int) -> Int {
            original[offset..<(offset + bytes)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let offsetSize = Int(original[trailer + 6]), referenceSize = Int(original[trailer + 7])
        let objects = integer(trailer + 8, 8), table = integer(trailer + 24, 8)
        let arrays = (0..<objects).filter { original[integer(table + $0 * offsetSize, offsetSize)] == 0xa1 }
        let index = try XCTUnwrap(arrays.first); XCTAssertEqual(arrays.count, 1)
        let arrayOffset = integer(table + index * offsetSize, offsetSize)
        let reference = original[(arrayOffset + 1)..<(arrayOffset + 1 + referenceSize)]
        var result = Data(original.prefix(table)); result.append(contentsOf: [0xaf, 0x12])
        for shift in [24, 16, 8, 0] { result.append(UInt8(truncatingIfNeeded: count >> shift)) }
        for _ in 0..<count { result.append(reference) }
        let newTable = result.count
        var offsets = Data(original[table..<trailer])
        for byte in 0..<offsetSize {
            offsets[index * offsetSize + byte] = UInt8(truncatingIfNeeded: table >> ((offsetSize - byte - 1) * 8))
        }
        result.append(offsets)
        var newTrailer = Data(original.suffix(32))
        for byte in 0..<8 { newTrailer[24 + byte] = UInt8(truncatingIfNeeded: newTable >> ((7 - byte) * 8)) }
        result.append(newTrailer); return result
    }
    func testPixelLengthsAndMetadataAreCheckedBeforeCopies() throws {
        var object = try dictionary()
        var layer = try XCTUnwrap((object["layers"] as? [[String: Any]])?.first)
        layer["pixels"] = Data(repeating: 0, count: 1024 * 1024)
        object["layers"] = [layer]
        XCTAssertThrowsError(try DocumentSnapshot.decode(encode(object)))
        var excessiveMetadata = document()
        excessiveMetadata.layers[0].properties.name = "a" + String(repeating: "\u{0301}", count: 40_000)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        XCTAssertThrowsError(try DocumentSnapshot.decode(encoder.encode(excessiveMetadata)))
    }
    func testPreservesBinarySlicesAndAlternateHeader() throws {
        let original = document(), encoded = try original.encoded()
        var prefix = Data([0, 1, 2]); prefix.append(encoded)
        XCTAssertEqual(try DocumentSnapshot.decode(prefix[3...]), original)
        var alternate = encoded; alternate[7] = Character("1").asciiValue!
        XCTAssertEqual(try DocumentSnapshot.decode(alternate), original)
        var truncated = encoded; truncated.removeLast()
        XCTAssertThrowsError(try DocumentSnapshot.decode(truncated))
        var overflow = encoded
        overflow.replaceSubrange((overflow.count - 8)..<overflow.count, with: repeatElement(UInt8.max, count: 8))
        XCTAssertThrowsError(try DocumentSnapshot.decode(overflow))
    }
    func testPreservesNamesWithLongUnicodeSequences() throws {
        var original = document()
        original.layers[0].properties.name = String(repeating: "👨‍👩‍👧‍👦", count: 256)
        XCTAssertEqual(original.layers[0].properties.name.count, 256)
        XCTAssertEqual(try DocumentSnapshot.decode(original.encoded()), original)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
        XCTAssertEqual(try DocumentSnapshot.decode(encoder.encode(original)), original)
        original.layers[0].properties.name = "a" + String(repeating: "\u{0301}", count: 10_000)
        XCTAssertEqual(try DocumentSnapshot.decode(original.encoded()), original)
    }
    func testPreservesXMLUnicodeCDATAAndEncodingVariants() throws {
        let original = document()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
        let data = try encoder.encode(original)
        let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
        let utf16 = xml.replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"UTF-16\"")
        for bytes in [data, Data("\n \t".utf8) + data, Data([0xef, 0xbb, 0xbf]) + data,
                      try XCTUnwrap(utf16.data(using: .utf16))] {
            XCTAssertEqual(try DocumentSnapshot.decode(bytes), original)
        }
        let start = try XCTUnwrap(xml.range(of: "<dict>")), end = try XCTUnwrap(xml.range(of: "</dict>", options: .backwards))
        XCTAssertEqual(try DocumentSnapshot.decode(Data(xml[start.lowerBound..<end.upperBound].utf8)), original)
        let cdata = xml.replacingOccurrences(of: "<string>線画 🎨</string>", with: "<string><![CDATA[線画 🎨]]></string>")
        XCTAssertEqual(try DocumentSnapshot.decode(Data(cdata.utf8)), original)
    }
    func testRejectsXMLLayerExcessEntitiesAndUnknownGraphExcess() throws {
        var object = try dictionary()
        let layer = try XCTUnwrap((object["layers"] as? [[String: Any]])?.first)
        object["layers"] = Array(repeating: layer, count: 9)
        XCTAssertThrowsError(try DocumentSnapshot.decode(encode(object, format: .xml)))
        object = try dictionary(); object["extra"] = Array(repeating: "x", count: 9)
        XCTAssertThrowsError(try DocumentSnapshot.decode(encode(object)))
        object = try dictionary(); object["extra"] = "small extension"
        XCTAssertEqual(try DocumentSnapshot.decode(encode(object)), documentWithIDs(from: object))
        let entity = Data("<!DOCTYPE plist [<!ENTITY x 'SUMIPAINT'>]><plist><dict><key>magic</key><string>&x;</string></dict></plist>".utf8)
        XCTAssertThrowsError(try DocumentSnapshot.decode(entity))
    }
    private func documentWithIDs(from object: [String: Any]) -> DocumentSnapshot {
        // Unknown fields must not alter the recognized document fields.
        var expected = document()
        expected.id = UUID(uuidString: object["id"] as! String)!
        let layer = (object["layers"] as! [[String: Any]])[0]
        let properties = layer["properties"] as! [String: Any]
        expected.layers[0].properties.id = UUID(uuidString: properties["id"] as! String)!
        expected.selectedLayerID = expected.layers[0].properties.id
        return expected
    }
    func testMaximumCanvasAndEightLayersRemainReadable() throws {
        let pixels = Data(repeating: 0, count: 2048 * 2048 * 4)
        let layers = (0..<8).map { LayerSnapshot(properties: .init(name: "レイヤー\($0)"), pixels: pixels) }
        let snapshot = DocumentSnapshot(width: 2048, height: 2048, layers: layers, selectedLayerID: layers[0].properties.id)
        let decoded = try DocumentSnapshot.decode(snapshot.encoded())
        XCTAssertEqual(decoded.layers.map(\.properties.id), layers.map(\.properties.id))
        XCTAssertEqual(decoded.layers.count, 8)
        XCTAssertTrue(decoded.layers.allSatisfy { $0.pixels.count == pixels.count })
    }
    func testLargeXMLDataNodesRemainReadable() throws {
        let properties = LayerProperties(name: "大きな作品")
        let snapshot = DocumentSnapshot(width: 2048, height: 2048,
            layers: [.init(properties: properties, pixels: Data(repeating: 0, count: 2048 * 2048 * 4))],
            selectedLayerID: properties.id)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
        let xml = try encoder.encode(snapshot)
        XCTAssertEqual(try DocumentSnapshot.decode(xml), snapshot)
    }
    func testFileReadUsesActualByteLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("input")
        try Data(repeating: 7, count: 1025).write(to: file)
        XCTAssertThrowsError(try BoundedFileReader.read(file, maximumBytes: 1024))
        XCTAssertEqual(try BoundedFileReader.read(file, maximumBytes: 1025).count, 1025)
        XCTAssertThrowsError(try BoundedFileReader.read(file, maximumBytes: Int.max))
    }
}
