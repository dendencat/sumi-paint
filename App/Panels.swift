import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct BrushPanel: View {
    @ObservedObject var engine: PaintEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ブラシ").font(.headline)
            HStack {
                ForEach([4, 12, 32, 80], id: \.self) { size in
                    Button("\(size)") { engine.brush.size = Double(size) }.buttonStyle(.bordered)
                }
            }
            parameter("サイズ", value: $engine.brush.size, range: 1...512, suffix: "px")
            parameter("不透明度", value: $engine.brush.opacity, range: 0.01...1, percent: true)
            parameter("手ぶれ補正", value: $engine.brush.stabilization, range: 0...1, percent: true)
            Text("補正を強くすると線の追従がゆっくりになります。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("詳細設定") {
                VStack(spacing: 14) {
                    parameter("硬さ", value: $engine.brush.hardness, range: 0...1, percent: true)
                    parameter("ブラシの間隔", value: $engine.brush.spacing, range: 0.02...1, percent: true)
                    parameter("筆圧カーブ", value: $engine.brush.pressurePower, range: 0.25...4, decimals: true)
                    parameter("最小の太さ", value: $engine.brush.minimumSize, range: 0...1, percent: true)
                    Toggle("筆圧で不透明度を変える", isOn: $engine.brush.pressureOpacity)
                    Toggle("筆圧がない入力の描き始めを細くする", isOn: $engine.brush.taperWithoutPressure)
                }.padding(.top, 12)
            }.font(.caption)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.white)
                Path { path in
                    path.move(to: CGPoint(x: 12, y: 42))
                    path.addCurve(to: CGPoint(x: 176, y: 24), control1: CGPoint(x: 60, y: -6), control2: CGPoint(x: 108, y: 74))
                }.stroke(Color(red: engine.color.red, green: engine.color.green, blue: engine.color.blue)
                    .opacity(engine.brush.opacity), style: StrokeStyle(lineWidth: min(20, engine.brush.size), lineCap: .round))
            }.frame(height: 65).accessibilityLabel("ブラシの色とサイズの目安")
            Text("試し描きはキャンバス上で行い、元に戻す操作で取り消せます。")
                .font(.caption2).foregroundStyle(.secondary)
            if engine.tool == .fill {
                parameter("塗りつぶしの許容差", value: Binding(get: { Double(engine.fillTolerance) },
                    set: { engine.fillTolerance = Int($0) }), range: 0...255)
                Text("現在のレイヤーのつながった領域を塗ります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(engine.isBusy)
    }
    private func parameter(_ name: String, value: Binding<Double>, range: ClosedRange<Double>,
                           suffix: String = "", percent: Bool = false, decimals: Bool = false) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(name); Spacer()
                Text(decimals ? String(format: "%.2f", value.wrappedValue) : "\(Int(value.wrappedValue * (percent ? 100 : 1)))\(percent ? "%" : suffix)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }.font(.caption)
            Slider(value: value, in: range).accessibilityLabel(name)
        }
    }
}

struct ColorPanel: View {
    @ObservedObject var engine: PaintEngine
    private var selectedColor: Binding<Color> {
        Binding(get: { Color(red: engine.color.red, green: engine.color.green, blue: engine.color.blue) }, set: { value in
            #if os(iOS)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a)
            engine.setColor(.init(Double(r), Double(g), Double(b)))
            #else
            if let color = NSColor(value).usingColorSpace(.sRGB) {
                engine.setColor(.init(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)))
            }
            #endif
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColorPicker("描画色", selection: selectedColor, supportsOpacity: false).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 28))], spacing: 8) {
                ForEach(Array(engine.recentColors.enumerated()), id: \.offset) { _, color in
                    Button { engine.setColor(color) } label: {
                        RoundedRectangle(cornerRadius: 7).fill(Color(red: color.red, green: color.green, blue: color.blue))
                            .frame(height: 28).overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.2)))
                    }.buttonStyle(.plain).accessibilityLabel("最近使った色")
                }
            }
            HStack {
                Button("黒") { engine.setColor(.ink) }
                Button("白") { engine.setColor(.init(1, 1, 1)) }
                Spacer()
                Button { engine.setTool(.eyedropper) } label: { Image(systemName: "eyedropper") }.accessibilityLabel("スポイト")
            }.buttonStyle(.bordered).font(.caption)
        }.disabled(engine.isBusy)
    }
}

