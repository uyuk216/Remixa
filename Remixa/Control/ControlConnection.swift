import Foundation

/// One accepted connection on the control socket. Reads newline-delimited JSON
/// requests off `queue` and hands each complete line to `onLine`; callers respond
/// asynchronously via `send(_:)`. All socket I/O happens on `queue` (a background
/// serial queue owned by `ControlServer`), never on the main actor.
final class ControlConnection: @unchecked Sendable {
    private static let maximumRequestBytes = 1_048_576
    let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var closed = false

    /// Called (on `queue`) once per complete NDJSON line received.
    var onLine: ((String) -> Void)?
    /// Called (on `queue`) once the connection has been torn down.
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.fd)
        }
        source.resume()
        self.source = source
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = chunk.withUnsafeMutableBytes { ptr in
            recv(fd, ptr.baseAddress, ptr.count, 0)
        }
        guard n > 0 else {
            teardown()
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            guard buffer.distance(from: buffer.startIndex, to: newlineIndex) <= Self.maximumRequestBytes else {
                teardown()
                return
            }
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            onLine?(trimmed)
        }
        if buffer.count > Self.maximumRequestBytes {
            teardown()
        }
    }

    /// Writes one NDJSON response line. Safe to call from any queue/thread.
    func send(_ jsonLine: String) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            var data = Data(jsonLine.utf8)
            data.append(0x0A)
            data.withUnsafeBytes { ptr in
                var offset = 0
                let base = ptr.baseAddress!
                while offset < ptr.count {
                    let written = write(self.fd, base + offset, ptr.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }

    /// Forcibly closes the connection (used when the server shuts down).
    func stop() {
        onClose = nil
        teardown()
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        onClose?()
    }
}
