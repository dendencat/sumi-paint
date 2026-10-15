import XCTest
import AppKit
import MetalKit
import ImageIO
@testable import SumiPaint

@MainActor
final class PaintEngineTests: XCTestCase {
    private func makeEngine() throws -> PaintEngine {
        guard MTLCreateSystemDefaultDevice() != nil else { throw PaintDocumentError.invalid("The required Metal test device is unavailable") }
        let suite = "SumiPaintTests.Engine.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let engine = try PaintEngine(defaults: defaults)
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
        let pixels = try engine.snapshot().layers[0].pixels
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
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, pixels)
    }
    func testEraserProximityDoesNotPaintAndRestoresOriginalTool() async throws {
        let engine = try makeEngine()
        engine.setTool(.pencil); engine.brush.hardness = 0.31
        let original = engine.brush, pixels = try engine.snapshot().layers[0].pixels
        let canvas = MouseCanvas(engine: engine, tabletSettings: tabletSettings())
        canvas.updateTabletProximity(isEntering: true, eraser: true)
        XCTAssertEqual(engine.tool, .eraser); XCTAssertFalse(engine.strokeActive)
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, pixels)
        canvas.updateTabletProximity(isEntering: false, eraser: true)
        XCTAssertEqual(engine.tool, .pencil); XCTAssertEqual(engine.brush, original)
    }
    func testXSwapsColorsAndIgnoresRepeatWithoutChangingTool() async throws {
        let engine = try makeEngine()
        let canvas = MouseCanvas(engine: engine, tabletSettings: tabletSettings())
        engine.setTool(.pencil); let original = engine.color
        canvas.keyDown(with: try keyEvent("x", code: 7))
        XCTAssertEqual(engine.color, .init(1, 1, 1)); XCTAssertEqual(engine.backgroundColor, original)
        canvas.keyDown(with: try keyEvent("x", code: 7, repeatKey: true))
        XCTAssertEqual(engine.color, .init(1, 1, 1))
        canvas.keyDown(with: try keyEvent("x", code: 7))
        XCTAssertEqual(engine.color, original); XCTAssertEqual(engine.tool, .pencil)
    }
    func testPaletteSeparatesSelectionFromUseAndPersistsSets() async throws {
        let suite = "SumiPaintTests.Palette.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = try PaintEngine(defaults: defaults)
        for index in 0..<20 { engine.setColor(.init(Double(index) / 20, 0, 0)) }
        XCTAssertTrue(engine.recentColors.isEmpty)
        engine.saveColor(); let saved = engine.color
        for index in 0..<12 { engine.setColor(.init(0, Double(index) / 12, 0)); engine.rememberColor() }
        XCTAssertEqual(engine.recentColors.count, 8); XCTAssertEqual(engine.colorSet, [saved])
        let restored = try PaintEngine(defaults: defaults)
        XCTAssertEqual(restored.recentColors, engine.recentColors); XCTAssertEqual(restored.colorSet, [saved])
        restored.removeSavedColor(saved)
        XCTAssertTrue(try PaintEngine(defaults: defaults).colorSet.isEmpty)
    }
    func testSpaceDuringStrokeCommitsInkAndFocusLossClearsMode() async throws {
        let engine = try makeEngine()
        engine.viewport.viewWidth = 64; engine.viewport.viewHeight = 64; engine.viewport.zoom = 1
        let canvas = MouseCanvas(engine: engine, tabletSettings: tabletSettings())
        canvas.pointer.begin(point: .init(32, 32), time: 0, pressure: 1)
        XCTAssertTrue(engine.strokeActive)
        let painted = try engine.snapshot().layers[0].pixels
        XCTAssertTrue(painted.contains { $0 != 0 })
        canvas.keyDown(with: try keyEvent(" ", code: 49))
        XCTAssertEqual(engine.tool, .hand); XCTAssertFalse(engine.strokeActive)
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, painted)
        _ = canvas.resignFirstResponder()
        XCTAssertEqual(engine.tool, .pen); XCTAssertNil(canvas.pointer.start)
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, painted)
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
        let painted = try engine.snapshot()
        let index = (32 * 64 + 32) * 4 + 3
        XCTAssertGreaterThan(painted.layers[0].pixels[index], 200)
        engine.setTool(.eraser); engine.brush.size = 16
        stroke(engine, from: .init(24, 32), to: .init(40, 32))
        XCTAssertLessThan(try engine.snapshot().layers[0].pixels[index], painted.layers[0].pixels[index])
        engine.undo(); XCTAssertEqual(try engine.snapshot().layers[0].pixels, painted.layers[0].pixels)
        engine.undo(); XCTAssertTrue(try engine.snapshot().layers[0].pixels.allSatisfy { $0 == 0 })
        engine.redo(); XCTAssertEqual(try engine.snapshot().layers[0].pixels, painted.layers[0].pixels)
    }
    func testSelectionClipsGPUBrushAndCancellationRestoresPixels() async throws {
        let engine = try makeEngine()
        engine.select(polygon: [.init(0, 0), .init(32, 0), .init(32, 64), .init(0, 64)])
        stroke(engine, from: .init(8, 32), to: .init(56, 32))
        let before = try engine.snapshot().layers[0].pixels
        XCTAssertGreaterThan(before[(32 * 64 + 20) * 4 + 3], 200)
        XCTAssertEqual(before[(32 * 64 + 44) * 4 + 3], 0)
        // Repeated immediate cancellations expose CPU/GPU timing races.
        for attempt in 0..<24 {
            engine.beginStroke(.init(point: .init(12 + Double(attempt % 8), attempt.isMultiple(of: 2) ? 10 : 50), time: Double(attempt + 2)))
            engine.endStroke(cancelled: true)
            let restored = try engine.snapshot().layers[0].pixels
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
        let snapshot = try engine.snapshot()
        let saved = try snapshot.encoded()
        let restored = try makeEngine(); try restored.load(DocumentSnapshot.decode(saved))
        XCTAssertEqual(try restored.snapshot(), snapshot)
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
    private func compositePixel(_ engine: PaintEngine, x: Int = 32, y: Int = 32) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try engine.pngData() as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: engine.width * engine.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: engine.width, height: engine.height,
                bitsPerComponent: 8, bytesPerRow: engine.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: engine.width, height: engine.height))
        }
        let offset = (y * engine.width + x) * 4
        return Array(pixels[offset..<offset + 4])
    }
    func testLayerOpacityPreviewsImmediatelyAndUndoesOnce() async throws {
        let engine = try makeEngine()
        stroke(engine, from: .init(10, 32), to: .init(54, 32))
        let id = try XCTUnwrap(engine.selectedLayerID), revision = engine.revision
        for opacity in [0.8, 0.5, 0.3] {
            engine.previewLayerOpacity(id, value: opacity)
            XCTAssertEqual(Double(try compositePixel(engine)[3]), opacity * 255, accuracy: 2)
            XCTAssertEqual(engine.revision, revision, "Preview must not create commits or reset the slider")
        }
        engine.finishLayerOpacityEdit()
        XCTAssertEqual(engine.revision, revision + 1)
        engine.undo(); XCTAssertEqual(engine.selectedLayer?.properties.opacity, 1)
        engine.redo(); XCTAssertEqual(engine.selectedLayer?.properties.opacity, 0.3)
        engine.undo(); engine.undo()
        XCTAssertTrue(try engine.snapshot().layers[0].pixels.allSatisfy { $0 == 0 })
    }
    func testClippingGroupPreservesBaseAlphaAndAppliesBaseOpacityOnce() async throws {
        let engine = try makeEngine()
        var base = LayerProperties(name: "半透明の基底"); base.opacity = 0.5
        let basePixels = Data(Array(repeating: [UInt8(128), 0, 0, 128], count: 64 * 64).flatMap { $0 })
        var layers = [LayerSnapshot(properties: base, pixels: basePixels)]
        for index in 0..<3 {
            var clip = LayerProperties(name: "クリップ\(index)"); clip.clipping = true
            layers.append(.init(properties: clip, pixels: Data(Array(repeating: [UInt8(0), 0, 255, 255], count: 64 * 64).flatMap { $0 })))
        }
        try engine.load(.init(width: 64, height: 64, layers: layers, selectedLayerID: base.id))
        let pixel = try compositePixel(engine)
        XCTAssertEqual(Double(pixel[3]), 64, accuracy: 1)
        XCTAssertEqual(Double(pixel[2]), 64, accuracy: 1)
        engine.changeLayer(base.id) { $0.visible = false }
        XCTAssertEqual(try compositePixel(engine)[3], 0)
    }
    func testLayerInsertionAndReorderKeepClippingValidThroughUndo() async throws {
        let engine = try makeEngine(), base = engine.layers[0].id
        engine.changeLayer(base) { $0.clipping = true }
        XCTAssertFalse(engine.layers[0].properties.clipping)
        engine.addLayer(); let clip = try XCTUnwrap(engine.selectedLayerID)
        engine.changeLayer(clip) { $0.clipping = true }
        engine.selectedLayerID = base; engine.addLayer()
        XCTAssertTrue(engine.layers[1].properties.clipping)
        let inserted = try XCTUnwrap(engine.selectedLayerID)
        engine.reorderLayer(clip, to: 0)
        XCTAssertEqual(engine.layers[0].id, clip); XCTAssertFalse(engine.layers[0].properties.clipping)
        engine.undo()
        XCTAssertEqual(engine.layers.map(\.id), [base, inserted, clip]); XCTAssertTrue(engine.layers[2].properties.clipping)
        engine.selectedLayerID = base; engine.deleteLayer()
        XCTAssertFalse(engine.layers[0].properties.clipping)
        engine.undo()
        XCTAssertEqual(engine.layers.map(\.id), [base, inserted, clip]); XCTAssertTrue(engine.layers[1].properties.clipping)
    }
    func testImageImportKeepsTopToBottomOrientation() async throws {
        let engine = try makeEngine()
        stroke(engine, from: .init(20, 10), to: .init(40, 10))
        let exported = try engine.pngData()
        let imported = try makeEngine(); try imported.importImage(exported)
        let pixels = try imported.snapshot().layers.last!.pixels
        XCTAssertGreaterThan(pixels[(10 * 64 + 30) * 4 + 3], 200)
        XCTAssertEqual(pixels[(54 * 64 + 30) * 4 + 3], 0)
    }
    func testNavigationCommitsInkAndUndoTargetsTheActiveStroke() async throws {
        let engine = try makeEngine()
        engine.viewport.viewWidth = 64; engine.viewport.viewHeight = 64; engine.viewport.zoom = 1
        stroke(engine, from: .init(10, 16), to: .init(54, 16))
        let first = try engine.snapshot().layers[0].pixels
        let pointer = CanvasPointer(engine: engine)
        pointer.begin(point: .init(32, 48), time: 2, pressure: 1)
        let both = try engine.snapshot().layers[0].pixels
        XCTAssertNotEqual(both, first)
        pointer.undoIncludingStroke()
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, first)
        engine.redo(); XCTAssertEqual(try engine.snapshot().layers[0].pixels, both)
        pointer.begin(point: .init(16, 32), time: 3, pressure: 1)
        let navigating = try engine.snapshot().layers[0].pixels
        pointer.end()
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, navigating)
        engine.undo(); XCTAssertEqual(try engine.snapshot().layers[0].pixels, both)
    }
    func testFocusLossCommitsActiveStrokeButEscapeCancelsIt() async throws {
        let engine = try makeEngine()
        engine.viewport.viewWidth = 64; engine.viewport.viewHeight = 64; engine.viewport.zoom = 1
        let canvas = MouseCanvas(engine: engine, tabletSettings: tabletSettings())
        canvas.pointer.begin(point: .init(32, 32), time: 0, pressure: 1)
        let painted = try engine.snapshot().layers[0].pixels
        _ = canvas.resignFirstResponder()
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, painted); XCTAssertTrue(engine.canUndo)
        canvas.pointer.begin(point: .init(32, 48), time: 1, pressure: 1)
        canvas.keyDown(with: try keyEvent("\u{1b}", code: 53))
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, painted)
        engine.undo(); XCTAssertTrue(try engine.snapshot().layers[0].pixels.allSatisfy { $0 == 0 })
    }
    func testUndoGestureDiscardsProvisionalDotAndUndoesPreviousStroke() async throws {
        let engine = try makeEngine()
        engine.viewport.viewWidth = 64; engine.viewport.viewHeight = 64; engine.viewport.zoom = 1
        stroke(engine, from: .init(8, 16), to: .init(56, 16))
        let first = try engine.snapshot().layers[0].pixels
        let pointer = CanvasPointer(engine: engine)
        pointer.begin(point: .init(32, 48), time: 2, pressure: 1); pointer.undoGesture()
        XCTAssertTrue(try engine.snapshot().layers[0].pixels.allSatisfy { $0 == 0 })
        engine.redo(); XCTAssertEqual(try engine.snapshot().layers[0].pixels, first)
    }
    func testClearWithoutSelectionIsSafeAndEmptySelectionNormalizes() async throws {
        let engine = try makeEngine()
        stroke(engine, from: .init(8, 32), to: .init(56, 32))
        let before = try engine.snapshot().layers[0].pixels, revision = engine.revision
        engine.clearSelectedPixels()
        XCTAssertFalse(engine.isBusy); XCTAssertEqual(engine.revision, revision)
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, before)
        engine.select(polygon: [.init(-30, -30), .init(-20, -30), .init(-20, -20)])
        XCTAssertFalse(engine.hasSelection)
        engine.setTool(.fill); engine.fill(at: .init(0, 0))
        while engine.isBusy { await Task.yield() }
        XCTAssertNotEqual(try engine.snapshot().layers[0].pixels, before)
    }
    func testToolSwitchRestoresIndividualBrushSettings() async throws {
        let engine = try makeEngine()
        engine.brush.size = 27; engine.brush.hardness = 0.22; let pen = engine.brush
        engine.setTool(.eyedropper); engine.setTool(.pen); XCTAssertEqual(engine.brush, pen)
        engine.setTool(.eraser); engine.brush.size = 49; let eraser = engine.brush
        engine.setTool(.pen); XCTAssertEqual(engine.brush, pen)
        engine.setTool(.eraser); XCTAssertEqual(engine.brush, eraser)
    }
    func testFailedUndoAndRedoKeepTheirHistoryUntilRetry() async throws {
        let engine = try makeEngine()
        stroke(engine, from: .init(10, 32), to: .init(54, 32))
        let painted = try engine.snapshot().layers[0].pixels, revision = engine.revision
        engine.failNextPatchAllocation = true; engine.undo()
        XCTAssertEqual(engine.revision, revision); XCTAssertTrue(engine.canUndo); XCTAssertFalse(engine.canRedo)
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, painted)
        engine.undo(); let undoneRevision = engine.revision
        XCTAssertTrue(try engine.snapshot().layers[0].pixels.allSatisfy { $0 == 0 })
        engine.failNextPatchAllocation = true; engine.redo()
        XCTAssertEqual(engine.revision, undoneRevision); XCTAssertTrue(engine.canRedo)
        XCTAssertTrue(try engine.snapshot().layers[0].pixels.allSatisfy { $0 == 0 })
        engine.redo(); XCTAssertEqual(try engine.snapshot().layers[0].pixels, painted)
    }
    func testFailedCancellationRetainsBackupUntilRetry() async throws {
        let engine = try makeEngine(), blank = try engine.snapshot().layers[0].pixels
        engine.beginStroke(.init(point: .init(32, 32), time: 0, pressure: 1))
        engine.failNextPatchAllocation = true; engine.endStroke(cancelled: true)
        XCTAssertTrue(engine.strokeActive); XCTAssertTrue(engine.hasPendingCancellation)
        XCTAssertFalse(engine.canUndo)
        XCTAssertNotEqual(try engine.snapshot().layers[0].pixels, blank)
        engine.retryPendingCancellation()
        XCTAssertFalse(engine.strokeActive); XCTAssertFalse(engine.hasPendingCancellation)
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, blank)
        XCTAssertFalse(engine.canUndo)
    }
    func testGPUFailureBlocksExportAndDoesNotConsumeUndo() async throws {
        let engine = try makeEngine()
        stroke(engine, from: .init(10, 32), to: .init(54, 32))
        let revision = engine.revision
        engine.failNextGPUCompletion = true
        XCTAssertThrowsError(try engine.pngData()); XCTAssertNotNil(engine.gpuFailure)
        XCTAssertThrowsError(try engine.snapshot())
        engine.undo(); XCTAssertTrue(engine.canUndo); XCTAssertFalse(engine.canRedo)
        XCTAssertEqual(engine.revision, revision)
        engine.beginStroke(.init(point: .init(32, 48), time: 2, pressure: 1))
        XCTAssertFalse(engine.strokeActive)
    }
    func testBrushOpacityCapsOneStrokeButSeparateStrokesBuildUp() async throws {
        let engine = try makeEngine(); engine.brush.opacity = 0.3
        engine.beginStroke(.init(point: .init(8, 32), time: 0, pressure: 1))
        for index in 1...12 {
            engine.appendStroke(.init(point: .init(index.isMultiple(of: 2) ? 8 : 56, 32), time: Double(index), pressure: 1))
        }
        let preview = try engine.snapshot().layers[0].pixels
        XCTAssertEqual(Double(preview[(32 * 64 + 32) * 4 + 3]), 76.5, accuracy: 1)
        engine.endStroke()
        let first = try engine.snapshot().layers[0].pixels
        XCTAssertLessThanOrEqual(first.enumerated().filter { $0.offset % 4 == 3 }.map(\.element).max()!, 77)
        stroke(engine, from: .init(8, 32), to: .init(56, 32))
        XCTAssertEqual(Double(try engine.snapshot().layers[0].pixels[(32 * 64 + 32) * 4 + 3]), 130, accuracy: 2)
        engine.undo(); XCTAssertEqual(try engine.snapshot().layers[0].pixels, first)
        engine.setTool(.eraser); engine.brush.opacity = 0.3
        stroke(engine, from: .init(8, 32), to: .init(56, 32))
        XCTAssertEqual(Double(try engine.snapshot().layers[0].pixels[(32 * 64 + 32) * 4 + 3]), 54, accuracy: 2)
    }
    func testFillReferencesVisibleLayersAndRespectsOpacity() async throws {
        let engine = try makeEngine()
        stroke(engine, from: .init(32, 0), to: .init(32, 64))
        engine.addLayer(); engine.moveLayer(-1)
        engine.setTool(.fill); engine.brush.opacity = 0.3; engine.setColor(.init(1, 0, 0))
        engine.fill(at: .init(8, 32))
        while engine.isBusy { await Task.yield() }
        let filled = try engine.snapshot().layers[0].pixels
        XCTAssertEqual(Double(filled[(32 * 64 + 8) * 4 + 3]), 76.5, accuracy: 1)
        XCTAssertEqual(filled[(32 * 64 + 56) * 4 + 3], 0)
        XCTAssertEqual(engine.recentColors.first, .init(1, 0, 0))
        engine.undo(); XCTAssertTrue(try engine.snapshot().layers[0].pixels.allSatisfy { $0 == 0 })
        engine.redo(); XCTAssertEqual(try engine.snapshot().layers[0].pixels, filled)
    }
    func testFillOpacitySurvivesToolChangesIndependently() async throws {
        let engine = try makeEngine()
        engine.brush.opacity = 0.2; let pen = engine.brush
        engine.setTool(.eraser); engine.brush.opacity = 0.1
        engine.setTool(.fill)
        XCTAssertEqual(engine.brush.opacity, 1, "Fill must not inherit eraser opacity")
        engine.brush.opacity = 0.4
        engine.setTool(.eyedropper); engine.setTool(.pen)
        XCTAssertEqual(engine.brush, pen)
        engine.setTool(.fill)
        XCTAssertEqual(engine.brush.opacity, 0.4)
        engine.fill(at: .init(8, 8))
        while engine.isBusy { await Task.yield() }
        XCTAssertEqual(Double(try engine.snapshot().layers[0].pixels[3]), 102, accuracy: 1)
        engine.setTool(.eraser); XCTAssertEqual(engine.brush.opacity, 0.1)
    }

    func testSavingFromOtherToolsPreservesDrawingBrush() async throws {
        let engine = try makeEngine()
        for drawingTool in [EditorTool.pen, .pencil] {
            engine.setTool(drawingTool)
            engine.brush.opacity = 0.23; engine.brush.size = 37; engine.brush.hardness = 0.42
            let drawingBrush = engine.brush
            engine.setTool(.eraser); engine.brush.opacity = 0.1; engine.brush.size = 83
            let eraser = engine.brush
            for tool in [EditorTool.eraser, .fill, .eyedropper, .hand] {
                engine.setTool(tool)
                if tool == .fill { engine.brush.opacity = 0.7 }
                let snapshot = try DocumentSnapshot.decode(engine.snapshot().encoded())
                XCTAssertEqual(snapshot.brush, drawingBrush)
                let restored = try makeEngine()
                try restored.load(snapshot)
                XCTAssertEqual(restored.tool, drawingTool)
                XCTAssertEqual(restored.brush, drawingBrush)
            }
            engine.setTool(.fill); XCTAssertEqual(engine.brush.opacity, 0.7)
            engine.setTool(.eraser); XCTAssertEqual(engine.brush, eraser)
        }
    }

    func testFingerNavigationPreservesPencilStrokeAndCancelsFingerInk() async throws {
        let engine = try makeEngine(), pointer = CanvasPointer(engine: engine)
        engine.viewport.viewWidth = 64; engine.viewport.viewHeight = 64; engine.viewport.zoom = 1
        pointer.begin(point: .init(8, 32), time: 0, pressure: 1)
        pointer.move(point: .init(56, 32), time: 1, pressure: 1)
        XCTAssertFalse(pointer.beginNavigationGesture(pencilActive: true))
        XCTAssertTrue(engine.strokeActive)
        pointer.end()
        let pencilPixels = try engine.snapshot().layers[0].pixels
        XCTAssertTrue(pencilPixels.contains { $0 != 0 })
        pointer.begin(point: .init(8, 48), time: 2, pressure: nil)
        pointer.move(point: .init(56, 48), time: 3, pressure: nil)
        XCTAssertTrue(pointer.beginNavigationGesture(pencilActive: false))
        XCTAssertFalse(engine.strokeActive)
        XCTAssertEqual(try engine.snapshot().layers[0].pixels, pencilPixels)
    }

    private func waitForThumbnail(_ engine: PaintEngine, layer: PaintLayer, after count: Int) async throws -> CGImage {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while engine.thumbnailGenerationCount <= count || engine.thumbnail(for: layer) == nil {
            guard ContinuousClock.now < deadline else { throw PaintDocumentError.invalid("Thumbnail generation timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(engine.thumbnail(for: layer))
    }
    func testThumbnailsReadSmallTexturesAndOnlyRefreshChangedPixels() async throws {
        let engine = try makeEngine(), base = try XCTUnwrap(engine.selectedLayer)
        _ = try await waitForThumbnail(engine, layer: base, after: 0)
        engine.addLayer(); let top = try XCTUnwrap(engine.selectedLayer)
        let original = try await waitForThumbnail(engine, layer: top, after: 1)
        let count = engine.thumbnailGenerationCount, bytes = engine.thumbnailReadbackBytes
        XCTAssertEqual(count, 2)
        XCTAssertEqual(bytes, count * 80 * 80 * 4)
        engine.changeLayer(top.id) { $0.name = "新しい名前"; $0.opacity = 0.5 }
        engine.reorderLayer(top.id, to: 0)
        engine.undo(); engine.redo()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.thumbnailGenerationCount, count, "Metadata and ordering do not alter pixel thumbnails")
        XCTAssertTrue(engine.thumbnail(for: top) === original)
        engine.selectedLayerID = top.id
        stroke(engine, from: .init(8, 32), to: .init(56, 32))
        let ink = try await waitForThumbnail(engine, layer: top, after: count)
        XCTAssertFalse(ink === original)
        XCTAssertEqual(engine.thumbnailGenerationCount, count + 1)
        XCTAssertEqual(engine.thumbnailReadbackBytes - bytes, 80 * 80 * 4)
        XCTAssertTrue(try XCTUnwrap(ink.dataProvider?.data as Data?).contains { $0 != 0 })
        engine.undo()
        let blank = try await waitForThumbnail(engine, layer: top, after: count + 1)
        XCTAssertTrue(try XCTUnwrap(blank.dataProvider?.data as Data?).allSatisfy { $0 == 0 })
        engine.redo()
        _ = try await waitForThumbnail(engine, layer: top, after: count + 2)
        engine.failNextGPUCompletion = true
        _ = engine.thumbnail(for: base)
        XCTAssertTrue(engine.failNextGPUCompletion, "View reads must not wait for GPU completion")
        XCTAssertNil(engine.errorMessage)
        engine.failNextGPUCompletion = false
    }

    func testStartupAndAutosavePreserveOldUnreviewedRecoveries() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SumiPaintTests.OldRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let engine = try makeEngine(), snapshot = try engine.snapshot(), writer = RecoveryWriter()
        for index in 0..<7 {
            let url = folder.appendingPathComponent("old-\(index).sumipaint")
            try await writer.write(snapshot, revision: 1, to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400 - Double(index))], ofItemAtPath: url.path)
        }
        let originals = try RecoveryCatalog.entries(in: folder).map(\.url)
        let model = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
        defer { model.cancelRecoveryForTesting(); model.acknowledgeCleanExit() }
        XCTAssertEqual(Set(model.recoveryEntries.map(\.url)), Set(originals))
        XCTAssertNotNil(model.recoveryURL)
        let current = try XCTUnwrap(model.engine)
        try current.newDocument(width: 64, height: 64)
        stroke(current, from: .init(8, 32), to: .init(56, 32))
        let saved = await model.saveRecovery(); XCTAssertTrue(saved)
        XCTAssertEqual(try RecoveryCatalog.entries(in: folder).count, 8)
        for url in originals { XCTAssertEqual(try DocumentSnapshot.decode(Data(contentsOf: url)), snapshot) }
    }
    private func recoveryModel() throws -> (EditorModel, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SumiPaintTests.RecoveryModel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = EditorModel(recoveryFolder: folder, idleDelay: 0.02, maximumInterval: 0.06, defaults: defaults)
        _ = try XCTUnwrap(model.engine)
        addTeardownBlock { @MainActor in
            model.cancelRecoveryForTesting()
            _ = await model.saveRecovery()
            try? FileManager.default.removeItem(at: folder)
        }
        return (model, folder)
    }
    func testPristineCanvasDoesNotCreateRecoveryAndContinuousInkDoes() async throws {
        let (model, folder) = try recoveryModel(), engine = try XCTUnwrap(model.engine)
        let initiallySaved = await model.saveRecovery(); XCTAssertTrue(initiallySaved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try engine.newDocument(width: 64, height: 64)
        engine.brush.stabilization = 0
        engine.beginStroke(.init(point: .init(8, 32), time: 0, pressure: 1))
        for sample in 1...12 {
            engine.appendStroke(.init(point: .init(8 + Double(sample) * 3, 32), time: Double(sample), pressure: 1))
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(engine.strokeActive)
        let entries = try RecoveryCatalog.entries(in: folder)
        let url = try XCTUnwrap(entries.first?.url)
        let checkpoint = try DocumentSnapshot.decode(Data(contentsOf: url))
        XCTAssertTrue(checkpoint.layers[0].pixels.contains { $0 != 0 })
        engine.endStroke(); let saved = await model.saveRecovery(); XCTAssertTrue(saved)
        XCTAssertEqual(try DocumentSnapshot.decode(Data(contentsOf: url)), try engine.snapshot())
    }
    func testGPUFailureDoesNotOverwriteLastRecovery() async throws {
        let (model, folder) = try recoveryModel(), engine = try XCTUnwrap(model.engine)
        try engine.newDocument(width: 64, height: 64)
        stroke(engine, from: .init(10, 16), to: .init(54, 16))
        let saved = await model.saveRecovery(); XCTAssertTrue(saved)
        let url = try XCTUnwrap(RecoveryCatalog.entries(in: folder).first?.url), good = try Data(contentsOf: url)
        stroke(engine, from: .init(10, 48), to: .init(54, 48))
        engine.failNextGPUCompletion = true
        let failed = await model.saveRecovery(); XCTAssertFalse(failed)
        XCTAssertEqual(try Data(contentsOf: url), good)
    }
    func testCleanExitKeepsUnsavedArtworkWithoutRepeatingRecoveryAlert() async throws {
        let suite = "SumiPaintTests.Recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
        let engine = try XCTUnwrap(model.engine); try engine.newDocument(width: 64, height: 64)
        stroke(engine, from: .init(8, 32), to: .init(56, 32))
        let saved = await model.saveRecovery(); XCTAssertTrue(saved)
        let url = try XCTUnwrap(RecoveryCatalog.entries(in: folder).first?.url)
        // Quit an old unsaved version, then launch past every retention limit.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: url.path)
        model.refreshRecoveryEntries()
        model.cancelRecoveryForTesting(); model.acknowledgeCleanExit()
        XCTAssertFalse((defaults.dictionary(forKey: "recovery.acknowledged") ?? [:]).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let next = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
        XCTAssertNil(next.recoveryURL)
        // A newer checkpoint after the acknowledgement represents interrupted work.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
        let interrupted = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
        XCTAssertEqual(interrupted.recoveryURL, url)
        interrupted.restoreRecovery(url)
        while interrupted.fileBusy { await Task.yield() }
        let restored = try XCTUnwrap(interrupted.engine)
        XCTAssertEqual(try restored.snapshot().layers[0].pixels, try engine.snapshot().layers[0].pixels)
        stroke(restored, from: .init(8, 48), to: .init(56, 48))
        let resaved = await interrupted.saveRecovery(); XCTAssertTrue(resaved)
        interrupted.cancelRecoveryForTesting()
        XCTAssertEqual(try RecoveryCatalog.entries(in: folder).map(\.url), [url], "Restoring must reuse the checkpoint")
    }

    func testPromptActionsAndLegacyAcknowledgementsNeverDeleteUnsavedVersions() async throws {
        for action in ["dismiss", "choose", "restore"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suite = "SumiPaintTests.Prompt.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
            let snapshot = try makeEngine().snapshot(), writer = RecoveryWriter()
            for index in 0..<7 {
                let url = folder.appendingPathComponent("old-\(index).sumipaint")
                try await writer.write(snapshot, revision: 1, to: url)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400 - Double(index))], ofItemAtPath: url.path)
            }
            let originals = try RecoveryCatalog.entries(in: folder)
            // Existing installations may have marked every version as read.
            defaults.set(Dictionary(uniqueKeysWithValues: originals.map {
                ($0.url.standardizedFileURL.path, $0.modified.timeIntervalSince1970)
            }), forKey: "recovery.acknowledged")
            let legacy = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
            XCTAssertNil(legacy.recoveryURL)
            XCTAssertEqual(legacy.recoveryEntries.count, 7)
            legacy.acknowledgeCleanExit()
            defaults.removeObject(forKey: "recovery.acknowledged")
            let model = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
            defer { model.cancelRecoveryForTesting(); model.acknowledgeCleanExit() }
            let shown = try XCTUnwrap(model.recoveryURL)
            if action == "restore" {
                model.restoreRecovery(shown)
                while model.fileBusy { await Task.yield() }
            } else {
                model.dismissRecoveryPrompt()
                if action == "choose" { model.showRecoveryManager = true }
            }
            let read = try XCTUnwrap(defaults.dictionary(forKey: "recovery.acknowledged"))
            XCTAssertEqual(Set(read.keys), [shown.standardizedFileURL.path], "Only the displayed version was acknowledged")
            let engine = try XCTUnwrap(model.engine)
            stroke(engine, from: .init(8, 32), to: .init(56, 32))
            let saved = await model.saveRecovery(); XCTAssertTrue(saved)
            for entry in originals {
                XCTAssertTrue(FileManager.default.fileExists(atPath: entry.url.path))
                if action != "restore" || entry.url != shown {
                    XCTAssertEqual(try DocumentSnapshot.decode(Data(contentsOf: entry.url)), snapshot)
                }
            }
        }
    }
    func testAcknowledgementsKeepAllExistingFilesAndDropDeletedRecords() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "SumiPaintTests.ManyRecoveries.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let snapshot = try makeEngine().snapshot(), writer = RecoveryWriter(), now = Date()
        for index in 0..<33 {
            let url = folder.appendingPathComponent("\(index).sumipaint")
            try await writer.write(snapshot, revision: 1, to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(index))], ofItemAtPath: url.path)
        }
        let entries = try RecoveryCatalog.entries(in: folder), oldest = try XCTUnwrap(entries.last)
        let missing = folder.appendingPathComponent("missing.sumipaint").standardizedFileURL.path
        var read = Dictionary(uniqueKeysWithValues: entries.dropLast().map {
            ($0.url.standardizedFileURL.path, $0.modified.timeIntervalSince1970)
        })
        read[missing] = now.timeIntervalSince1970
        defaults.set(read, forKey: "recovery.acknowledged")
        let model = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
        defer { model.acknowledgeCleanExit() }
        XCTAssertEqual(model.recoveryURL, oldest.url)
        XCTAssertNil(defaults.dictionary(forKey: "recovery.acknowledged")?[missing])
        model.dismissRecoveryPrompt()
        XCTAssertEqual(defaults.dictionary(forKey: "recovery.acknowledged")?.count, 33)
        let next = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
        defer { next.acknowledgeCleanExit() }
        XCTAssertNil(next.recoveryURL, "The oldest of 33 acknowledged versions must stay acknowledged")
        XCTAssertEqual(next.recoveryEntries.count, 33, "Dismissing the prompt must not grant deletion permission")
        next.removeRecovery(oldest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.url.path))
        XCTAssertNil(defaults.dictionary(forKey: "recovery.acknowledged")?[oldest.url.standardizedFileURL.path])
        // Files deleted outside the application are also removed from the records.
        try FileManager.default.removeItem(at: entries[0].url)
        next.refreshRecoveryEntries()
        XCTAssertEqual(defaults.dictionary(forKey: "recovery.acknowledged")?.count, 31)
        XCTAssertEqual(next.recoveryEntries.count, 31)
    }

    func testRestoredVersionsBecomePrunableAfterSwitchOrRestartButNewEditsStayProtected() async throws {
        for action in ["switch", "restart", "edit", "failed"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suite = "SumiPaintTests.ResolvedRecovery.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
            let snapshot = try makeEngine().snapshot(), writer = RecoveryWriter()
            let restoredURL = folder.appendingPathComponent("restored.sumipaint")
            let untouchedURL = folder.appendingPathComponent("untouched.sumipaint")
            for url in [restoredURL, untouchedURL] {
                try await writer.write(snapshot, revision: 1, to: url)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: url.path)
            }
            if action == "failed" { try Data([0]).write(to: restoredURL) }
            let model = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
            defer { model.cancelRecoveryForTesting(); model.acknowledgeCleanExit() }
            model.restoreRecovery(restoredURL)
            while model.fileBusy { await Task.yield() }
            if action == "failed" {
                XCTAssertNotNil(model.engine?.errorMessage)
                XCTAssertTrue((defaults.dictionary(forKey: "recovery.resolved") ?? [:]).isEmpty)
                continue
            }
            XCTAssertEqual(try model.engine?.snapshot(), snapshot)
            XCTAssertNotNil(defaults.dictionary(forKey: "recovery.resolved")?[restoredURL.standardizedFileURL.path])
            XCTAssertTrue(FileManager.default.fileExists(atPath: restoredURL.path), "The active restored version is protected")
            if action == "edit" {
                stroke(try XCTUnwrap(model.engine), from: .init(8, 32), to: .init(56, 32))
                let saved = await model.saveRecovery(); XCTAssertTrue(saved)
                XCTAssertNil(defaults.dictionary(forKey: "recovery.resolved")?[restoredURL.standardizedFileURL.path])
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: restoredURL.path)
            }
            if action == "restart" {
                model.cancelRecoveryForTesting(); model.acknowledgeCleanExit()
                let next = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
                next.acknowledgeCleanExit()
            } else {
                model.newCanvas(width: 64, height: 64)
                while model.fileBusy { await Task.yield() }
            }
            XCTAssertEqual(FileManager.default.fileExists(atPath: restoredURL.path), action == "edit")
            XCTAssertEqual(try DocumentSnapshot.decode(Data(contentsOf: untouchedURL)), snapshot, "Unreviewed versions survive pruning")
            if action != "edit" {
                XCTAssertNil(defaults.dictionary(forKey: "recovery.resolved")?[restoredURL.standardizedFileURL.path])
                XCTAssertNil(defaults.dictionary(forKey: "recovery.acknowledged")?[restoredURL.standardizedFileURL.path])
            }
        }
    }

    func testRecoveryStorageWarningKeepsUnreviewedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "SumiPaintTests.RecoveryStorage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = folder.appendingPathComponent("large.sumipaint")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: 256 * 1024 * 1024)
        let model = EditorModel(recoveryFolder: folder, defaults: defaults)
        defer { model.acknowledgeCleanExit() }
        XCTAssertTrue(model.recoveryStorageNeedsAttention)
        XCTAssertEqual(model.recoveryEntries.map { $0.url.standardizedFileURL }, [url.standardizedFileURL])
        model.removeRecovery(try XCTUnwrap(model.recoveryEntries.first))
        XCTAssertFalse(model.recoveryStorageNeedsAttention)
    }

    func testSuccessfulDocumentExportRemovesOnlyMatchingRecovery() async throws {
        let (model, folder) = try recoveryModel(), engine = try XCTUnwrap(model.engine)
        try engine.newDocument(width: 64, height: 64)
        stroke(engine, from: .init(8, 32), to: .init(56, 32))
        let saved = await model.saveRecovery(); XCTAssertTrue(saved)
        XCTAssertEqual(try RecoveryCatalog.entries(in: folder).count, 1)
        model.prepareExport(png: false)
        while model.fileBusy { await Task.yield() }
        let destination = folder.appendingPathComponent("exported.document")
        try XCTUnwrap(model.exportFile).data.write(to: destination)
        model.handleExport(.success(destination))
        for _ in 0..<100 {
            if try RecoveryCatalog.entries(in: folder).isEmpty { break }
            await Task.yield()
        }
        XCTAssertTrue(try RecoveryCatalog.entries(in: folder).isEmpty)
        let noMoreRecovery = await model.saveRecovery(); XCTAssertTrue(noMoreRecovery)
        XCTAssertTrue(try RecoveryCatalog.entries(in: folder).isEmpty)
        stroke(engine, from: .init(8, 48), to: .init(56, 48))
        let changed = await model.saveRecovery(); XCTAssertTrue(changed)
        model.prepareExport(png: false)
        while model.fileBusy { await Task.yield() }
        stroke(engine, from: .init(8, 16), to: .init(56, 16))
        let newer = await model.saveRecovery(); XCTAssertTrue(newer)
        model.handleExport(.success(destination))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(try RecoveryCatalog.entries(in: folder).count, 1, "Export of an older revision must preserve newer edits")
        model.prepareExport(png: true)
        while model.fileBusy { await Task.yield() }
        model.handleExport(.success(destination))
        await Task.yield()
        XCTAssertEqual(try RecoveryCatalog.entries(in: folder).count, 1, "PNG does not preserve an editable document")
    }

    func testOpeningRecoveryInAnotherWindowDoesNotOverwriteActiveCheckpoint() async throws {
        let (model, folder) = try recoveryModel(), engine = try XCTUnwrap(model.engine)
        try engine.newDocument(width: 64, height: 64)
        stroke(engine, from: .init(8, 16), to: .init(56, 16))
        let saved = await model.saveRecovery(); XCTAssertTrue(saved)
        let url = try XCTUnwrap(RecoveryCatalog.entries(in: folder).first?.url)
        let original = try Data(contentsOf: url)
        let suite = "SumiPaintTests.SecondWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let second = EditorModel(recoveryFolder: folder, idleDelay: 100, defaults: defaults)
        second.restoreRecovery(url)
        while second.fileBusy { await Task.yield() }
        stroke(try XCTUnwrap(second.engine), from: .init(8, 48), to: .init(56, 48))
        let savedSecond = await second.saveRecovery(); XCTAssertTrue(savedSecond)
        second.cancelRecoveryForTesting()
        XCTAssertEqual(try RecoveryCatalog.entries(in: folder).count, 2)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

}
