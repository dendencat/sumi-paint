import SwiftUI

#if os(iOS)
import UIKit

@MainActor
final class BackgroundSaveBudget {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save painting recovery") { [weak self] in
            Task { @MainActor in self?.finish() }
        }
    }
    func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid
    }
}
#else
import AppKit

@MainActor
final class RecoverySessions {
    static let shared = RecoverySessions()
    private let models = NSHashTable<EditorModel>.weakObjects()
    func add(_ model: EditorModel) { models.add(model) }
    var active: [EditorModel] { models.allObjects }
}

@MainActor
final class PaintApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let editors = RecoverySessions.shared.active
        guard !editors.isEmpty else { return .terminateNow }
        editors.forEach { $0.engine?.endStroke() }
        Task {
            var succeeded = true
            for editor in editors { if !(await editor.saveRecovery()) { succeeded = false } }
            if !succeeded {
                let alert = NSAlert()
                alert.messageText = "保存を完了できませんでした"
                alert.informativeText = "保存せず終了すると、最新の編集を失う可能性があります。前回の復旧ファイルは保持しています。"
                alert.addButton(withTitle: "終了を中止")
                alert.addButton(withTitle: "保存せず終了")
                succeeded = alert.runModal() == .alertSecondButtonReturn
            }
            sender.reply(toApplicationShouldTerminate: succeeded)
        }
        return .terminateLater
    }
}
#endif
