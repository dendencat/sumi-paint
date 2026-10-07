import XCTest
import AppKit
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
    private func tabletSettings() -> MacTabletSettings {
        let suite = "SumiPaintTests.Tablet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return MacTabletSettings(defaults: defaults)
    }
    private func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .init(x: 32, y: 32),
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    private func keyEvent(_ text: String, code: UInt16, repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: repeatKey, keyCode: code))
    }
    func testMappedRightButtonRestoresCompleteBrushSettings() async throws {
        let engine = try makeEngine()
        engine.setTool(.pencil); engine.brush.hardness = 0.27; engine.brush.size = 29
        let original = engine.brush
        let settings = tabletSettings(); settings.rightAction = .holdEraser
        let canvas = MouseCanvas(engine: engine, tabletSettings: settings)
        canvas.rightMouseDown(with: try mouseEvent(.rightMouseDown))
        XCTAssertEqual(engine.tool, .eraser); XCTAssertEqual(engine.brush.kind, .eraser)
        canvas.rightMouseUp(with: try mouseEvent(.rightMouseUp))
        XCTAssertEqual(engine.tool, .pencil); XCTAssertEqual(engine.brush, original)
        XCTAssertFalse(engine.strokeActive)
    }
    func testMiddleButtonPansWithoutModifyingPixels() async throws {
        let engine = try makeEngine()
        let canvas = MouseCanvas(engine: engine, tabletSettings: tabletSettings())
        let pixels = engine.snapshot().layers[0].pixels
        func middleEvent(_ type: CGEventType, x: Double) throws -> NSEvent {
            let cgEvent = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: x, y: 32), mouseButton: .center))
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        }
        canvas.otherMouseDown(with: try middleEvent(.otherMouseDown, x: 32))
        XCTAssertEqual(engine.tool, .hand)
        let before = engine.viewport.pan
        canvas.otherMouseDragged(with: try middleEvent(.otherMouseDragged, x: 52))
        XCTAssertNotEqual(engine.viewport.pan, before)
        canvas.otherMouseUp(with: try middleEvent(.otherMouseUp, x: 52))
        XCTAssertEqual(engine.tool, .pen)
        XCTAssertEqual(engine.snapshot().layers[0].pixels, pixels)
    }
    func testEraserProximityDoesNotPaintAndRestoresOriginalTool() async throws {
        let engine = try makeEngine()
        engine.setTool(.pencil); engine.brush.hardness = 0.31
        let original = engine.brush, pixels = engine.snapshot().layers[0].pixels
        let canvas = MouseCanvas(engine: engine, tabletSettings: tabletSettings())
        canvas.updateTabletProximity(isEntering: true, eraser: true)
        XCTAssertEqual(engine.tool, .eraser); XCTAssertFalse(engine.strokeActive)
        XCTAssertEqual(engine.snapshot().layers[0].pixels, pixels)
        canvas.updateTabletProximity(isEntering: false, eraser: true)
        XCTAssertEqual(engine.tool, .pencil); XCTAssertEqual(engine.brush, original)
    }
    func testToggleKeyPreservesPencilAndIgnoresKeyRepeat() async throws {
        let engine = try makeEngine()
        let canvas = MouseCanvas(engine: engine, tabletSettings: tabletSettings())
        engine.setTool(.pencil); engine.brush.hardness = 0.22
        let original = engine.brush
        canvas.keyDown(with: try keyEvent("x", code: 7))
        XCTAssertEqual(engine.tool, .eraser)
        canvas.keyDown(with: try keyEvent("x", code: 7, repeatKey: true))
        XCTAssertEqual(engine.tool, .eraser)
        canvas.keyDown(with: try keyEvent("x", code: 7))
        XCTAssertEqual(engine.tool, .pencil); XCTAssertEqual(engine.brush, original)
    }
    func testSpaceDuringStrokeCommitsInkAndFocusLossClearsMode() async throws {
        let engine = try makeEngine()
        engine.viewport.viewWidth = 64; engine.viewport.viewHeight = 64; engine.viewport.zoom = 1
        let canvas = MouseCanvas(engine: engine, tabletSettings: tabletSettings())
        canvas.pointer.begin(point: .init(32, 32), time: 0, pressure: 1)
        XCTAssertTrue(engine.strokeActive)
        let painted = engine.snapshot().layers[0].pixels
        XCTAssertTrue(painted.contains { $0 != 0 })
        canvas.keyDown(with: try keyEvent(" ", code: 49))
        XCTAssertEqual(engine.tool, .hand); XCTAssertFalse(engine.strokeActive)
        XCTAssertEqual(engine.snapshot().layers[0].pixels, painted)
        _ = canvas.resignFirstResponder()
        XCTAssertEqual(engine.tool, .pen); XCTAssertNil(canvas.pointer.start)
        XCTAssertEqual(engine.snapshot().layers[0].pixels, painted)
    }
    func testTabletButtonPreferencesPersist() async throws {
        let suite = "SumiPaintTests.Preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MacTabletSettings(defaults: defaults)
        settings.rightAction = .toggleEraser; settings.middleAction = .holdEraser; settings.automaticEraser = false
        let restored = MacTabletSettings(defaults: defaults)
        XCTAssertEqual(restored.rightAction, .toggleEraser)
        XCTAssertEqual(restored.middleAction, .holdEraser)
        XCTAssertFalse(restored.automaticEraser)
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
        // Repeated immediate cancellations expose CPU/GPU timing races.
        for attempt in 0..<24 {
            engine.beginStroke(.init(point: .init(12 + Double(attempt % 8), attempt.isMultiple(of: 2) ? 10 : 50), time: Double(attempt + 2)))
            engine.endStroke(cancelled: true)
            let restored = engine.snapshot().layers[0].pixels
            let differences = before.indices.filter { before[$0] != restored[$0] }
            let details = differences.prefix(8).map { "\($0):\(before[$0])->\(restored[$0])" }.joined(separator: ", ")
            XCTAssertTrue(differences.isEmpty, "Cancellation \(attempt) changed \(differences.count) bytes: \(details)")
        }
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
