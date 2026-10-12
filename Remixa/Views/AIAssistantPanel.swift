import SwiftUI
import UniformTypeIdentifiers

/// Toggleable side panel ("AIアシスタント") that lets the user chat with an AI CLI
/// (Claude Code or Codex) which drives the app itself through the `remixa mcp`
/// MCP server. History is kept in-session only (not persisted across launches).
struct AIAssistantPanel: View {
    @AppStorage("aiBackendKind") private var backendRaw: String = AIBackendKind.claude.rawValue
    @StateObject private var runner = AIAssistantRunner()
    @ObservedObject private var chatGPT = ChatGPTAuth.shared

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var currentAssistantID: UUID?
    @State private var currentThoughtID: UUID?
    @State private var resolvedPaths: [AIBackendKind: String] = [:]
    @EnvironmentObject private var project: RemixaProject
    @ObservedObject private var store = ChatStore.shared
    @State private var chatID = UUID()
    @State private var chatCreatedAt = Date()
    @State private var customTitle: String?
    @State private var lastSaveAt = Date.distantPast
    @State private var showList = false

    private var backend: AIBackendKind { AIBackendKind(rawValue: backendRaw) ?? .claude }
    private var backendPath: String? { resolvedPaths[backend] }
    private var isBackendReady: Bool {
        backend == .chatgpt ? (chatGPT.isSignedIn && chatGPT.planAvailable) : backendPath != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if chatGPT.usageLimitReached && backend == .chatgpt {
                ChatGPTUsageLimitCard { chatGPT.clearUsageLimit() }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider()
            AIProgressStrip(runner: runner)
            inputArea
        }
        .sheet(isPresented: Binding(get: { chatGPT.showWelcome }, set: { if !$0 { chatGPT.dismissWelcome() } })) {
            ChatGPTWelcomeView { chatGPT.dismissWelcome() }
        }
        .sheet(isPresented: $showList) {
            AIChatListView(store: store, currentID: chatID, disabled: runner.isRunning) { id in
                openChat(id)
            }
        }
        .onAppear { refreshAvailability(); restoreOnAppear() }
        .onChange(of: backendRaw) { _, _ in refreshAvailability() }
        .onChange(of: store.pendingOpenID) { _, id in consumePending(id) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AIアシスタント").font(.headline)
                Spacer()
                AIChatToolbar(
                    isRunning: runner.isRunning,
                    hasMessages: messages.contains { $0.role == .user },
                    onList: { showList = true },
                    onNew: { newChat() },
                    onRename: { renameCurrent($0) },
                    onSaveMarkdown: { saveMarkdown() },
                    onCopyMarkdown: { copyMarkdown() },
                    currentTitle: currentRecord()?.title ?? "新しいチャット"
                )
            }
            Picker("バックエンド", selection: $backendRaw) {
                ForEach(AIBackendKind.allCases) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if backend == .chatgpt {
                ChatGPTAccountView(auth: chatGPT)
            } else if let backendPath {
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
            .onChange(of: messages.last?.text) { _, _ in scrollToEnd(proxy) }
            .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    @ViewBuilder
    private func messageView(_ message: ChatMessage) -> some View {
        if message.role == .tool || message.role == .thought {
            Text(message.text)
                .font(.caption)
                .italic(message.role == .thought)
                .foregroundStyle(.secondary.opacity(0.8))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .id(message.id)
        } else {
            bubbleView(message)
        }
    }

    private func bubbleView(_ message: ChatMessage) -> some View {
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
        case .tool, .thought: return ""
        }
    }

    private func background(for role: ChatMessage.Role) -> Color {
        switch role {
        case .user: return Color.accentColor.opacity(0.15)
        case .assistant: return Color.gray.opacity(0.12)
        case .system: return Color.orange.opacity(0.12)
        case .tool, .thought: return Color.clear
        }
    }

    private var inputArea: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $inputText)
                .font(.body)
                .frame(height: 56)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
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
            && isBackendReady
    }

    private func refreshAvailability() {
        for kind in AIBackendKind.allCases where kind.requiresCLI {
            if let path = AIBackendLocator.resolve(kind) {
                resolvedPaths[kind] = path
            } else {
                resolvedPaths.removeValue(forKey: kind)
            }
        }
    }

    private func send() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, isBackendReady else { return }
        inputText = ""

        let prior = messages
        messages.append(ChatMessage(role: .user, text: prompt))
        currentAssistantID = nil
        currentThoughtID = nil
        persist(force: true)

        let finish: @MainActor @Sendable (Int32) -> Void = { code in
            if code != 0, code != -15, backend != .chatgpt { // -15 == SIGTERM (user cancel)
                messages.append(ChatMessage(role: .system, text: "プロセスが終了しました (code \(code))"))
            }
            finishRun(code: code)
        }

