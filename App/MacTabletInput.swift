#if os(macOS)
import SwiftUI
import AppKit

enum TabletButtonAction: String, CaseIterable, Identifiable {
    case holdEyedropper, holdHand, holdEraser, toggleEraser, undo, redo, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .holdEyedropper: return "押している間スポイト"
        case .holdHand: return "押している間キャンバス移動"
        case .holdEraser: return "押している間消しゴム"
        case .toggleEraser: return "描画ツールと消しゴムを切り替え"
        case .undo: return "元に戻す"
        case .redo: return "やり直す"
        case .none: return "割り当てなし"
        }
    }
    var heldTool: EditorTool? {
        switch self {
        case .holdEyedropper: return .eyedropper
        case .holdHand: return .hand
        case .holdEraser: return .eraser
        default: return nil
        }
    }
}

@MainActor
final class MacTabletSettings: ObservableObject {
    static let shared = MacTabletSettings()
    private let defaults: UserDefaults
    @Published var rightAction: TabletButtonAction {
        didSet { defaults.set(rightAction.rawValue, forKey: "tablet.rightAction") }
    }
    @Published var middleAction: TabletButtonAction {
        didSet { defaults.set(middleAction.rawValue, forKey: "tablet.middleAction") }
    }
    @Published var automaticEraser: Bool {
        didSet { defaults.set(automaticEraser, forKey: "tablet.automaticEraser") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rightAction = defaults.string(forKey: "tablet.rightAction").flatMap(TabletButtonAction.init(rawValue:)) ?? .holdEyedropper
        middleAction = defaults.string(forKey: "tablet.middleAction").flatMap(TabletButtonAction.init(rawValue:)) ?? .holdHand
        automaticEraser = defaults.object(forKey: "tablet.automaticEraser") as? Bool ?? true
    }
    func action(for button: Int) -> TabletButtonAction {
        button == 1 ? rightAction : button == 2 ? middleAction : .none
    }
}

private struct CanvasToolMode: Equatable, Sendable {
    var tool: EditorTool
    var brush: BrushSettings
}

@MainActor
final class MacCanvasToolState {
    private let engine: PaintEngine
    private let pointer: CanvasPointer
    private var modes: InputModeStack<CanvasToolMode>
    init(engine: PaintEngine, pointer: CanvasPointer) {
        self.engine = engine; self.pointer = pointer
        let initial = CanvasToolMode(tool: engine.tool, brush: engine.brush)
        modes = .init(baseMode: initial)
    }
    private func synchronizeSelection() {
        if !modes.hasOverrides || engine.tool != modes.currentMode.tool {
            modes.reset(to: .init(tool: engine.tool, brush: engine.brush))
        }
    }
    private func apply(_ mode: CanvasToolMode) {
        guard engine.tool != mode.tool || engine.brush != mode.brush else { return }
        // Commit the current segment before changing tools; never join drawing across navigation.
        pointer.end()
        engine.tool = mode.tool; engine.brush = mode.brush
        engine.requestDisplay?()
    }
    func press(_ source: String, tool: EditorTool) {
        guard !engine.isBusy else { return }
        synchronizeSelection()
        var mode = modes.baseMode
        mode.tool = tool
        if tool == .eraser { mode.brush.kind = .eraser }
        modes.press(source, mode: mode); apply(modes.currentMode)
    }
    func release(_ source: String) {
        synchronizeSelection(); modes.release(source); apply(modes.currentMode)
    }
    func select(_ tool: EditorTool) {
        guard !engine.isBusy else { return }
        synchronizeSelection()
        let base = modes.baseMode
        modes.reset(to: base); apply(base); pointer.end()
        engine.setTool(tool)
        modes.reset(to: .init(tool: engine.tool, brush: engine.brush))
    }
    func toggleEraser() {
        guard !engine.isBusy else { return }
        synchronizeSelection()
        if modes.baseMode.tool == .eraser {
            let drawingMode = CanvasToolMode(tool: engine.rememberedDrawingTool, brush: engine.rememberedDrawingBrush)
            pointer.end(); modes.reset(to: drawingMode); apply(drawingMode)
        } else {
            select(.eraser)
        }
    }
    func reset() {
        pointer.end(cancelled: true)
        synchronizeSelection()
        let base = modes.baseMode
        modes.reset(to: base); apply(base)
    }
}

struct MacTabletPanel: View {
    @ObservedObject private var settings = MacTabletSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("ペンボタン").font(.headline)
                actionPicker("右クリックに割り当てたボタン", selection: $settings.rightAction)
                actionPicker("中クリックに割り当てたボタン", selection: $settings.middleAction)
                Text("Wacom CenterでSumi Paint用の設定を作り、ペンボタンに「右クリック」「中クリック」を割り当ててください。通常のマウスにも同じ操作が適用されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("ペンの反転").font(.headline)
                Toggle("消しゴム側で自動切り替え", isOn: $settings.automaticEraser)
                Text("対応ペンが消しゴム側の入力を送ると切り替わり、戻すと元のツールとブラシ設定に戻ります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("キーを割り当てる場合").font(.headline)
                Text("B: ペン　P: 鉛筆　E: 消しゴム　H: 移動\nX: 描画ツールと消しゴムを切り替え\nSpace: 押している間移動　Option: 押している間スポイト\nCommand-Z: 元に戻す　Command-Shift-Z: やり直す")
                    .font(.caption)
                Text("文字入力中は文字入力を優先します。ボタンを使う前にキャンバスをクリックしてください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func actionPicker(_ title: String, selection: Binding<TabletButtonAction>) -> some View {
        Picker(title, selection: selection) {
            ForEach(TabletButtonAction.allCases) { action in Text(action.title).tag(action) }
        }
    }
}
#endif
