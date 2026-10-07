import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension UTType {
    static let sumiPainting = UTType(exportedAs: "app.dendencat.sumipaint.document", conformingTo: .data)
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.sumiPainting, .png] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw PaintDocumentError.invalid("ファイルを読み込めません。") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
final class EditorModel: ObservableObject {
    let engine: PaintEngine?
    @Published var startupError: String?
    @Published var status = "新しいキャンバス"
    @Published var showNewCanvas = false
    @Published var showImporter = false
    @Published var showExporter = false
    @Published var fileBusy = false
    @Published var exportFile: ExportFile?
    @Published var exportType: UTType = .sumiPainting
    @Published var exportName = "作品"
    @Published var recoveryURL: URL?
    private var importingImage = false
    private var recoveryTask: Task<Void, Never>?
    private let sessionID = UUID()
    private let writer = RecoveryWriter()
    private var latestWrittenRevision: UInt64?
    private var recoveryFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SumiPaint/Recovery", isDirectory: true)
    }
    init() {
        do {
            let engine = try PaintEngine(); self.engine = engine
            #if os(iOS)
            engine.fingerDrawing = UIDevice.current.userInterfaceIdiom == .phone
            #endif
            engine.onCommit = { [weak self] in self?.scheduleRecovery() }
            let files = (try? FileManager.default.contentsOfDirectory(at: recoveryFolder,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            recoveryURL = files.filter { $0.pathExtension == "sumipaint" }.max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
        } catch { engine = nil; startupError = error.localizedDescription }
    }
    private func scheduleRecovery() {
        recoveryTask?.cancel()
        status = "変更あり · 自動保存を待っています"
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            await self.saveRecovery()
        }
    }
    @discardableResult
    func saveRecovery() async -> Bool {
        guard let engine, !engine.isBusy, !engine.strokeActive else { scheduleRecovery(); return false }
        let revision = engine.revision
        if latestWrittenRevision == revision { return true }
        let snapshot = engine.snapshot()
        let folder = recoveryFolder
        let url = folder.appendingPathComponent("\(snapshot.id.uuidString)-\(sessionID.uuidString).sumipaint")
        do {
            try await writer.write(snapshot, revision: revision, to: url)
            latestWrittenRevision = max(latestWrittenRevision ?? 0, revision)
            if engine.revision == revision { status = "復旧用に自動保存済み" }
            return true
        } catch { engine.errorMessage = "自動保存に失敗しました: \(error.localizedDescription)"; return false }
    }
    func newCanvas(width: Int, height: Int) {
        guard let engine, !fileBusy, !engine.isBusy, !engine.strokeActive else { return }
        fileBusy = true
        Task {
            defer { fileBusy = false }
            guard await saveRecovery() else { return }
            do {
                try engine.newDocument(width: width, height: height)
                latestWrittenRevision = nil; showNewCanvas = false; status = "新しいキャンバス"
            } catch { engine.errorMessage = error.localizedDescription }
        }
    }
    func requestImport(image: Bool) {
        guard !fileBusy, engine?.isBusy != true, engine?.strokeActive != true else { return }
        importingImage = image; showImporter = true
    }
    var importTypes: [UTType] { importingImage ? [.png, .jpeg, .heic] : [.sumiPainting] }
    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error): engine?.errorMessage = error.localizedDescription
        case .success(let urls): if let url = urls.first { open(url, image: importingImage) }
        }
    }
    private func open(_ url: URL, image: Bool) {
        guard let engine, !fileBusy, !engine.isBusy, !engine.strokeActive else { return }
        fileBusy = true
        Task {
            defer { fileBusy = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= (image ? 32 * 1024 * 1024 : DocumentSnapshot.maximumFileBytes) else {
                        throw PaintDocumentError.invalid("ファイルが大きすぎます。")
                    }
                    return try Data(contentsOf: url)
                }.value
                if image { try engine.importImage(data) }
                else {
                    let snapshot = try await Task.detached(priority: .userInitiated) { try DocumentSnapshot.decode(data) }.value
                    guard await saveRecovery() else { return }
                    try engine.load(snapshot); latestWrittenRevision = nil
                }
                status = "\(url.deletingPathExtension().lastPathComponent)を開きました"
            } catch { engine.errorMessage = error.localizedDescription }
        }
    }
    func restoreRecovery(_ url: URL) {
        self.recoveryURL = nil; open(url, image: false)
    }
    func prepareExport(png: Bool) {
        guard let engine, !fileBusy, !engine.isBusy, !engine.strokeActive else { return }
        fileBusy = true
        Task {
            defer { fileBusy = false }
            do {
                let data: Data
                if png { data = try engine.pngData() }
                else {
                    let snapshot = engine.snapshot()
                    data = try await Task.detached(priority: .userInitiated) { try snapshot.encoded() }.value
                }
                exportFile = ExportFile(data: data); exportType = png ? .png : .sumiPainting
                exportName = png ? "Sumi-作品" : "作品"; showExporter = true
            } catch { engine.errorMessage = error.localizedDescription }
        }
    }
    func handleExport(_ result: Result<URL, Error>) {
        switch result {
        case .success: status = exportType == .png ? "PNGを書き出しました" : "作品を書き出しました"
        case .failure(let error): engine?.errorMessage = error.localizedDescription
        }
        exportFile = nil
    }
}

struct EditorFocusKey: FocusedValueKey { typealias Value = EditorModel }
extension FocusedValues {
    var paintEditor: EditorModel? {
        get { self[EditorFocusKey.self] }
        set { self[EditorFocusKey.self] = newValue }
    }
}
