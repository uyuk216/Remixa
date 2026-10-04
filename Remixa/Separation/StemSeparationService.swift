import Foundation

/// Runs Demucs (via the managed Python env in `StemEnvironment`) to split an audio file
/// into stems, e.g. vocals/drums/bass/other. Progress is parsed out of Demucs' tqdm
/// stderr output.
final class StemSeparationService: @unchecked Sendable {
    static let shared = StemSeparationService()
    private init() {}

    struct Stem: Sendable {
        let name: String
        let url: URL
    }

    enum StemError: LocalizedError, Equatable {
        case environmentNotReady
        case cancelled
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .environmentNotReady: return "AIパート分離の環境がインストールされていません"
            case .cancelled: return "キャンセルされました"
            case .processFailed(let message): return message
            }
        }
    }

    final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var process: Process?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let activeProcess = process
            lock.unlock()
            if activeProcess?.isRunning == true { activeProcess?.terminate() }
        }

        /// Returns true when cancellation happened before the process was registered.
        func register(_ process: Process) -> Bool {
            lock.lock()
            self.process = process
            let wasCancelled = cancelled
            lock.unlock()
            return wasCancelled
        }

        func clear(_ process: Process) {
            lock.lock()
            if self.process === process { self.process = nil }
            lock.unlock()
        }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Separates `audioURL` into stems. `outputDir`, if provided, is where the final wav
    /// files land (stable location); otherwise a per-run folder under
    /// `~/Library/Application Support/Remixa/stems-output/<uuid>/` is used.
    func separate(
        audioURL: URL,
        model: String = "htdemucs",
        twoStems: String? = nil,
        outputDir: URL? = nil,
        cancellation: CancellationToken? = nil,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [Stem] {
        let cancellation = cancellation ?? CancellationToken()
        guard !cancellation.isCancelled else { throw StemError.cancelled }
        let pythonPath = await StemEnvironment.shared.pythonExecutable
        guard FileManager.default.fileExists(atPath: pythonPath.path) else {
            throw StemError.environmentNotReady
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("remixa-stem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let device = Self.preferredDevice()
        var arguments = ["-m", "demucs", "-n", model]
        if let twoStems { arguments += ["--two-stems", twoStems] }
        arguments += ["-o", workDir.path, "--device", device, audioURL.path]

        do {
            try await runProcess(pythonPath, arguments, cancellation: cancellation) { fraction, message in
                progress(fraction, message)
            }
        } catch let error as StemError {
            guard error != .cancelled, !cancellation.isCancelled else { throw StemError.cancelled }
            // Retry once on CPU if MPS failed.
            if device == "mps" {
                progress(0, "MPSで失敗、CPUで再試行中…")
                var cpuArgs = ["-m", "demucs", "-n", model]
                if let twoStems { cpuArgs += ["--two-stems", twoStems] }
                cpuArgs += ["-o", workDir.path, "--device", "cpu", audioURL.path]
                try await runProcess(pythonPath, cpuArgs, cancellation: cancellation, progress: progress)
            } else {
                throw error
            }
        }
        guard !cancellation.isCancelled else { throw StemError.cancelled }

        // Demucs writes to <out>/<model>/<track-name-without-ext>/<stem>.wav
        let trackName = audioURL.deletingPathExtension().lastPathComponent
        let stemsDir = workDir.appendingPathComponent(model, isDirectory: true).appendingPathComponent(trackName, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: stemsDir, includingPropertiesForKeys: nil)) ?? []
        let wavFiles = files.filter { $0.pathExtension.lowercased() == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !wavFiles.isEmpty else {
            throw StemError.processFailed("分離結果のファイルが見つかりませんでした")
        }

        let destDir = outputDir ?? Self.defaultOutputDir()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var results: [Stem] = []
        for file in wavFiles {
            let stemName = file.deletingPathExtension().lastPathComponent
            let dest = destDir.appendingPathComponent("\(stemName).wav")
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: file, to: dest)
            results.append(Stem(name: stemName, url: dest))
        }
        return results
    }

    static func defaultOutputDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Remixa", isDirectory: true)
            .appendingPathComponent("stems-output", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// mps on Apple Silicon, cpu otherwise (falls back to cpu automatically on failure).
    private static func preferredDevice() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine == "arm64" ? "mps" : "cpu"
    }

    // MARK: - Process execution with tqdm progress parsing

    private func runProcess(
        _ executable: URL,
        _ arguments: [String],
        cancellation: CancellationToken,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw StemError.cancelled }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                let buffer = DataBox()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    buffer.data.append(chunk)
                    guard let text = String(data: chunk, encoding: .utf8) else { return }
                    // tqdm emits carriage-return-delimited progress like " 34%|███ | 12/35"
                    let pieces = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    for piece in pieces {
                        if let pct = Self.parsePercent(String(piece)) {
                            progress(pct, "分離中… \(Int(pct * 100))%")
                        }
                    }
                }
                process.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cancellation.clear(proc)
                    if cancellation.isCancelled {
                        continuation.resume(throwing: StemError.cancelled)
                    } else if proc.terminationStatus == 0 {
                        continuation.resume(returning: ())
                    } else {
                        let tail = String(data: buffer.data, encoding: .utf8) ?? ""
                        let lastLines = tail.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).suffix(6).joined(separator: "\n")
                        continuation.resume(throwing: StemError.processFailed(lastLines.isEmpty ? "分離処理が失敗しました" : lastLines))
                    }
                }
                do {
                    try process.run()
                    if cancellation.register(process), process.isRunning { process.terminate() }
                } catch {
                    cancellation.clear(process)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func parsePercent(_ line: String) -> Double? {
        guard let range = line.range(of: "%") else { return nil }
        var start = range.lowerBound
        var digits = ""
        while start > line.startIndex {
            let prev = line.index(before: start)
            if line[prev].isNumber || line[prev] == "." {
                digits = String(line[prev]) + digits
                start = prev
            } else {
                break
            }
        }
        guard let value = Double(digits) else { return nil }
        return max(0, min(1, value / 100))
    }
}
