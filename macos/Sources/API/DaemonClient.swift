import Foundation

enum DaemonError: LocalizedError, Equatable {
    case down
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .down:
            return "daemon not running"
        case let .http(_, message):
            return message
        }
    }
}

/// One started in-app sign-in: the approval URL to load and the CSRF state
/// riding it (the PKCE verifier stays inside the daemon).
struct LoginStart: Decodable, Equatable, Sendable {
    let authorizeURL: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case authorizeURL = "authorize_url"
        case state
    }
}

/// The app's only data source. Thin means thin: state from GET /v1/state
/// + SSE, actions via POST — never Keychain, never the usage endpoint.
protocol DaemonAPI: Sendable {
    func baseURL() -> URL?
    /// The cockpit-window URL; may carry the install token as a fragment.
    func cockpitURL() -> URL?
    func state() async throws -> DaemonState
    func switchAccount(to id: String) async throws
    func detect() async throws -> [DetectedDir]
    func adopt(configDir: String) async throws
    func config() async throws -> DaemonConfig
    /// Report the native no-card-trial marker so the daemon hides that rung.
    func reportMarker(present: Bool) async throws
    /// Begin an in-app sign-in (POST /v1/login/start).
    func startLogin() async throws -> LoginStart
    /// Finish it with the intercepted or pasted code (POST /v1/login/complete).
    func completeLogin(code: String, state: String) async throws
    /// Long-lived SSE stream of full states; throws when the connection drops.
    func events() -> AsyncThrowingStream<DaemonState, Error>
}

extension DaemonAPI {
    func cockpitURL() -> URL? { baseURL() }
}

/// The user-facing message for a non-2xx daemon response. The daemon wraps
/// every error as `{"error":"…"}` (httpError, server.go:980-982) — showing
/// the raw body would put JSON braces in a flash banner, so unwrap the
/// envelope first and only fall back to the raw text for non-JSON bodies.
func daemonErrorMessage(from data: Data, code: Int) -> String {
    if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
       !env.error.isEmpty {
        return env.error
    }
    // Any OTHER JSON object body ({"error":""}, {"ok":true}, …) would put
    // braces in a banner — the generic status line beats leaked JSON.
    if let obj = try? JSONSerialization.jsonObject(with: data), obj is [String: Any] {
        return "http \(code)"
    }
    let raw = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return raw?.isEmpty == false ? raw! : "http \(code)"
}

struct HTTPDaemonClient: DaemonAPI {
    /// $LLMPILOT_HOME or ~/.llmpilot — same resolution as internal/store.
    static func home() -> URL {
        if let env = ProcessInfo.processInfo.environment["LLMPILOT_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".llmpilot")
    }

    /// Loopback base from $LLMPILOT_HOME/daemon.port (the cockpit's own discovery).
    func baseURL() -> URL? {
        let portFile = Self.home().appendingPathComponent("daemon.port")
        guard let raw = try? String(contentsOf: portFile, encoding: .utf8),
              let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0
        else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// This run's install token from $LLMPILOT_HOME/daemon.token — the
    /// daemon's license reveal/mutation routes require it as a Bearer header
    /// (internal/daemon/auth.go).
    static func installToken() -> String? {
        let tokenFile = Self.home().appendingPathComponent("daemon.token")
        guard let raw = try? String(contentsOf: tokenFile, encoding: .utf8) else { return nil }
        let tok = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return tok.isEmpty ? nil : tok
    }

    /// Loopback base plus the install token as a URL fragment: the fragment
    /// never rides a request, and the embedded web app moves it into
    /// sessionStorage to authorize license actions.
    func cockpitURL() -> URL? {
        guard let base = baseURL() else { return nil }
        guard let tok = Self.installToken() else { return base }
        return URL(string: base.absoluteString + "/#token=" + tok)
    }

    private func url(_ path: String) throws -> URL {
        guard let base = baseURL() else { throw DaemonError.down }
        return base.appendingPathComponent(path)
    }

    private func get(_ path: String) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do {
            var req = URLRequest(url: try url(path))
            req.timeoutInterval = 5
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as DaemonError {
            throw e
        } catch {
            throw DaemonError.down
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw DaemonError.http(code, daemonErrorMessage(from: data, code: code))
        }
        return data
    }

    /// Mutations must send Content-Type: application/json — the daemon's
    /// CSRF posture 415-rejects anything else.
    private func postJSON<T: Encodable>(_ path: String, _ body: T, timeout: TimeInterval = 10) async throws {
        _ = try await postJSONData(path, body, timeout: timeout)
    }

    private func postJSONData<T: Encodable>(
        _ path: String, _ body: T, timeout: TimeInterval = 10
    ) async throws -> Data {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let tok = Self.installToken() {
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = timeout
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw DaemonError.down
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw DaemonError.http(code, daemonErrorMessage(from: data, code: code))
        }
        return data
    }

    private func post(_ path: String, body: [String: String]) async throws {
        try await postJSON(path, body)
    }

    func state() async throws -> DaemonState {
        try DaemonDates.decoder().decode(DaemonState.self, from: try await get("v1/state"))
    }

    func switchAccount(to id: String) async throws {
        try await post("v1/switch", body: ["account_id": id])
    }

    func detect() async throws -> [DetectedDir] {
        // The daemon marshals a nil slice as top-level JSON null when
        // nothing is detected — decode as optional and coalesce, the same
        // null/absent discipline every array field on the wire earns.
        try DaemonDates.decoder().decode([DetectedDir]?.self, from: try await get("v1/detect")) ?? []
    }

    func adopt(configDir: String) async throws {
        try await post("v1/adopt", body: ["config_dir": configDir])
    }

    func config() async throws -> DaemonConfig {
        try DaemonDates.decoder().decode(DaemonConfig.self, from: try await get("v1/config"))
    }

    func reportMarker(present: Bool) async throws {
        try await postJSON("v1/license/marker", ["present": present])
    }

    func startLogin() async throws -> LoginStart {
        let data = try await postJSONData("v1/login/start", [String: String]())
        return try JSONDecoder().decode(LoginStart.self, from: data)
    }

    func completeLogin(code: String, state: String) async throws {
        // The daemon's exchange (30s budget) + identity fetch + lock-first
        // install can legitimately take a while — never hang up mid-write.
        try await postJSON(
            "v1/login/complete", ["code": code, "state": state], timeout: 90)
    }

    func events() -> AsyncThrowingStream<DaemonState, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: try url("v1/events"))
                    req.timeoutInterval = 3600 * 24
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        throw DaemonError.down
                    }
                    let decoder = DaemonDates.decoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = Data(line.dropFirst("data: ".count).utf8)
                        if let s = try? decoder.decode(DaemonState.self, from: payload) {
                            continuation.yield(s)
                        }
                    }
                    continuation.finish(throwing: DaemonError.down)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
