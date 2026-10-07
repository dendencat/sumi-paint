import SwiftUI

private enum EditorPanel: String, Identifiable {
    case brush, color, layers, transform
    #if os(macOS)
    case tablet
    #endif
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brush: return "ブラシ"
        case .color: return "色"
        case .layers: return "レイヤー"
        case .transform: return "選択範囲の変形"
        #if os(macOS)
        case .tablet: return "ペンタブのボタン"
        #endif
        }
    }
}

struct EditorRoot: View {
    @StateObject private var model = EditorModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var panel: EditorPanel?
    var body: some View {
        Group {
            if let engine = model.engine {
                EditorWorkspace(model: model, engine: engine, panel: $panel)
                    .alert("操作を完了できませんでした", isPresented: Binding(
                        get: { engine.errorMessage != nil }, set: { if !$0 { engine.errorMessage = nil } })) {
                            Button("OK") { engine.errorMessage = nil }
                        } message: { Text(engine.errorMessage ?? "") }
            } else {
                ContentUnavailableView("描画を開始できません", systemImage: "exclamationmark.triangle",
                    description: Text(model.startupError ?? "Metalに対応した端末を使用してください。"))
            }
        }
        .tint(.mint)
        .focusedSceneValue(\.paintEditor, model)
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: model.importTypes,
                      allowsMultipleSelection: false, onCompletion: model.handleImport)
        .fileExporter(isPresented: $model.showExporter, document: model.exportFile,
                      contentType: model.exportType, defaultFilename: model.exportName, onCompletion: model.handleExport)
        .sheet(isPresented: $model.showNewCanvas) { NewCanvasSheet(model: model) }
        .sheet(item: $panel) { value in
            if let engine = model.engine {
                NavigationStack {
                    ScrollView {
                        Group {
                            switch value {
                            case .brush: BrushPanel(engine: engine)
                            case .color: ColorPanel(engine: engine)
                            case .layers: LayerPanel(engine: engine)
                            case .transform: TransformPanel(engine: engine, close: { panel = nil })
                            #if os(macOS)
                            case .tablet: MacTabletPanel()
                            #endif
                            }
                        }.padding(20)
                    }
                    .navigationTitle(value.title)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { panel = nil } } }
                }
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
                .frame(minWidth: 300, minHeight: 360)
            }
        }
        .alert("前回の作業が見つかりました", isPresented: Binding(
            get: { model.recoveryURL != nil }, set: { if !$0 { model.recoveryURL = nil } }), presenting: model.recoveryURL) { url in
                Button("復元する") { model.restoreRecovery(url) }
                Button("新しく始める", role: .cancel) { model.recoveryURL = nil }
            } message: { _ in Text("自動保存した作品を開けます。復旧ファイルはアプリの保存領域に残ります。") }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.engine?.endStroke()
                Task { await model.saveRecovery() }
            }
        }
    }
}

