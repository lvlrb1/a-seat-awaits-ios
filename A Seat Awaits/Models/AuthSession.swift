//
//  AuthSession.swift
//  A Seat Awaits
//
//  Models for the Supabase GoTrue auth responses we persist and use.
//

import Foundation

/// The authenticated user as returned by Supabase GoTrue.
///
/// Only `id`, `email` and `user_metadata` are guaranteed to be present on a
/// persisted session (the trimmed object stored in the Keychain). The richer
/// fields — verification timestamps, the auth provider, the account creation
/// date and a pending email change — are only populated by a fresh
/// `GET /auth/v1/user` fetch, so they are all optional and decode leniently.
nonisolated struct AuthUser: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let email: String?
    let userMetadata: UserMetadata?
    var appMetadata: AppMetadata?
    /// Set once the address is confirmed. Nil while a sign-up is unverified.
    var emailConfirmedAt: String?
    var confirmedAt: String?
    /// A requested-but-not-yet-confirmed email address (email change in flight).
    var newEmail: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case userMetadata = "user_metadata"
        case appMetadata = "app_metadata"
        case emailConfirmedAt = "email_confirmed_at"
        case confirmedAt = "confirmed_at"
        case newEmail = "new_email"
        case createdAt = "created_at"
    }

    nonisolated struct UserMetadata: Codable, Equatable, Sendable {
        let fullName: String?

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    /// GoTrue's `app_metadata` carries the sign-in provider(s). Server-owned, so
    /// it's a trustworthy signal for "Signed in with Apple" vs. password.
    nonisolated struct AppMetadata: Codable, Equatable, Sendable {
        let provider: String?
        let providers: [String]?
    }

    var displayName: String {
        userMetadata?.fullName ?? email ?? "Planner"
    }

    /// The primary authentication provider, e.g. `email` or `apple`.
    var primaryProvider: String { appMetadata?.provider ?? "email" }

    /// True for email/password accounts (the only provider that has a password
    /// to change). Apple accounts have no app-managed password.
    var isPasswordAccount: Bool { primaryProvider == "email" }

    /// True when the current email address has been confirmed.
    var isEmailVerified: Bool {
        (emailConfirmedAt?.nilIfBlank ?? confirmedAt?.nilIfBlank) != nil
    }

    /// A friendly label for the sign-in provider.
    var providerLabel: String {
        switch primaryProvider {
        case "apple": return "Apple"
        case "google": return "Google"
        case "email": return "Email & password"
        default: return primaryProvider.capitalized
        }
    }

    /// A pending email change awaiting confirmation, if any.
    var pendingEmail: String? { newEmail?.nilIfBlank }

    /// The account creation date, parsed from the ISO-8601 `created_at`.
    var createdDate: Date? { createdAt.flatMap(AuthUser.parseISO) }

    /// Parses a Supabase ISO-8601 timestamp (with or without fractional seconds).
    static func parseISO(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// A persisted auth session (tokens + user). Stored in the Keychain.
nonisolated struct AuthSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    /// Absolute expiry as Unix epoch seconds.
    var expiresAt: TimeInterval
    var user: AuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
        case user
    }

    init(accessToken: String, refreshToken: String, expiresAt: TimeInterval, user: AuthUser) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.user = user
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        user = try c.decode(AuthUser.self, forKey: .user)
        // GoTrue returns `expires_at` (epoch) on login; on refresh it may only
        // return `expires_in` (seconds from now). Support both.
        if let absolute = try c.decodeIfPresent(TimeInterval.self, forKey: .expiresAt) {
            expiresAt = absolute
        } else if let relative = try c.decodeIfPresent(TimeInterval.self, forKey: .expiresIn) {
            expiresAt = Date().timeIntervalSince1970 + relative
        } else {
            expiresAt = Date().timeIntervalSince1970 + 3600
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encode(refreshToken, forKey: .refreshToken)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(user, forKey: .user)
    }

    /// True when the access token is expired or within 60s of expiring.
    var isExpiring: Bool {
        Date().timeIntervalSince1970 >= (expiresAt - 60)
    }
}
