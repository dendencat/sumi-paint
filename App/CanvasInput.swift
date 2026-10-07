import SwiftUI
import MetalKit

/// Translates platform input to document-space samples. View gestures never modify the painting.
@MainActor
final class CanvasPointer {
    let engine: PaintEngine
    var start: PaintPoint?
    var polygon: [PaintPoint] = []
    var moving = false
    var lastViewPoint: PaintPoint?
    var lastPressure: Double?
    var onPath: (([PaintPoint]) -> Void)?
    init(engine: PaintEngine) { self.engine = engine }
    func begin(point: PaintPoint, time: Double, pressure: Double?, navigation: Bool = false) {
        guard !engine.isBusy else { return }
        start = engine.viewport.documentPoint(from: point); lastViewPoint = point; lastPressure = pressure
        moving = navigation || engine.tool == .hand
        guard !moving, let start else { return }
        switch engine.tool {
        case .pen, .pencil, .eraser: engine.beginStroke(.init(point: start, time: time, pressure: pressure))
        case .fill: engine.fill(at: start)
        case .eyedropper: engine.pickColor(at: start)
        case .rectangle, .lasso: polygon = [start]; onPath?(polygon)
        case .hand: break
        }
    }
    func move(point: PaintPoint, time: Double, pressure: Double?) {
        guard start != nil, !engine.isBusy else { return }
        lastPressure = pressure
        if moving {
            if let last = lastViewPoint { engine.viewport.pan.x += point.x - last.x; engine.viewport.pan.y += point.y - last.y }
            lastViewPoint = point; engine.requestDisplay?(); return
        }
        let documentPoint = engine.viewport.documentPoint(from: point)
        switch engine.tool {
        case .pen, .pencil, .eraser: engine.appendStroke(.init(point: documentPoint, time: time, pressure: pressure))
        case .rectangle:
            if let start { polygon = [start, .init(documentPoint.x, start.y), documentPoint, .init(start.x, documentPoint.y)]; onPath?(polygon) }
        case .lasso:
            if polygon.last?.distance(to: documentPoint) ?? 0 > 1 { polygon.append(documentPoint); onPath?(polygon) }
        case .eyedropper: engine.pickColor(at: documentPoint)
        default: break
        }
    }
    func end(cancelled: Bool = false) {
        if engine.strokeActive { engine.endStroke(cancelled: cancelled) }
        if !cancelled, !moving, (engine.tool == .rectangle || engine.tool == .lasso), polygon.count >= 3 {
            engine.select(polygon: polygon)
        }
        start = nil; polygon = []; moving = false; lastViewPoint = nil; lastPressure = nil; onPath?([])
    }
}

struct PaintCanvas: View {
    @ObservedObject var engine: PaintEngine
    @State private var selectionPath: [PaintPoint] = []
    var body: some View {
        NativeCanvas(engine: engine, onPath: { selectionPath = $0 })
            .overlay {
                if selectionPath.count > 1 {
                    Path { path in
                        let points = selectionPath.map { engine.viewport.viewPoint(from: $0) }
                        path.move(to: CGPoint(x: points[0].x, y: points[0].y))
                        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
                        if engine.tool == .rectangle { path.closeSubpath() }
                    }.stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).allowsHitTesting(false)
                }
            }
            .overlay {
                if engine.isBusy { ProgressView("処理中…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
            }
            .accessibilityLabel("描画キャンバス")
    }
}

#if os(iOS)
import UIKit

struct NativeCanvas: UIViewRepresentable {
    let engine: PaintEngine
    let onPath: ([PaintPoint]) -> Void
    func makeUIView(context: Context) -> TouchCanvas {
        let view = TouchCanvas(engine: engine); view.pointer.onPath = onPath
        return view
    }
    func updateUIView(_ view: TouchCanvas, context: Context) {
        view.pointer.onPath = onPath; view.setNeedsDisplay()
    }
}

final class TouchCanvas: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate {
    let engine: PaintEngine
    let pointer: CanvasPointer
    private weak var activeTouch: UITouch?
    private var lastSize = CGSize.zero
    init(engine: PaintEngine) {
        self.engine = engine; pointer = CanvasPointer(engine: engine)
        super.init(frame: .zero, device: engine.device)
        colorPixelFormat = .bgra8Unorm; framebufferOnly = true
        isPaused = true; enableSetNeedsDisplay = true; delegate = self
        isMultipleTouchEnabled = true
        engine.requestDisplay = { [weak self] in self?.setNeedsDisplay() }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
        let onePan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        onePan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotate(_:)))
        let undo = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap))
        undo.numberOfTouchesRequired = 2
        for recognizer in [pan, onePan, pinch, rotate, undo] {
            recognizer.delegate = self
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            addGestureRecognizer(recognizer)
        }
    }
    required init(coder: NSCoder) { fatalError("Interface Builder is not used") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        let first = lastSize == .zero; lastSize = bounds.size
        engine.viewport.viewWidth = Double(bounds.width); engine.viewport.viewHeight = Double(bounds.height)
        if first { engine.viewport.fit() }
        setNeedsDisplay()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) { engine.render(in: view) }
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard !engine.isBusy else { return false }
        if let pan = recognizer as? UIPanGestureRecognizer, pan.maximumNumberOfTouches == 1 {
            return engine.tool == .hand || !engine.fingerDrawing
        }
        return true
    }
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(recognizer is UITapGestureRecognizer) && !(other is UITapGestureRecognizer)
    }
    @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { pointer.end(cancelled: true); activeTouch = nil }
        let translation = recognizer.translation(in: self)
        engine.viewport.pan.x += Double(translation.x); engine.viewport.pan.y += Double(translation.y)
        recognizer.setTranslation(.zero, in: self); setNeedsDisplay()
    }
    @objc private func pinch(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began { pointer.end(cancelled: true); activeTouch = nil }
        let anchor = recognizer.location(in: self)
        engine.viewport.zoom(by: Double(recognizer.scale), around: .init(Double(anchor.x), Double(anchor.y)))
        recognizer.scale = 1; setNeedsDisplay()
    }
    @objc private func rotate(_ recognizer: UIRotationGestureRecognizer) {
        if recognizer.state == .began { pointer.end(cancelled: true); activeTouch = nil }
        engine.viewport.angle += Double(recognizer.rotation); recognizer.rotation = 0; setNeedsDisplay()
    }
    @objc private func twoFingerTap() { pointer.end(cancelled: true); activeTouch = nil; engine.undo() }
    private func pressure(_ touch: UITouch) -> Double? {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0, touch.force > 0 else { return nil }
        return min(1, Double(touch.force / touch.maximumPossibleForce))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, !engine.isBusy,
              let touch = touches.first(where: { $0.type == .pencil || engine.fingerDrawing }),
              engine.tool != .hand else { return }
        activeTouch = touch
        let point = touch.location(in: self)
        pointer.begin(point: .init(Double(point.x), Double(point.y)), time: touch.timestamp, pressure: pressure(touch))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        for touch in event?.coalescedTouches(for: activeTouch) ?? [activeTouch] {
            let point = touch.location(in: self)
            pointer.move(point: .init(Double(point.x), Double(point.y)), time: touch.timestamp, pressure: pressure(touch))
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let point = touch.location(in: self)
        // Release pressure can fall to zero; preserve the last sampled pressure for the tail.
        pointer.move(point: .init(Double(point.x), Double(point.y)), time: touch.timestamp, pressure: pointer.lastPressure)
        pointer.end(); activeTouch = nil
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        pointer.end(cancelled: true); activeTouch = nil
    }
}
#else
import AppKit