        if backend == .chatgpt {
            chatGPT.clearUsageLimit()
            let turns = prior.filter { $0.role == .user || $0.role == .assistant }
                .map { ChatContextTurn(isUser: $0.role == .user, text: $0.text) }
            runner.runChatGPT(prompt: prompt, conversationID: chatID, prior: turns, onOutput: { chunk in
                appendAssistant(chunk)
            }, onProgress: { event in
                handleProgress(event)
            }, onFinish: finish)
            return
        }
        guard let executablePath = backendPath else { return }

        let systemContext = """
        あなたはRemixa(macOS用DAWアプリ)をMCPツール経由で操作するアシスタントです。\
        まず project_get ツールを呼び出して現在のプロジェクトの状態(トラック、クリップ、BPMなど)を\
        確認してから作業してください。トラックやクリップの追加・編集、再生、ミックスの書き出しなどは\
        すべてMCPツールを通じて行い、勝手に推測で進めず、行った操作と結果を日本語で簡潔に報告してください。
        """
        let preface = ChatStore.contextPreface(from: prior)
        let fullPrompt = systemContext + "\n\n---\n\n" + preface + "ユーザーの指示:\n" + prompt

        runner.run(backend: backend, executablePath: executablePath, prompt: fullPrompt, onOutput: { chunk in
            appendAssistant(chunk)
        }, onFinish: finish)
    }

    /// Streams text into the current assistant bubble, starting a new one after a tool line.
    private func appendAssistant(_ chunk: String) {
        currentThoughtID = nil
        if let id = currentAssistantID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += chunk
        } else {
            let message = ChatMessage(role: .assistant, text: chunk)
            messages.append(message)
            currentAssistantID = message.id
        }
        persist(force: false)
    }

    private func handleProgress(_ event: ChatGPTProgress) {
        switch event {
        case .status:
            break // shown by AIProgressStrip
        case .toolLog(let line):
            currentAssistantID = nil
            currentThoughtID = nil
            messages.append(ChatMessage(role: .tool, text: line))
            persist(force: false)
        case .summaryDelta(let delta):
            if let id = currentThoughtID, let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text += delta
            } else {
                let message = ChatMessage(role: .thought, text: delta)
                messages.append(message)
                currentThoughtID = message.id
                currentAssistantID = nil
            }
        }
    }

    // MARK: persistence

    private func currentRecord() -> ChatRecord? {
        guard messages.contains(where: { $0.role == .user }) else { return nil }
        let title = customTitle ?? ChatStore.autoTitle(from: messages)
        return ChatRecord(
            id: chatID, title: title, customTitle: customTitle != nil,
            createdAt: chatCreatedAt, updatedAt: Date(), backend: backendRaw,
            model: backend == .chatgpt ? chatGPT.selectedModel : nil,
            projectName: project.fileURL?.deletingPathExtension().lastPathComponent,
            messages: messages
        )
    }

    /// Saves the conversation; streaming updates are throttled to once per 1.5s.
    private func persist(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSaveAt) > 1.5 else { return }
        guard let record = currentRecord() else { return }
        lastSaveAt = now
        store.save(record)
    }

    private func finishRun(code: Int32) {
        persist(force: true)
        guard code != -15 else { return }
        let lastReply = messages.last(where: { $0.role == .assistant })?.text ?? ""
        let failed = code != 0
        let text = failed && lastReply.isEmpty ? "プロセスが終了しました (code \(code))" : lastReply
        AINotifier.shared.notifyAIFinished(chatID: chatID, text: text, isError: failed)
    }

    private func newChat() {
        guard !runner.isRunning else { return }
        persist(force: true)
        messages = []
        chatID = UUID()
        chatCreatedAt = Date()
        customTitle = nil
        currentAssistantID = nil
        currentThoughtID = nil
        Task { await ChatGPTAgent.shared.resetConversation() }
    }

    private func openChat(_ id: UUID) {
        guard !runner.isRunning, id != chatID || messages.isEmpty, let record = store.load(id) else { return }
        persist(force: true)
        messages = record.messages
        chatID = record.id
        chatCreatedAt = record.createdAt
        customTitle = record.customTitle ? record.title : nil
        currentAssistantID = nil
        currentThoughtID = nil
        lastSaveAt = Date()
    }

    private func renameCurrent(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        customTitle = t
        persist(force: true)
    }

    private func restoreOnAppear() {
        if let id = store.pendingOpenID { consumePending(id); return }
        guard messages.isEmpty, let latest = store.summaries.first else { return }
        openChat(latest.id)
    }

    private func consumePending(_ id: UUID?) {
        guard let id else { return }
        store.pendingOpenID = nil
        openChat(id)
    }

    private func saveMarkdown() {
        guard let record = currentRecord() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = record.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ChatMarkdown.render(record).write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyMarkdown() {
        guard let record = currentRecord() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ChatMarkdown.render(record), forType: .string)
    }
}
