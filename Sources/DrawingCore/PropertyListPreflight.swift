import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Bounds the serialized object graph before Foundation constructs model or pixel copies.
enum PropertyListPreflight {
    private static let maximumObjects = 512
    private static let maximumReferences = 4096
    private static let maximumMetadataBytes = 256 * 1024
    private static let maximumStringBytes = 64 * 1024
    private static let maximumLayerBytes = DocumentSnapshot.maximumDimension * DocumentSnapshot.maximumDimension * 4

    private struct Node {
        var kind: String
        var children: [Int] = []
        var text: String = ""
        var number: Int?
        var bytes: Int = 0
    }
    private static func invalid() -> PaintDocumentError {
        .invalid("作品の構造またはデータ量が不正です。")
    }

    static func validate(_ data: Data) throws {
        let graph: [Node]
        let root: Int
        if data.prefix(7) == Data("bplist0".utf8) {
            (graph, root) = try binaryGraph(data)
        } else {
            let reader = XMLReader()
            let parser = XMLParser(stream: InputStream(data: xmlInput(data)))
            parser.shouldResolveExternalEntities = false
            parser.delegate = reader
            guard parser.parse(), !reader.failed, let index = reader.root else { throw invalid() }
            graph = reader.nodes
            root = index
        }
        var rootIndex = root
        if graph[rootIndex].kind == "plist" {
            guard graph[rootIndex].children.count == 1 else { throw invalid() }
            rootIndex = graph[rootIndex].children[0]
        }
        func dictionary(_ index: Int) throws -> [String: Int] {
            let node = graph[index]
            guard node.kind == "dict", node.children.count % 2 == 0 else { throw invalid() }
            var values: [String: Int] = [:]
            for i in stride(from: 0, to: node.children.count, by: 2) {
                let key = graph[node.children[i]]
                guard key.kind == "string" || key.kind == "key", values[key.text] == nil else { throw invalid() }
                values[key.text] = node.children[i + 1]
            }
            return values
        }
        let header = try dictionary(rootIndex)
        guard let magic = header["magic"], graph[magic].text == "SUMIPAINT",
              let version = header["version"], graph[version].number == 1,
              let widthIndex = header["width"], let width = graph[widthIndex].number,
              let heightIndex = header["height"], let height = graph[heightIndex].number,
              (1...DocumentSnapshot.maximumDimension).contains(width),
              (1...DocumentSnapshot.maximumDimension).contains(height),
              let layerIndex = header["layers"], graph[layerIndex].kind == "array",
              (1...DocumentSnapshot.maximumLayers).contains(graph[layerIndex].children.count) else { throw invalid() }
        let pixelBytes = width * height * 4
        for index in graph[layerIndex].children {
            let layer = try dictionary(index)
            guard let pixels = layer["pixels"], graph[pixels].kind == "data", graph[pixels].bytes == pixelBytes,
                  let properties = layer["properties"] else { throw invalid() }
            let values = try dictionary(properties)
            guard let name = values["name"], graph[name].text.utf8.count <= maximumStringBytes else { throw invalid() }
        }

        var visits = 0, pixelTotal = 0, metadataTotal = 0
        func visit(_ index: Int, depth: Int, ancestors: Set<Int>) throws {
            visits += 1
            guard depth <= 16, visits <= maximumReferences, !ancestors.contains(index) else { throw invalid() }
            let node = graph[index]
            if node.kind == "data" {
                guard node.bytes <= pixelBytes else { throw invalid() }
                pixelTotal += node.bytes
                guard pixelTotal <= DocumentSnapshot.maximumPixelBytes else { throw invalid() }
            }
            metadataTotal += node.text.utf8.count
            guard metadataTotal <= maximumMetadataBytes else { throw invalid() }
            if node.kind == "dict" { _ = try dictionary(index) }
            var next = ancestors; next.insert(index)
            for child in node.children { try visit(child, depth: depth + 1, ancestors: next) }
        }
        try visit(root, depth: 0, ancestors: [])
    }