struct LayerPanel: View {
    @ObservedObject var engine: PaintEngine
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var draggedID: UUID?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("レイヤー").font(.headline); Spacer()
                Text("\(engine.layers.count)/8").foregroundStyle(.secondary)
            }
            if let selected = engine.selectedLayer {
                Picker("合成", selection: Binding(get: { selected.properties.blend }, set: { mode in
                    engine.changeLayer(selected.id) { $0.blend = mode }
                })) {
                    Text("通常").tag(LayerBlend.normal); Text("乗算").tag(LayerBlend.multiply); Text("スクリーン").tag(LayerBlend.screen)
                }
                HStack {
                    Text("不透明度")
                    Slider(value: Binding(get: { selected.properties.opacity }, set: {
                        engine.previewLayerOpacity(selected.id, value: $0)
                    }), in: 0...1, onEditingChanged: { if !$0 { engine.finishLayerOpacityEdit() } })
                        .accessibilityLabel("レイヤーの不透明度")
                    Text("\(Int((selected.properties.opacity * 100).rounded()))%")
                        .monospacedDigit().frame(width: 34, alignment: .trailing)
                }
                HStack(spacing: 16) {
                    propertyButton("lock", title: "ロック", selected: selected, keyPath: \.locked)
                    propertyButton("checkerboard.rectangle", title: "透明度を保護", selected: selected, keyPath: \.alphaLocked)
                    propertyButton("arrow.turn.down.right", title: "下のレイヤーにクリッピング", selected: selected, keyPath: \.clipping)
                        .disabled(engine.layers.first?.id == selected.id)
                    Spacer()
                }
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(engine.layers.reversed()) { layer in layerRow(layer) }
                }
            }.frame(minHeight: 100, maxHeight: .infinity)
            Divider()
            HStack(spacing: 16) {
                icon("plus", label: "レイヤーを追加") { engine.addLayer() }.disabled(engine.layers.count >= 8)
                icon("plus.square.on.square", label: "レイヤーを複製") { engine.addLayer(duplicate: true) }.disabled(engine.layers.count >= 8)
                Spacer(minLength: 0)
                icon("arrow.up", label: "上に移動") { engine.moveLayer(1) }.disabled(engine.layers.last?.id == engine.selectedLayerID)
                icon("arrow.down", label: "下に移動") { engine.moveLayer(-1) }.disabled(engine.layers.first?.id == engine.selectedLayerID)
                icon("trash", label: "レイヤーを削除") { engine.deleteLayer() }.disabled(engine.layers.count <= 1)
            }.buttonStyle(.borderless)
        }
        .font(.caption)
        .disabled(engine.isBusy || engine.strokeActive)
        .onChange(of: engine.selectedLayerID) { _, _ in finishName(); engine.finishLayerOpacityEdit() }
        .onChange(of: nameFocused) { _, focused in if !focused { finishName() } }
        .onDisappear { finishName(); engine.finishLayerOpacityEdit() }
    }
    private func layerRow(_ layer: PaintLayer) -> some View {
        let selected = engine.selectedLayerID == layer.id
        return HStack(spacing: 6) {
            if layer.properties.clipping { Text("↳").foregroundStyle(.secondary) }
            Button { engine.changeLayer(layer.id) { $0.visible.toggle() } } label: {
                Image(systemName: layer.properties.visible ? "eye" : "eye.slash").frame(width: 20, height: 40)
            }.buttonStyle(.plain).accessibilityLabel("\(layer.properties.name)の表示を切り替える")
            ZStack {
                CheckerboardView()
                if let image = engine.thumbnail(for: layer) {
                    Image(decorative: image, scale: 2).resizable().interpolation(.medium)
                }
            }.frame(width: 40, height: 40).clipped().accessibilityLabel("\(layer.properties.name)のサムネイル")
            if editingID == layer.id {
                TextField("レイヤー名", text: $name).textFieldStyle(.plain).focused($nameFocused)
                    .onSubmit { finishName() }
            } else {
                Text(layer.properties.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) { beginName(layer) }
                    .onTapGesture { engine.selectedLayerID = layer.id }
                    .contextMenu { Button("名前を変更") { beginName(layer) } }
            }
            Text("\(Int((layer.properties.opacity * 100).rounded()))%")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.leading, layer.properties.clipping ? 12 : 0)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(selected ? Color.mint.opacity(0.14) : Color.clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(.mint).frame(width: 3) } }
        .contentShape(Rectangle()).onTapGesture { engine.selectedLayerID = layer.id }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onDrag { draggedID = layer.id; return NSItemProvider(object: layer.id.uuidString as NSString) }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard !providers.isEmpty, let id = draggedID,
                  let target = engine.layers.firstIndex(where: { $0.id == layer.id }) else { return false }
            engine.reorderLayer(id, to: target); draggedID = nil; return true
        }
    }
    private func beginName(_ layer: PaintLayer) {
        finishName(); engine.selectedLayerID = layer.id
        name = layer.properties.name; editingID = layer.id; nameFocused = true
    }
    private func finishName() {
        guard let id = editingID else { return }
        editingID = nil; nameFocused = false
        engine.changeLayer(id) { $0.name = name }
    }
    private func icon(_ image: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: image).frame(minWidth: 16, minHeight: 26) }.help(label).accessibilityLabel(label)
    }
    private func propertyButton(_ image: String, title: String, selected: PaintLayer,
                                keyPath: WritableKeyPath<LayerProperties, Bool>) -> some View {
        Button { engine.changeLayer(selected.id) { $0[keyPath: keyPath].toggle() } } label: {
            Image(systemName: image).frame(width: 28, height: 26)
                .foregroundStyle(selected.properties[keyPath: keyPath] ? Color.mint : Color.secondary)
                .background(selected.properties[keyPath: keyPath] ? Color.mint.opacity(0.14) : Color.clear)
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            .accessibilityValue(selected.properties[keyPath: keyPath] ? "オン" : "オフ")
    }
}

struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.85)))
            for y in 0..<Int(ceil(size.height / 5)) {
                for x in 0..<Int(ceil(size.width / 5)) where (x + y).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: x * 5, y: y * 5, width: 5, height: 5)), with: .color(.gray.opacity(0.45)))
                }
            }
        }
    }
}

struct NewCanvasSheet: View {
    @ObservedObject var model: EditorModel
    @State private var width = 1024
    @State private var height = 1024
    @State private var preset = 1024
    var body: some View {
        NavigationStack {
            Form {
                Section("サイズ") {
                    Picker("プリセット", selection: $preset) {
                        Text("512").tag(512); Text("1024").tag(1024); Text("1536").tag(1536); Text("2048").tag(2048)
                    }.onChange(of: preset) { _, value in width = value; height = value }
                    Stepper("幅: \(width)px", value: $width, in: 64...2048, step: 64)
                    Stepper("高さ: \(height)px", value: $height, in: 64...2048, step: 64)
                }
                Section {
                    Text("現在の作品は復旧用に保存してから切り替えます。持ち出せる作品ファイルは「作品を保存」から保存してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新しいキャンバス")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { model.showNewCanvas = false } }
                ToolbarItem(placement: .confirmationAction) { Button("作成") { model.newCanvas(width: width, height: height) }.disabled(model.fileBusy) }
            }
        }.frame(minWidth: 320, minHeight: 340)
    }
}

struct TransformPanel: View {
    @ObservedObject var engine: PaintEngine
    var close: () -> Void
    @State private var dx = 0.0
    @State private var dy = 0.0
    @State private var scale = 1.0
    @State private var degrees = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            adjustment("横に移動", value: $dx, range: -Double(engine.width)...Double(engine.width), unit: "px")
            adjustment("縦に移動", value: $dy, range: -Double(engine.height)...Double(engine.height), unit: "px")
            adjustment("拡大・縮小", value: $scale, range: 0.1...4, unit: "倍")
            adjustment("回転", value: $degrees, range: -180...180, unit: "°")
            Text("選択した画素を移動・変形します。確定後も元に戻せます。")
                .font(.caption).foregroundStyle(.secondary)
            Button("変形を確定") {
                engine.transformSelection(dx: dx.rounded(), dy: dy.rounded(), scale: scale, degrees: degrees); close()
            }.buttonStyle(.borderedProminent).disabled(engine.isBusy || !engine.hasSelection)
        }
    }
    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack {
            HStack { Text(title); Spacer(); Text(String(format: "%.1f%@", value.wrappedValue, unit)).foregroundStyle(.secondary) }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}
