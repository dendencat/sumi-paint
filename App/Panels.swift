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
            if engine.tool.isBrush {
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
            }
            if engine.tool == .fill {
                Text("塗りつぶし").font(.headline)
                parameter("不透明度", value: $engine.brush.opacity, range: 0.01...1, percent: true)
                parameter("塗りつぶしの許容差", value: Binding(get: { Double(engine.fillTolerance) },
                    set: { engine.fillTolerance = Int($0) }), range: 0...255)
                Stepper("領域を広げる: \(engine.fillExpansion)px", value: $engine.fillExpansion, in: 0...8)
                    .font(.caption)
                Text("表示中の全レイヤーを境界にして、選択レイヤーへ塗ります。")
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
    @State private var editingBackground = false
    @State private var hex = ""
    @State private var invalidHex = false
    @FocusState private var hexFocused: Bool
    private var activeColor: PaintColor { editingBackground ? engine.backgroundColor : engine.color }
    private var selection: Binding<PaintColor> {
        Binding(get: { activeColor }, set: { value in
            if editingBackground { engine.backgroundColor = value } else { engine.setColor(value) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("カラー").font(.headline)
                Spacer()
                ZStack {
                    colorButton(engine.backgroundColor, title: "背景色", selected: editingBackground) { editingBackground = true }
                        .offset(x: 10, y: 6)
                    colorButton(engine.color, title: "描画色", selected: !editingBackground) { editingBackground = false }
                        .offset(x: -10, y: -6)
                }.frame(width: 56, height: 40)
                Button { engine.swapColors() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.plain).help("描画色と背景色を入れ替え（X）").accessibilityLabel("描画色と背景色を入れ替え")
            }
            HSVColorControl(color: selection).frame(height: 168).frame(maxWidth: .infinity)
            HStack {
                Text(editingBackground ? "背景色 HEX" : "HEX").font(.caption)
                TextField("#RRGGBB", text: $hex).font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder).focused($hexFocused).onSubmit(commitHex)
                    .accessibilityLabel("HEXカラーコード")
                Button { engine.setTool(.eyedropper) } label: { Image(systemName: "eyedropper") }
                    .buttonStyle(.plain).help("スポイト").accessibilityLabel("スポイト")
            }
            if invalidHex { Text("6桁のHEXを入力してください").font(.caption2).foregroundStyle(.secondary) }
            Text("最近使った色").font(.caption).foregroundStyle(.secondary)
            swatches(engine.recentColors, saved: false)
            HStack {
                Text("カラーセット").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { engine.saveColor(activeColor) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("現在の色をカラーセットに追加").accessibilityLabel("現在の色をカラーセットに追加")
                    .disabled(engine.colorSet.count >= 64)
            }
            ScrollView {
                swatches(engine.colorSet, saved: true)
            }.frame(maxHeight: 64)
        }
        .disabled(engine.isBusy || engine.strokeActive)
        .onAppear { hex = activeColor.hex }
        .onChange(of: activeColor) { _, value in if !hexFocused { hex = value.hex; invalidHex = false } }
        .onChange(of: editingBackground) { _, _ in hex = activeColor.hex; invalidHex = false }
        .onChange(of: hexFocused) { _, focused in if !focused { commitHex() } }
    }
    private func commitHex() {
        guard let value = PaintColor(hex: hex) else { invalidHex = true; return }
        selection.wrappedValue = value; hex = value.hex; invalidHex = false
    }
    private func colorButton(_ color: PaintColor, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Rectangle().fill(Color(color)).frame(width: 28, height: 28)
                .overlay(Rectangle().stroke(selected ? Color.white : Color.gray, lineWidth: selected ? 2 : 1))
        }.buttonStyle(.plain).accessibilityLabel("\(title) \(color.hex)")
    }
    private func swatches(_ colors: [PaintColor], saved: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Rectangle().fill(Color(color)).frame(width: 24, height: 24)
                    .overlay(Rectangle().stroke(activeColor.hex == color.hex ? Color.white : Color.clear, lineWidth: 2))
                    .contentShape(Rectangle())
                    .onTapGesture { selection.wrappedValue = color }
                    .onLongPressGesture { if saved { engine.removeSavedColor(color) } }
                    .contextMenu { if saved { Button("カラーセットから削除", role: .destructive) { engine.removeSavedColor(color) } } }
                    .accessibilityElement().accessibilityLabel("\(saved ? "カラーセット" : "最近使った色") \(color.hex)")
                    .accessibilityAddTraits(activeColor.hex == color.hex ? [.isButton, .isSelected] : [.isButton])
                    .accessibilityAction { selection.wrappedValue = color }
                    .accessibilityAction(named: "削除") { if saved { engine.removeSavedColor(color) } }
            }
        }.frame(minHeight: 24, alignment: .topLeading)
    }
}

private extension Color {
    init(_ color: PaintColor) { self.init(red: color.red, green: color.green, blue: color.blue) }
}

struct HSVColorControl: View {
    @Binding var color: PaintColor
    @State private var hue = 0.0
    @State private var saturation = 0.0
    @State private var value = 0.0
    private let diameter = 164.0
    private let square = 96.0
    var body: some View {
        ZStack {
            Circle().strokeBorder(AngularGradient(colors: (0...12).map {
                Color(hue: Double($0) / 12, saturation: 1, brightness: 1)
            }, center: .center), lineWidth: 18)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    hue = (atan2(gesture.location.y - diameter/2, gesture.location.x - diameter/2) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
                    update()
                })
                .accessibilityLabel("色相").accessibilityValue("\(Int(hue * 360))度")
                .accessibilityAdjustableAction { direction in
                    hue = (hue + (direction == .increment ? 1.0/360 : 359.0/360)).truncatingRemainder(dividingBy: 1); update()
                }
            Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                .overlay(LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing))
                .overlay(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                .frame(width: square, height: square)
                .overlay(alignment: .topLeading) {
                    Circle().stroke(.black, lineWidth: 3).overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .frame(width: 9, height: 9).offset(x: saturation * square - 4.5, y: (1-value) * square - 4.5)
                        .allowsHitTesting(false)
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    saturation = min(1, max(0, gesture.location.x / square))
                    value = 1 - min(1, max(0, gesture.location.y / square)); update()
                })
                .accessibilityLabel("彩度と明度").accessibilityValue("彩度\(Int(saturation * 100))%、明度\(Int(value * 100))%")
                .accessibilityAdjustableAction { direction in
                    value = min(1, max(0, value + (direction == .increment ? 0.01 : -0.01))); update()
                }
                .accessibilityAction(named: "彩度を上げる") { saturation = min(1, saturation + 0.01); update() }
                .accessibilityAction(named: "彩度を下げる") { saturation = max(0, saturation - 0.01); update() }
            Circle().stroke(.white, lineWidth: 2).frame(width: 12, height: 12)
                .offset(x: cos(hue * 2 * .pi) * (diameter/2 - 9), y: sin(hue * 2 * .pi) * (diameter/2 - 9))
                .allowsHitTesting(false)
        }
        .onAppear { sync() }
        .onChange(of: color) { _, newColor in
            let current = PaintColor(hue: hue, saturation: saturation, value: value)
            if abs(current.red-newColor.red) + abs(current.green-newColor.green) + abs(current.blue-newColor.blue) > 0.00001 { sync() }
        }
    }
    private func update() { color = PaintColor(hue: hue, saturation: saturation, value: value) }
    private func sync() {
        let hsv = color.hsv
        if hsv.saturation > 0 { hue = hsv.hue }
        saturation = hsv.saturation; value = hsv.value
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
