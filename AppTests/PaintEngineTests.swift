import XCTest
import MetalKit
import ImageIO
@testable import SumiPaint

@MainActor
final class PaintEngineTests: XCTestCase {
    private func makeEngine() throws -> PaintEngine {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("This runner has no Metal device") }
        let engine = try PaintEngine()
        try engine.newDocument(width: 64, height: 64)
        engine.brush.stabilization = 0; engine.brush.size = 12; engine.brush.hardness = 0.99
        return engine
    }
    private func stroke(_ engine: PaintEngine, from: PaintPoint, to: PaintPoint) {
        engine.beginStroke(.init(point: from, time: 0, pressure: 1))
        engine.appendStroke(.init(point: to, time: 1, pressure: 1)); engine.endStroke()
    }
    func testPaintEraseAndUndoRestoreExactPixels() async throws {
        let engine = try makeEngine()
        stroke(engine, from: .init(10, 32), to: .init(54, 32))
        let painted = engine.snapshot()
        let index = (32 * 64 + 32) * 4 + 3
        XCTAssertGreaterThan(painted.layers[0].pixels[index], 200)
        engine.setTool(.eraser); engine.brush.size = 16
        stroke(engine, from: .init(24, 32), to: .init(40, 32))
        XCTAssertLessThan(engine.snapshot().layers[0].pixels[index], painted.layers[0].pixels[index])
        engine.undo(); XCTAssertEqual(engine.snapshot().layers[0].pixels, painted.layers[0].pixels)
        engine.undo(); XCTAssertTrue(engine.snapshot().layers[0].pixels.allSatisfy { $0 == 0 })
        engine.redo(); XCTAssertEqual(engine.snapshot().layers[0].pixels, painted.layers[0].pixels)
    }
    func testSelectionClipsGPUBrushAndCancellationRestoresPixels() async throws {
        let engine = try makeEngine()
        engine.select(polygon: [.init(0, 0), .init(32, 0), .init(32, 64), .init(0, 64)])
        stroke(engine, from: .init(8, 32), to: .init(56, 32))
        let before = engine.snapshot().layers[0].pixels
        XCTAssertGreaterThan(before[(32 * 64 + 20) * 4 + 3], 200)
        XCTAssertEqual(before[(32 * 64 + 44) * 4 + 3], 0)
        engine.beginStroke(.init(point: .init(16, 10), time: 2))
        engine.endStroke(cancelled: true)
        XCTAssertEqual(engine.snapshot().layers[0].pixels, before)
    }
    func testLayerStructureAndPropertiesUndo() async throws {
        let engine = try makeEngine()
        let first = engine.layers[0].id
        engine.addLayer(); let second = engine.layers[1].id
        engine.changeLayer(second) { $0.opacity = 0.5; $0.name = "色"; $0.blend = .multiply }
        engine.deleteLayer(); XCTAssertEqual(engine.layers.map(\.id), [first])
        engine.undo(); XCTAssertEqual(engine.layers.map(\.id), [first, second])
        XCTAssertEqual(engine.layers[1].properties.name, "色")
        engine.undo(); XCTAssertEqual(engine.layers[1].properties.opacity, 1)
        engine.undo(); XCTAssertEqual(engine.layers.map(\.id), [first])
        engine.redo(); XCTAssertEqual(engine.layers.map(\.id), [first, second])
    }
    func testDocumentAndPNGExportPreserveArtwork() async throws {
        let engine = try makeEngine()
        stroke(engine, from: .init(10, 32), to: .init(54, 32))
        let snapshot = engine.snapshot()
        let saved = try snapshot.encoded()
        let restored = try makeEngine(); try restored.load(DocumentSnapshot.decode(saved))
        XCTAssertEqual(restored.snapshot(), snapshot)
        let png = try restored.pngData()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 64)
    }
    func testClippingAndMultiplyComposite() async throws {
        let engine = try makeEngine()
        engine.color = .init(1, 0, 0)
        stroke(engine, from: .init(8, 32), to: .init(32, 32))
        engine.addLayer(); let upper = engine.selectedLayerID!
        engine.color = .init(0, 0, 1)
        stroke(engine, from: .init(8, 32), to: .init(56, 32))
        engine.changeLayer(upper) { $0.clipping = true }
        engine.pickColor(at: .init(20, 32))
        XCTAssertGreaterThan(engine.color.blue, 0.9)
        engine.color = .init(0, 1, 0); engine.pickColor(at: .init(48, 32))
        XCTAssertEqual(engine.color, .init(0, 1, 0), "The clipped area must be transparent")
        engine.changeLayer(upper) { $0.blend = .multiply }
        engine.pickColor(at: .init(20, 32))
        XCTAssertLessThan(engine.color.red, 0.05); XCTAssertLessThan(engine.color.blue, 0.05)
    }
    func testImageImportKeepsTopToBottomOrientation() async throws {
        let engine = try makeEngine()
        stroke(engine, from: .init(20, 10), to: .init(40, 10))
        let exported = try engine.pngData()
        let imported = try makeEngine(); try imported.importImage(exported)
        let pixels = imported.snapshot().layers.last!.pixels
        XCTAssertGreaterThan(pixels[(10 * 64 + 30) * 4 + 3], 200)
        XCTAssertEqual(pixels[(54 * 64 + 30) * 4 + 3], 0)
    }
}
