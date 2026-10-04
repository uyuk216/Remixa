import Foundation

/// Manages a self-contained Python environment (via the `uv` standalone tool) used to
/// run Demucs for AI stem separation. Nothing is bundled with the app: on first use we
/// download `uv`, have it install Python 3.11 and a venv, then `uv pip install` Demucs
/// and its dependencies (torch/torchaudio/soundfile) into
/// `~/Library/Application Support/Remixa/stems/`.
///
/// This is intentionally independent of `Remixa/Control/*` and `RemixaCLI/*`.
@MainActor
final class StemEnvironment: ObservableObject {
    static let shared = StemEnvironment()

    enum Status: Equatable {
        case notInstalled
        case installing(progress: Double, message: String)
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .notInstalled

    /// Log lines from the install process, newest last. Shown in the install sheet.
    @Published private(set) var log: [String] = []

    private var installTask: Task<Void, Never>?

    private init() {
        status = FileManager.default.fileExists(atPath: pythonExecutable.path) ? .ready : .notInstalled
    }

    // MARK: - Paths

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Remixa", isDirectory: true)
    }

    /// Root of the managed stem-separation environment.
    var stemsDir: URL { supportDir.appendingPathComponent("stems", isDirectory: true) }

    private var uvDir: URL { stemsDir.appendingPathComponent("uv-bin", isDirectory: true) }
    private var uvExecutable: URL { uvDir.appendingPathComponent("uv") }
    private var venvDir: URL { stemsDir.appendingPathComponent("venv", isDirectory: true) }
    var pythonExecutable: URL { venvDir.appendingPathComponent("bin/python") }

    /// Directory the managed `uv` uses for its own Python installs / cache, kept inside
    /// our sandboxed support folder rather than the user's global `~/.local/share/uv`.
    private var uvDataDir: URL { stemsDir.appendingPathComponent("uv-data", isDirectory: true) }

