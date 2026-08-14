import Foundation

/// One live notification delivered over GET /v1/notices — the wire shape of
/// `internal/daemon/notices.go`'s `Notice` struct (`{id, at, title, body}`).
struct Notice: Decodable, Equatable, Sendable {
    var id: String
    var at: Date
    var title: String
    var body: String
}

/// Parses `/v1/notices`'s SSE stream into a sequence of `Notice`s. Mirrors
/// `HTTPDaemonClient.events()` (API/DaemonClient.swift) — same base-URL
/// discovery and `data: <json>\n\n` line framing — but authenticated
/// (notices.go guards the route with requireAuth: a notice's body can carry
/// an account label or email) and never coalesced: every line is its own
/// notice, not "latest state wins" like the state stream.
enum NoticeStream {
    /// Parses one SSE line, returning a `Notice` only for a `data: ` line
    /// that decodes cleanly — every other line (event:, blank keep-alive, a
    /// malformed payload) is silently skipped. Pure and side-effect free on
    /// purpose: decode coverage (NoticeStreamTests.swift) needs no live
    /// connection to exercise it.
    static func parse(line: String, decoder: JSONDecoder = DaemonDates.decoder()) -> Notice? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = Data(line.dropFirst("data: ".count).utf8)
        return try? decoder.decode(Notice.self, from: payload)
    }

    /// Long-lived stream of notices from the daemon at `base`, authenticated
    /// with the install `token` (HTTPDaemonClient.installToken()) exactly
    /// like every other Bearer-guarded route (API/DaemonClient.swift
    /// postJSONData). Throws — ending the stream — when the connection
    /// drops or the daemon answers anything but 200; the caller reconnects
    /// (NoticeClient owns backoff, in NoticeNotifier.swift).
    static func connect(base: URL, token: String) -> AsyncThrowingStream<Notice, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("v1/notices"))
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 3600 * 24
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        throw DaemonError.down
                    }
                    let decoder = DaemonDates.decoder()
                    for try await line in bytes.lines {
                        if let n = parse(line: line, decoder: decoder) {
                            continuation.yield(n)
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
