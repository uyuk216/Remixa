import SwiftUI

/// Header buttons: history, new chat, and a menu with rename / export / copy.
struct AIChatToolbar: View {
    let isRunning: Bool
    let hasMessages: Bool
    let onList: () -> Void
    let onNew: () -> Void
    let onRename: (String) -> Void
    let onSaveMarkdown: () -> Void
    let onCopyMarkdown: () -> Void
    let currentTitle: String

    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onList) { Image(systemName: "clock.arrow.circlepath") }
                .help("会話の履歴")
            Button(action: onNew) { Image(systemName: "square.and.pencil") }
                .help("新しいチャット")
                .disabled(isRunning || !hasMessages)
            menu
        }
        .buttonStyle(.borderless)
        .alert("会話の名前を変更", isPresented: $renaming) {
            TextField("名前", text: $draft)
            Button("変更") { onRename(draft) }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var menu: some View {
        Menu {
            Button("名前を変更…") { draft = currentTitle; renaming = true }
            Button("Markdownで書き出し…", action: onSaveMarkdown)
            Button("Markdownをコピー", action: onCopyMarkdown)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!hasMessages)
    }
}

/// Searchable list of saved conversations (newest first) with open / rename / delete.
struct AIChatListView: View {
    @ObservedObject var store: ChatStore
    let currentID: UUID
    let disabled: Bool
    let onOpen: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var deleteTarget: ChatSummary?
    @State private var renameTarget: ChatSummary?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("会話の履歴").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
            }
            TextField("検索", text: $query).textFieldStyle(.roundedBorder)
            list
        }
        .padding(14)
        .frame(width: 380, height: 440)
        .confirmationDialog("この会話を削除しますか?", isPresented: deleteBinding, presenting: deleteTarget) { target in
            Button("ゴミ箱へ移動", role: .destructive) { store.delete(target.id) }
            Button("キャンセル", role: .cancel) {}
        } message: { target in
            Text("「\(target.title)」をゴミ箱へ移動します。")
        }
        .alert("会話の名前を変更", isPresented: renameBinding) {
            TextField("名前", text: $draft)
            Button("変更") { if let t = renameTarget { store.rename(t.id, to: draft) } }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    @ViewBuilder
    private var list: some View {
        let items = store.search(query)
        if items.isEmpty {
            Text(query.isEmpty ? "保存された会話はまだありません。" : "見つかりませんでした。")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(items) { item in
                AIChatRow(item: item, isCurrent: item.id == currentID)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !disabled else { return }
                        onOpen(item.id)
                        dismiss()
                    }
                    .contextMenu {
                        Button("名前を変更…") { draft = item.title; renameTarget = item }
                        Button("削除…", role: .destructive) { deleteTarget = item }
                    }
            }
        }
    }
}

private struct AIChatRow: View {
    let item: ChatSummary
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).lineLimit(1).fontWeight(isCurrent ? .semibold : .regular)
            HStack(spacing: 6) {
                Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                if let name = AIBackendKind(rawValue: item.backend)?.displayName { Text(name) }
                if let project = item.projectName { Text(project).lineLimit(1) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