    private static func binaryGraph(_ data: Data) throws -> ([Node], Int) {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard buffer.count >= 40 else { throw invalid() }
            let trailer = buffer.count - 32
            func unsigned(_ offset: Int, _ length: Int, end: Int) throws -> UInt64 {
                guard (1...8).contains(length), offset >= 0, offset <= end, length <= end - offset else { throw invalid() }
                var result: UInt64 = 0
                for i in offset..<(offset + length) { result = result << 8 | UInt64(buffer[i]) }
                return result
            }
            let offsetSize = Int(buffer[trailer + 6]), referenceSize = Int(buffer[trailer + 7])
            let objectCount = try unsigned(trailer + 8, 8, end: buffer.count)
            let root = try unsigned(trailer + 16, 8, end: buffer.count)
            let tableValue = try unsigned(trailer + 24, 8, end: buffer.count)
            guard (1...8).contains(offsetSize), (1...8).contains(referenceSize),
                  objectCount > 0, objectCount <= maximumObjects, root < objectCount,
                  tableValue >= 8, tableValue <= UInt64(trailer) else { throw invalid() }
            let count = Int(objectCount), table = Int(tableValue)
            guard count * offsetSize <= trailer - table else { throw invalid() }
            var nodes: [Node] = [], metadataBytes = 0
            for index in 0..<count {
                let offsetValue = try unsigned(table + index * offsetSize, offsetSize, end: trailer)
                guard offsetValue >= 8, offsetValue < tableValue else { throw invalid() }
                var cursor = Int(offsetValue)
                let marker = buffer[cursor]; cursor += 1
                let type = marker >> 4, low = marker & 15
                func length() throws -> Int {
                    if low != 15 { return Int(low) }
                    guard cursor < table, buffer[cursor] >> 4 == 1, buffer[cursor] & 15 <= 3 else { throw invalid() }
                    let size = 1 << Int(buffer[cursor] & 15); cursor += 1
                    let value = try unsigned(cursor, size, end: table); cursor += size
                    guard value <= UInt64(Int.max) else { throw invalid() }
                    return Int(value)
                }
                func require(_ bytes: Int) throws {
                    guard bytes >= 0, cursor <= table, bytes <= table - cursor else { throw invalid() }
                }
                func references(_ amount: Int) throws -> [Int] {
                    guard amount <= 64 else { throw invalid() }
                    try require(amount * referenceSize)
                    return try (0..<amount).map { i in
                        let value = try unsigned(cursor + i * referenceSize, referenceSize, end: table)
                        guard value < objectCount else { throw invalid() }
                        return Int(value)
                    }
                }
                var node = Node(kind: "scalar")
                switch type {
                case 0: break
                case 1:
                    guard low <= 4 else { throw invalid() }
                    let size = 1 << Int(low); try require(size)
                    if size <= 8 {
                        let value = try unsigned(cursor, size, end: table)
                        if value <= UInt64(Int.max) { node.number = Int(value) }
                    } else if try unsigned(cursor, 8, end: table) == 0 {
                        let value = try unsigned(cursor + 8, 8, end: table)
                        if value <= UInt64(Int.max) { node.number = Int(value) }
                    }
                case 2:
                    guard low == 2 || low == 3 else { throw invalid() }
                    let bits = try unsigned(cursor, 1 << Int(low), end: table)
                    let value = low == 2 ? Double(Float(bitPattern: UInt32(bits))) : Double(bitPattern: bits)
                    node.number = Int(exactly: value)
                case 3: guard low == 3 else { throw invalid() }; try require(8)
                case 4:
                    let size = try length(); guard size <= maximumLayerBytes else { throw invalid() }; try require(size)
                    node.kind = "data"; node.bytes = size
                case 5, 6, 7:
                    let size = try length()
                    guard size <= maximumStringBytes / (type == 6 ? 2 : 1) else { throw invalid() }
                    let bytes = size * (type == 6 ? 2 : 1); try require(bytes)
                    metadataBytes += bytes
                    guard metadataBytes <= maximumMetadataBytes else { throw invalid() }
                    let value = Data(buffer[cursor..<(cursor + bytes)])
                    let encoding: String.Encoding = type == 6 ? .utf16BigEndian : (type == 5 ? .ascii : .utf8)
                    guard let string = String(data: value, encoding: encoding) else { throw invalid() }
                    node.kind = "string"; node.text = string
                case 8: try require(Int(low) + 1)
                case 10, 11, 12:
                    let size = try length(); guard size <= DocumentSnapshot.maximumLayers else { throw invalid() }
                    node.kind = "array"; node.children = try references(size)
                case 13:
                    let size = try length(); guard size <= 32 else { throw invalid() }
                    let refs = try references(size * 2)
                    node.kind = "dict"
                    for i in 0..<size { node.children += [refs[i], refs[size + i]] }
                default: throw invalid()
                }
                nodes.append(node)
            }
            return (nodes, Int(root))
        }
    }

    // Foundation accepts whitespace preceding an XML declaration, unlike XMLParser.
    private static func xmlInput(_ data: Data) -> Data {
        let prefix = Array(data.prefix(3))
        let littleBOM = prefix.starts(with: [0xff, 0xfe]), bigBOM = prefix.starts(with: [0xfe, 0xff])
        let firstCharacters: [UInt8] = [9, 10, 13, 32, 60]
        let little = littleBOM || (prefix.count >= 2 && firstCharacters.contains(prefix[0]) && prefix[1] == 0)
        let big = bigBOM || (prefix.count >= 2 && prefix[0] == 0 && firstCharacters.contains(prefix[1]))
        let utf16 = little || big
        let bom = littleBOM || bigBOM ? 2 : (prefix.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0)
        let step = utf16 ? 2 : 1
        var offset = bom
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            while offset + step <= bytes.count {
                let character: UInt8
                if utf16 {
                    let zero = little ? bytes[offset + 1] : bytes[offset]
                    if zero != 0 { break }
                    character = little ? bytes[offset] : bytes[offset + 1]
                } else { character = bytes[offset] }
                if ![9, 10, 13, 32].contains(character) { break }
                offset += step
            }
        }
        guard offset != bom else { return data }
        return Data(data.prefix(bom)) + Data(data.dropFirst(offset))
    }

    private final class XMLReader: NSObject, XMLParserDelegate {
        var nodes: [Node] = []
        var root: Int?
        var failed = false
        private var stack: [Int] = []
        private var metadata = 0
        private var dataCharacters = 0, padding = 0
        private func fail(_ parser: XMLParser) { failed = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            guard ["plist", "dict", "array", "key", "string", "integer", "real", "data", "date", "true", "false"].contains(element),
                  nodes.count < maximumObjects, stack.count < 16 else { fail(parser); return }
            if let parent = stack.last {
                let kind = nodes[parent].kind
                guard ["plist", "dict", "array"].contains(kind) else { fail(parser); return }
                let maximum = kind == "dict" ? 64 : (kind == "array" ? DocumentSnapshot.maximumLayers : 1)
                guard nodes[parent].children.count < maximum else { fail(parser); return }
                nodes[parent].children.append(nodes.count)
            } else {
                guard root == nil else { fail(parser); return }
                root = nodes.count
            }
            stack.append(nodes.count); nodes.append(Node(kind: element))
            if element == "data" { dataCharacters = 0; padding = 0 }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let index = stack.last else { return }
            if nodes[index].kind == "data" {
                for byte in string.utf8 {
                    if [9, 10, 13, 32].contains(byte) { continue }
                    if byte == 61 { padding += 1; guard padding <= 2 else { fail(parser); return } }
                    else {
                        guard padding == 0, (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 43 || byte == 47 else { fail(parser); return }
                    }
                    dataCharacters += 1
                    guard dataCharacters <= ((maximumLayerBytes + 2) / 3) * 4 else { fail(parser); return }
                }
            } else if ["plist", "dict", "array", "true", "false"].contains(nodes[index].kind) {
                if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail(parser) }
            } else {
                metadata += string.utf8.count
                guard metadata <= maximumMetadataBytes, nodes[index].text.utf8.count + string.utf8.count <= maximumStringBytes else { fail(parser); return }
                nodes[index].text += string
            }
        }
        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { fail(parser); return }
            self.parser(parser, foundCharacters: text)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard let index = stack.popLast() else { fail(parser); return }
            if nodes[index].kind == "data" {
                guard dataCharacters % 4 == 0 else { fail(parser); return }
                nodes[index].bytes = dataCharacters / 4 * 3 - padding
            } else if nodes[index].kind == "integer" || nodes[index].kind == "real" {
                let text = nodes[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                nodes[index].number = Int(text) ?? Double(text).flatMap { Int(exactly: $0) }
            }
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { fail(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { fail(parser); return nil }
    }
}
