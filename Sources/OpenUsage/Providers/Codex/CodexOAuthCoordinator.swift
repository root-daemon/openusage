import AppKit
import CryptoKit
import Foundation
import Network
import Observation

@MainActor
@Observable
final class CodexOAuthCoordinator {
    enum Status: Equatable {
        case idle
        case waiting
        case succeeded(String)
        case failed(String)
    }

    nonisolated private static let callbackPort: UInt16 = 1455
    nonisolated private static let callbackPath = "/auth/callback"

    private let accountStore: CodexAccountStore
    private let usageClient: CodexUsageClient
    private var listener: NWListener?
    private var task: Task<Void, Never>?

    var status: Status = .idle

    init(accountStore: CodexAccountStore, usageClient: CodexUsageClient = CodexUsageClient()) {
        self.accountStore = accountStore
        self.usageClient = usageClient
    }

    func start(onAccountAdded: @escaping @MainActor () -> Void = {}) {
        cancel()
        status = .waiting
        let verifier = Self.randomToken(byteCount: 32)
        let state = Self.randomToken(byteCount: 24)
        let redirectURI = Self.redirectURI

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try await self.listenForCode(expectedState: state)
                let auth = try await self.usageClient.exchangeAuthorizationCode(
                    code: code,
                    redirectURI: redirectURI,
                    codeVerifier: verifier
                )
                try self.accountStore.saveManagedAuth(auth)
                self.status = .succeeded("Codex account added.")
                onAccountAdded()
            } catch is CancellationError {
                self.status = .idle
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.accountStore.lastError = message
                self.status = .failed(message)
            }
            self.stopListener()
        }

        NSWorkspace.shared.open(Self.authorizationURL(
            redirectURI: redirectURI,
            state: state,
            codeChallenge: Self.codeChallenge(for: verifier)
        ))
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopListener()
        status = .idle
    }

    func clearStatus() {
        status = .idle
        accountStore.lastError = nil
    }

    private func listenForCode(expectedState: String) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.callbackPort)!)
                    self.listener = listener
                    let box = CallbackContinuation(continuation)
                    listener.newConnectionHandler = { connection in
                        Task { @MainActor in
                            self.handle(connection: connection, expectedState: expectedState, continuation: box)
                        }
                    }
                    listener.stateUpdateHandler = { state in
                        if case .failed(let error) = state {
                            Task { @MainActor in
                                box.resume(throwing: CodexOAuthError.listenerFailed(error.localizedDescription))
                            }
                        }
                    }
                    listener.start(queue: .main)
                } catch {
                    continuation.resume(throwing: CodexOAuthError.listenerFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            Task { @MainActor in self.stopListener() }
        }
    }

    private func handle(connection: NWConnection, expectedState: String, continuation: CallbackContinuation) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
            guard error == nil, let data, let request = String(data: data, encoding: .utf8) else {
                Self.respond("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", on: connection)
                return
            }
            switch Self.parseCode(from: request, expectedState: expectedState) {
            case .success(let code):
                Self.respond(Self.successResponse, on: connection)
                continuation.resume(returning: code)
            case .failure(let oauthError):
                let response = oauthError == .invalidCallback
                    ? "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                    : Self.failureResponse
                Self.respond(response, on: connection)
                if oauthError != .invalidCallback {
                    continuation.resume(throwing: oauthError)
                }
            }
        }
    }

    nonisolated private static func respond(_ response: String, on connection: NWConnection) {
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    private static var redirectURI: String {
        "http://localhost:\(callbackPort)\(callbackPath)"
    }

    static func authorizationURLForTesting(redirectURI: String, state: String, codeChallenge: String) -> URL {
        authorizationURL(redirectURI: redirectURI, state: state, codeChallenge: codeChallenge)
    }

    static var redirectURIForTesting: String { redirectURI }

    private static func authorizationURL(redirectURI: String, state: String, codeChallenge: String) -> URL {
        var components = URLComponents(url: CodexUsageClient.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexUsageClient.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "openusage")
        ]
        return components.url!
    }

    nonisolated private static func parseCode(from request: String, expectedState: String) -> Result<String, CodexOAuthError> {
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              firstLine.hasPrefix("GET ")
        else { return .failure(.invalidCallback) }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://localhost\(parts[1])"),
              url.path == callbackPath,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .failure(.invalidCallback) }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        guard items["state"] == expectedState else { return .failure(.stateMismatch) }
        guard let code = items["code"], !code.isEmpty else { return .failure(.missingCode) }
        return .success(code)
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded
    }

    private static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    nonisolated private static let successResponse =
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 67\r\n\r\n<html><body><h3>Codex account added. You can close this tab.</h3></body></html>"

    nonisolated private static let failureResponse =
        "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 66\r\n\r\n<html><body><h3>Codex login failed. Return to OpenUsage.</h3></body></html>"
}

private enum CodexOAuthError: Error, LocalizedError, Equatable {
    case invalidCallback
    case missingCode
    case stateMismatch
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            return "Codex login callback was invalid."
        case .missingCode:
            return "Codex login did not return an authorization code."
        case .stateMismatch:
            return "Codex login state did not match. Try again."
        case .listenerFailed(let message):
            return message.isEmpty ? "Could not start Codex login callback server." : message
        }
    }
}

private final class CallbackContinuation: @unchecked Sendable {
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: String) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
