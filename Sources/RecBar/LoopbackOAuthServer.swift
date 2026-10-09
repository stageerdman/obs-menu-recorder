import Foundation
import Network

/// A one-shot loopback HTTP server that catches an OAuth2 authorization-code redirect.
///
/// This is the mechanism behind the "click Connect → sign in in your real browser → it just
/// finishes" flow (modelled on the Pensieve project's loopback approach), replacing the old
/// device-code flow where the user had to copy a code into a separate page. It binds an
/// OS-assigned ephemeral port on `127.0.0.1` only, hands that port back so the caller can build
/// the `redirect_uri`, then waits for the system browser to hit it with `?code=…&state=…`
/// (or `?error=…`), answers with a tiny "you can close this tab" page, and resolves.
///
/// Loopback + a dynamic port is the standard native-app pattern (RFC 8252): the Azure app just
/// needs `http://localhost` registered under "Mobile and desktop applications" — Microsoft
/// matches loopback redirects ignoring the port, so nothing here is hardcoded to one port.
@MainActor
final class LoopbackOAuthServer {
    struct Redirect {
        let code: String?
        let state: String?
        let error: String?
    }

    enum ServerError: Error, LocalizedError {
        case bindFailed(String)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .bindFailed(let m): return "Couldn't start the local sign-in listener: \(m)"
            case .timedOut: return "Timed out waiting for the browser sign-in to come back."
            case .cancelled: return "Sign-in cancelled."
            }
        }
    }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var redirectContinuation: CheckedContinuation<Redirect, Error>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    /// The path the OAuth redirect will hit (e.g. `/api/auth/callback`). Requests to any other
    /// path (favicon, etc.) get a 404 and the server keeps waiting for the real redirect.
    private var expectedPath = "/callback"

    private static let closePage = """
    <!doctype html><html><head><meta charset="utf-8"><title>RecBar</title>
    <style>body{font-family:-apple-system,system-ui,sans-serif;background:#1d1d1f;color:#f5f5f7;\
    display:flex;align-items:center;justify-content:center;height:100vh;margin:0}\
    .card{text-align:center}h1{font-size:20px;font-weight:600}p{color:#86868b}</style></head>
    <body><div class="card"><h1>✓ Signed in to OneDrive</h1>
    <p>You can close this tab and return to RecBar.</p></div></body></html>
    """

    /// Binds the given loopback `port` and listens for the OAuth redirect on `path`. Must be
    /// called (and must succeed) before the browser is opened, so the redirect is never missed.
    /// Throws `.bindFailed` if the port is already in use — the redirect would otherwise land on
    /// whatever else holds the port and the sign-in could never complete.
    func start(port: UInt16, path: String) async throws {
        expectedPath = path.isEmpty ? "/" : path

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.bindFailed("invalid port \(port)")
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        // Allow a quick rebind if a previous attempt left the port in TIME_WAIT.
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = false
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw ServerError.bindFailed(error.localizedDescription)
        }
        self.listener = listener

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.startContinuation = cont
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor in self?.resumeStart(.success(())) }
                case .failed(let error):
                    Task { @MainActor in
                        self?.resumeStart(.failure(ServerError.bindFailed(
                            "port \(port) may be in use (\(error.localizedDescription))")))
                        self?.cleanup()
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.handle(conn) }
            }
            listener.start(queue: .main)
        }
    }

    private func resumeStart(_ result: Result<Void, Error>) {
        guard let cont = startContinuation else { return }
        startContinuation = nil
        cont.resume(with: result)
    }

    /// Awaits the browser redirect to the loopback port, or throws on timeout.
    func waitForRedirect(timeout: TimeInterval) async throws -> Redirect {
        try await withCheckedThrowingContinuation { cont in
            self.redirectContinuation = cont
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(ServerError.timedOut))
            }
        }
    }

    func cancel() {
        finish(.failure(ServerError.cancelled))
    }

    private func handle(_ conn: NWConnection) {
        self.connection = conn
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }
            Task { @MainActor in
                if let data, let request = String(data: data, encoding: .utf8) {
                    self.respond(to: conn, request: request)
                } else if error != nil {
                    conn.cancel()
                }
            }
        }
    }

    private func respond(to conn: NWConnection, request: String) {
        // First line: "GET /api/auth/callback?code=…&state=… HTTP/1.1"
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let reqPath = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""

        // Ignore anything that isn't the OAuth redirect path (favicon, etc.) and keep waiting.
        guard reqPath == expectedPath else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: notFound.data(using: .utf8)!, completion: .contentProcessed { _ in
                conn.cancel()
            })
            // Listener stays up — the real redirect arrives as a fresh connection.
            return
        }

        let query = target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""

        var code: String?, state: String?, errorParam: String?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
            switch key {
            case "code": code = value
            case "state": state = value
            case "error": errorParam = value
            default: break
            }
        }

        let body = Self.closePage.data(using: .utf8)!
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = header.data(using: .utf8)! + body
        conn.send(content: response, completion: .contentProcessed { _ in
            conn.cancel()
        })

        finish(.success(Redirect(code: code, state: state, error: errorParam)))
    }

    private func finish(_ result: Result<Redirect, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let cont = redirectContinuation {
            redirectContinuation = nil
            cont.resume(with: result)
        }
        cleanup()
    }

    private func cleanup() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
    }
}
