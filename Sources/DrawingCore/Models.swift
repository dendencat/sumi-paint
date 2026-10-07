import Foundation

public struct PaintPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public func distance(to other: Self) -> Double { hypot(x - other.x, y - other.y) }
    public func interpolated(to other: Self, fraction: Double) -> Self {
        .init(x + (other.x - x) * fraction, y + (other.y - y) * fraction)
    }
}

public struct PaintColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let ink = Self(0.12, 0.13, 0.17)
    public var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    public var premultipliedBytes: [UInt8] {
        [red * alpha, green * alpha, blue * alpha, alpha].map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
    }
}

public enum BrushKind: String, Codable, CaseIterable, Sendable {
    case pen, pencil, eraser
}

public struct BrushSettings: Codable, Equatable, Sendable {
    public var kind: BrushKind = .pen
    public var size: Double = 12
    public var opacity: Double = 1
    public var hardness: Double = 0.85
    public var spacing: Double = 0.15
    public var stabilization: Double = 0.25
    public var pressurePower: Double = 1
    public var minimumSize: Double = 0.12
    public var pressureOpacity: Bool = false
    public var taperWithoutPressure: Bool = false
    public init() {}
    public var isValid: Bool {
        size.isFinite && (1...512).contains(size)
        && opacity.isFinite && (0...1).contains(opacity)
        && hardness.isFinite && (0...1).contains(hardness)
        && spacing.isFinite && (0.02...1).contains(spacing)
        && stabilization.isFinite && (0...1).contains(stabilization)
        && pressurePower.isFinite && (0.25...4).contains(pressurePower)
        && minimumSize.isFinite && (0...1).contains(minimumSize)
    }
}

public enum LayerBlend: String, Codable, CaseIterable, Sendable {
    case normal, multiply, screen
    public var shaderValue: Float {
        switch self { case .normal: return 0; case .multiply: return 1; case .screen: return 2 }
    }
}

public struct LayerProperties: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var visible: Bool = true
    public var locked: Bool = false
    public var alphaLocked: Bool = false
    public var clipping: Bool = false
    public var opacity: Double = 1
    public var blend: LayerBlend = .normal
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct LayerSnapshot: Codable, Equatable, Sendable {
    public var properties: LayerProperties
    /// Top-to-bottom rows, premultiplied RGBA8, sRGB numeric components.
    public var pixels: Data
    public init(properties: LayerProperties, pixels: Data) {
        self.properties = properties; self.pixels = pixels
    }
}

public enum PaintDocumentError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return "作品を開けません: \(reason)" }
    }
}

public struct DocumentSnapshot: Codable, Equatable, Sendable {
    public static let maximumDimension = 2048
    public static let maximumLayers = 8
    public static let maximumPixelBytes = 128 * 1024 * 1024
    public static let maximumFileBytes = 160 * 1024 * 1024
    public var magic: String = "SUMIPAINT"
    public var version: Int = 1
    public var id: UUID = UUID()
    public var width: Int
    public var height: Int
    public var layers: [LayerSnapshot]
    public var selectedLayerID: UUID
    public var brush: BrushSettings = .init()
    public var color: PaintColor = .ink
    public init(width: Int, height: Int, layers: [LayerSnapshot], selectedLayerID: UUID) {
        self.width = width; self.height = height; self.layers = layers
        self.selectedLayerID = selectedLayerID
    }
    public func validate() throws {
        guard magic == "SUMIPAINT", version == 1 else {
            throw PaintDocumentError.invalid("未対応のファイル形式です。")
        }
        guard (1...Self.maximumDimension).contains(width), (1...Self.maximumDimension).contains(height) else {
            throw PaintDocumentError.invalid("キャンバスの上限は2048×2048です。")
        }
        guard (1...Self.maximumLayers).contains(layers.count) else {
            throw PaintDocumentError.invalid("レイヤー数は1〜8枚です。")
        }
        let byteCount = width * height * 4
        guard byteCount * layers.count <= Self.maximumPixelBytes else {
            throw PaintDocumentError.invalid("作品のメモリ上限を超えています。")
        }
        let ids = layers.map { $0.properties.id }
        guard Set(ids).count == ids.count, ids.contains(selectedLayerID), brush.isValid, color.isValid else {
            throw PaintDocumentError.invalid("作品の設定が破損しています。")
        }
        for layer in layers {
            let properties = layer.properties
            guard layer.pixels.count == byteCount, properties.opacity.isFinite,
                  (0...1).contains(properties.opacity), properties.name.count <= 256 else {
                throw PaintDocumentError.invalid("レイヤーのデータが破損しています。")
            }
            // Premultiplication is an invariant used by the GPU compositing equations.
            let valid = layer.pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                stride(from: 0, to: bytes.count, by: 4).allSatisfy {
                    bytes[$0] <= bytes[$0 + 3] && bytes[$0 + 1] <= bytes[$0 + 3] && bytes[$0 + 2] <= bytes[$0 + 3]
                }
            }
            guard valid else { throw PaintDocumentError.invalid("画像の透明度データが不正です。") }
        }
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileBytes else { throw PaintDocumentError.invalid("ファイルが大きすぎます。") }
        let value = try PropertyListDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
}

public struct CanvasViewport: Equatable, Sendable {
    public var viewWidth: Double = 1
    public var viewHeight: Double = 1
    public var canvasWidth: Double = 1024
    public var canvasHeight: Double = 1024
    public var pan: PaintPoint = .init(0, 0)
    public var zoom: Double = 1
    public var angle: Double = 0
    public var mirrored: Bool = false
    public init() {}
    public func documentPoint(from point: PaintPoint) -> PaintPoint {
        let x = (point.x - viewWidth / 2 - pan.x) / zoom
        let y = (point.y - viewHeight / 2 - pan.y) / zoom
        let cosine = cos(angle), sine = sin(angle)
        let rotatedX = x * cosine + y * sine
        return .init((mirrored ? -rotatedX : rotatedX) + canvasWidth / 2,
                     -x * sine + y * cosine + canvasHeight / 2)
    }
    public func viewPoint(from point: PaintPoint) -> PaintPoint {
        let x = (point.x - canvasWidth / 2) * (mirrored ? -1 : 1)
        let y = point.y - canvasHeight / 2
        return .init((x * cos(angle) - y * sin(angle)) * zoom + viewWidth / 2 + pan.x,
                     (x * sin(angle) + y * cos(angle)) * zoom + viewHeight / 2 + pan.y)
    }
    public mutating func fit() {
        zoom = max(0.01, min((viewWidth - 40) / canvasWidth, (viewHeight - 40) / canvasHeight))
        pan = .init(0, 0); angle = 0
    }
    public mutating func zoom(by factor: Double, around anchor: PaintPoint) {
        let fixed = documentPoint(from: anchor)
        zoom = min(32, max(0.02, zoom * factor))
        let moved = viewPoint(from: fixed)
        pan.x += anchor.x - moved.x; pan.y += anchor.y - moved.y
    }
}
