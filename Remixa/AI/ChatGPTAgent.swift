import Foundation
import os

// MARK: - SSE parsing (pure)

/// Progress notifications surfaced to the UI (status line, tool log, reasoning summary).
enum ChatGPTProgress: Sendable, Equatable {
    case status(String)
    case toolLog(String)
    case summaryDelta(String)
}

enum ResponsesEvent: Sendable, Equatable {
    case created
    case outputItemAdded(JSONValue)
    case argumentsDone
    case summaryDelta(String)
    case textDelta(String)
    case outputItemDone(JSONValue)
    case completed
    case failed(String?)
    case incomplete
    case error(String?)
    case other
}

enum ResponsesSSE {
    /// Parses one SSE line. Only `data:` lines carry events; each OpenAI event is a single `data:` line.
    static func parse(line: String) -> ResponsesEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]", let json = JSONValue.parse(Data(payload.utf8)),
              let type = json["type"]?.stringValue else { return .other }
        switch type {
        case "response.output_text.delta":
            if let delta = json["delta"]?.stringValue { return .textDelta(delta) }
            return .other
        case "response.created":
            return .created
        case "response.output_item.added":
            if let item = json["item"] { return .outputItemAdded(item) }
            return .other
        case "response.function_call_arguments.done":
            return .argumentsDone
        case "response.reasoning_summary_text.delta":
            if let delta = json["delta"]?.stringValue { return .summaryDelta(delta) }
            return .other
        case "response.output_item.done":
            if let item = json["item"] { return .outputItemDone(item) }
            return .other
        case "response.completed":
            return .completed
        case "response.failed":
            return .failed(json["response"]?["error"]?["message"]?.stringValue)
        case "response.incomplete":
            return .incomplete
        case "error":
            return .error(json["message"]?.stringValue ?? json["error"]?["message"]?.stringValue)
        default:
            return .other
        }
    }
}

// MARK: - MCP tool conversion (pure)

enum ChatGPTToolConverter {
    /// MCP `tools/list` result tools -> Responses API function tools.
    static func functionTools(fromMCP tools: [JSONValue]) -> [JSONValue] {
        tools.compactMap { tool in
            guard let name = tool["name"]?.stringValue else { return nil }
            var parameters = tool["inputSchema"] ?? .object([:])
            if case .object(var o) = parameters {
                if o["type"] == nil { o["type"] = "object" }
                if o["properties"] == nil { o["properties"] = .object([:]) }
                parameters = .object(o)
            } else {
                parameters = ["type": "object", "properties": .object([:])]
            }
            return .object([
                "type": "function",
                "name": .string(name),
                "description": .string(tool["description"]?.stringValue ?? ""),
                "parameters": parameters,
                "strict": false
            ])
        }
    }

    /// "key=value, key=value" (max 2 entries, values truncated) for the one-line tool log.
    static func argumentSummary(_ args: JSONValue) -> String {
        guard case .object(let o) = args else { return "" }
        return o.keys.sorted().prefix(2).map { key in
            let value: String
            switch o[key] {
            case .string(let v)?: value = v
            case .number(let v)?: value = v == v.rounded() ? String(Int(v)) : String(v)
            case .bool(let v)?: value = String(v)
            default: value = "…"
            }
            return "\(key)=\(value.count > 24 ? String(value.prefix(24)) + "…" : value)"
        }.joined(separator: ", ")
    }

    /// Flattens an MCP `tools/call` result into the text sent back as `function_call_output`.
    static func outputText(fromMCPResult result: JSONValue) -> String {
        let parts = (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        var text = parts.joined(separator: "\n")
        if text.isEmpty { text = "(結果なし)" }
        if text.count > 100_000 { text = String(text.prefix(100_000)) + "\n…(長すぎるため省略)" }
        return result["isError"]?.boolValue == true ? "エラー: " + text : text
    }
}

// MARK: - Debug logging

enum ChatGPTDebugLog {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.remixa", category: "chatgpt")
    #endif

    /// DEBUG builds only (os_log, subsystem com.remixa / category chatgpt).
    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }
}

// MARK: - MCP stdio client

