import Foundation

/// Minimal MCP server over stdio: newline-delimited JSON-RPC 2.0, protocolVersion "2025-06-18".
/// Exposes one tool per Remixa control-socket method. All logging goes to stderr only —
/// stdout is reserved for JSON-RPC responses.
enum MCPServer {

    struct Tool: @unchecked Sendable {
        let name: String        // snake_case
        let method: String      // dotted RPC method, e.g. "project.get"
        let descriptionJA: String
        let descriptionEN: String
        let schema: [String: Any]
    }

    static let protocolVersion = "2025-06-18"

    static func log(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var s: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty { s["required"] = required }
        return s
    }

    static func prop(_ type: String, _ ja: String, _ en: String, extra: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = ["type": type, "description": "\(ja) / \(en)"]
        for (k, v) in extra { p[k] = v }
        return p
    }

    static let tools: [Tool] = [
        Tool(name: "ping", method: "ping",
             descriptionJA: "Remixa アプリの疎通確認とバージョン取得",
             descriptionEN: "Check connectivity and get the running Remixa app version",
             schema: schema([:])),

        Tool(name: "project_get", method: "project.get",
             descriptionJA: "現在のプロジェクトの全状態を取得（トラック、クリップ、BPM、再生状態など）",
             descriptionEN: "Get the full current project state (tracks, clips, BPM, playback state, etc.)",
             schema: schema([:])),

        Tool(name: "project_new", method: "project.new",
             descriptionJA: "新規プロジェクトを作成",
             descriptionEN: "Create a new empty project",
             schema: schema([:])),

        Tool(name: "project_open", method: "project.open",
             descriptionJA: ".remixa プロジェクトファイルを開く",
             descriptionEN: "Open a .remixa project file",
             schema: schema([
                "path": prop("string", "開く .remixa ファイルのパス", "Path to the .remixa file to open")
             ], required: ["path"])),

        Tool(name: "project_save", method: "project.save",
             descriptionJA: "プロジェクトを保存（path 省略時は現在のパスに保存）",
             descriptionEN: "Save the project (omit path to save in place)",
             schema: schema([
                "path": prop("string", "保存先パス（省略可）", "Destination path (optional)")
             ])),

        Tool(name: "project_set_bpm", method: "project.setBPM",
             descriptionJA: "プロジェクトの BPM を設定",
             descriptionEN: "Set the project's BPM",
             schema: schema([
                "bpm": prop("number", "BPM 値", "BPM value")
             ], required: ["bpm"])),

        Tool(name: "track_add", method: "track.add",
             descriptionJA: "トラックを追加（音声ファイルを同時に読み込み可能）",
             descriptionEN: "Add a track (optionally loading an audio file into it)",
             schema: schema([
                "name": prop("string", "トラック名（省略可）", "Track name (optional)"),
                "audioPath": prop("string", "読み込む音声ファイルのパス（省略可）", "Audio file path to load (optional)")
             ])),

        Tool(name: "track_remove", method: "track.remove",
             descriptionJA: "トラックを削除",
             descriptionEN: "Remove a track",
             schema: schema([
                "trackId": prop("string", "トラック ID", "Track ID")
             ], required: ["trackId"])),

        Tool(name: "track_update", method: "track.update",
             descriptionJA: "トラックの名前・音量・パン・ミュート・ソロを更新",
             descriptionEN: "Update a track's name, volume, pan, mute, or solo state",
             schema: schema([
                "trackId": prop("string", "トラック ID", "Track ID"),
                "name": prop("string", "新しい名前（省略可）", "New name (optional)"),
                "volume": prop("number", "音量 0.0〜2.0（省略可）", "Volume 0.0-2.0 (optional)"),
                "pan": prop("number", "パン -1.0〜1.0（省略可）", "Pan -1.0 to 1.0 (optional)"),
                "mute": prop("boolean", "ミュート（省略可）", "Mute (optional)"),
                "solo": prop("boolean", "ソロ（省略可）", "Solo (optional)")
             ], required: ["trackId"])),

        Tool(name: "track_set_effects", method: "track.setEffects",
             descriptionJA: "トラックのエフェクトラック設定を部分更新（マージ）",
             descriptionEN: "Partially update (merge) a track's effects rack settings",
             schema: schema([
                "trackId": prop("string", "トラック ID", "Track ID"),
                "effects": prop("object", "EffectsRackSettings の一部キー", "Partial EffectsRackSettings keys")
             ], required: ["trackId", "effects"])),

        Tool(name: "clip_add", method: "clip.add",
             descriptionJA: "トラックにクリップ（音声）を追加",
             descriptionEN: "Add a clip (audio) to a track",
             schema: schema([
                "trackId": prop("string", "トラック ID", "Track ID"),
                "audioPath": prop("string", "音声ファイルのパス", "Audio file path"),
                "start": prop("number", "配置開始位置（秒、省略可）", "Placement start time in seconds (optional)")
             ], required: ["trackId", "audioPath"])),

        Tool(name: "clip_update", method: "clip.update",
             descriptionJA: "クリップの位置・長さ・ゲイン・フェードを更新",
             descriptionEN: "Update a clip's position, length, gain, or fades",
             schema: schema([
                "clipId": prop("string", "クリップ ID", "Clip ID"),
                "start": prop("number", "開始位置（秒、省略可）", "Start time in seconds (optional)"),
                "sourceStart": prop("number", "ソース内開始位置（秒、省略可）", "Source-relative start time (optional)"),
                "duration": prop("number", "長さ（秒、省略可）", "Duration in seconds (optional)"),
                "gain": prop("number", "ゲイン（省略可）", "Gain (optional)"),
                "fadeIn": prop("number", "フェードイン（秒、省略可）", "Fade in seconds (optional)"),
                "fadeOut": prop("number", "フェードアウト（秒、省略可）", "Fade out seconds (optional)")
             ], required: ["clipId"])),

        Tool(name: "clip_split", method: "clip.split",
             descriptionJA: "クリップを指定位置で分割",
             descriptionEN: "Split a clip at the given time",
             schema: schema([
                "clipId": prop("string", "クリップ ID", "Clip ID"),
                "at": prop("number", "分割位置（秒）", "Split position in seconds")
             ], required: ["clipId", "at"])),

        Tool(name: "clip_duplicate", method: "clip.duplicate",
             descriptionJA: "クリップを複製",
             descriptionEN: "Duplicate a clip",
             schema: schema([
                "clipId": prop("string", "クリップ ID", "Clip ID")
             ], required: ["clipId"])),

        Tool(name: "clip_remove", method: "clip.remove",
             descriptionJA: "クリップを削除",
             descriptionEN: "Remove a clip",
             schema: schema([
                "clipId": prop("string", "クリップ ID", "Clip ID")
             ], required: ["clipId"])),

        Tool(name: "clip_process", method: "clip.process",
             descriptionJA: "クリップを破壊的に処理（テンポ・ピッチ変更、トリム）。既存 v0.1 エディタのコードでレンダリングし、ソースを置き換える",
             descriptionEN: "Destructively process a clip (tempo/pitch change, trim) via the v0.1 editor code, replacing its source",
             schema: schema([
                "clipId": prop("string", "クリップ ID", "Clip ID"),
                "tempo": prop("number", "テンポ倍率 0.5〜2.0（省略可）", "Tempo rate 0.5-2.0 (optional)"),
                "pitch": prop("number", "ピッチ半音 -12〜12（省略可）", "Pitch shift in semitones, -12 to 12 (optional)"),
                "trimStart": prop("number", "トリム開始（秒、省略可）", "Trim start in seconds (optional)"),
                "trimEnd": prop("number", "トリム終了（秒、省略可）", "Trim end in seconds (optional)")
             ], required: ["clipId"])),

        Tool(name: "transport_play", method: "transport.play",
             descriptionJA: "再生を開始",
             descriptionEN: "Start playback",
             schema: schema([
                "from": prop("number", "再生開始位置（秒、省略可）", "Playback start time in seconds (optional)")
             ])),

        Tool(name: "transport_stop", method: "transport.stop",
             descriptionJA: "再生を停止",
             descriptionEN: "Stop playback",
             schema: schema([:])),

        Tool(name: "transport_seek", method: "transport.seek",
             descriptionJA: "再生位置を移動",
             descriptionEN: "Seek the playhead",
             schema: schema([
                "time": prop("number", "移動先の位置（秒）", "Target time in seconds")
             ], required: ["time"])),

        Tool(name: "transport_set_loop", method: "transport.setLoop",
             descriptionJA: "ループ再生の設定",
             descriptionEN: "Configure loop playback",
             schema: schema([
                "enabled": prop("boolean", "ループを有効にするか", "Whether loop is enabled"),
                "start": prop("number", "ループ開始位置（秒、省略可）", "Loop start in seconds (optional)"),
                "end": prop("number", "ループ終了位置（秒、省略可）", "Loop end in seconds (optional)")
             ], required: ["enabled"])),

        Tool(name: "export_mix", method: "export.mix",
             descriptionJA: "ミックス全体をオフライン書き出し（完了まで待機）",
             descriptionEN: "Offline-export the full mix (waits until finished)",
             schema: schema([
                "path": prop("string", "書き出し先パス", "Output path"),
                "format": prop("string", "wav または m4a", "\"wav\" or \"m4a\"", extra: ["enum": ["wav", "m4a"]])
             ], required: ["path", "format"])),

        Tool(name: "audio_analyze", method: "audio.analyze",
             descriptionJA: "音声ファイルを解析（長さ、サンプルレート、チャンネル数、BPM）",
             descriptionEN: "Analyze an audio file (duration, sample rate, channels, BPM)",
             schema: schema([
                "path": prop("string", "音声ファイルのパス", "Audio file path")
             ], required: ["path"])),

        Tool(name: "undo", method: "undo",
             descriptionJA: "直前の操作を取り消す",
             descriptionEN: "Undo the last operation",
             schema: schema([:])),

        Tool(name: "redo", method: "redo",
             descriptionJA: "取り消した操作をやり直す",
             descriptionEN: "Redo the last undone operation",
             schema: schema([:])),
    ]

