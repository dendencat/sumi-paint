import Foundation
import Combine
import MetalKit
import ImageIO
import UniformTypeIdentifiers

enum EditorTool: String, CaseIterable, Sendable {
    case pen, pencil, eraser, fill, eyedropper, rectangle, lasso, hand
    var title: String {
        switch self {
        case .pen: return "ペン"; case .pencil: return "鉛筆"; case .eraser: return "消しゴム"
        case .fill: return "塗りつぶし"; case .eyedropper: return "スポイト"
        case .rectangle: return "矩形選択"; case .lasso: return "投げ縄"; case .hand: return "移動"
        }
    }
    var icon: String {
        switch self {
        case .pen: return "paintbrush.pointed"; case .pencil: return "pencil.tip"; case .eraser: return "eraser"
        case .fill: return "drop.fill"; case .eyedropper: return "eyedropper"
        case .rectangle: return "rectangle.dashed"; case .lasso: return "lasso"; case .hand: return "hand.draw"
        }
    }
    var isBrush: Bool { self == .pen || self == .pencil || self == .eraser }
}

final class PaintLayer: Identifiable {
    var properties: LayerProperties
    let texture: MTLTexture
    var id: UUID { properties.id }
    init(properties: LayerProperties, texture: MTLTexture) { self.properties = properties; self.texture = texture }
}

struct TilePatch {
    let x: Int, y: Int, width: Int, height: Int
    let data: Data
    var key: Int { (y / 128) * 32 + x / 128 }
}
enum EditRecord {
    case pixels(UUID, [TilePatch], [TilePatch], [UInt8]?, [UInt8]?)
    case insert(PaintLayer, Int)
    case remove(PaintLayer, Int)
    case properties(UUID, LayerProperties, LayerProperties)
    case reorder([LayerProperties], [LayerProperties])
    indirect case group([EditRecord])
    var byteCost: Int {
        switch self {
        case .pixels(_, let before, let after, let a, let b):
            let beforeBytes = before.reduce(0) { $0 + $1.data.count }
            let afterBytes = after.reduce(0) { $0 + $1.data.count }
            let selectionBytes = (a?.count ?? 0) + (b?.count ?? 0)
            return beforeBytes + afterBytes + selectionBytes
        case .insert: return 1024
        case .remove(let layer, _): return layer.texture.width * layer.texture.height * 4
        case .group(let records): return records.reduce(0) { $0 + $1.byteCost }
        default: return 1024
        }
    }
}

private struct GPUDab {
    var point: SIMD2<Float>; var radius: Float; var opacity: Float
    var color: SIMD4<Float>; var hardness: Float; var seed: Float; var kind: UInt32; var padding: Float = 0
}
private struct GPUView {
    var viewSize: SIMD2<Float>; var canvasSize: SIMD2<Float>; var pan: SIMD2<Float>
    var zoom: Float; var angle: Float; var mirrored: UInt32; var selection: UInt32
    var checkerboard: UInt32; var time: Float
}

@MainActor
final class PaintEngine: ObservableObject {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let coveragePipeline: MTLRenderPipelineState
    private let strokePipeline: MTLComputePipelineState
    let viewPipeline: MTLRenderPipelineState
    private let clearPipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    @Published private(set) var layers: [PaintLayer] = []
    @Published var selectedLayerID: UUID?
    @Published var tool: EditorTool = .pen
    @Published var brush = BrushSettings()
    private var toolBrushes: [EditorTool: BrushSettings] = [:]
    private(set) var rememberedDrawingTool: EditorTool = .pen
    private(set) var rememberedDrawingBrush = BrushSettings()
    private let colorDefaults: UserDefaults
    @Published var backgroundColor = PaintColor(1, 1, 1)
    @Published private(set) var colorSet: [PaintColor] = [] { didSet { persistColors(colorSet, key: "palette.saved") } }
    @Published var color = PaintColor.ink
    @Published private(set) var recentColors: [PaintColor] = [] { didSet { persistColors(recentColors, key: "palette.recent") } }
    @Published var viewport = CanvasViewport()
    @Published var checkerboard = false
    @Published var fingerDrawing = false
    @Published var leftHanded = false
    @Published var fillTolerance = 12
    @Published var fillExpansion = 1
    @Published var errorMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasSelection = false
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var width = 1024
    @Published private(set) var height = 1024
    var documentID = UUID()
    var onCommit: (() -> Void)?
    var onContentChange: (() -> Void)?
    private(set) var contentRevision: UInt64 = 0
    private(set) var gpuFailure: String?
    private var cancellationPending = false
    var hasPendingCancellation: Bool { cancellationPending }
    #if DEBUG
    var failNextPatchAllocation = false
    var failNextGPUCompletion = false
    #endif
    var requestDisplay: (() -> Void)?
    var strokeActive: Bool { processor != nil }
    var selectedLayer: PaintLayer? { layers.first { $0.id == selectedLayerID } }
    private var processor: StrokeProcessor?
    private var strokeLayer: PaintLayer?
    private var strokeBrush = BrushSettings()
    private var strokeColor = PaintColor.ink
    private var beforeTiles: [Int: TilePatch] = [:]
    private var selectionMask: [UInt8]?
    private var selectionTexture: MTLTexture!
    private var composite: MTLTexture!
    private var scratchA: MTLTexture!
    private var scratchB: MTLTexture!
    private var groupA: MTLTexture!
    private var groupB: MTLTexture!
    private var strokeBase: MTLTexture!
    private var strokeCoverage: MTLTexture!
    private var opacityEdit: (id: UUID, before: LayerProperties)?
    private var thumbnails: [UUID: CGImage] = [:]
    private var dirty: MTLRegion?
    private var undoRecords: [EditRecord] = []
    private var redoRecords: [EditRecord] = []
    private let historyBudget = 64 * 1024 * 1024
    private var strokeSeed: Float = 0
    private var gpuWrittenTextures: [ObjectIdentifier: MTLTexture] = [:]
    private var inFlightCommandBuffers: [MTLCommandBuffer] = []

