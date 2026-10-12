import Foundation
import AppKit

/// One message of an AI assistant conversation (also the on-disk representation).
struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case user, assistant, system, tool, thought }
    var id = UUID()
    var role: Role
    var text: String
    var time = Date()

    init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// A saved conversation: ~/Library/Application Support/Remixa/Chats/<uuid>.json
struct ChatRecord: Identifiable, Codable, Sendable {
    var id: UUID
    var title: String
    var customTitle: Bool = false
    var createdAt: Date
    var updatedAt: Date
    var backend: String
    var model: String?
    var projectName: String?
    var messages: [ChatMessage]
}

/// List row (no message bodies kept in memory beyond a search blob).
struct ChatSummary: Identifiable, Sendable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var backend: String
    var projectName: String?
    var searchText: String
}

enum ChatMarkdown {
    static func render(_ record: ChatRecord) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let name = AIBackendKind(rawValue: record.backend)?.displayName ?? record.backend
        var out = "# \(record.title)\n\n"
        out += "- 作成: \(df.string(from: record.createdAt))\n- バックエンド: \(name)"
        if let model = record.model { out += " (\(model))" }
        out += "\n"
        if let project = record.projectName { out += "- プロジェクト: \(project)\n" }
        out += "\n"
        for message in record.messages {
            switch message.role {
            case .user: out += "## あなた\n\n\(message.text)\n\n"
            case .assistant: out += "## \(name)\n\n\(message.text)\n\n"
            case .system: out += "> \(message.text)\n\n"
            case .tool: out += "`\(message.text)`\n\n"
            case .thought: break
            }
        }
        return out
    }
}

/// Persistent store for assistant conversations. Files are written atomically.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var summaries: [ChatSummary] = []
    /// Set when a notification click (or similar) asks the panel to open a conversation.
    @Published var pendingOpenID: UUID?

    let directory: URL

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        self.directory = directory ?? base.appendingPathComponent("Remixa/Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.makeDecoder()
        var list: [ChatSummary] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let r = try? decoder.decode(ChatRecord.self, from: data) else { continue }
            list.append(Self.summary(of: r))
        }
        summaries = list.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func summary(of r: ChatRecord) -> ChatSummary {
        let body = r.messages.filter { $0.role == .user || $0.role == .assistant }.map(\.text).joined(separator: "\n")
        return ChatSummary(id: r.id, title: r.title, updatedAt: r.updatedAt, backend: r.backend,
                           projectName: r.projectName, searchText: r.title + "\n" + body)
    }

    func load(_ id: UUID) -> ChatRecord? {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? Self.makeDecoder().decode(ChatRecord.self, from: data)
    }

    func save(_ record: ChatRecord) {
        guard let data = try? Self.makeEncoder().encode(record) else { return }
        do { try data.write(to: fileURL(record.id), options: .atomic) } catch { return }
        let s = Self.summary(of: record)
        summaries.removeAll { $0.id == record.id }
        summaries.insert(s, at: 0)
        summaries.sort { $0.updatedAt > $1.updatedAt }
    }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, var r = load(id) else { return }
        r.title = t
        r.customTitle = true
        save(r)
    }

    /// Moves the conversation file to the Trash (never hard-deletes).
    func delete(_ id: UUID) {
        try? FileManager.default.trashItem(at: fileURL(id), resultingItemURL: nil)
        summaries.removeAll { $0.id == id }
    }

    func search(_ query: String) -> [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return summaries }
        return summaries.filter { $0.searchText.localizedCaseInsensitiveContains(q) }
    }

    /// Title from the first user message (first line, ~30 chars).
    static func autoTitle(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user })?.text else { return "新しいチャット" }
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? first
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "新しいチャット" }
        return trimmed.count > 30 ? String(trimmed.prefix(30)) + "…" : trimmed
    }

    /// Short preface summarizing recent turns, for CLI backends that keep no session.
    static func contextPreface(from messages: [ChatMessage], maxMessages: Int = 6, maxChars: Int = 500) -> String {
        let recent = messages.filter { $0.role == .user || $0.role == .assistant }.suffix(maxMessages)
        guard !recent.isEmpty else { return "" }
        let lines = recent.map { m -> String in
            let who = m.role == .user ? "ユーザー" : "アシスタント"
            let body = m.text.count > maxChars ? String(m.text.prefix(maxChars)) + "…" : m.text
            return "\(who): \(body)"
        }
        return "これまでの会話(直近の要約):\n" + lines.joined(separator: "\n") + "\n\n---\n\n"
    }
}
