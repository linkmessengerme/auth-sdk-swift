import Foundation
#if canImport(LinkAuthCore)
import LinkAuthCore
#endif

public enum LinkAuthFailure: Error, Sendable {
    case protocolFailure(ErrorCode)
    case cannotOpenLink
    case closed
}

/// No refresh-token getter and no token-bearing description/Codable conformance.
public final class LinkSession: @unchecked Sendable {
    private let result: SignInResult
    init(_ result: SignInResult) { self.result = result }
    public var user: UserIdentity { result.user() }
    public var expiresAt: Date { Date(timeIntervalSince1970: Double(result.expiresAt())) }
    public var accessToken: String { result.accessToken() }
    public var idToken: String { result.idToken() }
}

public protocol LinkAuthorizationOpener: Sendable {
    /// Called on MainActor. True means the OS accepted opening the URL, not that
    /// authorization succeeded. Success comes only from a verified callback.
    @MainActor func open(_ url: URL) async -> Bool
}

/// One application-owned instance per OAuth configuration. The actor keeps
/// storage/FFI calls off MainActor; only opening the URL runs on MainActor.
public actor LinkAuth {
    private struct Login {
        let id: UUID
        let continuation: CheckedContinuation<LinkSession, Error>
        var expiry: Task<Void, Never>?
    }
    private let core: LinkSessionClient
    private let transport: URLSessionTransport
    private let opener: any LinkAuthorizationOpener
    private let signInTimeout: TimeInterval
    private var login: Login?
    private var generation: UInt64 = 0
    private var sessionCalls = 0
    private var callbackCalls = 0
    private var loggingOut = false
    private var closed = false

    public static func create(configJson: String, redirectUri: String,
        keychainService: String = "me.linkmessenger.auth",
        opener: any LinkAuthorizationOpener = SystemLinkOpener()) async throws -> LinkAuth {
        let client = try await Task.detached {
            let transport = URLSessionTransport()
            do {
                let storage = try KeychainStorage(service: keychainService)
                let core = try LinkSessionClient(configJson: configJson, redirectUri: redirectUri,
                    transport: transport, storage: storage)
                return LinkAuth(core: core, transport: transport, opener: opener)
            } catch { transport.close(); throw normalized(error) }
        }.value
        if Task.isCancelled { try await client.close(); throw CancellationError() }
        return client
    }

    // Injection seam for integration tests; production uses create().
    init(core: LinkSessionClient, transport: URLSessionTransport,
        opener: any LinkAuthorizationOpener, signInTimeout: TimeInterval = 600) {
        self.core = core; self.transport = transport; self.opener = opener
        self.signInTimeout = min(max(signInTimeout, 0.01), 600)
    }

    public func restore() throws -> SessionStatus {
        try requireIdle()
        do { return try core.restore() } catch { throw Self.normalized(error) }
    }

    /// Pass a fresh nonce from your backend when exchanging Link identity for your own session.
    public func signIn(scopes: [String], nonce: String? = nil) async throws -> LinkSession {
        try requireIdle()
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                login = Login(id: id, continuation: continuation)
                Task { await self.prepare(id, scopes: scopes, nonce: nonce) }
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    private func prepare(_ id: UUID, scopes: [String], nonce: String?) async {
        guard login?.id == id else { return }
        do {
            let request: AuthorizationRequest
            if let nonce {
                request = try await core.beginSignInWithNonce(scopes: scopes, nonce: nonce)
            } else {
                request = try await core.beginSignIn(scopes: scopes)
            }
            guard login?.id == id else { return }
            let remaining = min(Double(request.expiresAt()) - Date().timeIntervalSince1970, signInTimeout)
            guard remaining > 0, let url = URL(string: request.authorizationUrl()) else {
                await cancel(id, reason: .protocolFailure(.expired)); return
            }
            login?.expiry = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                catch { return }
                await self?.cancel(id, reason: .protocolFailure(.expired))
            }
            let opened = await opener.open(url)
            if !opened { await cancel(id, reason: .cannotOpenLink) }
        } catch { finish(id, .failure(Self.normalized(error))) }
    }

    /// Forward onOpenURL / scene URLContexts / universal-link webpageURL here.
    /// Returns nil for unrelated or duplicate callbacks. Also works after process
    /// recreation when there is no in-memory signIn() waiter.
    public func handleCallback(_ url: URL) async throws -> UserIdentity? {
        try requireOpen()
        guard !loggingOut else { throw LinkAuthFailure.protocolFailure(.alreadyInProgress) }
        guard core.isCallbackUrl(value: url.absoluteString) else { return nil }
        let id = login?.id, ticket = generation
        callbackCalls += 1; defer { callbackCalls -= 1 }
        do {
            let result = try await core.completeSignIn(callbackUrl: url.absoluteString)
            try requireGeneration(ticket)
            let session = LinkSession(result)
            finish(id, .success(session))
            return session.user
        } catch {
            let failure = Self.normalized(error)
            if case .protocolFailure(let code) = failure {
                switch code {
                case .noPendingLogin: return nil
                case .invalidCallback, .stateMismatch, .issuerMismatch: throw failure
                default: break
                }
            }
            // Invalid links cannot fail the real waiter. Terminal protocol errors
            // settle it exactly once; they never cancel a newer login.
            finish(id, .failure(failure))
            throw failure
        }
    }

    public func getSession(forceRefresh: Bool = false) async throws -> LinkSession {
        try requireOpen()
        guard login == nil && !loggingOut && callbackCalls == 0 else {
            throw LinkAuthFailure.protocolFailure(.alreadyInProgress)
        }
        try Task.checkCancellation()
        let ticket = generation
        sessionCalls += 1; defer { sessionCalls -= 1 }
        do {
            let result = try await (forceRefresh ? core.refresh() : core.validSession())
            try requireGeneration(ticket)
            try Task.checkCancellation()
            return LinkSession(result)
        } catch is CancellationError { throw CancellationError() }
        catch { throw Self.normalized(error) }
    }

    public func getIdToken(forceRefresh: Bool = false) async throws -> String {
        try await getSession(forceRefresh: forceRefresh).idToken
    }

    /// Fresh authorized data; phoneNumber is nil when unavailable or not granted.
    public func getUserInfo() async throws -> UserInfo {
        try requireOpen()
        guard login == nil && !loggingOut && callbackCalls == 0 else {
            throw LinkAuthFailure.protocolFailure(.alreadyInProgress)
        }
        try Task.checkCancellation()
        let ticket = generation
        sessionCalls += 1; defer { sessionCalls -= 1 }
        do {
            let info = try await core.getUserInfo()
            try requireGeneration(ticket)
            try Task.checkCancellation()
            return info
        } catch is CancellationError { throw CancellationError() }
        catch { throw Self.normalized(error) }
    }

    public func cancelSignIn() throws {
        try requireOpen()
        let id = login?.id
        do {
            try core.cancelSignIn()
            if id != nil || callbackCalls > 0 { transport.cancelRequests() }
            finish(id, .failure(LinkAuthFailure.protocolFailure(.cancelled)))
        } catch {
            let failure = Self.normalized(error)
            finish(id, .failure(failure)); throw failure
        }
    }

    public func signOut() async throws -> LogoutStatus {
        try requireOpen()
        guard !loggingOut else { throw LinkAuthFailure.protocolFailure(.alreadyInProgress) }
        loggingOut = true; generation &+= 1
        defer { loggingOut = false }
        do {
            try cancelSignIn()
            // Stop existing refresh before starting revocation. The core retains
            // its family handle and prevents a late result from restoring login.
            transport.cancelRequests()
            return try await core.logout()
        } catch { throw Self.normalized(error) }
    }

    /// Stops this SDK instance; a completed stored session survives disposal.
    public func close() throws {
        if closed { return }
        closed = true; generation &+= 1
        defer { transport.close() }
        let id = login?.id
        do {
            if id != nil || callbackCalls > 0 { try core.cancelSignIn() }
            finish(id, .failure(LinkAuthFailure.closed))
        } catch {
            let failure = Self.normalized(error)
            finish(id, .failure(failure)); throw failure
        }
    }

    private func cancel(_ id: UUID, reason: LinkAuthFailure = .protocolFailure(.cancelled)) async {
        guard login?.id == id else { return }
        do {
            try core.cancelSignIn(); transport.cancelRequests()
            finish(id, .failure(reason))
        } catch { finish(id, .failure(Self.normalized(error))) }
    }
    private func finish(_ id: UUID?, _ result: Result<LinkSession, Error>) {
        guard let id, let current = login, current.id == id else { return }
        login = nil; current.expiry?.cancel()
        current.continuation.resume(with: result)
    }
    private func requireOpen() throws {
        if closed { throw LinkAuthFailure.closed }
    }
    private func requireIdle() throws {
        try requireOpen()
        if login != nil || loggingOut || sessionCalls > 0 || callbackCalls > 0 {
            throw LinkAuthFailure.protocolFailure(.alreadyInProgress)
        }
    }
    private func requireGeneration(_ value: UInt64) throws {
        try requireOpen()
        if value != generation { throw LinkAuthFailure.protocolFailure(.cancelled) }
    }
    private static func normalized(_ error: Error) -> LinkAuthFailure {
        if let failure = error as? LinkAuthFailure { return failure }
        if case AuthError.Failure(let code) = error { return .protocolFailure(code) }
        return .protocolFailure(.internal)
    }
}