struct NativeCanvas: NSViewRepresentable {
    let engine: PaintEngine
    let onPath: ([PaintPoint]) -> Void
    func makeNSView(context: Context) -> MouseCanvas {
        let view = MouseCanvas(engine: engine); view.pointer.onPath = onPath
        return view
    }
    func updateNSView(_ view: MouseCanvas, context: Context) { view.pointer.onPath = onPath; view.needsDisplay = true }
}

final class MouseCanvas: MTKView, MTKViewDelegate {
    let engine: PaintEngine
    let pointer: CanvasPointer
    private var lastSize = CGSize.zero
    private var spaceDown = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(engine: PaintEngine) {
        self.engine = engine; pointer = CanvasPointer(engine: engine)
        super.init(frame: .zero, device: engine.device)
        colorPixelFormat = .bgra8Unorm; framebufferOnly = true
        isPaused = true; enableSetNeedsDisplay = true; delegate = self
        engine.requestDisplay = { [weak self] in self?.needsDisplay = true }
    }
    required init(coder: NSCoder) { fatalError("Interface Builder is not used") }
    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        let first = lastSize == .zero; lastSize = bounds.size
        engine.viewport.viewWidth = Double(bounds.width); engine.viewport.viewHeight = Double(bounds.height)
        if first { engine.viewport.fit() }
        needsDisplay = true
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) { engine.render(in: view) }
    private func point(_ event: NSEvent) -> PaintPoint {
        let value = convert(event.locationInWindow, from: nil)
        return .init(Double(value.x), Double(value.y))
    }
    private func pressure(_ event: NSEvent) -> Double? {
        event.subtype == .tabletPoint || event.type == .tabletPoint ? Double(event.pressure) : nil
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) { engine.pickColor(at: engine.viewport.documentPoint(from: point(event))); return }
        pointer.begin(point: point(event), time: event.timestamp, pressure: pressure(event), navigation: spaceDown)
    }
    override func mouseDragged(with event: NSEvent) { pointer.move(point: point(event), time: event.timestamp, pressure: pressure(event)) }
    override func mouseUp(with event: NSEvent) {
        pointer.move(point: point(event), time: event.timestamp, pressure: pointer.lastPressure)
        pointer.end()
    }
    override func tabletPoint(with event: NSEvent) {
        if pointer.start != nil { pointer.move(point: point(event), time: event.timestamp, pressure: Double(event.pressure)) }
    }
    override func scrollWheel(with event: NSEvent) {
        guard !engine.strokeActive, !engine.isBusy else { return }
        if event.modifierFlags.contains(.command) {
            engine.viewport.zoom(by: exp(Double(event.scrollingDeltaY) * 0.01), around: point(event))
        } else {
            engine.viewport.pan.x += Double(event.scrollingDeltaX); engine.viewport.pan.y += Double(event.scrollingDeltaY)
        }
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard !engine.strokeActive else { return }
        engine.viewport.zoom(by: max(0.1, 1 + Double(event.magnification)), around: point(event)); needsDisplay = true
    }
    override func rotate(with event: NSEvent) {
        guard !engine.strokeActive else { return }
        engine.viewport.angle += Double(event.rotation) * .pi / 180; needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = true; return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": engine.setTool(.pen); case "p": engine.setTool(.pencil); case "e": engine.setTool(.eraser)
        case "g": engine.setTool(.fill); case "i": engine.setTool(.eyedropper); case "h": engine.setTool(.hand)
        case "[": engine.brush.size = max(1, engine.brush.size - 2)
        case "]": engine.brush.size = min(512, engine.brush.size + 2)
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceDown = false } else { super.keyUp(with: event) } }
    override func resignFirstResponder() -> Bool { spaceDown = false; pointer.end(cancelled: true); return super.resignFirstResponder() }
}
#endif
