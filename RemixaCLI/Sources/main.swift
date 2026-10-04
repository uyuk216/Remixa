import Foundation

func appVersionString() -> String {
    // Best-effort: read our own CFBundleShortVersionString if embedded, else "unknown".
    if let info = Bundle.main.infoDictionary,
       let v = info["CFBundleShortVersionString"] as? String {
        return v
    }
    return "unknown"
}

let helpText = """
remixa - Remixa.app 制御用コマンドラインツール / CLI for controlling the Remixa app

使い方 / Usage:
  remixa status                     アプリの状態を簡潔に表示 (ping + 基本情報)
  remixa open <file|.remixa>        プロジェクトまたは .remixa パッケージを開く
  remixa add <audio> [--track name] 音声ファイルをトラックに追加（トラックが無ければ新規作成）
  remixa bpm <n>                    プロジェクトの BPM を設定
  remixa play [sec]                 再生開始（位置省略可）
  remixa stop                       再生停止
  remixa seek <sec>                 再生位置を移動
  remixa snap <unit> [4/4|3/4]      スナップ単位と拍子を設定
  remixa metronome <option> <value> メトロノーム設定 (playback/export/count-in/volume)
  remixa key <name|none>            プロジェクトのキーを設定
  remixa clip-key <clipId>           クリップのキーを検出
  remixa marker-add <sec> [name]     再生位置に名前付きマーカーを追加
  remixa marker-update <id> [opts]   マーカー名・位置を変更 (--name / --time)
  remixa marker-remove <id>          マーカーを削除
  remixa export <out.wav|out.m4a>    ミックスを書き出し (--wav pcm24|float32, --m4a-bitrate 128000|192000|256000|320000)
  remixa export-stems <directory> [wav|m4a] トラック別に書き出し (--wav pcm24|float32, --m4a-bitrate ...)
  remixa analyze <audio>            音声ファイルを解析
  remixa state                      プロジェクトの全状態を JSON で出力
  remixa stems status               AI パート分離環境の状態を表示
  remixa stems install              AI パート分離環境をインストール（初回は ~1GB、完了まで待機）
  remixa stems separate <clipId>    クリップを AI でパート分離（ボーカル/ドラム等のトラックを新規作成、完了まで待機）
  remixa split <audio>              音声ファイルをトラックに追加してすぐパート分離（初回は ~1GB、完了まで待機）
  remixa call <method> [json]       任意の RPC メソッドを直接呼び出す (例: remixa call project.get '{}')
  remixa install-cli                このバイナリを /usr/local/bin または ~/.local/bin にシンボリックリンク
  remixa mcp                        MCP サーバとして標準入出力で待ち受け (Claude Code / Codex 用)
  remixa help                       このヘルプを表示

例 / Examples:
  remixa status
  remixa open ~/Music/song.remixa
  remixa add ~/Music/vocal.wav --track "Vocal"
  remixa bpm 128
  remixa play
  remixa export ~/Desktop/mix.wav
  remixa snap halfBeat 3/4
  remixa key Cメジャー
  remixa marker-add 32 "サビ"
  remixa export ~/Desktop/mix.wav --wav float32
  remixa export-stems ~/Desktop/stems m4a
  remixa call track.update '{"trackId":"...","volume":0.8}'
  remixa call automation.set '{"trackId":"...","parameter":"volume","points":[{"time":0,"value":1}]}'
"""

