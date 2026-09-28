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
  remixa export <out.wav|out.m4a>   ミックスを書き出し
  remixa analyze <audio>            音声ファイルを解析
  remixa state                      プロジェクトの全状態を JSON で出力
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
  remixa call track.update '{"trackId":"...","volume":0.8}'
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

case "export":
    guard let out = args.first else { printErrorAndExit("使い方: remixa export <out.wav|out.m4a>") }
    let ext = (out as NSString).pathExtension.lowercased()
    let format = (ext == "m4a") ? "m4a" : "wav"
    runCall(method: "export.mix", params: ["path": absolutePath(out), "format": format])

case "analyze":
    guard let audio = args.first else { printErrorAndExit("使い方: remixa analyze <audio>") }
    runCall(method: "audio.analyze", params: ["path": absolutePath(audio)])

case "state":
    runCall(method: "project.get")

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
