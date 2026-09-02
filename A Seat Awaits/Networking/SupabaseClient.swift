//
//  SupabaseClient.swift
//  A Seat Awaits
//
//  A small, dependency-free Supabase client built on URLSession. It talks to
//  the same backend the web app uses (Supabase GoTrue for auth + PostgREST for
//  data, protected by row-level security), so no server secrets ship in the app
//  — only the public anon key.
//
//  Implemented as an `actor` so the cached session/token can be mutated safely
//  from concurrent callers and refreshed transparently before each request.
//
//  Robustness notes:
//   - Token refresh is single-flight. Actor reentrancy means five parallel
//     selects (e.g. `SeatingStore.loadAll`) could each observe an expiring
//     token and each POST the same rotating refresh token; GoTrue rejects the
//     replays and the session dies. `refreshToken()` shares one in-flight task.
//   - An authenticated request that comes back 401 forces one refresh and is
//     retried exactly once. If the refresh itself is rejected (4xx), the session
//     is cleared and `sessionEvents()` subscribers (AppState) flip the app to
//     signed-out with a friendly message.
//   - `URLError.cancelled` surfaces as `CancellationError`, never as a
//     transport failure, so a `.task` cancelled by navigation stays silent.
//

import Foundation

/// Session lifecycle events broadcast by `SupabaseClient.sessionEvents()`.
nonisolated enum SupabaseSessionEvent: Sendable, Equatable {
    /// The refresh token was rejected by the server and the local session was
    /// cleared. The app must return to the signed-out state.
    case sessionInvalidated
}

