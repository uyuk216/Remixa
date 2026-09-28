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
        for dir in pathDirs + extraSearchDirs {
            guard seen.insert(dir).inserted else { continue }
            let candidate = (dir as NSString).appendingPathComponent(kind.executableName)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
