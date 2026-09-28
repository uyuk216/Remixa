import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Unix domain socket client for talking to the running Remixa app's control socket.
/// Newline-delimited JSON-RPC 2.0, one JSON object per line.
final class RemixaSocketClient {
    static let socketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Remixa/control.sock"
    }()

    private var fd: Int32 = -1

    enum ClientError: Error, CustomStringConvertible {
        case socketCreateFailed
        case connectFailed(String)
        case notConnected
        case writeFailed
        case readFailed
        case invalidResponse(String)
        case rpcError(code: Int, message: String)

        var description: String {
            switch self {
            case .socketCreateFailed: return "ソケットの作成に失敗しました"
            case .connectFailed(let s): return "Remixa に接続できませんでした: \(s)"
            case .notConnected: return "未接続です"
            case .writeFailed: return "送信に失敗しました"
            case .readFailed: return "受信に失敗しました"
            case .invalidResponse(let s): return "不正な応答: \(s)"
            case .rpcError(let code, let message): return "エラー(\(code)): \(message)"
            }
        }
    }

    func connect() throws {
        let path = RemixaSocketClient.socketPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw ClientError.connectFailed("ソケットが見つかりません: \(path)")
        }

        let sockFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFd >= 0 else { throw ClientError.socketCreateFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(sockFd)
            throw ClientError.connectFailed("パスが長すぎます")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buf = rawPtr.bindMemory(to: CChar.self)
            for (i, b) in pathBytes.enumerated() {
                buf[i] = CChar(bitPattern: b)
            }
            buf[pathBytes.count] = 0
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sockFd, sockPtr, addrLen)
            }
        }
        guard result == 0 else {
            close(sockFd)
            throw ClientError.connectFailed(String(cString: strerror(errno)))
        }
        self.fd = sockFd
    }

    func close_() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    deinit {
        close_()
    }

    /// Send a single JSON-RPC request line and read back one response line.
    func call(method: String, params: [String: Any]? = nil, id: String = UUID().uuidString) throws -> [String: Any] {
        guard fd >= 0 else { throw ClientError.notConnected }

        var request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params = params {
            request["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: request, options: [])
        var lineData = data
        lineData.append(0x0A) // \n

        try lineData.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            var remaining = rawBuf.count
            var ptr = rawBuf.baseAddress!
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n <= 0 {
                    throw ClientError.writeFailed
                }
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }

        // Read until newline. No SO_RCVTIMEO is set on this socket, so this blocks
        // indefinitely — required because `export.mix`, `stems.install`, and
        // `stems.separate` can legitimately take up to ~30 minutes (first-run
        // ~1GB model download, offline rendering, etc.) and must not time out.
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n < 0 {
                throw ClientError.readFailed
            }
            if n == 0 {
                break // EOF
            }
            if byte == 0x0A {
                break
            }
            buffer.append(byte)
        }

        guard !buffer.isEmpty else {
            throw ClientError.invalidResponse("空の応答")
        }

        let respData = Data(buffer)
        guard let obj = try JSONSerialization.jsonObject(with: respData, options: []) as? [String: Any] else {
            throw ClientError.invalidResponse(String(data: respData, encoding: .utf8) ?? "?")
        }

        if let error = obj["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? -1
            let message = (error["message"] as? String) ?? "unknown error"
            throw ClientError.rpcError(code: code, message: message)
        }

        return obj
    }
}
