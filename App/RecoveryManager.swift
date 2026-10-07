import SwiftUI

struct RecoveryManager: View {
    @ObservedObject var model: EditorModel
    @State private var pendingDeletion: RecoveryEntry?
    var body: some View {
        NavigationStack {
            Group {
                if model.recoveryEntries.isEmpty {
                    ContentUnavailableView("復旧ファイルはありません", systemImage: "clock.arrow.circlepath")
                } else {
                    List(model.recoveryEntries) { entry in
                        HStack {
                            Button {
                                model.showRecoveryManager = false; model.restoreRecovery(entry.url)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.modified.formatted(date: .abbreviated, time: .shortened))
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(entry.url.lastPathComponent).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button { pendingDeletion = entry } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).accessibilityLabel("この復旧ファイルを削除")
                                .disabled(model.isSavingRecovery || model.fileBusy)
                        }.padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("復旧ファイル")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { model.showRecoveryManager = false } } }
            .alert("復旧ファイルを削除しますか", isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { entry in
                    Button("削除", role: .destructive) { model.removeRecovery(entry); pendingDeletion = nil }
                    Button("キャンセル", role: .cancel) { pendingDeletion = nil }
                } message: { _ in Text("この復旧版からは復元できなくなります。編集中の作品は次回の自動保存で復旧版が作られます。") }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}
