import Foundation

// MARK: - SSE parsing (pure)

enum ResponsesEvent: Sendable, Equatable {
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

    /// Flattens an MCP `tools/call` result into the text sent back as `function_call_output`.
    static func outputText(fromMCPResult result: JSONValue) -> String {
        let parts = (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        var text = parts.joined(separator: "\n")
        if text.isEmpty { text = "(結果なし)" }
        if text.count > 100_000 { text = String(text.prefix(100_000)) + "\n…(長すぎるため省略)" }
        return result["isError"]?.boolValue == true ? "エラー: " + text : text
    }
}

// MARK: - MCP stdio client

/// Talks to `remixa mcp` over newline-delimited JSON-RPC. All blocking IO runs on a private queue.
final class MCPStdioClient: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let queue = DispatchQueue(label: "remixa.chatgpt.mcp")
    private var buffer = Data()
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
        do { try process.run() } catch {
            throw ChatGPTError(code: "mcp_failed", message: "Remixaの操作用ヘルパーを起動できませんでした。")
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        try? stdin.fileHandleForWriting.close()
    }

    func notify(_ method: String) {
        queue.async { [self] in
            try? write(["jsonrpc": "2.0", "method": .string(method)])
        }
    }

    func request(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            queue.async { [self] in
                do {
                    let id = nextID
                    nextID += 1
                    var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
                    if let params { message["params"] = params }
                    try write(message)
                    cont.resume(returning: try readResponse(id: id))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func write(_ message: [String: JSONValue]) throws {
        guard var data = JSONValue.object(message).serialized() else { return }
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    private func readResponse(id: Int) throws -> JSONValue {
        while true {
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let json = JSONValue.parse(Data(line)), json["id"]?.numberValue == Double(id) else { continue }
                if let error = json["error"] {
                    throw ChatGPTError(code: "mcp_error", message: "Remixaの操作でエラーが発生しました: \(error["message"]?.stringValue ?? "不明")")
                }
                return json["result"] ?? .object([:])
            }
            guard let chunk = try stdout.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty else {
                throw ChatGPTError(code: "mcp_closed", message: "Remixaの操作用ヘルパーが予期せず終了しました。")
            }
            buffer.append(chunk)
        }
    }
}

// MARK: - Agent

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

    func resetConversation() { history = [] }

    struct FunctionCall: Sendable {
        let callID: String
        let name: String
        let arguments: String
    }

    struct TurnResult: Sendable {
        var text = ""
        var calls: [FunctionCall] = []
    }

    func run(prompt: String, onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/remixa").path
        let mcp = MCPStdioClient(executablePath: helper)
        try mcp.start()
        defer { mcp.terminate() }
        let snapshot = history
        do {
            try await withTaskCancellationHandler {
                try await runLoop(prompt: prompt, mcp: mcp, onOutput: onOutput)
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
                         onOutput: @escaping @MainActor @Sendable (String) -> Void) async throws {
        _ = try await mcp.request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": .object([:]),
            "clientInfo": ["name": "remixa-chatgpt", "version": "1"]
        ])
        mcp.notify("notifications/initialized")
        let listed = try await mcp.request("tools/list")
        let tools = ChatGPTToolConverter.functionTools(fromMCP: listed["tools"]?.arrayValue ?? [])

        let model = try await ChatGPTAuth.shared.resolveModel()
        var working = history
        working.append(["role": "user", "content": .string(prompt)])

        for _ in 0..<Self.maxTurns {
            try Task.checkCancellation()
            let token = try await ChatGPTAuth.shared.validAccessToken()
            let turn = try await Self.streamTurn(accessToken: token, model: model, input: working, tools: tools, onOutput: onOutput)
            if !turn.text.isEmpty {
                working.append(["role": "assistant", "content": .string(turn.text)])
            }
            if turn.calls.isEmpty {
                history = working
                return
            }
            for call in turn.calls {
                try Task.checkCancellation()
                await onOutput((turn.text.isEmpty ? "" : "\n") + "[ツール実行: \(call.name)]\n")
                working.append(["type": "function_call", "call_id": .string(call.callID),
                                "name": .string(call.name), "arguments": .string(call.arguments)])
                let output = await Self.execute(call: call, mcp: mcp)
                working.append(["type": "function_call_output", "call_id": .string(call.callID), "output": .string(output)])
            }
        }
        throw ChatGPTError(code: "too_many_turns", message: "ツール呼び出しの往復が上限(\(Self.maxTurns)回)に達したため中断しました。指示を分けてもう一度お試しください。")
    }

    private static func execute(call: FunctionCall, mcp: MCPStdioClient) async -> String {
        let args = JSONValue.parse(Data(call.arguments.utf8)) ?? .object([:])
        do {
            let result = try await mcp.request("tools/call", params: ["name": .string(call.name), "arguments": args])
            return ChatGPTToolConverter.outputText(fromMCPResult: result)
        } catch {
            return "エラー: \(error.localizedDescription)"
        }
    }

    // MARK: request

    static func requestBody(model: String, input: [JSONValue], tools: [JSONValue]) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "input": .array(input),
            "instructions": .string(instructions),
            "store": false,
            "stream": true
        ]
        if !tools.isEmpty { body["tools"] = .array(tools) }
        return .object(body)
    }

    static func streamTurn(
        accessToken: String, model: String, input: [JSONValue], tools: [JSONValue],
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> TurnResult {
        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = requestBody(model: model, input: input, tools: tools).serialized()

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

        var result = TurnResult()
        var completed = false
        do {
            for try await line in bytes.lines {
                guard let event = ResponsesSSE.parse(line: line) else { continue }
                switch event {
                case .textDelta(let delta):
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