private struct EditorWorkspace: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var engine: PaintEngine
    @Binding var panel: EditorPanel?
    private let panelColor = Color(red: 0.10, green: 0.11, blue: 0.14)
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Divider()
                #if os(macOS)
                desktop
                #else
                if geometry.size.width >= 850 {
                    HStack(spacing: 0) {
                        ScrollView { ToolStrip(engine: engine, vertical: true) }.frame(width: 62).background(panelColor)
                        PaintCanvas(engine: engine).allowsHitTesting(!model.fileBusy)
                        ScrollView {
                            ColorPanel(engine: engine); Divider().padding(.vertical)
                            BrushPanel(engine: engine); Divider().padding(.vertical)
                            LayerPanel(engine: engine)
                        }.padding(14).frame(width: 250).background(panelColor)
                    }
                } else {
                    PaintCanvas(engine: engine).allowsHitTesting(!model.fileBusy)
                    quickBrush
                    ScrollView(.horizontal, showsIndicators: false) { ToolStrip(engine: engine, vertical: false).padding(.horizontal, 8) }
                        .background(panelColor)
                    HStack {
                        panelButton("ブラシ", icon: "slider.horizontal.3", value: .brush)
                        panelButton("色", icon: "circle.lefthalf.filled", value: .color)
                        panelButton("レイヤー", icon: "square.3.layers.3d", value: .layers)
                    }.padding(.horizontal, 12).padding(.vertical, 6).background(panelColor)
                }
                #endif
                footer
            }
            .background(panelColor)
            .disabled(model.fileBusy)
        }
    }
    private var desktop: some View {
        HStack(spacing: 0) {
            if !engine.leftHanded { leftPanel }
            PaintCanvas(engine: engine).allowsHitTesting(!model.fileBusy)
            if engine.leftHanded { leftPanel }
            ScrollView { LayerPanel(engine: engine).padding(14) }.frame(width: 240).background(panelColor)
        }
    }
    private var leftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("TOOLS").font(.caption).foregroundStyle(.secondary)
                ToolStrip(engine: engine, vertical: false)
                Divider(); ColorPanel(engine: engine); Divider(); BrushPanel(engine: engine)
            }.padding(14)
        }.frame(width: 220).background(panelColor)
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "paintbrush.pointed.fill").foregroundStyle(.mint)
            Text("Sumi Paint").font(.headline)
            Spacer(minLength: 4)
            Button { engine.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!engine.canUndo || engine.strokeActive || engine.isBusy || model.fileBusy).help("元に戻す")
                .accessibilityLabel("元に戻す")
            Button { engine.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!engine.canRedo || engine.strokeActive || engine.isBusy || model.fileBusy).help("やり直す")
                .accessibilityLabel("やり直す")
            Menu {
                Button("新しいキャンバス", systemImage: "doc.badge.plus") { model.showNewCanvas = true }
                Button("作品を開く", systemImage: "folder") { model.requestImport(image: false) }
                Button("画像を読み込む", systemImage: "photo") { model.requestImport(image: true) }
                Divider()
                Button("作品を保存", systemImage: "square.and.arrow.down") { model.prepareExport(png: false) }
                Button("PNGを書き出す", systemImage: "square.and.arrow.up") { model.prepareExport(png: true) }
                Divider()
                Button("全体を表示", systemImage: "arrow.up.left.and.arrow.down.right") { engine.viewport.fit(); engine.requestDisplay?() }
                Button("左右反転表示", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { engine.viewport.mirrored.toggle(); engine.requestDisplay?() }
                Toggle("透明部分をチェック柄で表示", isOn: $engine.checkerboard)
                Toggle("左利き用の配置", isOn: $engine.leftHanded)
                #if os(iOS)
                Toggle("指で描く", isOn: $engine.fingerDrawing)
                #else
                Button("ペンタブのボタン設定", systemImage: "pencil.tip.crop.circle") { panel = .tablet }
                #endif
                Divider()
                Button("すべて選択") { engine.selectAll() }
                Button("選択を解除") { engine.clearSelection() }.disabled(!engine.hasSelection)
                Button("選択範囲を変形") { panel = .transform }.disabled(!engine.hasSelection)
                Button("選択した画素を消去", role: .destructive) { engine.clearSelectedPixels() }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .disabled(engine.isBusy || engine.strokeActive || model.fileBusy)
                .accessibilityLabel("作品とキャンバスのメニュー")
        }
        .buttonStyle(.borderless).font(.body)
        .padding(.horizontal, 14).frame(height: 48)
    }
    private var quickBrush: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: engine.color.red, green: engine.color.green, blue: engine.color.blue))
                .frame(width: 24, height: 24).onTapGesture { panel = .color }.accessibilityLabel("現在の色")
            Text("\(Int(engine.brush.size))px").font(.caption.monospacedDigit()).frame(width: 42)
            Slider(value: $engine.brush.size, in: 1...200, step: 1).accessibilityLabel("ブラシサイズ")
            Text("\(Int(engine.brush.opacity * 100))%").font(.caption.monospacedDigit()).frame(width: 36)
            Slider(value: $engine.brush.opacity, in: 0.01...1).frame(maxWidth: 100).accessibilityLabel("不透明度")
        }.padding(.horizontal, 12).frame(height: 40).background(panelColor)
    }
    private func panelButton(_ title: String, icon: String, value: EditorPanel) -> some View {
        Button { panel = value } label: { Label(title, systemImage: icon).font(.caption).frame(maxWidth: .infinity, minHeight: 30) }
            .buttonStyle(.borderless)
    }
    private var footer: some View {
        HStack {
            Text("\(engine.width) × \(engine.height)")
            Text("\(Int(engine.viewport.zoom * 100))%").monospacedDigit()
            Spacer()
            if model.fileBusy { ProgressView().controlSize(.small) }
            Text(model.status).lineLimit(1)
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 24)
    }
}

struct ToolStrip: View {
    @ObservedObject var engine: PaintEngine
    var vertical: Bool
    var body: some View {
        let columns = vertical ? [GridItem(.fixed(52))] : [GridItem(.adaptive(minimum: 44))]
        Group {
            if vertical {
                VStack(spacing: 6) { buttons }
            } else {
                #if os(macOS)
                LazyVGrid(columns: columns, spacing: 6) { buttons }
                #else
                HStack(spacing: 4) { buttons }
                #endif
            }
        }.padding(.vertical, 8).disabled(engine.isBusy)
    }
    private var buttons: some View {
        ForEach(EditorTool.allCases, id: \.self) { tool in
            Button { engine.setTool(tool) } label: {
                VStack(spacing: 4) {
                    Image(systemName: tool.icon).font(.system(size: 19))
                    Text(tool.title).font(.system(size: 9)).lineLimit(1)
                }.frame(width: 46, height: 46)
                    .foregroundStyle(engine.tool == tool ? Color.mint : Color.secondary)
                    .background(engine.tool == tool ? Color.mint.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).help(tool.title).accessibilityLabel(tool.title)
                .accessibilityAddTraits(engine.tool == tool ? .isSelected : [])
        }
    }
}
