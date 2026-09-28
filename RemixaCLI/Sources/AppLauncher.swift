import Foundation

enum AppLauncher {
    static let bundleId = "io.github.uyuk216.remixa"

    /// Ensures Remixa.app is running and its control socket is ready.
    /// Launches it via `open -b <bundleId>` if the socket isn't present, then waits up to `timeout` seconds.
    static func ensureRunning(timeout: TimeInterval = 15) throws {
        if FileManager.default.fileExists(atPath: RemixaSocketClient.socketPath) {
            if socketAcceptsConnection() { return }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleId]
        do {
            try process.run()
        } catch {
            throw CLIError.message("Remixa アプリを起動できませんでした: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: RemixaSocketClient.socketPath), socketAcceptsConnection() {
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw CLIError.message("Remixa アプリの起動を \(Int(timeout)) 秒待ちましたが、ソケットが利用可能になりませんでした。")
    }

    private static func socketAcceptsConnection() -> Bool {
        let client = RemixaSocketClient()
        do {
            try client.connect()
            client.close_()
            return true
        } catch {
            return false
        }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let m): return m
        }
    }
}
