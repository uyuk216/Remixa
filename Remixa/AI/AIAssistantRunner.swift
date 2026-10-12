import Foundation

/// Runs a CLI AI backend (`claude` or `codex`) as a non-interactive subprocess,
/// wired up to the Remixa MCP server (`remixa mcp`, exposed by the CLI target)
/// so the AI can drive the live app. Streams stdout/stderr chunks back to the
/// caller as they arrive; never blocks the calling (main) thread.
@MainActor
final class AIAssistantRunner: ObservableObject {
    @Published private(set) var isRunning = false
    /// Current progress line ("考え中…" etc.) and when the run started; both nil while idle.
    @Published private(set) var statusText: String?
    @Published private(set) var startedAt: Date?

    private func beginProgress() {
        startedAt = Date()
        statusText = "考え中…"
    }

    private func clearProgress() {
        statusText = nil
        startedAt = nil
    }

    private var process: Process?
    private var mcpConfigURL: URL?
    private var chatGPTTask: Task<Void, Never>?

    /// Starts `backend` with `prompt`. `onOutput` is called on the main actor with
    /// each chunk of interleaved stdout/stderr text as it streams in; `onFinish`
    /// is called once, also on the main actor, with the process's exit code
    /// (or a negative value if the process could not even be launched).
    func run(
        backend: AIBackendKind,
        executablePath: String,
        prompt: String,
        onOutput userOutput: @escaping @MainActor @Sendable (String) -> Void,
        onFinish: @escaping @MainActor @Sendable (Int32) -> Void
    ) {
        cancel() // only one run at a time
        beginProgress()
        let onOutput: @MainActor @Sendable (String) -> Void = { [weak self] chunk in
            self?.statusText = "応答を受信中…"
            userOutput(chunk)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)

        let mcpCommand = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/remixa").path

        switch backend {
        case .claude:
            let config: [String: Any] = [
                "mcpServers": [
                    "remixa": [
                        "command": mcpCommand,
                        "args": ["mcp"]
                    ]
                ]
            ]
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("remixa-mcp-\(UUID().uuidString).json")
            if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) {
                try? data.write(to: tmpURL)
            }
            mcpConfigURL = tmpURL
            process.arguments = [
                "-p", prompt,
                "--mcp-config", tmpURL.path,
                "--allowedTools", "mcp__remixa__*",
                "--permission-mode", "dontAsk",
                "--output-format", "text"
            ]
        case .chatgpt:
            // CLI不要。パネルは runChatGPT を使う。
            onFinish(-1)
            return
        case .codex:
            mcpConfigURL = nil
            process.arguments = [
                "exec", "--skip-git-repo-check",
                // ユーザーのconfig.toml(未対応モデル指定や他のMCP)を読まず、認証だけ使う
                "--ignore-user-config",
                // 非対話で承認待ちにならないよう、remixa MCPツールだけ承認不要にする(sandboxはread-onlyのまま)
                "-c", "approval_policy=\"never\"",
                "-c", "mcp_servers.remixa.default_tools_approval_mode=\"approve\"",
                "-c", "mcp_servers.remixa.command=\"\(mcpCommand)\"",
                "-c", "mcp_servers.remixa.args=[\"mcp\"]",
                prompt
            ]
        }

        process.environment = AIBackendLocator.childEnvironment(executablePath: executablePath)
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in onOutput(text) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in onOutput(text) }
        }

        process.terminationHandler = { [weak self] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.clearProgress()
                self.process = nil
                if let configURL = self.mcpConfigURL {
                    try? FileManager.default.removeItem(at: configURL)
                    self.mcpConfigURL = nil
                }
                onFinish(proc.terminationStatus)
            }
        }

        self.process = process
        isRunning = true
        do {
            try process.run()
        } catch {
            isRunning = false
            clearProgress()
            self.process = nil
            onOutput("実行に失敗しました: \(error.localizedDescription)")
            onFinish(-1)
        }
    }

    /// Runs the ChatGPT backend (Responses API tool loop, no subprocess for the model itself).
    func runChatGPT(
        prompt: String,
        conversationID: UUID? = nil,
        prior: [ChatContextTurn] = [],
        onOutput: @escaping @MainActor @Sendable (String) -> Void,
        onProgress: @escaping @MainActor @Sendable (ChatGPTProgress) -> Void,
        onFinish: @escaping @MainActor @Sendable (Int32) -> Void
    ) {
        cancel()
        isRunning = true
        beginProgress()
        let progress: @MainActor @Sendable (ChatGPTProgress) -> Void = { [weak self] event in
            if case .status(let text) = event { self?.statusText = text }
            onProgress(event)
        }
        chatGPTTask = Task { [weak self] in
            var code: Int32 = 0
            do {
                try await ChatGPTAgent.shared.run(prompt: prompt, conversationID: conversationID, prior: prior, onOutput: onOutput, onProgress: progress)
            } catch is CancellationError {
                code = -15
            } catch {
                if (error as? ChatGPTError)?.code == "rate_limited" { ChatGPTAuth.shared.reportUsageLimit() }
                onOutput("\n" + error.localizedDescription)
                code = 1
            }
            self?.isRunning = false
            self?.clearProgress()
            self?.chatGPTTask = nil
            onFinish(code)
        }
    }

    /// Terminates the currently running process, if any. Safe to call when idle.
    func cancel() {
        chatGPTTask?.cancel()
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        // Escalate if the CLI ignores SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
