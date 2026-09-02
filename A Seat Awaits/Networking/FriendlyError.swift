//
//  FriendlyError.swift
//  A Seat Awaits
//
//  One place that turns any thrown error into calm, user-presentable copy, so no
//  raw `localizedDescription` or PostgREST string ever reaches the UI (design
//  audit F10). Stores route every caught error through `FriendlyError.message`.
//

import Foundation

enum FriendlyError {

    /// A friendly, human sentence for any error. Connectivity problems become an
    /// offline message; known auth/permission failures get specific guidance;
    /// everything else falls back to a calm generic line (never a stack-y string).
    static func message(for error: Error) -> String {
        // A cancelled request (navigation tore down a `.task`) is not a
        // failure. Callers should skip it via `isCancellation`; this neutral
        // line is only a backstop so no raw description ever shows.
        if isCancellation(error) {
            return "That request was canceled."
        }

        if isOffline(error) {
            return "You're offline. Your changes weren't saved. Reconnect and try again."
        }

        if let supabase = error as? SupabaseError {
            switch supabase {
            case .notAuthenticated:
                return "You've been signed out. Please sign in again."
            case .http(let status, let message):
                if let auth = authMessage(status: status, message: message) {
                    return auth
                }
                return httpMessage(status: status, raw: message)
            case .notConfigured(let msg):
                return msg
            case .decoding:
                return "Something went wrong reading the server's response. Please try again."
            case .transport:
                return "We couldn't reach the server. Please try again in a moment."
            case .offline:
                return "You're offline. Your changes weren't saved. Reconnect and try again."
            }
        }

        // Edge functions return curated, user-presentable messages (plan
        // gates, rate limits) — surface them instead of the generic line.
        if let edge = error as? EdgeFunctionError {
            return edge.errorDescription ?? "Something went wrong. Please try again."
        }

        // The local guest-cap gate writes its own upgrade copy.
        if let cap = error as? GuestCapReachedError {
            return cap.message
        }

        // Any non-Supabase error (file I/O, etc.) gets a calm generic line.
        return "Something went wrong. Please try again."
    }

    /// Whether an error represents a connectivity failure, so callers can show an
    /// offline banner instead of a one-off alert.
    static func isOffline(_ error: Error) -> Bool {
        if case SupabaseError.offline = error { return true }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotConnectToHost, .cannotFindHost, .dataNotAllowed,
                 .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Whether an error is a task/request cancellation (a SwiftUI `.task`
    /// cancelled by navigation, or `URLError.cancelled`). Stores must never
    /// surface these to the user.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: - GoTrue auth failures

    /// Specific guidance for the GoTrue failures a person can actually act on.
    /// Matches on the server's message or `error_code` (both shapes GoTrue has
    /// used) rather than the bare status, since 400/422 are shared by several
    /// unrelated validation failures. Returns nil when not an auth case.
    static func authMessage(status: Int, message: String) -> String? {
        guard (400..<500).contains(status) else { return nil }
        let m = message.lowercased()

        if m.contains("invalid login credentials")
            || m.contains("invalid_credentials")
            || m.contains("invalid email or password") {
            return "That email or password doesn't match. Try again, or reset your password."
        }
        if m.contains("already registered")
            || m.contains("already exists")
            || m.contains("user_already_exists")
            || m.contains("email_exists") {
            return "An account with this email already exists. Sign in instead."
        }
        if m.contains("email not confirmed") || m.contains("email_not_confirmed") {
            return "Please verify your email first. Check your inbox for the confirmation link."
        }
        return nil
    }

    /// Maps an HTTP status to friendly guidance, ignoring the raw server string
    /// for the common cases so PostgREST jargon never reaches users.
    private static func httpMessage(status: Int, raw: String) -> String {
        switch status {
        case 401, 403:
            return "You don't have permission to do that, or your session expired. Try signing in again."
        case 404:
            return "We couldn't find that. It may have been removed."
        case 409:
            return "That conflicts with existing data. Refresh and try again."
        case 408, 429:
            return "The server is busy. Please try again in a moment."
        case 500...599:
            return "The server had a problem. Please try again shortly."
        default:
            // Last resort: a trimmed server message only if it looks human, else generic.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count < 140, !trimmed.contains("{"), !trimmed.contains("\"") {
                return trimmed
            }
            return "Something went wrong. Please try again."
        }
    }
}
