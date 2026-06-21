//
//  EmailService.swift
//  A Seat Awaits
//
//  Thin, injectable wrapper over the Supabase Edge Function email layer. Every
//  email the app can trigger goes through a trusted Edge Function — the app
//  never calls Resend and ships no server credentials (see [[ios-architecture]]).
//

import Foundation

/// The subset of `SupabaseClient` the email service needs, abstracted so tests
/// can inject a mock invoker without a network stack.
protocol EmailFunctionInvoking: Sendable {
    func invokeFunction<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ name: String, body: Body, as type: T.Type) async throws -> T
    func invokePublicFunction<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ name: String, body: Body, as type: T.Type) async throws -> T
}

extension SupabaseClient: EmailFunctionInvoking {}

/// Calls the email Edge Functions and returns their structured responses.
/// Stateless and `Sendable`, so it can be created on demand from any actor.
struct EmailService: Sendable {

    private let invoker: any EmailFunctionInvoking

    init(invoker: any EmailFunctionInvoking) {
        self.invoker = invoker
    }

    // MARK: - Public (pre-sign-in) flows

    /// Sends (or resends) the verification email. The response is deliberately
    /// generic and includes the cooldown the UI must honor.
    func sendVerificationEmail(to email: String) async throws -> SendEmailResponse {
        try await invoker.invokePublicFunction(
            "send-verification-email",
            body: SendEmailRequest(email: email),
            as: SendEmailResponse.self)
    }

    /// Requests a password-reset email. Always returns a generic success; never
    /// reveals whether an account exists.
    func sendPasswordReset(to email: String) async throws -> SendEmailResponse {
        try await invoker.invokePublicFunction(
            "send-password-reset-email",
            body: SendEmailRequest(email: email),
            as: SendEmailResponse.self)
    }

    // MARK: - Authenticated flows

    /// Invites a collaborator to an event. Only the four fields below are sent;
    /// everything else is decided server-side after authorization.
    func sendInvitation(eventId: String,
                        inviteeName: String,
                        inviteeEmail: String,
                        role: CollaboratorRole) async throws -> SendInvitationResponse {
        try await invoker.invokeFunction(
            "send-event-invitation",
            body: SendInvitationRequest(eventId: eventId,
                                        inviteeName: inviteeName,
                                        inviteeEmail: inviteeEmail,
                                        role: role.dbValue),
            as: SendInvitationResponse.self)
    }

    /// Re-sends a pending invitation. The server enforces the cooldown + limits.
    func resendInvitation(invitationId: String) async throws -> SendInvitationResponse {
        try await invoker.invokeFunction(
            "resend-event-invitation",
            body: ResendInvitationRequest(invitationId: invitationId),
            as: SendInvitationResponse.self)
    }
}