    /// Total on-disk size of the managed environment, for the Settings UI.
    func installedSizeBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: stemsDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Install

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        if case .installing = status {
            status = .notInstalled
            appendLog("キャンセルしました")
        }
    }

    /// Deletes the whole managed environment. Status returns to `.notInstalled`.
    func uninstall() throws {
        cancelInstall()
        if FileManager.default.fileExists(atPath: stemsDir.path) {
            try FileManager.default.removeItem(at: stemsDir)
        }
        status = .notInstalled
        log.removeAll()
    }

    func reinstall(progress: @escaping @MainActor (Double, String) -> Void) {
        installTask?.cancel()
        installTask = Task {
            do { try FileManager.default.removeItem(at: stemsDir) } catch {}
            await install(progress: progress)
        }
    }

    /// Runs the full install pipeline. Safe to call again if a previous attempt failed.
    func install(progress: @escaping @MainActor (Double, String) -> Void) async {
        if case .ready = status { return }
        if case .installing = status { return }
        log.removeAll()
        status = .installing(progress: 0, message: "準備中…")

        let task = Task { () -> Void in
            do {
                try FileManager.default.createDirectory(at: stemsDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: uvDataDir, withIntermediateDirectories: true)

                try Task.checkCancellation()
                await report(0.05, "uv をダウンロード中…", progress)
                try await downloadAndInstallUv()

                try Task.checkCancellation()
                await report(0.25, "Python 3.11 をインストール中…", progress)
                try await run(uvExecutable, ["python", "install", "3.11"], env: uvEnv())

                try Task.checkCancellation()
                await report(0.4, "仮想環境を作成中…", progress)
                if FileManager.default.fileExists(atPath: venvDir.path) {
                    try? FileManager.default.removeItem(at: venvDir)
                }
                try await run(uvExecutable, ["venv", "--python", "3.11", venvDir.path], env: uvEnv())

                try Task.checkCancellation()
                await report(0.55, "Demucs をインストール中(数分かかります)…", progress)
                try await run(uvExecutable, [
                    "pip", "install",
                    "--python", pythonExecutable.path,
                    "demucs==4.0.1",
                    "soundfile",
                    "torchaudio<2.9"
                ], env: uvEnv())

                try Task.checkCancellation()
                await report(0.85, "モデルを取得中(初回のみ、数百MB)…", progress)
                try await prefetchModel()

                try Task.checkCancellation()
                await report(1.0, "完了", progress)
                status = .ready
            } catch is CancellationError {
                status = .notInstalled
            } catch {
                let message = (error as NSError).localizedDescription
                status = .failed(message)
                appendLog("エラー: \(message)")
            }
        }
        installTask = task
        await task.value
    }

    private func report(_ value: Double, _ message: String, _ progress: @escaping @MainActor (Double, String) -> Void) async {
        status = .installing(progress: value, message: message)
        appendLog(message)
        progress(value, message)
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func uvEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["UV_PYTHON_INSTALL_DIR"] = uvDataDir.appendingPathComponent("python").path
        env["UV_CACHE_DIR"] = uvDataDir.appendingPathComponent("cache").path
        env["UV_UNMANAGED_INSTALL"] = "1"
        return env
    }

    // MARK: - uv download

    private func downloadAndInstallUv() async throws {
        if FileManager.default.fileExists(atPath: uvExecutable.path) {
            // Verify it still runs; if not, fall through to re-download.
            if (try? await run(uvExecutable, ["--version"], env: [:])) != nil {
                return
            }
        }
        try FileManager.default.createDirectory(at: uvDir, withIntermediateDirectories: true)

        let arch = machineArch()
        let assetName = "uv-\(arch)-apple-darwin.tar.gz"
        let urlString = "https://github.com/astral-sh/uv/releases/latest/download/\(assetName)"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Remixa.Stem", code: 1, userInfo: [NSLocalizedDescriptionKey: "uv のダウンロードURLが不正です"])
        }

        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Remixa.Stem", code: 2, userInfo: [NSLocalizedDescriptionKey: "uv のダウンロードに失敗しました"])
        }

        let archivePath = uvDir.appendingPathComponent("uv.tar.gz")
        if FileManager.default.fileExists(atPath: archivePath.path) {
            try? FileManager.default.removeItem(at: archivePath)
        }
        try FileManager.default.moveItem(at: tmpURL, to: archivePath)

        // Extract with the system's tar (present on all Macs).
        try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archivePath.path, "-C", uvDir.path], env: [:])
        try? FileManager.default.removeItem(at: archivePath)

        // The archive contains a top-level `uv-<arch>-apple-darwin/` directory with `uv`
        // and `uvx` inside; flatten so `uvExecutable` (uvDir/uv) is directly usable.
        let extractedDir = uvDir.appendingPathComponent(assetName.replacingOccurrences(of: ".tar.gz", with: ""))
        if FileManager.default.fileExists(atPath: extractedDir.appendingPathComponent("uv").path) {
            let dest = uvExecutable
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: extractedDir.appendingPathComponent("uv"), to: dest)
            try? FileManager.default.removeItem(at: extractedDir)
        }

        guard FileManager.default.fileExists(atPath: uvExecutable.path) else {
            throw NSError(domain: "Remixa.Stem", code: 3, userInfo: [NSLocalizedDescriptionKey: "uv の展開に失敗しました"])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uvExecutable.path)

        // Verify it runs.
        try await run(uvExecutable, ["--version"], env: [:])
    }

    private func machineArch() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(cString: ptr)
            }
        }
        // arm64 -> aarch64 for uv's asset naming.
        return machine == "arm64" ? "aarch64" : "x86_64"
    }

    /// Runs a ~1s silent separation so Demucs downloads & caches the htdemucs model
    /// weights now, rather than surprising the user during their first real separation.
    private func prefetchModel() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("remixa-stem-prefetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let silenceURL = tmpDir.appendingPathComponent("silence.wav")
        try Self.writeSilence(seconds: 1.0, to: silenceURL)

        let outDir = tmpDir.appendingPathComponent("out", isDirectory: true)
        try await run(pythonExecutable, [
            "-m", "demucs", "-n", "htdemucs", "-o", outDir.path, "--device", "cpu", silenceURL.path
        ], env: [:])
    }

    /// Writes a minimal 16-bit PCM WAV of digital silence, without pulling in AVFoundation
    /// (kept dependency-free so this file compiles standalone if reused from a CLI context).
    static func writeSilence(seconds: Double, to url: URL, sampleRate: Double = 44100) throws {
        let frameCount = Int(seconds * sampleRate)
        let channels = 2
        let bytesPerSample = 2
        let dataSize = frameCount * channels * bytesPerSample
        var data = Data()
        func appendLE(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendLE16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(16)
        appendLE16(1) // PCM
        appendLE16(UInt16(channels))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate) * UInt32(channels) * UInt32(bytesPerSample))
        appendLE16(UInt16(channels * bytesPerSample))
        appendLE16(UInt16(bytesPerSample * 8))
        data.append(contentsOf: "data".utf8)
        appendLE(UInt32(dataSize))
        data.append(Data(repeating: 0, count: dataSize))
        try data.write(to: url)
    }

    // MARK: - Process execution

    /// Runs a process to completion, throwing on non-zero exit. Output is captured into
    /// `log`. Used for install steps where we just need success/failure + a log trail.
    @discardableResult
    private func run(_ executable: URL, _ arguments: [String], env: [String: String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if !env.isEmpty { process.environment = env }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            final class DataBox: @unchecked Sendable { var data = Data() }
            let collected = DataBox()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                collected.data.append(chunk)
                if let text = String(data: chunk, encoding: .utf8) {
                    Task { @MainActor [weak self] in
                        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                            self?.appendLog(String(line))
                        }
                    }
                }
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let output = String(data: collected.data, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let tail = output.split(separator: "\n").suffix(5).joined(separator: "\n")
                    continuation.resume(throwing: NSError(domain: "Remixa.Stem", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: tail.isEmpty ? "コマンドが失敗しました (\(proc.terminationStatus))" : tail]))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
