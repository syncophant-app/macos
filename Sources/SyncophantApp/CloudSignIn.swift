import AppKit
import CoreKit
import Network

/// Browser sign-in for a cloud drive with the person's own OAuth app: opens the provider's consent page,
/// receives the redirect on http://localhost:53682/ (loopback only), checks `state`, and trades the code
/// for tokens with PKCE. Tokens stay in memory until Connect saves them to the Keychain.
enum CloudSignIn {
    static func run(_ service: OAuthService, client: OAuthClient) async throws -> (token: OAuthToken, account: String) {
        let verifier = OAuthPKCE.verifier(), state = OAuthPKCE.state()
        let url = service.authorizationURL(clientID: client.clientID, state: state, challenge: OAuthPKCE.challenge(for: verifier))
        let code = try await LoopbackRedirect.code(state: state) { NSWorkspace.shared.open(url) }
        let token = try await service.exchange(code: code, verifier: verifier, client: client)
        let account = try await CloudStore(service: service, session: OAuthSession(service: service, client: client, token: token)).accountName()
        return (token, account)
    }
}

/// One-shot HTTP listener on the loopback interface for the OAuth redirect.
private enum LoopbackRedirect {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, any Error>?
        private var early: Result<String, any Error>?
        func set(_ continuation: CheckedContinuation<String, any Error>) {
            lock.lock()
            if let early { lock.unlock(); continuation.resume(with: early); return }
            self.continuation = continuation; lock.unlock()
        }
        func finish(_ result: Result<String, any Error>) {
            lock.lock()
            guard let c = continuation else { if early == nil { early = result }; lock.unlock(); return }
            continuation = nil; early = result; lock.unlock()
            c.resume(with: result)
        }
    }

    static func code(state: String, opened: @escaping @Sendable () -> Void) async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: OAuthService.callbackPort) else { throw AppError.unavailable("Invalid sign-in port.") }
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: port) }
        catch { throw AppError.unavailable("Port \(OAuthService.callbackPort) is busy, so the sign-in can’t receive its answer. Close other sign-in windows and try again.") }
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.set(continuation)
                listener.newConnectionHandler = { connection in
                    connection.start(queue: .global(qos: .userInitiated))
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                        let outcome = parse(data ?? Data(), state: state)
                        let page = outcome == nil ? "Not found" : "You can close this tab and return to Syncophant."
                        let status = outcome == nil ? "404 Not Found" : "200 OK"
                        let body = "<!doctype html><meta charset=utf-8><title>Syncophant</title><p style=\"font:15px -apple-system;margin:40px\">\(page)</p>"
                        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                        if let outcome { once.finish(outcome); listener.cancel() }
                    }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: opened()
                    case .failed(let error):
                        once.finish(.failure(AppError.unavailable("The sign-in listener stopped: \(error.localizedDescription)")))
                    default: break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                    once.finish(.failure(AppError.unavailable("The sign-in timed out. Try again.")))
                    listener.cancel()
                }
            }
        } onCancel: { once.finish(.failure(CancellationError())); listener.cancel() }
    }

    /// nil for unrelated requests (such as a favicon); otherwise the code or the provider's refusal.
    private static func parse(_ data: Data, state: String) -> Result<String, any Error>? {
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first,
              line.hasPrefix("GET /?"),
              let target = line.split(separator: " ").dropFirst().first,
              let items = URLComponents(string: "http://localhost" + target)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == state else { return .failure(AppError.unavailable("The sign-in answer didn’t match this request. Try again.")) }
        if let code = value("code"), !code.isEmpty { return .success(code) }
        let reason = value("error_description") ?? value("error") ?? "no reason given"
        return .failure(AppError.unavailable("Sign-in was refused: \(reason)."))
    }
}
