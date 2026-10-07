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
    @Published var recoveryEntries: [RecoveryEntry] = []
    @Published var showRecoveryManager = false
    @Published private(set) var isSavingRecovery = false
    private var importingImage = false
    private var recoveryTask: Task<Void, Never>?
    private var recoverySave: Task<Bool, Never>?
    private var recoverySchedule: RecoverySchedule
    private var hasWork = false
    #if DEBUG
    func cancelRecoveryForTesting() { recoveryTask?.cancel() }
    #endif
    private let sessionID = UUID()
    private let writer = RecoveryWriter()
    private var latestWrittenRevision: UInt64?
    private let recoveryFolder: URL
    init(recoveryFolder: URL? = nil, idleDelay: Double = 2, maximumInterval: Double = 10) {
        self.recoveryFolder = recoveryFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SumiPaint/Recovery", isDirectory: true)
        recoverySchedule = .init(idleDelay: idleDelay, maximumInterval: maximumInterval)
        do {
            let engine = try PaintEngine(); self.engine = engine
            #if os(iOS)
            engine.fingerDrawing = UIDevice.current.userInterfaceIdiom == .phone
            #endif
            engine.onContentChange = { [weak self] in self?.hasWork = true; self?.scheduleRecovery() }
            refreshRecoveryEntries()
            recoveryURL = recoveryEntries.first?.url
            #if os(macOS)
            RecoverySessions.shared.add(self)
            #endif
        } catch { engine = nil; startupError = error.localizedDescription }
    }
    private func scheduleRecovery() {
        recoverySchedule.noteChange(at: ProcessInfo.processInfo.systemUptime)
        if status != "変更あり · 自動保存を待っています" { status = "変更あり · 自動保存を待っています" }
        guard recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { recoveryTask = nil }
            while let delay = recoverySchedule.delay(at: ProcessInfo.processInfo.systemUptime) {
                do { try await Task.sleep(for: .seconds(max(0.01, delay))) } catch { return }
                guard !Task.isCancelled else { return }
                if (recoverySchedule.delay(at: ProcessInfo.processInfo.systemUptime) ?? 0) > 0 { continue }
                if engine?.isBusy == true {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    continue
                }
                guard await saveRecovery() else { return }
            }
        }
    }
    @discardableResult
    func saveRecovery() async -> Bool {
        if let recoverySave {
            guard await recoverySave.value else { return false }
            return await saveRecovery()
        }
        guard hasWork else { return true }
        guard let engine, !engine.isBusy, !engine.hasPendingCancellation else { return false }
        let revision = engine.contentRevision
        if latestWrittenRevision == revision { return true }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            defer { recoverySave = nil; isSavingRecovery = false }
            return await writeRecovery()
        }
        recoverySave = task; isSavingRecovery = true
        return await task.value
    }
    private func writeRecovery() async -> Bool {
        guard let engine, !engine.isBusy, !engine.hasPendingCancellation else { return false }
        let capturedAt = ProcessInfo.processInfo.systemUptime
        let revision = engine.contentRevision
        do {
            let snapshot = try engine.snapshot()
            recoverySchedule.reset()
            let url = recoveryFolder.appendingPathComponent("\(snapshot.id.uuidString)-\(sessionID.uuidString).sumipaint")
            try await writer.write(snapshot, revision: revision, to: url)
            latestWrittenRevision = max(latestWrittenRevision ?? 0, revision)
            refreshRecoveryEntries()
            if engine.contentRevision == revision { status = "復旧用に自動保存済み" }
            return true
        } catch {
            recoverySchedule.noteChange(at: capturedAt)
            status = "復旧保存に失敗しました"
            engine.errorMessage = "自動保存に失敗しました: \(error.localizedDescription)"; return false
        }
    }
    func refreshRecoveryEntries() {
        do { recoveryEntries = try RecoveryCatalog.entries(in: recoveryFolder) }
        catch { engine?.errorMessage = "復旧ファイルの一覧を取得できません。" }
    }
    func removeRecovery(_ entry: RecoveryEntry) {
        guard !isSavingRecovery else { return }
        do {
            try RecoveryCatalog.remove(entry, from: recoveryFolder)
            latestWrittenRevision = nil; refreshRecoveryEntries()
        }
        catch { engine?.errorMessage = error.localizedDescription }
    }
    func saveForBackground() {
        engine?.endStroke()
        #if os(iOS)
        let budget = BackgroundSaveBudget()
        budget.begin()
        Task { defer { budget.finish() }; _ = await saveRecovery() }
        #else
        Task { _ = await saveRecovery() }
        #endif
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
                hasWork = false; recoverySchedule.reset()
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
                    return try BoundedFileReader.read(url, maximumBytes: image ? 32 * 1024 * 1024 : DocumentSnapshot.maximumFileBytes)
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
                    let snapshot = try engine.snapshot()
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
