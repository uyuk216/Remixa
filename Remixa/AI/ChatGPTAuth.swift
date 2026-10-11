import AppKit
import CryptoKit
import Foundation
import Network
import Security

// MARK: - Shared value types

/// Localized (Japanese) error shown to the user. `code` is a stable machine-readable identifier.
struct ChatGPTError: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct ChatGPTModel: Identifiable, Hashable, Sendable {
    let slug: String
    let displayName: String
    var id: String { slug }
}

/// Minimal Sendable JSON tree (avoids passing `[String: Any]` across isolation domains).
enum JSONValue: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral,
                ExpressibleByArrayLiteral, ExpressibleByBooleanLiteral {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { JSONValue(any: $0) })
        case let dict as [String: Any]: self = .object(dict.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.any }
        case .object(let o): return o.mapValues { $0.any }
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    static func parse(_ data: Data) -> JSONValue? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: obj)
    }

    func serialized() -> Data? {
        try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }
}

// MARK: - Persisted state

struct ChatGPTStoredState: Codable, Sendable {
    var hostId: String
    var clientId: String?
    var email: String?
    var subject: String?
    var scopes: [String] = []
    var selectedModel: String?
    var welcomeShown: Bool?
}

struct ChatGPTCredentials: Codable, Sendable {
    var accessToken: String
    var expiresAt: Date
    var refreshToken: String?
}

/// Token storage in the macOS keychain; non-secret metadata in Application Support/Remixa/chatgpt.json.
enum ChatGPTStore {
    static let keychainService = "com.remixa.chatgpt"
    static let keychainAccount = "oauth-credentials"

    static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Remixa/chatgpt.json")
    }

    static func loadState() -> ChatGPTStoredState {
        if let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(ChatGPTStoredState.self, from: data) {
            return state
        }
        let fresh = ChatGPTStoredState(hostId: "urn:uuid:\(UUID().uuidString.lowercased())")
        saveState(fresh)
        return fresh
    }

    static func saveState(_ state: ChatGPTStoredState) {
        let url = stateURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    static func loadCredentials() -> ChatGPTCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ChatGPTCredentials.self, from: data)
    }

    static func saveCredentials(_ credentials: ChatGPTCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            throw ChatGPTError(code: "keychain_failed", message: "キーチェーンに認証情報を保存できませんでした (\(status))。")
        }
    }

    static func deleteCredentials() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Pure OAuth helpers (unit-checkable)

enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let sharingScope = "chatgpt.tokens.use.direct"
    static let callbackPath = "/auth/callback"
    static let placeholderClientID = "dynamic_agent_client"
    static let appName = "Remixa"

    // MARK: encoding

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    static func randomValue() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func codeChallenge(verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// application/x-www-form-urlencoded (same escaping as URLSearchParams for our inputs).
    static func formEncode(_ items: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return items.map { "\(esc($0.0))=\(esc($0.1))" }.joined(separator: "&")
    }

    // MARK: authorization URL

    static func authorizationURL(
        endpoint: URL, clientId: String?, redirectURI: String, state: String, nonce: String,
        codeChallenge: String, hostId: String, loginHint: String?
    ) -> URL? {
        var items: [(String, String)] = [
            ("client_id", clientId ?? placeholderClientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", scopes),
            ("resource", resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", codeChallenge),
            ("ext_agent_host_id", hostId)
        ]
        if clientId == nil { items.append(("agent_name_hint", appName)) }
        if let loginHint, !loginHint.isEmpty { items.append(("login_hint", loginHint)) }
        var base = endpoint.absoluteString
        if let q = base.firstIndex(of: "?") { base = String(base[..<q]) }
        return URL(string: base + "?" + formEncode(items))
    }

    // MARK: token response

    struct TokenFields: Sendable {
        var scopes: [String]
        var credentials: ChatGPTCredentials?
    }

    static func parseTokenFields(_ data: JSONValue, requireRefresh: Bool, now: Date = Date()) throws -> TokenFields {
        let bad = { (msg: String) in ChatGPTError(code: "invalid_token_response", message: msg) }
        guard let scopeString = data["scope"]?.stringValue else {
            throw bad("ChatGPTから許可された権限を確認できませんでした。もう一度サインインしてください。")
        }
        let scopes = scopeString.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        let refresh = data["refresh_token"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if let access = data["access_token"]?.stringValue, !access.isEmpty {
            guard data["token_type"]?.stringValue?.lowercased() == "bearer",
                  let expiresIn = data["expires_in"]?.numberValue, expiresIn > 0, expiresIn.isFinite,
                  !((requireRefresh || scopes.contains("offline_access")) && refresh == nil) else {
                throw bad("ChatGPTから不完全な認証情報が返されました。もう一度サインインしてください。")
            }
            return TokenFields(scopes: scopes, credentials: ChatGPTCredentials(
                accessToken: access, expiresAt: now.addingTimeInterval(expiresIn), refreshToken: refresh))
        }
        if requireRefresh || scopes.contains("offline_access") || scopes.contains(sharingScope) {
            throw bad("ChatGPTが必要な認証情報を返しませんでした。もう一度サインインしてください。")
        }
        return TokenFields(scopes: scopes, credentials: nil)
    }

    static func oauthError(_ body: JSONValue?, status: Int) -> ChatGPTError {
        let code = body?["error"]?.stringValue ?? "http_\(status)"
        switch code {
        case "invalid_grant":
            return ChatGPTError(code: code, message: "ChatGPTとの接続の有効期限が切れました。もう一度サインインしてください。")
        case "access_denied":
            return ChatGPTError(code: code, message: "ChatGPTでのサインインが許可されませんでした。")
        default:
            let detail = body?["error_description"]?.stringValue ?? code
            return ChatGPTError(code: code, message: "ChatGPTのサインイン処理でエラーが発生しました (\(String(detail.prefix(120))))。")
        }
    }

    // MARK: ID token

    struct JWT: Sendable {
        let header: JSONValue
        let payload: JSONValue
        let signingInput: Data
        let signature: Data
    }

    static func decodeJWT(_ token: String) -> JWT? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let h = base64URLDecode(parts[0]), let p = base64URLDecode(parts[1]), let s = base64URLDecode(parts[2]),
              let header = JSONValue.parse(h), let payload = JSONValue.parse(p) else { return nil }
        return JWT(header: header, payload: payload, signingInput: Data("\(parts[0]).\(parts[1])".utf8), signature: s)
    }

    struct Identity: Sendable {
        let subject: String
        let email: String?
    }

    /// Validates iss / aud / azp / nonce / exp / sub. Signature is checked separately.
    static func validateClaims(_ payload: JSONValue, clientId: String, nonce: String?, now: Date = Date()) throws -> Identity {
        let invalid = ChatGPTError(code: "invalid_id_token", message: "ChatGPTのアカウント情報を検証できませんでした。もう一度サインインしてください。")
        guard payload["iss"]?.stringValue == issuer,
              let sub = payload["sub"]?.stringValue, !sub.isEmpty,
              let exp = payload["exp"]?.numberValue, exp + 5 > now.timeIntervalSince1970 else { throw invalid }
        switch payload["aud"] {
        case .string(let aud)?:
            guard aud == clientId else { throw invalid }
        case .array(let list)?:
            guard list.contains(.string(clientId)) else { throw invalid }
            if list.count > 1, payload["azp"]?.stringValue != clientId { throw invalid }
        default: throw invalid
        }
        if let azp = payload["azp"]?.stringValue, azp != clientId { throw invalid }
        if let nonce, payload["nonce"]?.stringValue != nonce { throw invalid }
        return Identity(subject: sub, email: payload["email"]?.stringValue)
    }

    /// RS256 signature check against a JWKS document using Security.framework.
    static func verifySignature(_ jwt: JWT, jwks: JSONValue) -> Bool {
        guard jwt.header["alg"]?.stringValue == "RS256",
              let kid = jwt.header["kid"]?.stringValue,
              let keys = jwks["keys"]?.arrayValue,
              let key = keys.first(where: { $0["kid"]?.stringValue == kid && $0["kty"]?.stringValue == "RSA" }),
              let n = key["n"]?.stringValue.flatMap(base64URLDecode),
              let e = key["e"]?.stringValue.flatMap(base64URLDecode) else { return false }
        let der = rsaPublicKeyDER(modulus: n, exponent: e)
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let secKey = SecKeyCreateWithData(Data(der) as CFData, attrs as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(secKey, .rsaSignatureMessagePKCS1v15SHA256,
                                     jwt.signingInput as CFData, jwt.signature as CFData, nil)
    }

    static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> [UInt8] {
        func length(_ n: Int) -> [UInt8] {
            if n < 128 { return [UInt8(n)] }
            if n < 256 { return [0x81, UInt8(n)] }
            return [0x82, UInt8(n >> 8), UInt8(n & 0xff)]
        }
        func integer(_ d: Data) -> [UInt8] {
            var b = Array(d)
            while b.count > 1, b.first == 0 { b.removeFirst() }
            if (b.first ?? 0) >= 0x80 { b.insert(0, at: 0) }
            return [0x02] + length(b.count) + b
        }
        let content = integer(modulus) + integer(exponent)
        return [0x30] + length(content.count) + content
    }
}

// MARK: - HTTP

/// URLSession that never follows redirects (the Authorization header / body must not leave the origin).
enum ChatGPTHTTP {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let delegate = NoRedirect()

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 180
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ChatGPTError(code: "network_error", message: "ChatGPTに接続できませんでした。")
            }
            return (data, http)
        } catch let error as ChatGPTError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ChatGPTError(code: "network_error", message: "ChatGPTに接続できませんでした。ネットワーク接続を確認してもう一度お試しください。")
        }
    }
}

