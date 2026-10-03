import Foundation

/// The AI CLI backends the in-app assistant panel can drive.
enum AIBackendKind: String, CaseIterable, Identifiable, Hashable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The CLI executable's file name, as it would appear on `PATH`.
    var executableName: String { rawValue }

    var installHint: String {
        switch self {
        case .claude:
            return "claude コマンドが見つかりません。npm install -g @anthropic-ai/claude-code などでインストールしてください。"
        case .codex:
            return "codex コマンドが見つかりません。Codex CLIをインストールしてください。"
        }
    }
}

/// Finds a CLI backend's executable on `PATH`, plus the handful of common
/// install locations that aren't always on a GUI app's `PATH` (Homebrew,
/// user-local npm/pip installs, etc).
enum AIBackendLocator {
    private static var extraSearchDirs: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.local/bin",
            home + "/.npm-global/bin"
        ]
    }

    /// Returns the absolute path to the backend's executable, or `nil` if not found.
    static func resolve(_ kind: AIBackendKind) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirs = pathEnv.split(separator: ":").map(String.init)
        var seen = Set<String>()
        for dir in pathDirs + searchDirs() {
            guard seen.insert(dir).inserted else { continue }
            let candidate = (dir as NSString).appendingPathComponent(kind.executableName)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// PATH-ish directories a GUI-launched app usually lacks (node for `#!/usr/bin/env node` CLIs).
    static func searchDirs() -> [String] {
        let home = NSHomeDirectory()
        var dirs = extraSearchDirs + [home + "/.volta/bin", home + "/.bun/bin", home + "/.cargo/bin",
                                      home + "/.asdf/shims", home + "/.local/share/fnm/aliases/default/bin"]
        let fm = FileManager.default
        let nvm = home + "/.nvm/versions/node"
        if let vers = try? fm.contentsOfDirectory(atPath: nvm) {
            for v in vers.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                dirs.append("\(nvm)/\(v)/bin")
            }
        }
        return dirs
    }

    /// Environment for the child CLI: current env with an enriched PATH.
    static func childEnvironment(executablePath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        let all = [(executablePath as NSString).deletingLastPathComponent] + searchDirs()
            + current + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        env["PATH"] = all.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        return env
    }
}
