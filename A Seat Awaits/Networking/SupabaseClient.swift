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

import Foundation

actor SupabaseClient {

    private let baseURL: URL
    private let anonKey: String
    private let urlSession: URLSession
    private let keychain: KeychainStore

    /// In-memory cache of the current session (also persisted in the Keychain).
    private var session: AuthSession?

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

    /// Restores a persisted session, refreshing the token if needed. Returns the
    /// user when a valid session exists, otherwise nil.
    func restoreSession() async -> AuthUser? {
        guard let existing = session else { return nil }
        if existing.isExpiring {
            do {
                try await refreshToken()
            } catch {
                setSession(nil)
                return nil
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

    /// Exchanges an Apple identity token for a Supabase session. Requires the
    /// Apple provider to be enabled on the Supabase project and the "Sign in
    /// with Apple" capability on the app target.
    func signInWithApple(idToken: String, nonce: String, fullName: String?) async throws -> AuthUser {
        struct Body: Encodable {
            let provider = "apple"
            let id_token: String
            let nonce: String
        }
        let data = try await authRequest(path: "token",
                                         query: [URLQueryItem(name: "grant_type", value: "id_token")],
                                         body: Body(id_token: idToken, nonce: nonce))
        let session = try decode(AuthSession.self, from: data)
        setSession(session)
        return session.user
    }

    func sendPasswordReset(email: String) async throws {
        struct Body: Encodable { let email: String }
        _ = try await authRequest(path: "recover", body: Body(email: email))
    }

    func signOut() async {
        if let token = session?.accessToken {
            // Best-effort server-side revocation; ignore failures.
            _ = try? await authRequest(path: "logout", body: EmptyBody(), accessToken: token, expectsBody: false)
        }
        setSession(nil)
    }

    private func refreshToken() async throws {
        guard let refresh = session?.refreshToken else { throw SupabaseError.notAuthenticated }
        struct Body: Encodable { let refresh_token: String }
        let data = try await authRequest(path: "token",
                                         query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                         body: Body(refresh_token: refresh))
        let refreshed = try decode(AuthSession.self, from: data)
        setSession(refreshed)
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

    // MARK: - Request plumbing

    private struct EmptyBody: Encodable {}

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

    private func restRequest<Body: Encodable>(method: String,
                                              table: String,
                                              query: [URLQueryItem],
                                              body: Body?,
                                              prefer: String? = nil) async throws -> Data {
        let token = try await validAccessToken()
        var comps = URLComponents(url: baseURL.appendingPathComponent("rest/v1/\(table)"),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = method
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SupabaseError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(SupabaseErrorBody.self, from: data))?.bestMessage
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw SupabaseError.http(status: http.statusCode, message: message)
        }
        return data
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
