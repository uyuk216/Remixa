import Foundation

/// Unix-domain-socket JSON-RPC control server (see `ai-protocol.md`).
///
/// Listens on `~/Library/Application Support/Remixa/control.sock`, one NDJSON
/// (newline-delimited JSON-RPC 2.0) object per request/response. All socket
/// plumbing runs on a private background queue; every request is handed to
/// `ControlMethods`, which is `@MainActor`-isolated so it can safely read and
/// mutate the live project/engine and go through the same undo stack as the UI.
final class ControlServer: @unchecked Sendable {
    static let shared = ControlServer()

    private let queue = DispatchQueue(label: "io.github.uyuk216.remixa.control")
    private let methods = ControlMethods()

    private var listenSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: ControlConnection] = [:]

    private init() {}

    var isRunning: Bool { listenSocket >= 0 }

    static func socketURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("Remixa", isDirectory: true).appendingPathComponent("control.sock")
    }

    @MainActor
    func attach(project: RemixaProject, timelineEngine: TimelineEngine) {
        methods.attach(project: project, timelineEngine: timelineEngine)
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    // MARK: - Socket setup (runs on `queue`)

    private func startOnQueue() {
        guard listenSocket < 0 else { return }
        guard let socketURL = Self.socketURL() else { return }

        let dir = socketURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        unlink(socketURL.path) // remove stale socket from a previous run/crash

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { cptr in
                _ = path.withCString { strncpy(cptr, $0, maxLen - 1) }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { rawPtr -> Int32 in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            close(fd)
            return
        }

        listenSocket = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        acceptSource = source
    }

    private func stopOnQueue() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenSocket >= 0 {
            listenSocket = -1
        }
        for (_, conn) in connections { conn.stop() }
        connections.removeAll()
        if let url = Self.socketURL() { unlink(url.path) }
    }

    private func acceptConnection() {
        let clientFd = accept(listenSocket, nil, nil)
        guard clientFd >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        let conn = ControlConnection(fd: clientFd, queue: queue)
        let key = ObjectIdentifier(conn)
        conn.onLine = { [weak self] line in
            guard let self else { return }
            Task {
                if let response = await self.methods.handleLine(line) {
                    conn.send(response)
                }
            }
        }
        conn.onClose = { [weak self] in
            // ControlConnection invokes this callback on the server's serial queue.
            self?.connections.removeValue(forKey: key)
        }
        connections[key] = conn
        conn.start()
    }
}