// MARK: - Loopback callback server

/// Single-shot HTTP listener on 127.0.0.1 that waits for `/auth/callback?code=...&state=...`.
final class ChatGPTLoopbackServer: @unchecked Sendable {
    struct Callback: Sendable {
        let code: String
        let clientID: String?
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "remixa.chatgpt.loopback")
    private let expectedState: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Callback, Error>?
    private var finished: Result<Callback, Error>?
    private(set) var port: UInt16 = 0

    init(expectedState: String) { self.expectedState = expectedState }

    var redirectURI: String { "http://127.0.0.1:\(port)\(ChatGPTOAuth.callbackPath)" }

    func start(timeout: TimeInterval = 300) async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch {
            throw ChatGPTError(code: "callback_port_unavailable", message: "サインイン用のローカルポートを確保できませんでした。")
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        let once = Once()
        let assigned: UInt16 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed, .cancelled:
                    if once.take() {
                        cont.resume(throwing: ChatGPTError(code: "callback_port_unavailable", message: "サインイン用のローカルポートを確保できませんでした。"))
                    }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard assigned != 0 else {
            listener.cancel()
            throw ChatGPTError(code: "callback_port_unavailable", message: "サインイン用のローカルポートを確保できませんでした。")
        }
        register(listener: listener, port: assigned)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.complete(.failure(ChatGPTError(code: "timeout", message: "サインインがタイムアウトしました。もう一度お試しください。")))
        }
    }

    private func register(listener: NWListener, port: UInt16) {
        lock.lock(); defer { lock.unlock() }
        self.listener = listener
        self.port = port
    }

    func waitForCallback() async throws -> Callback {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Callback, Error>) in
            lock.lock()
            if let finished {
                lock.unlock()
                cont.resume(with: finished)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<Callback, Error>) {
        lock.lock()
        if finished != nil { lock.unlock(); return }
        finished = result
        let cont = continuation
        continuation = nil
        let l = listener
        listener = nil
        lock.unlock()
        l?.cancel()
        cont?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let (status, body, outcome) = self.process(request: text)
            self.respond(connection, status: status, html: body)
            if let outcome { self.complete(outcome) }
        }
    }

    /// Parses a raw HTTP request. Unrelated requests never consume the pending transaction.
    private func process(request: String) -> (Int, String, Result<Callback, Error>?) {
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        guard first.count >= 2, first[0] == "GET",
              let comps = URLComponents(string: "http://127.0.0.1:\(port)" + first[1]),
              comps.path == ChatGPTOAuth.callbackPath else {
            return (404, "Not found", nil)
        }
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?
            .dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard host == "127.0.0.1:\(port)" else { return (404, "Not found", nil) }
        let items = comps.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        guard values("state").count == 1, Self.constantTimeEqual(values("state")[0], expectedState) else {
            return (400, "サインインの state が一致しません。サインインを開始したブラウザのタブに戻ってください。", nil)
        }
        let page = Self.successHTML()
        if let err = values("error").first {
            let result = ChatGPTOAuth.oauthError(.object(["error": .string(err)]), status: 400)
            return (200, page, .failure(result))
        }
        let codes = values("code")
        guard codes.count == 1, values("client_id").count <= 1 else {
            return (200, page, .failure(ChatGPTError(code: "registration_incomplete",
                                                    message: "ChatGPTがアプリの登録を完了しませんでした。もう一度サインインしてください。")))
        }
        return (200, page, .success(Callback(code: codes[0], clientID: values("client_id").first)))
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private static let script = "history.replaceState(null, \"\", \"/auth/complete\");"

    private static func successHTML() -> String {
        """
        <!doctype html><html lang="ja"><meta charset="utf-8"><title>アプリに戻ってください</title>\
        <style>body{font:17px system-ui;max-width:32rem;margin:18vh auto;padding:24px;color:#202123}h1{font-size:26px}</style>\
        <h1>アプリに戻ってください</h1><p>Remixa がChatGPTとの接続を確認しています。このタブは閉じて構いません。</p>\
        <script>\(script)</script></html>
        """
    }

    private func respond(_ connection: NWConnection, status: Int, html: String) {
        let hash = Data(SHA256.hash(data: Data(Self.script.utf8))).base64EncodedString()
        let reason = status == 200 ? "OK" : (status == 400 ? "Bad Request" : "Not Found")
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n"
            + "Content-Security-Policy: default-src 'none'; script-src 'sha256-\(hash)'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Auth manager

@MainActor
final class ChatGPTAuth: ObservableObject {
    static let shared = ChatGPTAuth()

    @Published private(set) var isSignedIn = false
    @Published private(set) var email: String?
    @Published private(set) var planAvailable = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var models: [ChatGPTModel] = []
    @Published private(set) var selectedModel: String?
    @Published private(set) var lastError: String?
    @Published private(set) var showWelcome = false
    @Published private(set) var usageLimitReached = false

    private struct Discovery: Sendable {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let jwksURI: URL
        let revocationEndpoint: URL?
    }

    private var state: ChatGPTStoredState
    private var credentials: ChatGPTCredentials?
    private var discoveryCache: Discovery?
    private var signInTask: Task<Void, Never>?
    private var activeServer: ChatGPTLoopbackServer?
    private var refreshTask: Task<ChatGPTCredentials, Error>?
    private var modelsTask: Task<Void, Never>?

    private init() {
        state = ChatGPTStore.loadState()
        credentials = ChatGPTStore.loadCredentials()
        publish()
    }

    private func publish() {
        isSignedIn = credentials != nil
        email = state.email
        planAvailable = credentials != nil && state.scopes.contains(ChatGPTOAuth.sharingScope)
        selectedModel = state.selectedModel
    }

    // MARK: discovery

    private func discovery() async throws -> Discovery {
        if let discoveryCache { return discoveryCache }
        let failure = ChatGPTError(code: "discovery_failed", message: "ChatGPTのサインイン設定を確認できませんでした。しばらくしてからお試しください。")
        guard let url = URL(string: "\(ChatGPTOAuth.issuer)/.well-known/openid-configuration") else { throw failure }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, http) = try await ChatGPTHTTP.data(for: request)
        guard http.statusCode == 200, let json = JSONValue.parse(data), json["issuer"]?.stringValue == ChatGPTOAuth.issuer else { throw failure }
        func endpoint(_ key: String) -> URL? {
            guard let s = json[key]?.stringValue, let u = URL(string: s), let scheme = u.scheme, let host = u.host,
                  "\(scheme)://\(host)" == ChatGPTOAuth.issuer else { return nil }
            return u
        }
        guard let auth = endpoint("authorization_endpoint"), let token = endpoint("token_endpoint"), let jwks = endpoint("jwks_uri") else { throw failure }
        if json["revocation_endpoint"] != nil, endpoint("revocation_endpoint") == nil { throw failure }
        let value = Discovery(authorizationEndpoint: auth, tokenEndpoint: token, jwksURI: jwks, revocationEndpoint: endpoint("revocation_endpoint"))
        discoveryCache = value
        return value
    }

    // MARK: sign in

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performSignIn()
            } catch is CancellationError {
                // user cancelled
            } catch {
                self.lastError = error.localizedDescription
            }
            self.activeServer = nil
            self.isSigningIn = false
            self.signInTask = nil
        }
    }

    func cancelSignIn() {
        activeServer?.cancel()
        signInTask?.cancel()
    }

    private func tokenRequest(_ items: [(String, String)]) async throws -> JSONValue {
        let provider = try await discovery()
        var request = URLRequest(url: provider.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(ChatGPTOAuth.formEncode(items).utf8)
        let (data, http) = try await ChatGPTHTTP.data(for: request)
        let json = JSONValue.parse(data)
        guard http.statusCode == 200 else { throw ChatGPTOAuth.oauthError(json, status: http.statusCode) }
        guard let json, case .object = json else {
            throw ChatGPTError(code: "invalid_token_response", message: "ChatGPTから不正なトークン応答が返されました。もう一度サインインしてください。")
        }
        return json
    }

    private func performSignIn() async throws {
        let provider = try await discovery()
        let oauthState = ChatGPTOAuth.randomValue()
        let nonce = ChatGPTOAuth.randomValue()
        let verifier = ChatGPTOAuth.randomValue()
        let server = ChatGPTLoopbackServer(expectedState: oauthState)
        activeServer = server
        try await server.start()
        try Task.checkCancellation()
        defer { server.cancel() }

        guard let url = ChatGPTOAuth.authorizationURL(
            endpoint: provider.authorizationEndpoint, clientId: state.clientId, redirectURI: server.redirectURI,
            state: oauthState, nonce: nonce, codeChallenge: ChatGPTOAuth.codeChallenge(verifier: verifier),
            hostId: state.hostId, loginHint: state.email) else {
            throw ChatGPTError(code: "invalid_url", message: "サインインURLを作成できませんでした。")
        }
        guard NSWorkspace.shared.open(url) else {
            throw ChatGPTError(code: "browser_unavailable", message: "ブラウザを開けませんでした。既定のブラウザを確認してください。")
        }
        let callback = try await withTaskCancellationHandler {
            try await server.waitForCallback()
        } onCancel: {
            server.cancel()
        }

        // The issued client_id is stored before the one-time code exchange so a failure does not re-register.
        let saved = state.clientId
        let returned = callback.clientID
        guard let clientId = returned ?? saved,
              clientId.range(of: "^[a-zA-Z0-9_-]{1,200}$", options: .regularExpression) != nil,
              clientId != ChatGPTOAuth.placeholderClientID,
              !(saved != nil && returned != nil && saved != returned) else {
            throw ChatGPTError(code: "registration_incomplete", message: "ChatGPTがアプリの登録を完了しませんでした。もう一度サインインしてください。")
        }
        state.clientId = clientId
        ChatGPTStore.saveState(state)

        let data = try await tokenRequest([
            ("grant_type", "authorization_code"), ("client_id", clientId), ("code", callback.code),
            ("code_verifier", verifier), ("redirect_uri", server.redirectURI), ("resource", ChatGPTOAuth.resource)
        ])
        guard let idToken = data["id_token"]?.stringValue else {
            throw ChatGPTError(code: "invalid_id_token", message: "ChatGPTのアカウント情報を検証できませんでした。もう一度サインインしてください。")
        }
        let identity = try await verifyIDToken(idToken, clientId: clientId, nonce: nonce)
        if let subject = state.subject, subject != identity.subject {
            throw ChatGPTError(code: "account_mismatch", message: "以前とは別のChatGPTアカウントでサインインされました。元のアカウントを選んでください。")
        }
        let fields = try ChatGPTOAuth.parseTokenFields(data, requireRefresh: false)
        guard let creds = fields.credentials else {
            throw ChatGPTError(code: "invalid_token_response", message: "ChatGPTが必要な認証情報を返しませんでした。もう一度サインインしてください。")
        }
        try Task.checkCancellation()
        try ChatGPTStore.saveCredentials(creds)
        credentials = creds
        state.subject = identity.subject
        state.email = identity.email ?? state.email
        state.scopes = fields.scopes
        ChatGPTStore.saveState(state)
        publish()
        if !planAvailable {
            lastError = "このChatGPTアカウントではプランの利用許可(chatgpt.tokens.use.direct)が付与されませんでした。"
        }
        reloadModels()
        if planAvailable, state.welcomeShown != true { showWelcome = true }
    }

    /// Records that the first-sign-in welcome was shown so it never reappears.
    func dismissWelcome() {
        showWelcome = false
        state.welcomeShown = true
        ChatGPTStore.saveState(state)
    }

    func reportUsageLimit() { usageLimitReached = true }
    func clearUsageLimit() { usageLimitReached = false }

    private func verifyIDToken(_ idToken: String, clientId: String, nonce: String?) async throws -> ChatGPTOAuth.Identity {
        guard let jwt = ChatGPTOAuth.decodeJWT(idToken) else {
            throw ChatGPTError(code: "invalid_id_token", message: "ChatGPTのアカウント情報を検証できませんでした。もう一度サインインしてください。")
        }
        let identity = try ChatGPTOAuth.validateClaims(jwt.payload, clientId: clientId, nonce: nonce)
        let unavailable = ChatGPTError(code: "identity_verification_unavailable", message: "ChatGPTの本人確認が一時的に利用できません。しばらくしてからお試しください。")
        let provider = try await discovery()
        var request = URLRequest(url: provider.jwksURI)
        request.timeoutInterval = 15
        guard let (data, http) = try? await ChatGPTHTTP.data(for: request), http.statusCode == 200,
              let jwks = JSONValue.parse(data) else { throw unavailable }
        guard ChatGPTOAuth.verifySignature(jwt, jwks: jwks) else {
            throw ChatGPTError(code: "invalid_id_token", message: "ChatGPTのアカウント情報の署名を検証できませんでした。もう一度サインインしてください。")
        }
        return identity
    }

    // MARK: tokens

    /// Returns a valid access token, refreshing it first when it expires within 5 minutes.
    func validAccessToken() async throws -> String {
        guard let creds = credentials else {
            throw ChatGPTError(code: "not_signed_in", message: "ChatGPTにサインインしていません。AIアシスタントパネルからサインインしてください。")
        }
        guard state.scopes.contains(ChatGPTOAuth.sharingScope) else {
            throw ChatGPTError(code: "plan_unavailable", message: "このChatGPTアカウントではプランの利用が許可されていません。サインインし直してください。")
        }
        if creds.expiresAt.timeIntervalSinceNow > 300 { return creds.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    private func refresh() async throws -> ChatGPTCredentials {
        guard let clientId = state.clientId, let refreshToken = credentials?.refreshToken else {
            clearTokens()
            throw ChatGPTError(code: "invalid_grant", message: "ChatGPTとの接続の有効期限が切れました。もう一度サインインしてください。")
        }
        let data: JSONValue
        do {
            data = try await tokenRequest([
                ("grant_type", "refresh_token"), ("client_id", clientId),
                ("refresh_token", refreshToken), ("resource", ChatGPTOAuth.resource)
            ])
        } catch let error as ChatGPTError where error.code == "invalid_grant" {
            clearTokens()
            throw error
        }
        // OAuth may omit scope on refresh when unchanged: carry over the previous scopes.
        var merged = data
        if data["scope"] == nil, case .object(var o) = data {
            o["scope"] = .string(state.scopes.joined(separator: " "))
            merged = .object(o)
        }
        let fields = try ChatGPTOAuth.parseTokenFields(merged, requireRefresh: true)
        guard let creds = fields.credentials else {
            throw ChatGPTError(code: "invalid_token_response", message: "ChatGPTが必要な認証情報を返しませんでした。もう一度サインインしてください。")
        }
        if let idToken = data["id_token"]?.stringValue {
            let identity = try await verifyIDToken(idToken, clientId: clientId, nonce: nil)
            if let subject = state.subject, subject != identity.subject {
                clearTokens()
                throw ChatGPTError(code: "account_mismatch", message: "更新後のChatGPTアカウントが一致しません。もう一度サインインしてください。")
            }
            state.email = identity.email ?? state.email
        }
        try ChatGPTStore.saveCredentials(creds)
        credentials = creds
        state.scopes = fields.scopes
        ChatGPTStore.saveState(state)
        publish()
        return creds
    }

    private func clearTokens() {
        ChatGPTStore.deleteCredentials()
        credentials = nil
        state.scopes = []
        ChatGPTStore.saveState(state)
        models = []
        publish()
    }

    // MARK: sign out

    func signOut() async {
        cancelSignIn()
        let token = credentials?.refreshToken
        let clientId = state.clientId
        var revokeFailed = false
        if let token, let clientId {
            do {
                let provider = try await discovery()
                guard let endpoint = provider.revocationEndpoint else { throw ChatGPTError(code: "revocation_failed", message: "") }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(ChatGPTOAuth.formEncode([
                    ("token", token), ("token_type_hint", "refresh_token"), ("client_id", clientId)]).utf8)
                let (_, http) = try await ChatGPTHTTP.data(for: request)
                revokeFailed = http.statusCode != 200
            } catch {
                revokeFailed = true
            }
        }
        // client_id / host_id / email are kept so a later sign-in reuses the same registration.
        clearTokens()
        await ChatGPTAgent.shared.resetConversation()
        lastError = revokeFailed
            ? "端末の認証情報は削除しましたが、ChatGPT側の接続解除を確認できませんでした。ChatGPTの設定からRemixaの接続を解除してください。"
            : nil
    }

    // MARK: models

    func selectModel(_ slug: String) {
        state.selectedModel = slug
        ChatGPTStore.saveState(state)
        publish()
    }

    func reloadModels() {
        guard isSignedIn, modelsTask == nil else { return }
        modelsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await self.validAccessToken()
                let list = try await Self.fetchModels(accessToken: token)
                self.models = list
                if self.state.selectedModel == nil || !list.contains(where: { $0.slug == self.state.selectedModel }),
                   let first = list.first {
                    self.selectModel(first.slug)
                }
            } catch is CancellationError {
            } catch {
                self.lastError = error.localizedDescription
            }
            self.modelsTask = nil
        }
    }

    /// Model slug to use for a request (loads the catalog when nothing is selected yet).
    func resolveModel() async throws -> String {
        if let m = state.selectedModel { return m }
        let token = try await validAccessToken()
        let list = try await Self.fetchModels(accessToken: token)
        models = list
        guard let first = list.first else {
            throw ChatGPTError(code: "no_models", message: "利用できるChatGPTモデルが見つかりませんでした。")
        }
        selectModel(first.slug)
        return first.slug
    }

    nonisolated static func parseModels(_ body: JSONValue) -> [ChatGPTModel]? {
        guard let list = body["models"]?.arrayValue else { return nil }
        var result: [ChatGPTModel] = []
        for model in list where model["visibility"]?.stringValue == "list" {
            guard let slug = model["slug"]?.stringValue, !slug.trimmingCharacters(in: .whitespaces).isEmpty, slug.count <= 200,
                  let name = model["display_name"]?.stringValue, !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 200 else { return nil }
            result.append(ChatGPTModel(slug: slug, displayName: name))
        }
        return result
    }

    nonisolated static func fetchModels(accessToken: String) async throws -> [ChatGPTModel] {
        guard let url = URL(string: "\(ChatGPTOAuth.resource)/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await ChatGPTHTTP.data(for: request)
        guard http.statusCode == 200 else {
            throw ChatGPTAgent.httpError(status: http.statusCode, body: data)
        }
        guard let json = JSONValue.parse(data), let models = parseModels(json) else {
            throw ChatGPTError(code: "invalid_model_catalog", message: "ChatGPTのモデル一覧を取得できませんでした。もう一度お試しください。")
        }
        return models
    }
}