func printErrorAndExit(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func connectedClient() -> RemixaSocketClient {
    do {
        try AppLauncher.ensureRunning()
        let client = RemixaSocketClient()
        try client.connect()
        return client
    } catch {
        printErrorAndExit("エラー: \(error)")
    }
}

func printResult(_ response: [String: Any]) {
    let result = response["result"] ?? [:] as [String: Any]
    print(JSONHelpers.prettyString(from: result))
}

func runCall(method: String, params: [String: Any]? = nil) {
    let client = connectedClient()
    defer { client.close_() }
    do {
        let response = try client.call(method: method, params: params)
        printResult(response)
    } catch {
        printErrorAndExit("エラー: \(error)")
    }
}

// MARK: - Argument parsing

var args = Array(CommandLine.arguments.dropFirst())

guard let command = args.first else {
    print(helpText)
    exit(0)
}
args.removeFirst()

switch command {
case "help", "-h", "--help":
    print(helpText)

case "mcp":
    MCPServer.run()

case "status":
    let client = connectedClient()
    defer { client.close_() }
    do {
        let pingResp = try client.call(method: "ping")
        let pingResult = pingResp["result"] as? [String: Any] ?? [:]
        let version = pingResult["version"] as? String ?? "?"
        print("Remixa は起動中です (バージョン: \(version))")
        if let stateResp = try? client.call(method: "project.get"),
           let state = stateResp["result"] as? [String: Any] {
            let name = state["name"] as? String ?? "?"
            let bpm = state["bpm"] ?? "?"
            let isPlaying = (state["isPlaying"] as? Bool) ?? false
            let trackCount = (state["tracks"] as? [Any])?.count ?? 0
            print("プロジェクト: \(name), BPM: \(bpm), 再生中: \(isPlaying), トラック数: \(trackCount)")
        }
    } catch {
        printErrorAndExit("エラー: \(error)")
    }

case "open":
    guard let path = args.first else { printErrorAndExit("使い方: remixa open <file|.remixa>") }
    runCall(method: "project.open", params: ["path": absolutePath(path)])

case "add":
    guard let audio = args.first else { printErrorAndExit("使い方: remixa add <audio> [--track name]") }
    var trackName: String? = nil
    var i = 1
    while i < args.count {
        if args[i] == "--track", i + 1 < args.count {
            trackName = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }
    var params: [String: Any] = ["audioPath": absolutePath(audio)]
    if let name = trackName { params["name"] = name }
    runCall(method: "track.add", params: params)

case "bpm":
    guard let s = args.first, let bpm = Double(s) else { printErrorAndExit("使い方: remixa bpm <n>") }
    runCall(method: "project.setBPM", params: ["bpm": bpm])

case "play":
    var params: [String: Any]? = nil
    if let s = args.first, let sec = Double(s) {
        params = ["from": sec]
    }
    runCall(method: "transport.play", params: params)

case "stop":
    runCall(method: "transport.stop")

case "seek":
    guard let s = args.first, let sec = Double(s) else { printErrorAndExit("使い方: remixa seek <sec>") }
    runCall(method: "transport.seek", params: ["time": sec])

case "snap":
    guard let unit = args.first else { printErrorAndExit("使い方: remixa snap <quarterBeat|halfBeat|beat|bar|off> [4/4|3/4]") }
    var params: [String: Any] = ["snapDivision": unit]
    if args.count > 1 { params["timeSignature"] = args[1] }
    runCall(method: "project.setTimelineSettings", params: params)

case "metronome":
    guard args.count > 1 else { printErrorAndExit("使い方: remixa metronome playback|export|count-in|volume <on|off|0...1>") }
    let option = args[0]
    let value = args[1]
    let params: [String: Any]
    switch option {
    case "playback": params = ["playbackEnabled": parseBoolean(value)]
    case "export": params = ["exportEnabled": parseBoolean(value)]
    case "count-in": params = ["countIn": parseBoolean(value)]
    case "volume":
        guard let volume = Double(value), volume.isFinite, (0...1).contains(volume) else {
            printErrorAndExit("音量は0〜1の数値で指定してください")
        }
        params = ["volume": volume]
    default:
        printErrorAndExit("metronome の項目は playback / export / count-in / volume です")
    }
    runCall(method: "project.setMetronome", params: params)

case "key":
    guard let key = args.first else { printErrorAndExit("使い方: remixa key <Cメジャー|Aマイナー|none>") }
    let value: Any = key.lowercased() == "none" ? NSNull() : key
    runCall(method: "project.setKey", params: ["key": value])

case "clip-key":
    guard let clipId = args.first else { printErrorAndExit("使い方: remixa clip-key <clipId>") }
    runCall(method: "clip.detectKey", params: ["clipId": clipId])

case "marker-add":
    guard let rawTime = args.first, let time = Double(rawTime) else { printErrorAndExit("使い方: remixa marker-add <sec> [name]") }
    let name = args.count > 1 ? args.dropFirst().joined(separator: " ") : nil
    var params: [String: Any] = ["time": time]
    if let name { params["name"] = name }
    runCall(method: "marker.add", params: params)

case "marker-update":
    guard let markerId = args.first else { printErrorAndExit("使い方: remixa marker-update <id> [--name name] [--time sec]") }
    var params: [String: Any] = ["markerId": markerId]
    var i = 1
    while i < args.count {
        if args[i] == "--name", i + 1 < args.count {
            params["name"] = args[i + 1]
            i += 2
        } else if args[i] == "--time", i + 1 < args.count, let time = Double(args[i + 1]) {
            params["time"] = time
            i += 2
        } else {
            printErrorAndExit("不明な marker-update オプションです: \(args[i])")
        }
    }
    runCall(method: "marker.update", params: params)

case "marker-remove":
    guard let markerId = args.first else { printErrorAndExit("使い方: remixa marker-remove <id>") }
    runCall(method: "marker.remove", params: ["markerId": markerId])

case "export":
    guard let out = args.first else { printErrorAndExit("使い方: remixa export <out.wav|out.m4a>") }
    let ext = (out as NSString).pathExtension.lowercased()
    let format = (ext == "m4a") ? "m4a" : "wav"
    var params: [String: Any] = ["path": absolutePath(out), "format": format]
    var i = 1
    while i < args.count {
        if args[i] == "--wav", i + 1 < args.count {
            params["wavEncoding"] = args[i + 1]
            i += 2
        } else if args[i] == "--m4a-bitrate", i + 1 < args.count, let bitrate = Int(args[i + 1]) {
            params["m4aBitrate"] = bitrate
            i += 2
        } else {
            printErrorAndExit("不明な export オプションです: \(args[i])")
        }
    }
    runCall(method: "export.mix", params: params)

case "export-stems":
    guard let directory = args.first else { printErrorAndExit("使い方: remixa export-stems <directory> [wav|m4a]") }
    let format = args.count > 1 ? args[1].lowercased() : "wav"
    var params: [String: Any] = ["directory": absolutePath(directory), "format": format]
    var i = min(2, args.count)
    while i < args.count {
        if args[i] == "--wav", i + 1 < args.count {
            params["wavEncoding"] = args[i + 1]
            i += 2
        } else if args[i] == "--m4a-bitrate", i + 1 < args.count, let bitrate = Int(args[i + 1]) {
            params["m4aBitrate"] = bitrate
            i += 2
        } else {
            printErrorAndExit("不明な export-stems オプションです: \(args[i])")
        }
    }
    runCall(method: "export.stems", params: params)

case "analyze":
    guard let audio = args.first else { printErrorAndExit("使い方: remixa analyze <audio>") }
    runCall(method: "audio.analyze", params: ["path": absolutePath(audio)])

case "state":
    runCall(method: "project.get")

case "stems":
    guard let sub = args.first else { printErrorAndExit("使い方: remixa stems status|install|separate <clipId>") }
    switch sub {
    case "status":
        runCall(method: "stems.status")
    case "install":
        print("AI パート分離環境をインストールしています（初回は ~1GB のダウンロードが発生します）…")
        runCall(method: "stems.install")
    case "separate":
        guard args.count > 1 else { printErrorAndExit("使い方: remixa stems separate <clipId>") }
        runCall(method: "stems.separate", params: ["clipId": args[1]])
    default:
        printErrorAndExit("不明な stems サブコマンドです: \(sub)")
    }

case "split":
    guard let audio = args.first else { printErrorAndExit("使い方: remixa split <audio>") }
    let client = connectedClient()
    defer { client.close_() }
    do {
        let addResp = try client.call(method: "track.add", params: ["audioPath": absolutePath(audio)])
        guard let addResult = addResp["result"] as? [String: Any], let clipId = addResult["clipId"] as? String else {
            printErrorAndExit("エラー: track.add がクリップIDを返しませんでした")
        }
        print("AI パート分離を実行しています（初回は環境構築で ~1GB のダウンロードが発生します）…")
        let sepResp = try client.call(method: "stems.separate", params: ["clipId": clipId])
        printResult(sepResp)
    } catch {
        printErrorAndExit("エラー: \(error)")
    }

case "call":
    guard let method = args.first else { printErrorAndExit("使い方: remixa call <method> [json-params]") }
    var params: [String: Any]? = nil
    if args.count > 1 {
        do {
            params = try JSONHelpers.parseParams(args[1])
        } catch {
            printErrorAndExit("エラー: \(error)")
        }
    }
    runCall(method: method, params: params)

case "install-cli":
    installCLI()

default:
    printErrorAndExit("不明なコマンドです: \(command)\n\n\(helpText)")
}

func absolutePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    if path.hasPrefix("~") {
        return (path as NSString).expandingTildeInPath
    }
    let cwd = FileManager.default.currentDirectoryPath
    return (cwd as NSString).appendingPathComponent(path)
}

func parseBoolean(_ value: String) -> Bool {
    switch value.lowercased() {
    case "on", "true", "1", "yes": return true
    case "off", "false", "0", "no": return false
    default: printErrorAndExit("真偽値は on または off で指定してください")
    }
}

func installCLI() {
    guard let exePath = Bundle.main.executablePath ?? CommandLine.arguments.first else {
        printErrorAndExit("実行ファイルのパスを取得できませんでした")
    }
    let resolvedExe = (exePath as NSString).resolvingSymlinksInPath

    let candidates = [
        "/usr/local/bin/remixa",
        (NSString(string: "~/.local/bin/remixa")).expandingTildeInPath
    ]

    for target in candidates {
        let dir = (target as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        let dirExists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDir)
        if !dirExists {
            continue
        }
        do {
            if FileManager.default.fileExists(atPath: target) {
                try FileManager.default.removeItem(atPath: target)
            }
            try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: resolvedExe)
            print("シンボリックリンクを作成しました: \(target) -> \(resolvedExe)")
            print("ターミナルを再起動するか、PATH に \(dir) が含まれていることを確認してください。")
            return
        } catch {
            continue
        }
    }

    print("自動インストールに失敗しました。手動で以下を実行してください:")
    print("  mkdir -p ~/.local/bin && ln -sf \"\(resolvedExe)\" ~/.local/bin/remixa")
    print("  export PATH=\"$HOME/.local/bin:$PATH\"  # ~/.zshrc などに追加")
}