/// Talks to `remixa mcp` over newline-delimited JSON-RPC. Reads are event driven (no blocking read),
/// and every request has a deadline: on timeout the pending call fails and the child is terminated.
final class MCPStdioClient: @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<JSONValue, Error>

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let queue = DispatchQueue(label: "remixa.chatgpt.mcp")
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [Int: (label: String, cont: Continuation)] = [:]
    private var nextID = 1

    init(executablePath: String) {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["mcp"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
    }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: process.executableURL?.path ?? "") else {
            throw ChatGPTError(code: "mcp_missing", message: "Remixaの操作用ヘルパー(remixa)が見つかりません。")
        }
        signal(SIGPIPE, SIG_IGN) // a dead child must surface as an error, not kill the app
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.failAll(Self.closedError)
            } else {
                self?.ingest(data)
            }
        }
        do { try process.run() } catch {
            throw ChatGPTError(code: "mcp_failed", message: "Remixaの操作用ヘルパーを起動できませんでした。")
        }
    }

    func terminate() {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? stdin.fileHandleForWriting.close()
        failAll(Self.closedError)
    }

    private static let closedError = ChatGPTError(code: "mcp_closed", message: "Remixaの操作用ヘルパーが予期せず終了しました。")

    // MARK: sending

    private func encode(_ message: [String: JSONValue]) throws -> Data {
        guard var data = JSONValue.object(message).serialized() else {
            throw ChatGPTError(code: "mcp_encode", message: "Remixaへの依頼をJSONに変換できませんでした(数値などが不正です)。")
        }
        data.append(0x0A)
        return data
    }

    private func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    func notify(_ method: String) {
        guard let data = try? encode(["jsonrpc": "2.0", "method": .string(method)]) else { return }
        ChatGPTDebugLog.debug("mcp -> notify \(method)")
        queue.async { [self] in try? stdin.fileHandleForWriting.write(contentsOf: data) }
    }

    /// `label` names the operation in the timeout error (e.g. the tool name).
    func request(_ method: String, params: JSONValue? = nil, timeout: TimeInterval, label: String? = nil) async throws -> JSONValue {
        let id = allocateID()
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { message["params"] = params }
        let data = try encode(message)
        let name = label ?? method
        ChatGPTDebugLog.debug("mcp -> request id=\(id) method=\(method) label=\(name)")
        return try await withCheckedThrowingContinuation { (cont: Continuation) in
            register(id: id, label: name, cont: cont)
            queue.async { [self] in
                do { try stdin.fileHandleForWriting.write(contentsOf: data) } catch {
                    resolve(id: id, .failure(Self.closedError))
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                let timeoutError = ChatGPTError(code: "mcp_timeout", message: "Remixaの操作が応答しません(\(name))。")
                if resolve(id: id, .failure(timeoutError)) {
                    ChatGPTDebugLog.debug("mcp timeout id=\(id) label=\(name)")
                    terminate()
                }
            }
        }
    }

    // MARK: receiving

    private func register(id: Int, label: String, cont: Continuation) {
        lock.lock(); defer { lock.unlock() }
        pending[id] = (label, cont)
    }

    /// Completes a pending request exactly once; returns false when it was already completed.
    @discardableResult
    private func resolve(id: Int, _ result: Result<JSONValue, Error>) -> Bool {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return false }
        entry.cont.resume(with: result)
        return true
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let all = pending
        pending = [:]
        lock.unlock()
        for (_, entry) in all { entry.cont.resume(throwing: error) }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<nl]))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines where !line.isEmpty { handle(line: line) }
    }

    private func handle(line: Data) {
        guard let json = JSONValue.parse(line) else {
            ChatGPTDebugLog.debug("mcp <- unparseable line: \(String(decoding: line.prefix(300), as: UTF8.self))")
            return
        }
        guard let idValue = json["id"]?.numberValue, json["method"] == nil else {
            ChatGPTDebugLog.debug("mcp <- ignored message method=\(json["method"]?.stringValue ?? "-")")
            return
        }
        let id = Int(idValue)
        ChatGPTDebugLog.debug("mcp <- response id=\(id)")
        if let error = json["error"] {
            let text = error["message"]?.stringValue ?? "不明"
            if !resolve(id: id, .failure(ChatGPTError(code: "mcp_error", message: "Remixaの操作でエラーが発生しました: \(text)"))) {
                ChatGPTDebugLog.debug("mcp <- unmatched error id=\(id)")
            }
        } else if !resolve(id: id, .success(json["result"] ?? .object([:]))) {
            ChatGPTDebugLog.debug("mcp <- unmatched response id=\(id)")
        }
    }
}

/// Tracks the last time the SSE stream showed life (any line), for the idle watchdog.
final class StreamHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() { lock.lock(); last = Date(); lock.unlock() }

    var idleSeconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}

