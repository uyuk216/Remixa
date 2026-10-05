import SwiftUI

/// Tracks long-running background work (export, stem separation, analysis) so the
/// transport bar can show one unified progress area.
@MainActor
final class ActivityCenter: ObservableObject {
    static let shared = ActivityCenter()

    struct Item: Identifiable {
        let id: UUID
        var title: String
        var detail: String
        /// nil = indeterminate
        var progress: Double?
        var isFinished: Bool
        var cancel: (@MainActor () -> Void)?
    }

    @Published private(set) var items: [Item] = []

    @discardableResult
    func begin(title: String, detail: String = "", progress: Double? = 0, cancel: (@MainActor () -> Void)? = nil) -> UUID {
        let item = Item(id: UUID(), title: title, detail: detail, progress: progress, isFinished: false, cancel: cancel)
        items.append(item)
        return item.id
    }

    func update(_ id: UUID, progress: Double?, detail: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isFinished else { return }
        items[index].progress = progress
        if let detail { items[index].detail = detail }
    }

    /// Shows `message` briefly, then removes the item.
    func finish(_ id: UUID, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFinished = true
        items[index].progress = 1
        items[index].detail = message
        items[index].cancel = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            items.removeAll { $0.id == id }
        }
    }

    func setCancel(_ id: UUID, _ cancel: @escaping @MainActor () -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isFinished else { return }
        items[index].cancel = cancel
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}

/// Right end of the transport bar.
struct ActivityStrip: View {
    @ObservedObject private var center = ActivityCenter.shared

    var body: some View {
        if let item = center.items.first {
            HStack(spacing: 8) {
                itemInfo(item)
                if center.items.count > 1 {
                    Text("+\(center.items.count - 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let cancel = item.cancel {
                    Button { cancel() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("キャンセル")
                }
            }
        }
    }

    private func itemInfo(_ item: ActivityCenter.Item) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(item.isFinished ? item.detail : item.title)
                .font(.system(size: 10))
                .foregroundStyle(item.isFinished ? Color.green : Color.secondary)
                .lineLimit(1)
            progressBar(item)
        }
        .frame(maxWidth: 150, alignment: .trailing)
    }

    @ViewBuilder
    private func progressBar(_ item: ActivityCenter.Item) -> some View {
        if let value = item.progress {
            HStack(spacing: 6) {
                ProgressView(value: min(1, max(0, value))).frame(width: 90)
                Text("\(Int(value * 100))%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        } else {
            ProgressView().controlSize(.small).progressViewStyle(.linear).frame(width: 90)
        }
    }
}
