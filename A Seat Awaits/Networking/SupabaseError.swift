//
//  SupabaseError.swift
//  A Seat Awaits
//

import Foundation

/// Errors surfaced by the Supabase client, with user-presentable messages.
enum SupabaseError: LocalizedError {
    case notConfigured(String)
    case notAuthenticated
    case http(status: Int, message: String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): return msg
        case .notAuthenticated: return "You are signed out. Please sign in again."
        case .http(let status, let message):
            return message.isEmpty ? "Request failed (HTTP \(status))." : message
        case .decoding(let msg): return "Couldn't read the server response. \(msg)"
        case .transport(let msg): return msg
        }
    }
}

/// Shape of a Supabase/PostgREST/GoTrue error body, used to extract a readable message.
struct SupabaseErrorBody: Decodable {
    let message: String?
    let error: String?
    let errorDescription: String?
    let msg: String?
    let hint: String?

    enum CodingKeys: String, CodingKey {
        case message, error, hint, msg
        case errorDescription = "error_description"
    }

    var bestMessage: String? {
        message ?? errorDescription ?? error ?? msg ?? hint
    }
}