actor SupabaseClient {

    private let baseURL: URL
    private let anonKey: String
    private let urlSession: URLSession
    private let keychain: KeychainStore

    /// In-memory cache of the current session (also persisted in the Keychain).
    private var session: AuthSession?

    /// The single in-flight refresh, shared by every concurrent caller.
    private var refreshTask: Task<Void, Error>?

    /// Live subscribers to session lifecycle events.
    private var sessionEventContinuations: [UUID: AsyncStream<SupabaseSessionEvent>.Continuation] = [:]

    // MARK: - Init

    init(config: AppConfig.Values,
         urlSession: URLSession = .shared,
         keychain: KeychainStore = KeychainStore()) {
        self.baseURL = config.supabaseURL
        self.anonKey = config.supabaseAnonKey
        self.urlSession = urlSession
        self.keychain = keychain
        self.session = keychain.load(AuthSession.self)
    }

    // MARK: - Session

    var currentSession: AuthSession? { session }
    var currentUser: AuthUser? { session?.user }
    var isAuthenticated: Bool { session != nil }

    private func setSession(_ newValue: AuthSession?) {
        session = newValue
        if let newValue {
            keychain.save(newValue)
        } else {
            keychain.clear()
        }
    }

    /// A stream of session lifecycle events. `AppState` subscribes so a dead
    /// refresh token (detected mid-request, long after launch) flips the root
    /// view to signed-out instead of leaving every screen erroring.
    func sessionEvents() -> AsyncStream<SupabaseSessionEvent> {
        let (stream, continuation) = AsyncStream<SupabaseSessionEvent>.makeStream()
        let id = UUID()
        sessionEventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSessionEventContinuation(id) }
        }
        return stream
    }

    private func removeSessionEventContinuation(_ id: UUID) {
        sessionEventContinuations[id] = nil
    }

    private func broadcast(_ event: SupabaseSessionEvent) {
        for continuation in sessionEventContinuations.values {
            continuation.yield(event)
        }
    }

    /// Restores a persisted session, refreshing the token if needed. Returns the
    /// user when a valid session exists, otherwise nil.
    func restoreSession() async -> AuthUser? {
        guard let existing = session else { return nil }
        if existing.isExpiring {
            do {
                try await refreshToken()
            } catch SupabaseError.notAuthenticated {
                // Definitive auth rejection — the refresh token is dead and
                // `refreshToken()` already cleared the session.
                return nil
            } catch {
                // Transient failure (offline, timeout, 5xx): keep the stored
                // session — the refresh token may be perfectly valid, and
                // `validAccessToken` retries the refresh before every request
                // once connectivity returns. Wiping the Keychain here would
                // sign the user out over a network blip at launch.
                return session?.user ?? existing.user
            }
        }
        return session?.user
    }

    // MARK: - Auth

    enum SignUpResult {
        case signedIn(AuthUser)
        case confirmationRequired
    }

    func signUp(email: String, password: String, fullName: String) async throws -> SignUpResult {
        struct Body: Encodable {
            let email: String
            let password: String
            let data: [String: String]
        }
        let body = Body(email: email, password: password, data: ["full_name": fullName])
        let data = try await authRequest(path: "signup", body: body)

        // Signup either returns a full session (auto-confirm) or just a user
        // record (email confirmation required).
        if let session = try? decoder.decode(AuthSession.self, from: data) {
            setSession(session)
            return .signedIn(session.user)
        }
        return .confirmationRequired
    }

    func signIn(email: String, password: String) async throws -> AuthUser {
        struct Body: Encodable { let email: String; let password: String }
        let data = try await authRequest(path: "token",
                                         query: [URLQueryItem(name: "grant_type", value: "password")],
                                         body: Body(email: email, password: password))
        let session = try decode(AuthSession.self, from: data)
        setSession(session)
        return session.user
    }

    func sendPasswordReset(email: String) async throws {
        struct Body: Encodable { let email: String }
        _ = try await authRequest(path: "recover", body: Body(email: email))
    }

    /// Sign-out scope. `.local` revokes only this device's refresh token;
    /// `.global` revokes every session for the user (sign out everywhere).
    enum SignOutScope: String { case local, global }

    func signOut(scope: SignOutScope = .global) async {
        if let token = session?.accessToken {
            // Best-effort server-side revocation; ignore failures.
            _ = try? await authRequest(path: "logout",
                                       query: [URLQueryItem(name: "scope", value: scope.rawValue)],
                                       body: EmptyBody(), accessToken: token, expectsBody: false)
        }
        setSession(nil)
    }

    /// Clears credentials without making a logout request. Used only after the
    /// server has permanently deleted the auth user, when there is no remaining
    /// session to revoke remotely.
    func clearDeletedAccountSession() {
        setSession(nil)
    }

    // MARK: - Authenticated user (GoTrue /user)

    /// Fetches the full authenticated user from `GET /auth/v1/user`, including
    /// the fields a persisted session omits (provider, verification timestamps,
    /// creation date, pending email change). Does not mutate the cached session.
    func fetchCurrentUser() async throws -> AuthUser {
        let data = try await performAuthenticated { token in
            try self.userRequest(method: "GET", body: Optional<EmptyBody>.none, accessToken: token)
        }
        return try decode(AuthUser.self, from: data)
    }

    /// Updates the authenticated user via `PUT /auth/v1/user`. Any combination of
    /// email, password and full-name metadata may be changed in one call. Returns
    /// the updated user and reconciles the cached session's user so the rest of
    /// the app sees the change immediately. For an email change requiring
    /// confirmation, the returned user keeps its old `email` and exposes the
    /// requested address as `new_email` (pending) until Supabase confirms it.
    @discardableResult
    func updateAuthUser(email: String? = nil,
                        password: String? = nil,
                        fullName: String? = nil) async throws -> AuthUser {
        struct Metadata: Encodable { let full_name: String }
        struct Body: Encodable {
            var email: String?
            var password: String?
            var data: Metadata?
        }
        var body = Body()
        body.email = email
        body.password = password
        if let fullName { body.data = Metadata(full_name: fullName) }

        let data = try await performAuthenticated { token in
            try self.userRequest(method: "PUT", body: body, accessToken: token)
        }
        let updated = try decode(AuthUser.self, from: data)

        // Reconcile the cached session's user (token is unchanged by an update).
        if var current = session {
            current.user = updated
            setSession(current)
        }
        return updated
    }

    /// Fetches the GoTrue user for an arbitrary access token (not the cached one).
    private func fetchUser(withAccessToken token: String) async throws -> AuthUser {
        let request = try userRequest(method: "GET", body: Optional<EmptyBody>.none, accessToken: token)
        let data = try await perform(request)
        return try decode(AuthUser.self, from: data)
    }

    /// Establishes a session from password-recovery deep-link tokens so the user
    /// can set a new password, then returns the recovered user. Tokens are never
    /// logged. Used by the recovery universal link.
    @discardableResult
    func applyRecoverySession(accessToken: String,
                              refreshToken: String,
                              expiresIn: TimeInterval? = nil) async throws -> AuthUser {
        let user = try await fetchUser(withAccessToken: accessToken)
        let session = AuthSession(accessToken: accessToken,
                                  refreshToken: refreshToken,
                                  expiresAt: Date().timeIntervalSince1970 + (expiresIn ?? 3600),
                                  user: user)
        setSession(session)
        return user
    }

    /// Verifies the supplied password by performing a password grant for the
    /// current email. On success the session is refreshed with the new tokens;
    /// on failure it throws (the caller surfaces "incorrect password"). Used to
    /// reauthenticate before a sensitive change such as a password update.
    func reauthenticate(email: String, password: String) async throws {
        struct Body: Encodable { let email: String; let password: String }
        let data = try await authRequest(path: "token",
                                         query: [URLQueryItem(name: "grant_type", value: "password")],
                                         body: Body(email: email, password: password))
        let session = try decode(AuthSession.self, from: data)
        setSession(session)
    }

    // MARK: - Token refresh (single-flight)

    /// Refreshes the session. Concurrent callers share one in-flight refresh
    /// rather than each replaying the same (rotating) refresh token.
    ///
    /// Throws `SupabaseError.notAuthenticated` when there is no session or the
    /// server definitively rejected the refresh token (4xx); in the latter case
    /// the session is cleared and `.sessionInvalidated` is broadcast. Transient
    /// failures (offline, 5xx) rethrow unchanged and keep the session.
    private func refreshToken() async throws {
        if let inFlight = refreshTask {
            try await inFlight.value
            return
        }
        guard session?.refreshToken != nil else { throw SupabaseError.notAuthenticated }

        let task = Task<Void, Error> {
            defer { refreshTask = nil }
            try await performRefresh()
        }
        refreshTask = task
        try await task.value
    }

    private func performRefresh() async throws {
        guard let refresh = session?.refreshToken else { throw SupabaseError.notAuthenticated }
        struct Body: Encodable { let refresh_token: String }
        do {
            let data = try await authRequest(path: "token",
                                             query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                             body: Body(refresh_token: refresh))
            let refreshed = try decode(AuthSession.self, from: data)
            setSession(refreshed)
        } catch SupabaseError.http(let status, _) where (400..<500).contains(status) {
            // Only invalidate if nobody else has already replaced the session
            // (e.g. a fresh sign-in landed while this refresh was in flight).
            if session?.refreshToken == refresh {
                setSession(nil)
                broadcast(.sessionInvalidated)
            }
            throw SupabaseError.notAuthenticated
        }
    }

    /// Returns a valid access token, refreshing first if it is about to expire.
    private func validAccessToken() async throws -> String {
        guard let session else { throw SupabaseError.notAuthenticated }
        if session.isExpiring {
            try await refreshToken()
        }
        guard let token = self.session?.accessToken else { throw SupabaseError.notAuthenticated }
        return token
    }

    // MARK: - PostgREST data API

    /// GET rows from a table. `query` carries `select`, filters, `order`, etc.
    func select<T: Decodable & Sendable>(_ table: String,
                                         query: [URLQueryItem],
                                         as type: T.Type) async throws -> T {
        let data = try await restRequest(method: "GET", table: table, query: query, body: Optional<EmptyBody>.none)
        return try decode(T.self, from: data)
    }

    /// GET rows as raw JSON bytes (a PostgREST array). Used by the data export,
    /// which serializes exactly the RLS-visible columns the `select` requests
    /// without binding them to a Swift model.
    func selectRaw(_ table: String, query: [URLQueryItem]) async throws -> Data {
        try await restRequest(method: "GET", table: table, query: query, body: Optional<EmptyBody>.none)
    }

    /// INSERT a row and return the created representation.
    func insert<Body: Encodable & Sendable, T: Decodable & Sendable>(_ table: String,
                                                                      values: Body,
                                                                      returning type: T.Type) async throws -> T {
        let data = try await restRequest(method: "POST", table: table, query: [], body: values,
                                         prefer: "return=representation")
        return try decode(T.self, from: data)
    }

    /// UPDATE rows matching `query` and return the updated representation.
    func update<Body: Encodable & Sendable, T: Decodable & Sendable>(_ table: String,
                                               values: Body,
                                               query: [URLQueryItem],
                                               returning type: T.Type) async throws -> T {
        let data = try await restRequest(method: "PATCH", table: table, query: query, body: values,
                                         prefer: "return=representation")
        return try decode(T.self, from: data)
    }

    /// DELETE rows matching `query`.
    func delete(_ table: String, query: [URLQueryItem]) async throws {
        _ = try await restRequest(method: "DELETE", table: table, query: query, body: Optional<EmptyBody>.none)
    }

    /// Calls a Postgres function (RPC) and decodes its JSON result.
    func rpc<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ function: String,
        params: Body,
        as type: T.Type
    ) async throws -> T {
        let data = try await restRequest(method: "POST", table: "rpc/\(function)", query: [], body: params)
        return try decode(T.self, from: data)
    }

    // MARK: - Edge Functions

    /// Invokes an authenticated Edge Function at `functions/v1/{name}`, attaching
    /// the anon apikey and a freshly-refreshed Bearer token. Decodes a structured
    /// success body, or throws `EdgeFunctionError` carrying the server's safe
    /// message and (for 429) cooldown. An expired session surfaces as
    /// `.sessionExpired`. Never logs JWTs or payloads.
    func invokeFunction<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ name: String, body: Body, as type: T.Type) async throws -> T {
        let token: String
        do {
            token = try await validAccessToken()
        } catch {
            throw EdgeFunctionError.sessionExpired
        }
        let data: Data
        do {
            data = try await performFunction(try functionRequest(name: name, body: body, accessToken: token))
        } catch EdgeFunctionError.sessionExpired {
            // A 401 with a token we believed valid: refresh once and retry once.
            let fresh: String
            do {
                fresh = try await tokenAfterForcedRefresh(rejected: token)
            } catch {
                throw EdgeFunctionError.sessionExpired
            }
            data = try await performFunction(try functionRequest(name: name, body: body, accessToken: fresh))
        }
        return try decode(T.self, from: data)
    }

    /// Invokes a public (pre-sign-in) Edge Function with only the anon apikey and
    /// no Bearer token — used by verification / password-reset before sign-in.
    func invokePublicFunction<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ name: String, body: Body, as type: T.Type) async throws -> T {
        let data = try await performFunction(try functionRequest(name: name, body: body, accessToken: nil))
        return try decode(T.self, from: data)
    }

    // MARK: - Request plumbing

    private struct EmptyBody: Encodable {}

    private func functionRequest<Body: Encodable>(name: String,
                                                  body: Body,
                                                  accessToken: String?) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("functions/v1/\(name)"))
        request.httpMethod = "POST"
        // AI-backed functions (e.g. guest import) can run for tens of seconds, well
        // past URLSession's 60s default — without this they fail as `.offline`.
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Like `perform`, but decodes the edge functions' structured error body so
    /// the UI can read the safe message + `retryAfterSeconds` cooldown.
    private func performFunction(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw EdgeFunctionError.sessionExpired }
            let parsed = try? decoder.decode(EdgeErrorBody.self, from: data)
            throw EdgeFunctionError.http(status: http.statusCode,
                                         message: parsed?.error ?? "",
                                         code: parsed?.code,
                                         retryAfterSeconds: parsed?.retryAfterSeconds)
        }
        return data
    }

    private func authRequest<Body: Encodable>(path: String,
                                              query: [URLQueryItem] = [],
                                              body: Body,
                                              accessToken: String? = nil,
                                              expectsBody: Bool = true) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent("auth/v1/\(path)"),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)
        return try await perform(request)
    }

    /// Builds a GET/PUT request for the GoTrue user endpoint (`auth/v1/user`).
    private func userRequest<Body: Encodable>(method: String,
                                              body: Body?,
                                              accessToken: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/v1/user"))
        request.httpMethod = method
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    private func restRequest<Body: Encodable>(method: String,
                                              table: String,
                                              query: [URLQueryItem],
                                              body: Body?,
                                              prefer: String? = nil) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent("rest/v1/\(table)"),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        let url = comps.url!
        // Encode once; the body doesn't change between the attempt and a retry.
        let encodedBody: Data? = try body.map { try encoder.encode($0) }

        return try await performAuthenticated { token in
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(self.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
            if let encodedBody {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = encodedBody
            }
            return request
        }
    }

    /// Performs a request that carries the cached session's bearer token. On a
    /// 401 the token is refreshed once (single-flight) and the request retried
    /// exactly once; a second 401 propagates. If the refresh is rejected, the
    /// session is cleared, `.sessionInvalidated` is broadcast and
    /// `SupabaseError.notAuthenticated` is thrown.
    private func performAuthenticated(_ build: (String) throws -> URLRequest) async throws -> Data {
        let token = try await validAccessToken()
        do {
            return try await perform(try build(token))
        } catch SupabaseError.http(let status, _) where status == 401 {
            let fresh = try await tokenAfterForcedRefresh(rejected: token)
            return try await perform(try build(fresh))
        }
    }

    /// After a 401 with `rejected`: if another caller already rotated the
    /// session, reuse the new token; otherwise force one refresh. Throws
    /// `notAuthenticated` when the refresh is definitively rejected.
    private func tokenAfterForcedRefresh(rejected: String) async throws -> String {
        if let current = session?.accessToken, current != rejected {
            return current
        }
        try await refreshToken()
        guard let fresh = session?.accessToken else { throw SupabaseError.notAuthenticated }
        return fresh
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = try? decoder.decode(SupabaseErrorBody.self, from: data)
            let message = parsed?.bestMessage
                ?? parsed?.errorCode
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw SupabaseError.http(status: http.statusCode, message: message)
        }
        return data
    }

    /// Maps a `URLSession` failure to the client's error vocabulary: common
    /// connectivity failures become `.offline` so the UI can surface an offline
    /// state; a cancelled load (a `.task` torn down by navigation) becomes
    /// `CancellationError` so callers can ignore it instead of alerting.
    nonisolated static func mapTransportError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CancellationError()
            case .notConnectedToInternet, .networkConnectionLost,
                 .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .dataNotAllowed, .internationalRoamingOff:
                return SupabaseError.offline
            default:
                break
            }
        }
        return SupabaseError.transport(error.localizedDescription)
    }

    // MARK: - Coders

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SupabaseError.decoding(error.localizedDescription)
        }
    }
}
