import SwiftUI

/// Toggleable side panel ("AIアシスタント") that lets the user chat with an AI CLI
/// (Claude Code or Codex) which drives the app itself through the `remixa mcp`
/// MCP server. History is kept in-session only (not persisted across launches).
struct AIAssistantPanel: View {
    @AppStorage("aiBackendKind") private var backendRaw: String = AIBackendKind.claude.rawValue
    @StateObject private var runner = AIAssistantRunner()

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var resolvedPaths: [AIBackendKind: String] = [:]

    private var backend: AIBackendKind { AIBackendKind(rawValue: backendRaw) ?? .claude }
    private var backendPath: String? { resolvedPaths[backend] }

    struct ChatMessage: Identifiable {
        let id = UUID()
        let role: Role
        var text: String
        enum Role { case user, assistant, system }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputArea
        }
        .onAppear { refreshAvailability() }
        .onChange(of: backendRaw) { _, _ in refreshAvailability() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AIアシスタント").font(.headline)
            Picker("バックエンド", selection: $backendRaw) {
                ForEach(AIBackendKind.allCases) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let backendPath {
                Text(backendPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(backend.installHint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if messages.isEmpty {
                        Text("Remixaを操作してほしいことを日本語で入力してください。例:「BPMを128にして」「トラック1にリバーブをかけて」")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    ForEach(messages) { message in
                        messageView(message)
                    }
                }
                .padding(8)
            }
            .onChange(of: messages.last?.text) { _, _ in
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(roleLabel(message.role))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.system(.body, design: message.role == .system ? .default : .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background(for: message.role))
                .cornerRadius(6)
        }
        .id(message.id)
    }

    private func roleLabel(_ role: ChatMessage.Role) -> String {
        switch role {
        case .user: return "あなた"
        case .assistant: return backend.displayName
        case .system: return "システム"
        }
    }

    private func background(for role: ChatMessage.Role) -> Color {
        switch role {
        case .user: return Color.accentColor.opacity(0.15)
        case .assistant: return Color.gray.opacity(0.12)
        case .system: return Color.orange.opacity(0.12)
        }
    }

    private var inputArea: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $inputText)
                .font(.body)
                .frame(height: 56)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                if runner.isRunning {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    Button("キャンセル") { runner.cancel() }
                }
                Spacer()
                Button("送信") { send() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSend)
            }
        }
        .padding(10)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !runner.isRunning
            && backendPath != nil
    }

    private func refreshAvailability() {
        for kind in AIBackendKind.allCases {
            if let path = AIBackendLocator.resolve(kind) {
                resolvedPaths[kind] = path
            } else {
                resolvedPaths.removeValue(forKey: kind)
            }
        }
    }

    private func send() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let executablePath = backendPath else { return }
        inputText = ""

        messages.append(ChatMessage(role: .user, text: prompt))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let assistantID = messages[messages.count - 1].id

        let systemContext = """
        あなたはRemixa(macOS用DAWアプリ)をMCPツール経由で操作するアシスタントです。\
        まず project_get ツールを呼び出して現在のプロジェクトの状態(トラック、クリップ、BPMなど)を\
        確認してから作業してください。トラックやクリップの追加・編集、再生、ミックスの書き出しなどは\
        すべてMCPツールを通じて行い、勝手に推測で進めず、行った操作と結果を日本語で簡潔に報告してください。
        """
        let fullPrompt = systemContext + "\n\n---\n\nユーザーの指示:\n" + prompt

        runner.run(backend: backend, executablePath: executablePath, prompt: fullPrompt, onOutput: { chunk in
            appendToMessage(id: assistantID, chunk: chunk)
        }, onFinish: { code in
            if code != 0, code != -15 { // -15 == SIGTERM (user cancel)
                messages.append(ChatMessage(role: .system, text: "プロセスが終了しました (code \(code))"))
            }
        })
    }

    private func appendToMessage(id: UUID, chunk: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += chunk
    }
}
