//
//  GuestImportService.swift
//  A Seat Awaits
//
//  Thin, injectable wrapper over the `ai-import-guests` Supabase Edge Function.
//  Mirrors `EmailService`: the app never holds the AI key — it invokes an
//  authenticated, rate-limited, plan-gated Edge Function that owns the model and
//  prompt (see [[ios-architecture]]). On failure the caller falls back to the
//  on-device `GuestImportParser`.
//

import Foundation

/// The subset of `SupabaseClient` the import service needs, abstracted so tests
/// can inject a mock invoker without a network stack.
protocol GuestImportFunctionInvoking: Sendable {
    func invokeFunction<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ name: String, body: Body, as type: T.Type) async throws -> T
}

extension SupabaseClient: GuestImportFunctionInvoking {}

/// Calls the AI guest-import Edge Function and returns its structured preview.
/// Stateless and `Sendable`, so it can be created on demand from any actor.
struct GuestImportService: Sendable {

    private let invoker: any GuestImportFunctionInvoking

    init(invoker: any GuestImportFunctionInvoking) {
        self.invoker = invoker
    }

    /// Sends a pasted/CSV list or an Excel file for the event and returns the
    /// AI-extracted guests. Throws `EdgeFunctionError` (plan/rate-limit/AI
    /// failure) or a transport error — callers fall back to the local parser.
    func aiImport(eventId: String, input: GuestImportInput) async throws -> AiGuestImportResponse {
        let body: AiGuestImportRequest
        switch input {
        case .text(let text):
            body = AiGuestImportRequest(eventId: eventId, text: text, fileBase64: nil, filename: nil)
        case .file(let data, let name):
            body = AiGuestImportRequest(eventId: eventId, text: nil,
                                        fileBase64: data.base64EncodedString(), filename: name)
        }
        return try await invoker.invokeFunction("ai-import-guests", body: body, as: AiGuestImportResponse.self)
    }
}
