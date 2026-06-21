//
//  DeepLinkRouter.swift
//  A Seat Awaits
//
//  Parses incoming universal links (https://aseatawaits.com/…) and the custom
//  `aseatawaits://` scheme into typed deep links: collaborator invitations,
//  password recovery, and email confirmation. Token/recovery values are parsed
//  but never logged. See [[ios-architecture]].
//
//  Configuration required outside the app (documented in DEPLOYMENT.md):
//   - Associated Domains entitlement: `applinks:aseatawaits.com`
//   - apple-app-site-association hosted at https://aseatawaits.com/.well-known/
//   - Supabase Auth redirect allowlist must include the /auth/confirm and
//     /auth/reset URLs used by the edge functions.
//

import Foundation

nonisolated enum DeepLink: Equatable {
    /// `/invite/{token}` — open a collaboration invitation.
    case inviteToken(String)
    /// `/auth/reset` recovery link carrying session tokens.
    case recovery(accessToken: String, refreshToken: String)
    /// `/auth/confirm` magic/confirmation link carrying session tokens.
    case emailConfirmed(accessToken: String, refreshToken: String)
    /// Anything we don't handle (let the OS/other handlers deal with it).
    case unhandled
}

nonisolated enum DeepLinkRouter {

    /// Hosts we accept universal links from.
    static let approvedHosts: Set<String> = ["aseatawaits.com", "www.aseatawaits.com"]
    static let customScheme = "aseatawaits"

    static func parse(_ url: URL) -> DeepLink {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .unhandled
        }

        // Normalize the path across universal links and the custom scheme. For
        // `aseatawaits://invite/{token}` the host is "invite" and the token is in
        // the path; fold the host into the path segments so both shapes match.
        var segments = comps.path.split(separator: "/").map(String.init)
        let isCustomScheme = (comps.scheme == customScheme)
        if isCustomScheme, let host = comps.host, !host.isEmpty {
            segments.insert(host, at: 0)
        } else if !isCustomScheme {
            // Universal link: enforce the approved host.
            guard let host = comps.host?.lowercased(), approvedHosts.contains(host) else {
                return .unhandled
            }
        }

        let params = mergedParameters(comps)

        // /invite/{token}
        if let idx = segments.firstIndex(of: "invite"), idx + 1 < segments.count {
            let token = segments[idx + 1].trimmingCharacters(in: .whitespaces)
            if !token.isEmpty { return .inviteToken(token) }
        }

        let type = params["type"]?.lowercased()
        let accessToken = params["access_token"]
        let refreshToken = params["refresh_token"]

        let isReset = segments.contains("reset") || type == "recovery"
        let isConfirm = segments.contains("confirm") || type == "magiclink" || type == "signup" || type == "email"

        if isReset, let at = accessToken, let rt = refreshToken, !at.isEmpty, !rt.isEmpty {
            return .recovery(accessToken: at, refreshToken: rt)
        }
        if isConfirm, let at = accessToken, let rt = refreshToken, !at.isEmpty, !rt.isEmpty {
            return .emailConfirmed(accessToken: at, refreshToken: rt)
        }

        return .unhandled
    }

    /// Supabase puts session tokens in the URL fragment; `URLComponents` doesn't
    /// parse the fragment into query items, so merge both sources.
    private static func mergedParameters(_ comps: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            if let value = item.value { result[item.name] = value }
        }
        if let fragment = comps.fragment {
            for pair in fragment.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                let key = kv[0]
                let value = kv[1].removingPercentEncoding ?? kv[1]
                result[key] = value
            }
        }
        return result
    }
}
