import SwiftUI

@main
struct SumiPaintApp: App {
    var body: some Scene {
        WindowGroup("Sumi Paint") { EditorRoot().preferredColorScheme(.dark) }
            .defaultSize(width: 1180, height: 800)
            #if os(macOS)
            .commands { PaintCommands() }
            #endif
    }
}

#if os(macOS)
struct PaintCommands: Commands {
    @FocusedValue(\.paintEditor) private var editor
    private var busy: Bool { editor?.fileBusy == true || editor?.engine?.isBusy == true || editor?.engine?.strokeActive == true }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新しいキャンバス") { editor?.showNewCanvas = true }.keyboardShortcut("n").disabled(busy)
            Button("作品を開く…") { editor?.requestImport(image: false) }.keyboardShortcut("o").disabled(busy)
        }
        CommandGroup(replacing: .saveItem) {
            Button("作品を保存…") { editor?.prepareExport(png: false) }.keyboardShortcut("s").disabled(busy)
            Button("PNGを書き出す…") { editor?.prepareExport(png: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(busy)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("元に戻す") { editor?.engine?.undo() }.keyboardShortcut("z").disabled(busy || editor?.engine?.canUndo != true)
            Button("やり直す") { editor?.engine?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(busy || editor?.engine?.canRedo != true)
        }
        CommandMenu("キャンバス") {
            Button("全体を表示") { editor?.engine?.viewport.fit(); editor?.engine?.requestDisplay?() }.keyboardShortcut("0").disabled(busy)
            Button("左右反転表示") { editor?.engine?.viewport.mirrored.toggle(); editor?.engine?.requestDisplay?() }.disabled(busy)
            Button("すべて選択") { editor?.engine?.selectAll() }.keyboardShortcut("a").disabled(busy)
            Button("選択を解除") { editor?.engine?.clearSelection() }.keyboardShortcut("d").disabled(busy)
            Button("選択した画素を消去") { editor?.engine?.clearSelectedPixels() }.disabled(busy)
            Button("画像を読み込む…") { editor?.requestImport(image: true) }.disabled(busy)
        }
    }
}
#endif
