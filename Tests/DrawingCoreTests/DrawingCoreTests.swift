import XCTest
@testable import DrawingCore

final class DrawingCoreTests: XCTestCase {
    func testStrokeSpacingDoesNotDependOnEventDensity() {
        var brush = BrushSettings(); brush.stabilization = 0; brush.size = 10; brush.spacing = 0.2
        func line(steps: Int) -> [BrushDab] {
            var processor = StrokeProcessor(settings: brush)
            return (0...steps).flatMap { step in
                processor.append(.init(point: .init(Double(step) * 100 / Double(steps), 5), time: Double(step) / Double(steps)))
            }
        }
        XCTAssertEqual(line(steps: 1).count, line(steps: 100).count)
        for (a, b) in zip(line(steps: 1), line(steps: 100)) {
            XCTAssertEqual(a.point.x, b.point.x, accuracy: 0.00001)
        }
    }
    func testPressureAndMouseFallback() {
        var brush = BrushSettings(); brush.size = 20
        var light = StrokeProcessor(settings: brush), heavy = StrokeProcessor(settings: brush), mouse = StrokeProcessor(settings: brush)
        let low = light.append(.init(point: .init(0, 0), time: 0, pressure: 0.1))[0]
        let high = heavy.append(.init(point: .init(0, 0), time: 0, pressure: 1))[0]
        let fallback = mouse.append(.init(point: .init(0, 0), time: 0))[0]
        XCTAssertLessThan(low.radius, high.radius)
        XCTAssertEqual(fallback.radius, high.radius)
    }
    func testStabilizationFinishesAtActualEndpoint() {
        var brush = BrushSettings(); brush.stabilization = 1
        var stroke = StrokeProcessor(settings: brush)
        _ = stroke.append(.init(point: .init(0, 0), time: 0))
        let moving = stroke.append(.init(point: .init(100, 0), time: 0.01))
        XCTAssertLessThan(moving.last?.point.x ?? 0, 100)
        XCTAssertEqual(stroke.finish().last?.point, .init(100, 0))
    }
    func testInvalidAndOutOfOrderInputIsIgnored() {
        var stroke = StrokeProcessor(settings: .init())
        XCTAssertTrue(stroke.append(.init(point: .init(.nan, 0), time: 1)).isEmpty)
        XCTAssertFalse(stroke.append(.init(point: .init(0, 0), time: 2)).isEmpty)
        XCTAssertTrue(stroke.append(.init(point: .init(50, 0), time: 1)).isEmpty)
    }
    func testViewportRoundTripAndZoomAnchor() {
        var view = CanvasViewport(); view.viewWidth = 600; view.viewHeight = 800
        view.pan = .init(22, -17); view.zoom = 2.3; view.angle = 0.7; view.mirrored = true
        let point = PaintPoint(100, 300), screen = view.viewPoint(from: point)
        let roundtrip = view.documentPoint(from: screen)
        XCTAssertEqual(roundtrip.x, point.x, accuracy: 0.00001)
        XCTAssertEqual(roundtrip.y, point.y, accuracy: 0.00001)
        view.zoom(by: 1.5, around: screen)
        let anchored = view.documentPoint(from: screen)
        XCTAssertEqual(anchored.x, point.x, accuracy: 0.00001)
        XCTAssertEqual(anchored.y, point.y, accuracy: 0.00001)
    }
    func testSelectionUsesPixelCentersAndClipsToCanvas() {
        let mask = RasterOperations.selection(width: 4, height: 4,
            polygon: [.init(-1, -1), .init(2, -1), .init(2, 2), .init(-1, 2)])
        XCTAssertEqual(mask.filter { $0 == 255 }.count, 4)
        XCTAssertEqual(mask[0], 255); XCTAssertEqual(mask[2], 0)
    }
    func testFloodFillDoesNotCrossBoundaryOrSelection() {
        var pixels = [UInt8](repeating: 0, count: 5 * 3 * 4)
        for y in 0..<3 { pixels[(y * 5 + 2) * 4 + 3] = 255 }
        RasterOperations.floodFill(pixels: &pixels, width: 5, height: 3, x: 0, y: 1,
                                  color: .init(1, 0, 0), tolerance: 0, mask: nil, alphaLocked: false)
        XCTAssertEqual(pixels[0], 255); XCTAssertEqual(pixels[4 * 4], 0)
        let mask: [UInt8] = [0, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        RasterOperations.floodFill(pixels: &pixels, width: 5, height: 3, x: 4, y: 0,
                                  color: .init(0, 1, 0), tolerance: 0, mask: mask, alphaLocked: false)
        XCTAssertEqual(pixels[4 * 4 + 1], 255); XCTAssertEqual(pixels[9 * 4 + 1], 0)
    }
    func testIdentityAndTranslationTransform() {
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        pixels.replaceSubrange(20..<24, with: [128, 0, 0, 128])
        var mask = [UInt8](repeating: 0, count: 16); mask[5] = 255
        let identity = RasterOperations.transform(pixels: pixels, mask: mask, width: 4, height: 4,
            translation: .init(0, 0), scale: 1, angle: 0)
        XCTAssertEqual(identity.pixels, pixels); XCTAssertEqual(identity.mask, mask)
        let moved = RasterOperations.transform(pixels: pixels, mask: mask, width: 4, height: 4,
            translation: .init(1, 0), scale: 1, angle: 0)
        XCTAssertEqual(Array(moved.pixels[20..<24]), [0, 0, 0, 0])
        XCTAssertEqual(Array(moved.pixels[24..<28]), [128, 0, 0, 128])
    }
    func testDocumentRoundTripAndBounds() throws {
        let properties = LayerProperties(name: "線画")
        let layer = LayerSnapshot(properties: properties, pixels: Data(repeating: 0, count: 16))
        let document = DocumentSnapshot(width: 2, height: 2, layers: [layer], selectedLayerID: properties.id)
        XCTAssertEqual(try DocumentSnapshot.decode(document.encoded()), document)
        var invalid = document; invalid.width = Int.max
        XCTAssertThrowsError(try invalid.validate())
        invalid = document; invalid.layers.append(layer)
        XCTAssertThrowsError(try invalid.validate())
        invalid = document; invalid.version = 99
        XCTAssertThrowsError(try invalid.validate())
        invalid = document; invalid.layers[0].pixels[0] = 255
        XCTAssertThrowsError(try invalid.validate())
    }
    func testCorruptFileFailsRatherThanReturningPartialDocument() {
        XCTAssertThrowsError(try DocumentSnapshot.decode(Data("not a painting".utf8)))
    }
}