    static func run() {
        log("Remixa MCP server starting (stdio, protocolVersion \(protocolVersion))")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("不正な JSON 行を無視しました: \(trimmed)")
                continue
            }
            handle(obj)
        }
        log("Remixa MCP server exiting (stdin closed)")
    }

    private static func writeResponse(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }

    private static func handle(_ req: [String: Any]) {
        let method = req["method"] as? String ?? ""
        let id = req["id"] // may be absent for notifications

        func respond(result: Any) {
            guard let id = id else { return } // notification: no response
            writeResponse(["jsonrpc": "2.0", "id": id, "result": result])
        }
        func respondError(code: Int, message: String) {
            guard let id = id else { return }
            writeResponse(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        }

        switch method {
        case "initialize":
            respond(result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "remixa", "version": appVersionString()]
            ])

        case "notifications/initialized":
            // No response for notifications.
            break

        case "ping":
            respond(result: [:] as [String: Any])

        case "tools/list":
            let list: [[String: Any]] = tools.map { t in
                [
                    "name": t.name,
                    "description": "\(t.descriptionJA) / \(t.descriptionEN)",
                    "inputSchema": t.schema
                ]
            }
            respond(result: ["tools": list])

        case "tools/call":
            guard let params = req["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                respondError(code: -32602, message: "Invalid params")
                return
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard let tool = tools.first(where: { $0.name == name }) else {
                respond(result: [
                    "content": [["type": "text", "text": "不明なツールです: \(name)"]],
                    "isError": true
                ])
                return
            }
            do {
                try AppLauncher.ensureRunning()
                let client = RemixaSocketClient()
                try client.connect()
                defer { client.close_() }
                let response = try client.call(method: tool.method, params: args.isEmpty ? nil : args)
                let result = response["result"] ?? [:] as [String: Any]
                let text = JSONHelpers.prettyString(from: result)
                respond(result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false
                ])
            } catch {
                respond(result: [
                    "content": [["type": "text", "text": "\(error)"]],
                    "isError": true
                ])
            }

        default:
            respondError(code: -32601, message: "Unknown method: \(method)")
        }
    }
}
