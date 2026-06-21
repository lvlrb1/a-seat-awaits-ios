//
//  EmailSystemTests.swift
//  A Seat AwaitsTests
//
//  Tests for the native email layer: edge-function request routing/encoding,
//  authenticated-vs-public calls, structured error decoding + retry-after,
//  delivery-status decoding, deep-link parsing, and a guard that no Resend /
//  server credentials are shipped in the app bundle.
//

import Foundation
import Testing
@testable import A_Seat_Awaits

// MARK: - Mock invoker

/// Records every edge-function call and returns canned JSON, so the service
/// layer can be exercised without a network stack.
final class MockInvoker: EmailFunctionInvoking, @unchecked Sendable {
    struct Call: Sendable { let name: String; let authenticated: Bool; let body: Data }
    private(set) var calls: [Call] = []
    var responses: [String: Data] = [:]
    var errorToThrow: Error?

    func invokeFunction<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ name: String, body: Body, as type: T.Type) async throws -> T {
        try record(name, authenticated: true, body: body, as: type)
    }
    func invokePublicFunction<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ name: String, body: Body, as type: T.Type) async throws -> T {
        try record(name, authenticated: false, body: body, as: type)
    }
    private func record<Body: Encodable, T: Decodable>(
        _ name: String, authenticated: Bool, body: Body, as type: T.Type) throws -> T {
        if let errorToThrow { throw errorToThrow }
        calls.append(Call(name: name, authenticated: authenticated, body: try JSONEncoder().encode(body)))
        let data = responses[name] ?? Data("{}".utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }
    var last: Call? { calls.last }
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

// MARK: - Service routing + encoding

@Suite("EmailService routing")
struct EmailServiceRoutingTests {

    @Test func verificationIsPublicAndEncodesEmail() async throws {
        let mock = MockInvoker()
        mock.responses["send-verification-email"] = json(["ok": true, "sent": true, "retryAfterSeconds": 60])
        let service = EmailService(invoker: mock)

        let response = try await service.sendVerificationEmail(to: "Brooke@Example.com")
        #expect(response.sent == true)
        #expect(response.retryAfterSeconds == 60)

        let call = try #require(mock.last)
        #expect(call.name == "send-verification-email")
        #expect(call.authenticated == false)        // pre-sign-in: no JWT
        let body = try JSONSerialization.jsonObject(with: call.body) as? [String: Any]
        #expect(body?["email"] as? String == "Brooke@Example.com")
    }

    @Test func passwordResetIsPublic() async throws {
        let mock = MockInvoker()
        mock.responses["send-password-reset-email"] = json(["ok": true, "sent": true, "retryAfterSeconds": 60])
        let service = EmailService(invoker: mock)

        _ = try await service.sendPasswordReset(to: "a@b.com")
        #expect(mock.last?.name == "send-password-reset-email")
        #expect(mock.last?.authenticated == false)
    }

    @Test func invitationIsAuthenticatedAndEncodesEditorRole() async throws {
        let mock = MockInvoker()
        mock.responses["send-event-invitation"] = json([
            "ok": true, "emailed": true,
            "invitation": ["id": "i1", "inviteeEmail": "g@h.com", "role": "editor",
                           "status": "pending", "emailStatus": "sent",
                           "inviteUrl": "https://aseatawaits.com/invite/tok"],
        ])
        let service = EmailService(invoker: mock)

        let response = try await service.sendInvitation(
            eventId: "e1", inviteeName: "Guest", inviteeEmail: "g@h.com", role: .editor)
        #expect(response.invitation.deliveryStatus == .sent)

        let call = try #require(mock.last)
        #expect(call.name == "send-event-invitation")
        #expect(call.authenticated == true)         // requires JWT
        let body = try JSONSerialization.jsonObject(with: call.body) as? [String: Any]
        #expect(body?["eventId"] as? String == "e1")
        #expect(body?["role"] as? String == "editor")
        #expect(body?["inviteeEmail"] as? String == "g@h.com")
        // The body must NOT contain trust-sensitive fields.
        #expect(body?["inviterName"] == nil)
        #expect(body?["token"] == nil)
        #expect(body?["subject"] == nil)
    }

    @Test func resendIsAuthenticated() async throws {
        let mock = MockInvoker()
        mock.responses["resend-event-invitation"] = json([
            "ok": true, "emailed": true,
            "invitation": ["id": "i1", "inviteeEmail": "g@h.com", "role": "viewer",
                           "status": "pending", "emailStatus": "sent"],
        ])
        let service = EmailService(invoker: mock)
        _ = try await service.resendInvitation(invitationId: "i1")
        #expect(mock.last?.name == "resend-event-invitation")
        #expect(mock.last?.authenticated == true)
    }
}

// MARK: - Decoding

@Suite("Email decoding")
struct EmailDecodingTests {

    @Test func deliveryStatusMappingAndResend() {
        #expect(EmailDeliveryStatus(raw: "delivered") == .delivered)
        #expect(EmailDeliveryStatus(raw: "BOUNCED") == .bounced)
        #expect(EmailDeliveryStatus(raw: "garbage") == .pending)   // lenient
        #expect(EmailDeliveryStatus.delivered.canResend == false)  // already delivered
        #expect(EmailDeliveryStatus.failed.canResend == true)
        #expect(EmailDeliveryStatus.bounced.canResend == false)
        #expect(EmailDeliveryStatus.bounced.isFailure == true)
    }

    @Test func edgeErrorBodyDecodes() throws {
        let data = json(["ok": false, "error": "Too many requests.", "code": "rate_limited",
                         "retryAfterSeconds": 42, "correlationId": "abc123"])
        let body = try JSONDecoder().decode(EdgeErrorBody.self, from: data)
        #expect(body.error == "Too many requests.")
        #expect(body.retryAfterSeconds == 42)
        #expect(body.code == "rate_limited")
    }

    @Test func edgeFunctionErrorExposesRetryAfter() {
        let err = EdgeFunctionError.http(status: 429, message: "Slow down.", code: "rate_limited", retryAfterSeconds: 30)
        #expect(err.retryAfterSeconds == 30)
        #expect(err.errorDescription == "Slow down.")
    }

    @Test func invitationStatusRowDecodesSnakeCase() throws {
        let data = json(["id": "i1", "invitee_email": "x@y.com", "email_status": "delayed",
                         "email_send_attempts": 2, "email_last_sent_at": "2026-06-21T00:00:00Z"])
        let row = try JSONDecoder().decode(InvitationDeliveryStatusRow.self, from: data)
        #expect(row.deliveryStatus == .delayed)
        #expect(row.emailSendAttempts == 2)
    }
}

// MARK: - Deep link parsing

@Suite("DeepLinkRouter")
struct DeepLinkRouterTests {

    @Test func parsesUniversalInvite() {
        let link = DeepLinkRouter.parse(URL(string: "https://aseatawaits.com/invite/abc-123")!)
        #expect(link == .inviteToken("abc-123"))
    }

    @Test func parsesCustomSchemeInvite() {
        let link = DeepLinkRouter.parse(URL(string: "aseatawaits://invite/tok9")!)
        #expect(link == .inviteToken("tok9"))
    }

    @Test func rejectsOffHostInvite() {
        let link = DeepLinkRouter.parse(URL(string: "https://evil.example.com/invite/abc")!)
        #expect(link == .unhandled)
    }

    @Test func parsesRecoveryWithFragmentTokens() {
        let url = URL(string: "https://aseatawaits.com/auth/reset#access_token=AT&refresh_token=RT&type=recovery")!
        #expect(DeepLinkRouter.parse(url) == .recovery(accessToken: "AT", refreshToken: "RT"))
    }

    @Test func parsesConfirmWithTokens() {
        let url = URL(string: "https://aseatawaits.com/auth/confirm#access_token=AT&refresh_token=RT&type=magiclink")!
        #expect(DeepLinkRouter.parse(url) == .emailConfirmed(accessToken: "AT", refreshToken: "RT"))
    }
}

// MARK: - Bundle hygiene

@Suite("No server credentials in bundle")
struct BundleSecurityTests {

    @Test func infoPlistHasNoResendOrServerSecrets() {
        let info = Bundle.main.infoDictionary ?? [:]
        for (key, value) in info {
            let k = key.lowercased(), v = String(describing: value).lowercased()
            #expect(!k.contains("resend"))
            #expect(!k.contains("service_role"))
            #expect(!v.contains("resend.com"))
            #expect(!v.contains("re_"))  // Resend API keys start with "re_"
        }
    }

    @Test func bundledSecretsOnlyHoldPublicConfig() {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return } // No bundled Secrets in the test host — nothing to check.
        for key in dict.keys {
            let k = key.uppercased()
            #expect(!k.contains("RESEND"))
            #expect(!k.contains("SERVICE_ROLE"))
            #expect(!k.contains("SMTP"))
            #expect(!k.contains("WEBHOOK_SECRET"))
        }
    }
}