    init(defaults: UserDefaults = .standard) throws {
        colorDefaults = defaults
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "brushVertex"),
              let fragment = library.makeFunction(name: "brushFragment"),
              let quad = library.makeFunction(name: "quadVertex"),
              let display = library.makeFunction(name: "canvasFragment"),
              let clear = library.makeFunction(name: "clearRegion"),
              let compose = library.makeFunction(name: "compositeLayer"),
              let resolve = library.makeFunction(name: "resolveStroke") else {
            throw PaintDocumentError.invalid("Metal描画機能を初期化できません。")
        }
        self.device = device; self.queue = queue
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = vertex; description.fragmentFunction = fragment
        let attachment = description.colorAttachments[0]!
        attachment.pixelFormat = .rgba8Unorm; attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .max; attachment.alphaBlendOperation = .max
        coveragePipeline = try device.makeRenderPipelineState(descriptor: description)
        strokePipeline = try device.makeComputePipelineState(function: resolve)
        let viewDescription = MTLRenderPipelineDescriptor()
        viewDescription.vertexFunction = quad; viewDescription.fragmentFunction = display
        viewDescription.colorAttachments[0].pixelFormat = .bgra8Unorm
        viewPipeline = try device.makeRenderPipelineState(descriptor: viewDescription)
        clearPipeline = try device.makeComputePipelineState(function: clear)
        compositePipeline = try device.makeComputePipelineState(function: compose)
        for key in ["palette.recent", "palette.saved"] {
            if let data = defaults.data(forKey: key), let colors = try? JSONDecoder().decode([PaintColor].self, from: data) {
                let valid = colors.filter(\.isValid)
                if key == "palette.recent" { recentColors = Array(valid.prefix(8)) }
                else { colorSet = Array(valid.prefix(64)) }
            }
        }
        try newDocument(width: 1024, height: 1024)
    }

    private func makeTexture(format: MTLPixelFormat = .rgba8Unorm) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        #if os(macOS)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        descriptor.usage = format == .r8Unorm ? [.shaderRead] : [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PaintDocumentError.invalid("画像用のメモリが不足しています。")
        }
        return texture
    }
    private func transparentTexture() throws -> MTLTexture {
        let texture = try makeTexture()
        let data = Data(repeating: 0, count: width * height * 4)
        replace(texture, data: data)
        return texture
    }
    private func allocateWorkingTextures() throws {
        let nextComposite = try transparentTexture(), nextA = try makeTexture(), nextB = try makeTexture()
        let nextGroupA = try makeTexture(), nextGroupB = try makeTexture()
        let nextStrokeBase = try makeTexture(), nextStrokeCoverage = try makeTexture()
        let nextSelection = try makeTexture(format: .r8Unorm)
        let empty = [UInt8](repeating: 0, count: width * height)
        empty.withUnsafeBytes { nextSelection.replace(region: fullRegion, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width) }
        composite = nextComposite; scratchA = nextA; scratchB = nextB; groupA = nextGroupA; groupB = nextGroupB; selectionTexture = nextSelection
        strokeBase = nextStrokeBase; strokeCoverage = nextStrokeCoverage
    }
    private var fullRegion: MTLRegion { MTLRegionMake2D(0, 0, width, height) }
    private func checkCompletion(_ command: MTLCommandBuffer) {
        if command.status == .error {
            failGPU("GPU処理が失敗しました: \(command.error?.localizedDescription ?? "不明なエラー")")
        }
    }
    private func failGPU(_ message: String) {
        if gpuFailure == nil {
            gpuFailure = message; dirty = fullRegion
            errorMessage = message + " 最新の保存を確認してアプリを再起動してください。"
        }
    }
    @discardableResult
    private func submit(_ command: MTLCommandBuffer) -> Bool {
        for previous in inFlightCommandBuffers where previous.status == .completed || previous.status == .error {
            checkCompletion(previous)
        }
        guard gpuFailure == nil else { return false }
        command.commit()
        inFlightCommandBuffers.removeAll { $0.status == .completed || $0.status == .error }
        inFlightCommandBuffers.append(command)
        return true
    }
    @discardableResult
    private func waitForGPU() -> Bool {
        // An empty command buffer is not a fence for actual drawing work.
        // Wait for the commands that used the textures before reading or restoring them.
        for command in inFlightCommandBuffers { command.waitUntilCompleted(); checkCompletion(command) }
        inFlightCommandBuffers.removeAll()
        #if DEBUG
        if failNextGPUCompletion { failNextGPUCompletion = false; failGPU("検証用GPU実行エラー") }
        #endif
        guard gpuFailure == nil else { return false }
        #if os(macOS)
        // Synchronizing a CPU-edited managed texture before a GPU read can overwrite
        // the restored pixels with the old GPU copy. Only synchronize actual GPU writes.
        let resources = Array(gpuWrittenTextures.values)
        if resources.contains(where: { $0.storageMode == .managed }) {
            guard let barrier = queue.makeCommandBuffer(), let blit = barrier.makeBlitCommandEncoder() else {
                failGPU("GPUと保存画像を同期できません。"); return false
            }
            for texture in resources where texture.storageMode == .managed { blit.synchronize(resource: texture) }
            blit.endEncoding()
            barrier.commit(); barrier.waitUntilCompleted()
            checkCompletion(barrier)
        }
        #endif
        gpuWrittenTextures.removeAll()
        return gpuFailure == nil
    }
    private func read(_ texture: MTLTexture, region: MTLRegion? = nil) -> Data {
        let region = region ?? fullRegion
        var data = Data(count: region.size.width * region.size.height * 4)
        data.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: region.size.width * 4, from: region, mipmapLevel: 0) }
        return data
    }
    private func replace(_ texture: MTLTexture, data: Data, region: MTLRegion? = nil) {
        let region = region ?? fullRegion
        data.withUnsafeBytes { texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: region.size.width * 4) }
        gpuWrittenTextures.removeValue(forKey: ObjectIdentifier(texture))
    }

    func newDocument(width: Int, height: Int) throws {
        finishLayerOpacityEdit()
        guard !strokeActive, !isBusy, (64...2048).contains(width), (64...2048).contains(height) else {
            throw PaintDocumentError.invalid("サイズは64〜2048ピクセルにしてください。")
        }
        guard waitForGPU() else { throw PaintDocumentError.invalid(gpuFailure!) }
        // Allocate in a temporary engine state; loading uses the same rollback-safe path.
        let previousWidth = self.width, previousHeight = self.height
        self.width = width; self.height = height
        do {
            let layer = PaintLayer(properties: .init(name: "レイヤー1"), texture: try transparentTexture())
            try allocateWorkingTextures()
            layers = [layer]; selectedLayerID = layer.id
        } catch { self.width = previousWidth; self.height = previousHeight; throw error }
        documentID = UUID(); resetEditingState(); commit()
    }
    private func resetEditingState() {
        cancellationPending = false
        undoRecords = []; redoRecords = []; canUndo = false; canRedo = false
        selectionMask = nil; hasSelection = false; processor = nil; strokeLayer = nil; beforeTiles = [:]
        viewport.canvasWidth = Double(width); viewport.canvasHeight = Double(height); viewport.fit()
        markDirty(fullRegion)
    }
    func snapshot() throws -> DocumentSnapshot {
        guard waitForGPU() else { throw PaintDocumentError.invalid(gpuFailure!) }
        var document = DocumentSnapshot(width: width, height: height,
            layers: layers.map { .init(properties: $0.properties, pixels: read($0.texture)) },
            selectedLayerID: selectedLayerID ?? layers[0].id)
        document.id = documentID; document.brush = brush; document.color = color
        return document
    }
    func load(_ snapshot: DocumentSnapshot) throws {
        finishLayerOpacityEdit()
        guard !strokeActive, !isBusy else { return }
        try snapshot.validate()
        guard waitForGPU() else { throw PaintDocumentError.invalid(gpuFailure!) }
        let oldWidth = width, oldHeight = height
        width = snapshot.width; height = snapshot.height
        do {
            let imported = try snapshot.layers.map { stored -> PaintLayer in
                let texture = try makeTexture(); replace(texture, data: stored.pixels)
                return PaintLayer(properties: stored.properties, texture: texture)
            }
            try allocateWorkingTextures()
            layers = imported
            layers.first?.properties.clipping = false
        } catch { width = oldWidth; height = oldHeight; throw error }
        selectedLayerID = snapshot.selectedLayerID; documentID = snapshot.id
        brush = snapshot.brush; color = snapshot.color
        tool = brush.kind == .eraser ? .eraser : (brush.kind == .pencil ? .pencil : .pen)
        toolBrushes = [tool: brush]
        rememberedDrawingTool = tool == .pencil ? .pencil : .pen
        rememberedDrawingBrush = brush
        rememberedDrawingBrush.kind = rememberedDrawingTool == .pencil ? .pencil : .pen
        resetEditingState(); commit()
    }

    func setTool(_ value: EditorTool) {
        guard !strokeActive, tool != value else { return }
        if tool.isBrush { toolBrushes[tool] = brush }
        if tool == .pen || tool == .pencil {
            rememberedDrawingTool = tool; rememberedDrawingBrush = brush
        }
        tool = value
        if value.isBrush {
            var initial = BrushSettings()
            initial.kind = value == .eraser ? .eraser : (value == .pencil ? .pencil : .pen)
            initial.hardness = value == .pencil ? 0.6 : 0.85
            brush = toolBrushes[value] ?? initial
        }
    }
    func setColor(_ value: PaintColor) {
        guard [value.red, value.green, value.blue, value.alpha].allSatisfy(\.isFinite) else { return }
        let clamped = PaintColor(min(1, max(0, value.red)), min(1, max(0, value.green)), min(1, max(0, value.blue)), min(1, max(0, value.alpha)))
        color = clamped
    }
    private func persistColors(_ colors: [PaintColor], key: String) {
        if let data = try? JSONEncoder().encode(colors) { colorDefaults.set(data, forKey: key) }
    }
    func rememberColor(_ value: PaintColor? = nil) {
        let used = value ?? color
        guard used.isValid else { return }
        recentColors.removeAll { $0.hex == used.hex }; recentColors.insert(used, at: 0)
        recentColors = Array(recentColors.prefix(8))
    }
    func saveColor(_ value: PaintColor? = nil) {
        let saved = value ?? color
        guard saved.isValid, !colorSet.contains(where: { $0.hex == saved.hex }), colorSet.count < 64 else { return }
        colorSet.append(saved)
    }
    func removeSavedColor(_ value: PaintColor) { colorSet.removeAll { $0 == value } }
    func swapColors() {
        guard !strokeActive, !isBusy else { return }
        let previous = color; setColor(backgroundColor); backgroundColor = previous
    }
    func beginStroke(_ sample: StrokeSample) {
        finishLayerOpacityEdit()
        guard gpuFailure == nil, !isBusy, !strokeActive, tool.isBrush, let layer = editableLayer() else { return }
        if tool == .eraser && layer.properties.alphaLocked { return }
        // Keep the original pixels immutable for this stroke. Coverage accumulates
        // by maximum, and every preview resolves once against these original pixels.
        guard let command = queue.makeCommandBuffer(), let copy = command.makeBlitCommandEncoder() else { return }
        copy.copy(from: layer.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: fullRegion.origin,
                  sourceSize: fullRegion.size, to: strokeBase, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: fullRegion.origin)
        copy.endEncoding()
        guard let clear = command.makeComputeCommandEncoder() else { return }
        var origin = SIMD2<UInt32>(0, 0)
        clear.setComputePipelineState(clearPipeline); clear.setTexture(strokeCoverage, index: 0)
        clear.setBytes(&origin, length: 8, index: 0)
        dispatch(clear, pipeline: clearPipeline, region: fullRegion); clear.endEncoding()
        guard submit(command) else { return }
        strokeBrush = brush; strokeColor = color; strokeLayer = layer; beforeTiles = [:]
        strokeSeed = Float.random(in: 0...10000)
        processor = StrokeProcessor(settings: strokeBrush)
        if let values = processor?.append(sample) { drawDabs(values, layer: layer) }
    }
    func appendStroke(_ sample: StrokeSample) {
        guard gpuFailure == nil, !cancellationPending, let layer = strokeLayer, let values = processor?.append(sample) else { return }
        drawDabs(values, layer: layer)
    }
    func endStroke(cancelled: Bool = false) {
        guard let layer = strokeLayer else { return }
        let shouldCancel = cancelled || cancellationPending
        if !shouldCancel, let tail = processor?.finish() { drawDabs(tail, layer: layer) }
        guard waitForGPU() else { processor = nil; strokeLayer = nil; return }
        let before = beforeTiles.values.sorted { $0.key < $1.key }
        if shouldCancel {
            guard applyPatches(before, to: layer) else { cancellationPending = true; return }
            markDirty(fullRegion)
        } else if !before.isEmpty {
            let after = before.map { tile in patch(layer.texture, x: tile.x, y: tile.y, width: tile.width, height: tile.height) }
            record(.pixels(layer.id, before, after, nil, nil)); if strokeBrush.kind != .eraser { rememberColor(strokeColor) }; commit()
        }
        cancellationPending = false
        processor = nil; strokeLayer = nil; beforeTiles = [:]; requestDisplay?()
    }
    func retryPendingCancellation() { if cancellationPending { endStroke(cancelled: true) } }
    private func editableLayer() -> PaintLayer? {
        guard gpuFailure == nil else { return nil }
        guard let layer = selectedLayer else { return nil }
        if layer.properties.locked || !layer.properties.visible {
            errorMessage = "描画するにはレイヤーを表示し、ロックを解除してください。"; return nil
        }
        return layer
    }
    private func patch(_ texture: MTLTexture, x: Int, y: Int, width: Int, height: Int) -> TilePatch {
        .init(x: x, y: y, width: width, height: height, data: read(texture, region: MTLRegionMake2D(x, y, width, height)))
    }
    private func captureTiles(for bounds: MTLRegion, layer: PaintLayer) {
        var missing: [(Int, Int)] = []
        let maxX = bounds.origin.x + bounds.size.width - 1, maxY = bounds.origin.y + bounds.size.height - 1
        for y in stride(from: bounds.origin.y / 128 * 128, through: maxY, by: 128) {
            for x in stride(from: bounds.origin.x / 128 * 128, through: maxX, by: 128) {
                if beforeTiles[(y / 128) * 32 + x / 128] == nil { missing.append((x, y)) }
            }
        }
        guard !missing.isEmpty else { return }
        guard waitForGPU() else { return }
        for (x, y) in missing {
            let tile = patch(layer.texture, x: x, y: y, width: min(128, width - x), height: min(128, height - y))
            beforeTiles[tile.key] = tile
        }
    }
    private func drawDabs(_ values: [BrushDab], layer: PaintLayer) {
        guard !values.isEmpty else { return }
        let lowX = max(0, Int(floor(values.map { $0.point.x - $0.radius }.min()!)))
        let lowY = max(0, Int(floor(values.map { $0.point.y - $0.radius }.min()!)))
        let highX = min(width, Int(ceil(values.map { $0.point.x + $0.radius }.max()!)))
        let highY = min(height, Int(ceil(values.map { $0.point.y + $0.radius }.max()!)))
        guard lowX < highX, lowY < highY else { return }
        let bounds = MTLRegionMake2D(lowX, lowY, highX - lowX, highY - lowY)
        captureTiles(for: bounds, layer: layer)
        guard gpuFailure == nil else { return }
        let dabs = values.map { value in
            GPUDab(point: .init(Float(value.point.x), Float(value.point.y)), radius: Float(value.radius),
                opacity: Float(value.opacity), color: .init(Float(strokeColor.red), Float(strokeColor.green), Float(strokeColor.blue), Float(strokeColor.alpha)),
                hardness: Float(strokeBrush.hardness), seed: strokeSeed,
                kind: strokeBrush.kind == .pencil ? 1 : 0)
        }
        guard let buffer = device.makeBuffer(bytes: dabs, length: dabs.count * MemoryLayout<GPUDab>.stride),
              let command = queue.makeCommandBuffer() else { errorMessage = "描画用のメモリが不足しています。"; return }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = strokeCoverage
        pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(coveragePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var size = SIMD2<Float>(Float(width), Float(height)), selected: UInt32 = hasSelection ? 1 : 0
        encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&selected, length: 4, index: 0); encoder.setFragmentTexture(selectionTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: dabs.count)
        encoder.endEncoding()
        guard let resolve = command.makeComputeCommandEncoder() else { return }
        var origin = SIMD2<UInt32>(UInt32(bounds.origin.x), UInt32(bounds.origin.y))
        var mode = SIMD2<UInt32>(strokeBrush.kind == .eraser ? 1 : 0, layer.properties.alphaLocked ? 1 : 0)
        resolve.setComputePipelineState(strokePipeline)
        resolve.setTexture(strokeBase, index: 0); resolve.setTexture(strokeCoverage, index: 1)
        resolve.setTexture(layer.texture, index: 2)
        resolve.setBytes(&origin, length: 8, index: 0); resolve.setBytes(&mode, length: 8, index: 1)
        dispatch(resolve, pipeline: strokePipeline, region: bounds); resolve.endEncoding()
        guard submit(command) else { return }
        gpuWrittenTextures[ObjectIdentifier(layer.texture)] = layer.texture
        markDirty(bounds)
    }

    private func markDirty(_ region: MTLRegion) {
        if let previous = dirty {
            let x = min(previous.origin.x, region.origin.x), y = min(previous.origin.y, region.origin.y)
            let right = max(previous.origin.x + previous.size.width, region.origin.x + region.size.width)
            let bottom = max(previous.origin.y + previous.size.height, region.origin.y + region.size.height)
            dirty = MTLRegionMake2D(x, y, right - x, bottom - y)
        } else { dirty = region }
        contentRevision &+= 1; onContentChange?(); requestDisplay?()
    }
    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, region: MTLRegion) {
        encoder.dispatchThreads(.init(width: region.size.width, height: region.size.height, depth: 1),
            threadsPerThreadgroup: .init(width: 8, height: 8, depth: 1))
    }
    func updateComposite() {
        guard gpuFailure == nil, let region = dirty, let command = queue.makeCommandBuffer() else { return }
        var origin = SIMD2<UInt32>(UInt32(region.origin.x), UInt32(region.origin.y))
        guard let clear = command.makeComputeCommandEncoder() else { return }
        clear.setComputePipelineState(clearPipeline); clear.setTexture(scratchA, index: 0)
        clear.setBytes(&origin, length: 8, index: 0); dispatch(clear, pipeline: clearPipeline, region: region); clear.endEncoding()
        var destination = scratchA!, output = scratchB!
        func compose(_ source: MTLTexture, into target: MTLTexture, output: MTLTexture,
                     opacity: Double, blend: LayerBlend, preserveAlpha: Bool = false) -> Bool {
            guard let encoder = command.makeComputeCommandEncoder() else { return false }
            var settings = SIMD4<Float>(Float(opacity), blend.shaderValue, preserveAlpha ? 1 : 0, 0)
            encoder.setComputePipelineState(compositePipeline)
            encoder.setTexture(target, index: 0); encoder.setTexture(source, index: 1)
            encoder.setTexture(source, index: 2); encoder.setTexture(output, index: 3)
            encoder.setBytes(&settings, length: 16, index: 0); encoder.setBytes(&origin, length: 8, index: 1)
            dispatch(encoder, pipeline: compositePipeline, region: region); encoder.endEncoding()
            return true
        }
        var index = 0
        while index < layers.count {
            let base = layers[index]
            var end = index + 1
            while end < layers.count && layers[end].properties.clipping { end += 1 }
            defer { index = end }
            guard base.properties.visible else { continue }
            var source = base.texture
            if end > index + 1 {
                // Compose the clipping group with the base's pixel alpha preserved.
                // Apply the base layer opacity and blend exactly once, to the group.
                var group = groupA!, nextGroup = groupB!
                guard let copy = command.makeBlitCommandEncoder() else { return }
                copy.copy(from: base.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin,
                          sourceSize: region.size, to: group, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: region.origin)
                copy.endEncoding()
                for clip in layers[(index + 1)..<end] where clip.properties.visible {
                    guard compose(clip.texture, into: group, output: nextGroup,
                                  opacity: clip.properties.opacity, blend: clip.properties.blend,
                                  preserveAlpha: true) else { return }
                    swap(&group, &nextGroup)
                }
                source = group
            }
            guard compose(source, into: destination, output: output,
                          opacity: base.properties.opacity, blend: base.properties.blend) else { return }
            swap(&destination, &output)
        }
        guard let blit = command.makeBlitCommandEncoder() else { return }
        blit.copy(from: destination, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size,
                  to: composite, destinationSlice: 0, destinationLevel: 0, destinationOrigin: region.origin)
        blit.endEncoding()
        guard submit(command) else { return }
        gpuWrittenTextures[ObjectIdentifier(composite)] = composite
        dirty = nil
    }
    func render(in view: MTKView) {
        guard gpuFailure == nil else { return }
        updateComposite()
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var settings = GPUView(viewSize: .init(Float(viewport.viewWidth), Float(viewport.viewHeight)),
            canvasSize: .init(Float(width), Float(height)), pan: .init(Float(viewport.pan.x), Float(viewport.pan.y)),
            zoom: Float(viewport.zoom), angle: Float(viewport.angle), mirrored: viewport.mirrored ? 1 : 0,
            selection: hasSelection ? 1 : 0, checkerboard: checkerboard ? 1 : 0, time: Float(Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)))
        encoder.setRenderPipelineState(viewPipeline)
        encoder.setFragmentTexture(composite, index: 0); encoder.setFragmentTexture(selectionTexture, index: 1)
        encoder.setFragmentBytes(&settings, length: MemoryLayout<GPUView>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); command.present(drawable); submit(command)
    }

    private func commit() { thumbnails.removeAll(); revision &+= 1; onCommit?(); requestDisplay?() }
    private func record(_ value: EditRecord) {
        redoRecords.removeAll(); undoRecords.append(value)
        while undoRecords.reduce(0, { $0 + $1.byteCost }) > historyBudget || undoRecords.count > 100 { undoRecords.removeFirst() }
        canUndo = !undoRecords.isEmpty; canRedo = false
    }
    private func applyPatches(_ patches: [TilePatch], to layer: PaintLayer) -> Bool {
        guard gpuFailure == nil else { return false }
        guard !patches.isEmpty else { return true }
        #if DEBUG
        if failNextPatchAllocation {
            failNextPatchAllocation = false; errorMessage = "検証用の画像復元メモリ不足"; return false
        }
        #endif
        // Restore through the same GPU queue as painting. CPU replace calls on a
        // recently rendered shared texture can race with the driver's optimized copy.
        var uploads: [(TilePatch, MTLBuffer, Int)] = []
        for tile in patches {
            let rowBytes = (tile.width * 4 + 255) / 256 * 256
            guard let buffer = device.makeBuffer(length: rowBytes * tile.height, options: .storageModeShared) else {
                errorMessage = "画像を復元するメモリが不足しています。"; return false
            }
            tile.data.withUnsafeBytes { bytes in
                for row in 0..<tile.height {
                    buffer.contents().advanced(by: row * rowBytes).copyMemory(
                        from: bytes.baseAddress!.advanced(by: row * tile.width * 4), byteCount: tile.width * 4)
                }
            }
            uploads.append((tile, buffer, rowBytes))
        }
        guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
            errorMessage = "画像を復元できません。"; return false
        }
        for (tile, buffer, rowBytes) in uploads {
            blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * tile.height,
                sourceSize: .init(width: tile.width, height: tile.height, depth: 1),
                to: layer.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: tile.x, y: tile.y, z: 0))
        }
        blit.endEncoding()
        guard submit(command) else { return false }
        gpuWrittenTextures[ObjectIdentifier(layer.texture)] = layer.texture
        return waitForGPU()
    }
    private func apply(_ record: EditRecord, forward: Bool) -> Bool {
        switch record {
        case .pixels(let id, let before, let after, let oldMask, let newMask):
            guard let layer = layers.first(where: { $0.id == id }),
                  applyPatches(forward ? after : before, to: layer) else { return false }
            if oldMask != nil || newMask != nil { setSelectionMask(forward ? newMask : oldMask) }
            selectedLayerID = id
        case .insert(let layer, let index):
            if forward { layers.insert(layer, at: min(index, layers.count)); selectedLayerID = layer.id }
            else { layers.removeAll { $0.id == layer.id } }
        case .remove(let layer, let index):
            if forward { layers.removeAll { $0.id == layer.id } }
            else { layers.insert(layer, at: min(index, layers.count)); selectedLayerID = layer.id }
        case .properties(let id, let before, let after):
            layers.first { $0.id == id }?.properties = forward ? after : before
        case .reorder(let before, let after):
            let properties = forward ? after : before
            layers = properties.compactMap { item in
                guard let layer = layers.first(where: { $0.id == item.id }) else { return nil }
                layer.properties = item; return layer
            }
        case .group(let records):
            for item in (forward ? records : Array(records.reversed())) {
                guard apply(item, forward: forward) else { return false }
            }
        }
        if !layers.contains(where: { $0.id == selectedLayerID }) { selectedLayerID = layers.last?.id }
        objectWillChange.send(); markDirty(fullRegion); commit()
        return true
    }
    func undo() {
        finishLayerOpacityEdit()
        guard !strokeActive, !isBusy, let record = undoRecords.last,
              waitForGPU(), apply(record, forward: false) else { return }
        undoRecords.removeLast(); redoRecords.append(record)
        canUndo = !undoRecords.isEmpty; canRedo = true
    }
    func redo() {
        finishLayerOpacityEdit()
        guard !strokeActive, !isBusy, let record = redoRecords.last,
              waitForGPU(), apply(record, forward: true) else { return }
        redoRecords.removeLast(); undoRecords.append(record)
        canUndo = true; canRedo = !redoRecords.isEmpty
    }
    func addLayer(duplicate: Bool = false) {
        finishLayerOpacityEdit()
        guard !strokeActive, !isBusy else { return }
        guard layers.count < DocumentSnapshot.maximumLayers else { errorMessage = "初期版のレイヤー上限は8枚です。"; return }
        do {
            guard waitForGPU() else { return }
            let texture = try transparentTexture()
            var number = 1
            while layers.contains(where: { $0.properties.name == "レイヤー\(number)" }) { number += 1 }
            var properties = LayerProperties(name: "レイヤー\(number)")
            if duplicate, let selected = selectedLayer {
                replace(texture, data: read(selected.texture)); properties = selected.properties
                properties.id = UUID(); properties.name = String((properties.name + " コピー").prefix(256))
            }
            let layer = PaintLayer(properties: properties, texture: texture)
            let index = (layers.firstIndex { $0.id == selectedLayerID }).map { $0 + 1 } ?? layers.count
            if index < layers.count && layers[index].properties.clipping { layer.properties.clipping = true }
            layers.insert(layer, at: index); selectedLayerID = layer.id
            record(.insert(layer, index)); markDirty(fullRegion); commit()
        } catch { errorMessage = error.localizedDescription }
    }
    func deleteLayer() {
        finishLayerOpacityEdit()
        guard gpuFailure == nil, !strokeActive, !isBusy, layers.count > 1, let index = layers.firstIndex(where: { $0.id == selectedLayerID }) else { return }
        let removed = layers.remove(at: index); selectedLayerID = layers[min(index, layers.count - 1)].id
        var records: [EditRecord] = [.remove(removed, index)]
        if let first = layers.first, first.properties.clipping {
            let before = first.properties; first.properties.clipping = false
            records.append(.properties(first.id, before, first.properties))
        }
        record(.group(records)); markDirty(fullRegion); commit()
    }
    func moveLayer(_ direction: Int) {
        guard let index = layers.firstIndex(where: { $0.id == selectedLayerID }),
              layers.indices.contains(index + direction) else { return }
        reorderLayer(layers[index].id, to: index + direction)
    }
    func reorderLayer(_ id: UUID, to index: Int) {
        guard gpuFailure == nil, !strokeActive, !isBusy, layers.indices.contains(index),
              let old = layers.firstIndex(where: { $0.id == id }), old != index else { return }
        finishLayerOpacityEdit()
        let before = layers.map(\.properties)
        let layer = layers.remove(at: old); layers.insert(layer, at: index)
        layers.first?.properties.clipping = false
        record(.reorder(before, layers.map(\.properties))); markDirty(fullRegion); commit()
    }
    func previewLayerOpacity(_ id: UUID, value: Double) {
        guard gpuFailure == nil, !strokeActive, !isBusy, value.isFinite,
              let layer = layers.first(where: { $0.id == id }) else { return }
        if opacityEdit?.id != id { finishLayerOpacityEdit(); opacityEdit = (id, layer.properties) }
        objectWillChange.send(); layer.properties.opacity = min(1, max(0, value))
        markDirty(fullRegion)
    }
    func finishLayerOpacityEdit() {
        guard let edit = opacityEdit else { return }
        opacityEdit = nil
        guard let layer = layers.first(where: { $0.id == edit.id }), edit.before != layer.properties else { return }
        record(.properties(edit.id, edit.before, layer.properties)); commit()
    }
    func thumbnail(for layer: PaintLayer) -> CGImage? {
        if let cached = thumbnails[layer.id] { return cached }
        guard !strokeActive, waitForGPU() else { return nil }
        let data = read(layer.texture)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 320,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(80.0 / Double(width), 80.0 / Double(height))
        let w = Double(width) * scale, h = Double(height) * scale
        context.draw(image, in: CGRect(x: (80-w)/2, y: (80-h)/2, width: w, height: h))
        let result = context.makeImage(); thumbnails[layer.id] = result; return result
    }
    func changeLayer(_ id: UUID, _ change: (inout LayerProperties) -> Void) {
        guard gpuFailure == nil, !strokeActive, !isBusy, let layer = layers.first(where: { $0.id == id }) else { return }
        finishLayerOpacityEdit()
        let before = layer.properties; var after = before; change(&after)
        if layers.first?.id == id { after.clipping = false }
        guard after.name.utf8.count <= 64 * 1024, after.opacity.isFinite, (0...1).contains(after.opacity) else {
            errorMessage = "レイヤーの設定または名前が不正です。"; return
        }
        after.name = String(after.name.prefix(256))
        guard before != after else { return }
        layer.properties = after; record(.properties(id, before, after)); objectWillChange.send()
        markDirty(fullRegion); commit()
    }

    private func setSelectionMask(_ mask: [UInt8]?) {
        guard waitForGPU() else { return }
        let normalized = mask?.contains(where: { $0 != 0 }) == true ? mask : nil
        selectionMask = normalized; hasSelection = normalized != nil
        let values = normalized ?? [UInt8](repeating: 0, count: width * height)
        values.withUnsafeBytes { selectionTexture.replace(region: fullRegion, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width) }
        requestDisplay?()
    }
    func select(polygon: [PaintPoint]) {
        guard !isBusy, !strokeActive else { return }
        setSelectionMask(RasterOperations.selection(width: width, height: height, polygon: polygon))
    }
    func clearSelection() { guard !strokeActive, !isBusy else { return }; setSelectionMask(nil) }
    func selectAll() { guard !strokeActive, !isBusy else { return }; setSelectionMask([UInt8](repeating: 255, count: width * height)) }
    func pickColor(at point: PaintPoint) {
        guard !isBusy, (0..<Double(width)).contains(point.x), (0..<Double(height)).contains(point.y) else { return }
        updateComposite(); guard waitForGPU(), dirty == nil else { return }
        let data = [UInt8](read(composite, region: MTLRegionMake2D(Int(point.x), Int(point.y), 1, 1)))
        let alpha = Double(data[3]) / 255
        if alpha > 0 { setColor(.init(Double(data[0]) / 255 / alpha, Double(data[1]) / 255 / alpha, Double(data[2]) / 255 / alpha)) }
    }
    private func allPatches(_ texture: MTLTexture) -> [TilePatch] {
        stride(from: 0, to: height, by: 128).flatMap { y in
            stride(from: 0, to: width, by: 128).map { x in
                patch(texture, x: x, y: y, width: min(128, width - x), height: min(128, height - y))
            }
        }
    }
    private func rasterEdit(usedColor: PaintColor? = nil, _ operation: @escaping @Sendable ([UInt8], [UInt8]?, Int, Int) -> (pixels: [UInt8], mask: [UInt8]?)) {
        guard !isBusy, !strokeActive, let layer = editableLayer() else { return }
        guard waitForGPU() else { return }; isBusy = true
        let before = allPatches(layer.texture), pixels = [UInt8](read(layer.texture))
        let oldMask = selectionMask, w = width, h = height
        Task {
            defer { isBusy = false }
            let result = await Task.detached(priority: .userInitiated) { operation(pixels, oldMask, w, h) }.value
            guard waitForGPU() else { return }
            replace(layer.texture, data: Data(result.pixels))
            let after = allPatches(layer.texture)
            var changedBefore: [TilePatch] = [], changedAfter: [TilePatch] = []
            for (a, b) in zip(before, after) where a.data != b.data { changedBefore.append(a); changedAfter.append(b) }
            let changedMask = oldMask != result.mask
            if !changedBefore.isEmpty || changedMask {
                record(.pixels(layer.id, changedBefore, changedAfter, changedMask ? oldMask : nil, changedMask ? result.mask : nil))
                if changedMask { setSelectionMask(result.mask) }
                if let usedColor { rememberColor(usedColor) }
                markDirty(fullRegion); commit()
            }
            isBusy = false
        }
    }
    func fill(at point: PaintPoint) {
        guard (0..<Double(width)).contains(point.x), (0..<Double(height)).contains(point.y) else { return }
        guard !isBusy, !strokeActive else { return }
        updateComposite(); guard waitForGPU(), dirty == nil else { return }
        let reference = [UInt8](read(composite))
        let color = PaintColor(self.color.red, self.color.green, self.color.blue, self.color.alpha * brush.opacity)
        let tolerance = fillTolerance, expansion = fillExpansion, alphaLocked = selectedLayer?.properties.alphaLocked ?? false
        rasterEdit(usedColor: self.color) { pixels, mask, width, height in
            var result = pixels
            RasterOperations.floodFill(pixels: &result, width: width, height: height, x: Int(point.x), y: Int(point.y),
                color: color, tolerance: tolerance, mask: mask, alphaLocked: alphaLocked, reference: reference, expansion: expansion)
            return (result, mask)
        }
    }
    func transformSelection(dx: Double, dy: Double, scale: Double, degrees: Double) {
        guard hasSelection else { return }
        if selectedLayer?.properties.alphaLocked == true { errorMessage = "変形するには透明度保護を解除してください。"; return }
        rasterEdit { pixels, mask, width, height in
            let result = RasterOperations.transform(pixels: pixels, mask: mask!, width: width, height: height,
                translation: .init(dx, dy), scale: scale, angle: degrees * .pi / 180)
            return (result.pixels, result.mask)
        }
    }
    func clearSelectedPixels() {
        guard hasSelection, selectedLayer?.properties.alphaLocked != true else { return }
        rasterEdit { pixels, mask, _, _ in
            var result = pixels
            for index in stride(from: 0, to: pixels.count, by: 4) where (mask?[index / 4] ?? 0) != 0 {
                for c in 0..<4 { result[index + c] = 0 }
            }
            return (result, mask)
        }
    }
    func importImage(_ data: Data) throws {
        guard !isBusy, !strokeActive else { return }
        guard layers.count < DocumentSnapshot.maximumLayers else { throw PaintDocumentError.invalid("レイヤー上限です。") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else { throw PaintDocumentError.invalid("画像を読み込めません。") }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
            let w = Double(image.width) * scale, h = Double(image.height) * scale
            context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
            return true
        }
        guard success else { throw PaintDocumentError.invalid("画像用のメモリが不足しています。") }
        guard waitForGPU() else { throw PaintDocumentError.invalid(gpuFailure!) }
        let texture = try makeTexture(); replace(texture, data: Data(pixels))
        let layer = PaintLayer(properties: .init(name: "読み込んだ画像"), texture: texture)
        layers.append(layer); selectedLayerID = layer.id
        record(.insert(layer, layers.count - 1)); markDirty(fullRegion); commit()
    }
    func pngData() throws -> Data {
        updateComposite()
        guard waitForGPU() else { throw PaintDocumentError.invalid(gpuFailure!) }
        guard dirty == nil else { throw PaintDocumentError.invalid("画像の合成を完了できません。") }
        let pixels = read(composite)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PaintDocumentError.invalid("PNGを生成できません。")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw PaintDocumentError.invalid("PNGを生成できません。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PaintDocumentError.invalid("PNGの保存に失敗しました。") }
        return output as Data
    }
}
