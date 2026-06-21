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
        if isOffline(error) {
            return "You're offline. Your changes weren't saved — reconnect and try again."
        }

        if let supabase = error as? SupabaseError {
            switch supabase {
            case .notAuthenticated:
                return "You've been signed out. Please sign in again."
            case .http(let status, let message):
                return httpMessage(status: status, raw: message)
            case .notConfigured(let msg):
                return msg
            case .decoding:
                return "Something went wrong reading the server's response. Please try again."
            case .transport:
                return "We couldn't reach the server. Please try again in a moment."
            case .offline:
                return "You're offline. Your changes weren't saved — reconnect and try again."
            }
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

    /// Maps an HTTP status to friendly guidance, ignoring the raw server string
    /// for the common cases so PostgREST jargon never reaches users.
    private static func httpMessage(status: Int, raw: String) -> String {
        switch status {
        case 401, 403:
            return "You don't have permission to do that, or your session expired. Try signing in again."
        case 404:
            return "We couldn't find that — it may have been removed."
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