// MARK: - Client plumbing (URLProtocol) — public call attaches no JWT

@Suite("SupabaseClient edge plumbing", .serialized)
struct EdgeFunctionPlumbingTests {

    @Test func publicCallTargetsFunctionsPathWithApiKeyAndNoBearer() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responseStatus = 200
        StubURLProtocol.responseBody = json(["ok": true, "sent": true, "retryAfterSeconds": 60])

        let client = makeClient()
        let response = try await client.invokePublicFunction(
            "send-verification-email", body: SendEmailRequest(email: "a@b.com"), as: SendEmailResponse.self)
        #expect(response.sent == true)

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.path.hasSuffix("/functions/v1/send-verification-email") == true)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon-key-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil) // pre-sign-in: no JWT
    }

    @Test func structuredErrorSurfacesRetryAfter() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responseStatus = 429
        StubURLProtocol.responseBody = json(["ok": false, "error": "Too many requests.",
                                             "code": "rate_limited", "retryAfterSeconds": 17,
                                             "correlationId": "z9"])
        let client = makeClient()
        await #expect(throws: EdgeFunctionError.self) {
            _ = try await client.invokePublicFunction(
                "send-password-reset-email", body: SendEmailRequest(email: "a@b.com"), as: SendEmailResponse.self)
        }
        do {
            _ = try await client.invokePublicFunction(
                "send-password-reset-email", body: SendEmailRequest(email: "a@b.com"), as: SendEmailResponse.self)
        } catch let error as EdgeFunctionError {
            #expect(error.retryAfterSeconds == 17)
        }
    }

    private func makeClient() -> SupabaseClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let values = AppConfig.Values(
            supabaseURL: URL(string: "https://proj.supabase.co")!,
            supabaseAnonKey: "anon-key-test",
            publicSiteURL: URL(string: "https://aseatawaits.com")!)
        return SupabaseClient(config: values, urlSession: session)
    }
}

/// Captures the outgoing request and returns a canned response.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var responseStatus = 200
    nonisolated(unsafe) static var responseBody = Data()

    static func reset() { lastRequest = nil; responseStatus = 200; responseBody = Data() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseStatus,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