// MARK: - Agent

/// A saved user/assistant turn used to rebuild ChatGPT context when resuming a conversation.
struct ChatContextTurn: Sendable {
    let isUser: Bool
    let text: String
}

/// Responses-API tool-calling loop against the user's ChatGPT plan, driving Remixa via `remixa mcp`.
actor ChatGPTAgent {
    static let shared = ChatGPTAgent()

    static let maxTurns = 20
    static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    static let instructions = """
    あなたはRemixa(macOS用DAWアプリ)を、提供されたツール経由で操作するアシスタントです。\
    まず project_get ツールで現在のプロジェクトの状態(トラック、クリップ、BPMなど)を確認してから作業してください。\
    トラックやクリップの追加・編集、再生、書き出しなどはすべてツールを通じて行い、推測で進めず、\
    行った操作と結果を日本語で簡潔に報告してください。必ず日本語で返答してください。
    """

    /// Client-side conversation (store:false means the server keeps nothing).
    private var history: [JSONValue] = []

    /// Which saved conversation `history` belongs to (nil = none / fresh).
    private var historyOwner: UUID?

    func resetConversation() { history = []; historyOwner = nil }

    /// store:false means no previous_response_id is available, so when the active
    /// conversation differs from the one in memory, rebuild the input from saved messages.
    private func adopt(conversationID: UUID?, prior: [ChatContextTurn]) {
        guard let conversationID else { return }
        if historyOwner == conversationID { return }
        history = prior.suffix(40).map { turn in
            let text = turn.text.count > 4000 ? String(turn.text.prefix(4000)) + "…" : turn.text
            return ["role": .string(turn.isUser ? "user" : "assistant"), "content": .string(text)]
        }
        historyOwner = conversationID
    }

    struct FunctionCall: Sendable {
        let callID: String
        let name: String
        let arguments: String
    }

    struct TurnResult: Sendable {
        var text = ""
        var calls: [FunctionCall] = []
    }

    func run(prompt: String, conversationID: UUID? = nil, prior: [ChatContextTurn] = [],
             onOutput: @escaping @MainActor @Sendable (String) -> Void,
             onProgress: @escaping @MainActor @Sendable (ChatGPTProgress) -> Void) async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/remixa").path
        let mcp = MCPStdioClient(executablePath: helper)
        try mcp.start()
        defer { mcp.terminate() }
        adopt(conversationID: conversationID, prior: prior)
        let snapshot = history
        do {
            try await withTaskCancellationHandler {
                try await runLoop(prompt: prompt, mcp: mcp, onOutput: onOutput, onProgress: onProgress)
            } onCancel: {
                mcp.terminate()
            }
        } catch {
            history = snapshot
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func runLoop(prompt: String, mcp: MCPStdioClient,
                         onOutput: @escaping @MainActor @Sendable (String) -> Void,
                         onProgress: @escaping @MainActor @Sendable (ChatGPTProgress) -> Void) async throws {
        await onProgress(.status("準備中…"))
        _ = try await mcp.request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": .object([:]),
            "clientInfo": ["name": "remixa-chatgpt", "version": "1"]
        ], timeout: 15)
        mcp.notify("notifications/initialized")
        let listed = try await mcp.request("tools/list", timeout: 15)
        let tools = ChatGPTToolConverter.functionTools(fromMCP: listed["tools"]?.arrayValue ?? [])

        let model = try await ChatGPTAuth.shared.resolveModel()
        var useSummary = true
        var effort = await ChatGPTAuth.shared.effectiveReasoningEffort(model: model)
        var working = history
        working.append(["role": "user", "content": .string(prompt)])

        for _ in 0..<Self.maxTurns {
            try Task.checkCancellation()
            let token = try await ChatGPTAuth.shared.validAccessToken()
            var attempt: TurnResult?
            while attempt == nil {
                do {
                    attempt = try await Self.streamTurn(accessToken: token, model: model, input: working, tools: tools,
                                                        effort: effort, summary: useSummary,
                                                        onOutput: onOutput, onProgress: onProgress)
                } catch let error as ChatGPTError where error.code == "http_400" && (useSummary || effort != nil) {
                    // 非対応パラメータの可能性: まず要約、次に思考量を外して再試行
                    if useSummary { useSummary = false } else { effort = nil }
                }
            }
            guard let turn = attempt else { return }
            if !turn.text.isEmpty {
                working.append(["role": "assistant", "content": .string(turn.text)])
            }
            if turn.calls.isEmpty {
                history = working
                return
            }
            for call in turn.calls {
                try Task.checkCancellation()
                await onProgress(.status("ツール実行中: \(call.name)"))
                working.append(["type": "function_call", "call_id": .string(call.callID),
                                "name": .string(call.name), "arguments": .string(call.arguments)])
                let args = JSONValue.parse(Data(call.arguments.utf8)) ?? .object([:])
                let (output, ok) = try await Self.execute(call: call, mcp: mcp)
                working.append(["type": "function_call_output", "call_id": .string(call.callID), "output": .string(output)])
                let summary = ChatGPTToolConverter.argumentSummary(args)
                await onProgress(.toolLog("🔧 \(call.name)(\(summary)) → \(ok ? "成功" : "失敗")"))
            }
            await onProgress(.status("考え中…"))
        }
        throw ChatGPTError(code: "too_many_turns", message: "ツール呼び出しの往復が上限(\(Self.maxTurns)回)に達したため中断しました。指示を分けてもう一度お試しください。")
    }

    /// Slow tools (waits until finished) get long deadlines; everything else 120s.
    static func timeout(forTool name: String) -> TimeInterval {
        switch name {
        case "export_mix", "export_stems", "stems_install", "stems_separate": return 1800
        case "audio_analyze": return 300
        default: return 120
        }
    }

    /// Returns (output for the model, success). Timeouts / helper death propagate and end the run.
    private static func execute(call: FunctionCall, mcp: MCPStdioClient) async throws -> (String, Bool) {
        let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = JSONValue.object([:])
        if !trimmed.isEmpty {
            guard let parsed = JSONValue.parse(Data(trimmed.utf8)), case .object = parsed, parsed.serialized() != nil else {
                return ("エラー: 引数が正しいJSONオブジェクトではありません。JSONの形式を確認してもう一度ツールを呼び出してください。", false)
            }
            args = parsed
        }
        do {
            let result = try await mcp.request("tools/call", params: ["name": .string(call.name), "arguments": args],
                                               timeout: timeout(forTool: call.name), label: call.name)
            return (ChatGPTToolConverter.outputText(fromMCPResult: result), result["isError"]?.boolValue != true)
        } catch let error as ChatGPTError where error.code == "mcp_timeout" || error.code == "mcp_closed" {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ("エラー: \(error.localizedDescription)", false)
        }
    }

    // MARK: request

    static func requestBody(model: String, input: [JSONValue], tools: [JSONValue], effort: String? = nil, summary: Bool = false) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "input": .array(input),
            "instructions": .string(instructions),
            "store": false,
            "stream": true
        ]
        if !tools.isEmpty { body["tools"] = .array(tools) }
        var reasoning: [String: JSONValue] = [:]
        if let effort { reasoning["effort"] = .string(effort) }
        if summary { reasoning["summary"] = "auto" }
        if !reasoning.isEmpty { body["reasoning"] = .object(reasoning) }
        return .object(body)
    }

    static func consumeTurn(
        heartbeat: StreamHeartbeat,
        accessToken: String, model: String, input: [JSONValue], tools: [JSONValue], effort: String? = nil, summary: Bool = false,
        onOutput: @escaping @MainActor @Sendable (String) -> Void,
        onProgress: @escaping @MainActor @Sendable (ChatGPTProgress) -> Void
    ) async throws -> TurnResult {
        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = requestBody(model: model, input: input, tools: tools, effort: effort, summary: summary).serialized()

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await ChatGPTHTTP.session.bytes(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ChatGPTError(code: "network_error", message: "ChatGPTに接続できませんでした。ネットワーク接続を確認してもう一度お試しください。")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTError(code: "network_error", message: "ChatGPTに接続できませんでした。")
        }
        guard http.statusCode == 200 else {
            var body = Data()
            do { for try await byte in bytes { body.append(byte); if body.count > 65536 { break } } } catch {}
            throw httpError(status: http.statusCode, body: body)
        }
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased(), type != "text/event-stream" {
            throw ChatGPTError(code: "invalid_stream", message: "ChatGPTから想定外の応答が返されました。もう一度お試しください。")
        }

        heartbeat.touch()
        var result = TurnResult()
        var completed = false
        do {
            for try await line in bytes.lines {
                heartbeat.touch()
                guard let event = ResponsesSSE.parse(line: line) else { continue }
                switch event {
                case .created:
                    await onProgress(.status("考え中…"))
                case .outputItemAdded(let item):
                    switch item["type"]?.stringValue {
                    case "reasoning": await onProgress(.status("考え中…"))
                    case "function_call": await onProgress(.status("操作を準備中: \(item["name"]?.stringValue ?? "")"))
                    case "message": await onProgress(.status("結果を受信中…"))
                    default: break
                    }
                case .argumentsDone:
                    await onProgress(.status("操作の引数を受信しました"))
                case .summaryDelta(let delta):
                    await onProgress(.summaryDelta(delta))
                case .textDelta(let delta):
                    if result.text.isEmpty { await onProgress(.status("結果を受信中…")) }
                    result.text += delta
                    if result.text.count > 16 * 1024 * 1024 {
                        throw ChatGPTError(code: "response_too_large", message: "応答が大きすぎます。依頼を小さく分けてください。")
                    }
                    await onOutput(delta)
                case .outputItemDone(let item):
                    if item["type"]?.stringValue == "function_call",
                       let callID = item["call_id"]?.stringValue, let name = item["name"]?.stringValue {
                        result.calls.append(FunctionCall(callID: callID, name: name, arguments: item["arguments"]?.stringValue ?? "{}"))
                    }
                case .completed:
                    completed = true
                case .failed(let message), .error(let message):
                    throw ChatGPTError(code: "response_failed", message: "ChatGPTの応答に失敗しました\(message.map { ": " + String($0.prefix(200)) } ?? "")。")
                case .incomplete:
                    throw ChatGPTError(code: "response_incomplete", message: "ChatGPTが応答を最後まで生成できませんでした。もう一度お試しください。")
                case .other:
                    break
                }
                if completed { break }
            }
        } catch let error as ChatGPTError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChatGPTError(code: "stream_interrupted", message: "ChatGPTとの接続が途中で切れました。もう一度お試しください。")
        }
        try Task.checkCancellation()
        guard completed else {
            throw ChatGPTError(code: "stream_interrupted", message: "応答が完了する前に終了しました。もう一度お試しください。")
        }
        return result
    }

    static let streamIdleLimit: TimeInterval = 60

    /// One Responses request. Fails when no SSE line arrives for 60s (separate from the 180s overall limit).
    static func streamTurn(
        accessToken: String, model: String, input: [JSONValue], tools: [JSONValue], effort: String? = nil, summary: Bool = false,
        onOutput: @escaping @MainActor @Sendable (String) -> Void,
        onProgress: @escaping @MainActor @Sendable (ChatGPTProgress) -> Void
    ) async throws -> TurnResult {
        let beat = StreamHeartbeat()
        return try await withThrowingTaskGroup(of: TurnResult?.self) { group in
            group.addTask {
                try await consumeTurn(heartbeat: beat, accessToken: accessToken, model: model, input: input, tools: tools,
                                      effort: effort, summary: summary, onOutput: onOutput, onProgress: onProgress)
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    if beat.idleSeconds > streamIdleLimit {
                        throw ChatGPTError(code: "stream_idle", message: "ChatGPTからの応答が\(Int(streamIdleLimit))秒間ありません。止まったとみなして中断しました。もう一度お試しください。")
                    }
                }
                return nil
            }
            defer { group.cancelAll() }
            if let first = try await group.next(), let turn = first { return turn }
            throw CancellationError()
        }
    }

    // MARK: errors

    nonisolated static func httpError(status: Int, body: Data) -> ChatGPTError {
        let json = JSONValue.parse(body)
        let detail = json?["error"]?["message"]?.stringValue ?? json?["error"]?.stringValue ?? json?["detail"]?.stringValue
        switch status {
        case 401:
            return ChatGPTError(code: "unauthorized", message: "ChatGPTの認証が無効です。サインアウトしてもう一度サインインしてください。")
        case 403:
            return ChatGPTError(code: "forbidden", message: "このChatGPTアカウントではこの操作が許可されていません。プランやサインインし直しを確認してください。")
        case 429:
            return ChatGPTError(code: "rate_limited", message: "ChatGPTプランの利用上限に達しました。時間をおくか、パネルの「使用量を管理」から利用状況を確認してください。")
        case 500...599:
            return ChatGPTError(code: "server_error", message: "ChatGPT側でエラーが発生しました (\(status))。しばらくしてからお試しください。")
        default:
            return ChatGPTError(code: "http_\(status)", message: "ChatGPTへのリクエストが失敗しました (\(status))\(detail.map { ": " + String($0.prefix(200)) } ?? "")。")
        }
    }
}
