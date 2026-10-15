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
    private let defaults: UserDefaults
    private var acknowledgedRecoveries: [String: Double]
    private var adoptedRecoveryURL: URL?
    private var writtenRecoveryURLs: Set<URL> = []
    private var exportedSnapshot: (id: UUID, revision: UInt64)?
    private let sessionID = UUID()
    private let writer = RecoveryWriter()
    private var latestWrittenRevision: UInt64?
    private let recoveryFolder: URL
    init(recoveryFolder: URL? = nil, idleDelay: Double = 2, maximumInterval: Double = 10, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        acknowledgedRecoveries = defaults.dictionary(forKey: "recovery.acknowledged") as? [String: Double] ?? [:]
        self.recoveryFolder = recoveryFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SumiPaint/Recovery", isDirectory: true)
        recoverySchedule = .init(idleDelay: idleDelay, maximumInterval: maximumInterval)
        do {
            let engine = try PaintEngine(defaults: defaults); self.engine = engine
            #if os(iOS)
            engine.fingerDrawing = UIDevice.current.userInterfaceIdiom == .phone
            #endif
            engine.onContentChange = { [weak self] in self?.hasWork = true; self?.scheduleRecovery() }
            pruneRecoveries()
            refreshRecoveryEntries()
            recoveryURL = recoveryEntries.first(where: {
                $0.modified.timeIntervalSince1970 > (acknowledgedRecoveries[$0.url.standardizedFileURL.path] ?? 0)
            })?.url
            RecoverySessions.shared.add(self)
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
            let url = adoptedRecoveryURL ?? recoveryFolder.appendingPathComponent("\(snapshot.id.uuidString)-\(sessionID.uuidString).sumipaint")
            try await writer.write(snapshot, revision: revision, to: url)
            writtenRecoveryURLs.insert(url)
            latestWrittenRevision = max(latestWrittenRevision ?? 0, revision)
            pruneRecoveries()
            refreshRecoveryEntries()
            if engine.contentRevision == revision { status = "復旧用に自動保存済み" }
            return true
        } catch {
            recoverySchedule.noteChange(at: capturedAt)
            status = "復旧保存に失敗しました"
            engine.errorMessage = "自動保存に失敗しました: \(error.localizedDescription)"; return false
        }
    }
    var protectedRecoveryURLs: Set<URL> {
        guard let engine else { return [] }
        if let adoptedRecoveryURL { return [adoptedRecoveryURL] }
        return [recoveryFolder.appendingPathComponent("\(engine.documentID.uuidString)-\(sessionID.uuidString).sumipaint")]
    }
    private func pruneRecoveries() {
        var protected = protectedRecoveryURLs
        for model in RecoverySessions.shared.active { protected.formUnion(model.protectedRecoveryURLs) }
        // All remaining checkpoints may be the only editable copy. Read/quit
        // acknowledgements suppress alerts only; export removes its exact version.
        do { try RecoveryCatalog.prune(in: recoveryFolder, protected: protected) }
        catch { engine?.errorMessage = "古い復旧ファイルを整理できません: \(error.localizedDescription)" }
    }
    func acknowledgeRecovery(_ url: URL) {
        guard let entry = recoveryEntries.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) else { return }
        acknowledgedRecoveries[url.standardizedFileURL.path] = entry.modified.timeIntervalSince1970
        let latest = acknowledgedRecoveries.sorted { $0.value > $1.value }.prefix(32)
        acknowledgedRecoveries = Dictionary(uniqueKeysWithValues: latest.map { ($0.key, $0.value) })
        defaults.set(acknowledgedRecoveries, forKey: "recovery.acknowledged")
    }
    func dismissRecoveryPrompt() {
        if let recoveryURL { acknowledgeRecovery(recoveryURL) }
        recoveryURL = nil
    }
    /// Unsaved artwork must survive a normal quit. Acknowledge these checkpoints
    /// so only a newer, interrupted session prompts automatically next launch.
    func acknowledgeCleanExit() {
        for url in writtenRecoveryURLs { acknowledgeRecovery(url) }
        RecoverySessions.shared.remove(self)
    }
    private func removeExportedRecovery(id: UUID, revision: UInt64) async {
        if let recoverySave { _ = await recoverySave.value }
        guard let engine, engine.documentID == id, engine.contentRevision == revision else { return }
        do {
            for entry in try RecoveryCatalog.entries(in: recoveryFolder) where
                entry.url.lastPathComponent.hasPrefix("\(id.uuidString)-\(sessionID.uuidString)") || entry.url.standardizedFileURL.path == adoptedRecoveryURL?.standardizedFileURL.path {
                try RecoveryCatalog.remove(entry, from: recoveryFolder)
                writtenRecoveryURLs.remove(entry.url)
            }
            hasWork = false; recoverySchedule.reset(); recoveryTask?.cancel()
            latestWrittenRevision = nil; refreshRecoveryEntries()
        } catch { engine.errorMessage = "保存済みの復旧ファイルを整理できません: \(error.localizedDescription)" }
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
                adoptedRecoveryURL = nil; latestWrittenRevision = nil; showNewCanvas = false; status = "新しいキャンバス"
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
                    let candidate = recoveryEntries.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path })?.url
                    let inUse = RecoverySessions.shared.active.contains { model in
                        model !== self && model.protectedRecoveryURLs.contains(where: { $0.standardizedFileURL.path == candidate?.standardizedFileURL.path })
                    }
                    adoptedRecoveryURL = inUse ? nil : candidate
                }
                status = "\(url.deletingPathExtension().lastPathComponent)を開きました"
            } catch { engine.errorMessage = error.localizedDescription }
        }
    }
    func restoreRecovery(_ url: URL) {
        dismissRecoveryPrompt(); open(url, image: false)
    }
    func prepareExport(png: Bool) {
        guard let engine, !fileBusy, !engine.isBusy, !engine.strokeActive else { return }
        fileBusy = true
        Task {
            defer { fileBusy = false }
            do {
                let data: Data
                exportedSnapshot = nil
                if png { data = try engine.pngData() }
                else {
                    exportedSnapshot = (engine.documentID, engine.contentRevision)
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
        case .success:
            status = exportType == .png ? "PNGを書き出しました" : "作品を書き出しました"
            if let saved = exportedSnapshot {
                Task { await removeExportedRecovery(id: saved.id, revision: saved.revision) }
            }
        case .failure(let error): engine?.errorMessage = error.localizedDescription
        }
        exportedSnapshot = nil; exportFile = nil
    }
}

struct EditorFocusKey: FocusedValueKey { typealias Value = EditorModel }
extension FocusedValues {
    var paintEditor: EditorModel? {
        get { self[EditorFocusKey.self] }
        set { self[EditorFocusKey.self] = newValue }
    }
}
