//
//  AuthSession.swift
//  A Seat Awaits
//
//  Models for the Supabase GoTrue auth responses we persist and use.
//

import Foundation

/// The authenticated user as returned by Supabase GoTrue.
nonisolated struct AuthUser: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let email: String?
    let userMetadata: UserMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case userMetadata = "user_metadata"
    }

    nonisolated struct UserMetadata: Codable, Equatable, Sendable {
        let fullName: String?

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    var displayName: String {
        userMetadata?.fullName ?? email ?? "Planner"
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
