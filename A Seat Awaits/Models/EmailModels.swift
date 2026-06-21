//
//  EmailModels.swift
//  A Seat Awaits
//
//  Request/response DTOs and the typed error for the Supabase Edge Function
//  email layer. The iOS app NEVER talks to Resend; it invokes authenticated or
//  rate-limited Edge Functions (see [[ios-architecture]]). No Resend keys,
//  webhook secrets, or service-role keys exist anywhere in the app — only the
//  public anon key, which already ships for normal Supabase access.
//

import Foundation

// MARK: - Edge function error

/// The structured error body returned by every edge function on failure:
/// `{ ok:false, error, code, retryAfterSeconds, correlationId }`.
nonisolated struct EdgeErrorBody: Decodable, Sendable {
    let ok: Bool?
    let error: String?
    let code: String?
    let retryAfterSeconds: Int?
    let correlationId: String?
}

/// Error thrown by `SupabaseClient.invokeFunction` / `invokePublicFunction`.
enum EdgeFunctionError: LocalizedError, Equatable {
    /// A structured non-2xx response from the function.
    case http(status: Int, message: String, code: String?, retryAfterSeconds: Int?)
    /// The session expired and the call required authentication.
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .http(_, let message, _, _):
            return message.isEmpty ? "The request failed. Please try again." : message
        case .sessionExpired:
            return "Your session has expired. Please sign in again."
        }
    }

    /// Server-provided cooldown (HTTP 429), if any. The UI honors this.
    var retryAfterSeconds: Int? {
        if case .http(_, _, _, let retry) = self { return retry }
        return nil
    }

    var code: String? {
        if case .http(_, _, let code, _) = self { return code }
        return nil
    }
}

// MARK: - Request DTOs (the ONLY fields iOS may supply)

/// Body for `send-verification-email` / `send-password-reset-email`.
nonisolated struct SendEmailRequest: Encodable, Sendable {
    let email: String
}

/// Body for `send-event-invitation`. Inviter identity, event details, token,
/// URL, subject and HTML are all decided server-side — never sent here.
nonisolated struct SendInvitationRequest: Encodable, Sendable {
    let eventId: String
    let inviteeName: String
    let inviteeEmail: String
    let role: String // "viewer" | "editor"
}

/// Body for `resend-event-invitation`.
nonisolated struct ResendInvitationRequest: Encodable, Sendable {
    let invitationId: String
}

// MARK: - Response DTOs

/// Generic verification/reset response. Deliberately identical for existing and
/// unknown addresses — it never reveals whether an account exists.
nonisolated struct SendEmailResponse: Decodable, Sendable {
    let ok: Bool
    let sent: Bool
    let retryAfterSeconds: Int?
}

/// Delivery status reported for an invitation. Mirrors the server vocabulary.
nonisolated enum EmailDeliveryStatus: String, Decodable, Sendable, Equatable, CaseIterable {
    case pending
    case sent
    case delivered
    case delayed
    case bounced
    case complained
    case failed

    /// Lenient mapping (unknown -> pending).
    init(raw: String?) {
        self = EmailDeliveryStatus(rawValue: (raw ?? "").lowercased()) ?? .pending
    }

    /// Short, owner-facing label (never a raw provider error).
    var label: String {
        switch self {
        case .pending: return "Pending"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .delayed: return "Delivery delayed"
        case .bounced: return "Bounced"
        case .complained: return "Marked as spam"
        case .failed: return "Delivery failed"
        }
    }

    /// True when delivery failed or the address can't receive mail.
    var isFailure: Bool { self == .failed || self == .bounced || self == .complained }

    /// Whether a "Resend" affordance is appropriate for this state.
    var canResend: Bool {
        switch self {
        case .failed, .delayed, .sent, .pending: return true
        case .delivered, .bounced, .complained: return false
        }
    }
}

/// Safe invitation summary returned by send/resend.
nonisolated struct InvitationSummary: Decodable, Sendable, Equatable {
    let id: String
    let inviteeEmail: String
    let role: String
    let status: String
    let emailStatus: String
    let inviteUrl: String?

    var deliveryStatus: EmailDeliveryStatus { EmailDeliveryStatus(raw: emailStatus) }
}

nonisolated struct SendInvitationResponse: Decodable, Sendable {
    let ok: Bool
    let emailed: Bool
    let invitation: InvitationSummary
}

/// One row from the `invitation_delivery_status(p_event_id)` RPC — the
/// owner-scoped, safe status read (no raw errors, no ledger access).
nonisolated struct InvitationDeliveryStatusRow: Decodable, Sendable, Equatable {
    let id: String
    let inviteeEmail: String?
    let emailStatus: String?
    let emailSendAttempts: Int?
    let emailLastSentAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case inviteeEmail = "invitee_email"
        case emailStatus = "email_status"
        case emailSendAttempts = "email_send_attempts"
        case emailLastSentAt = "email_last_sent_at"
    }

    var deliveryStatus: EmailDeliveryStatus { EmailDeliveryStatus(raw: emailStatus) }
}
